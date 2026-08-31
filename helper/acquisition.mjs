import { spawn } from 'node:child_process'
import { access, link, open, rm, stat } from 'node:fs/promises'
import { constants } from 'node:fs'
import { basename, join } from 'node:path'

export function parseProgressChunk(state, chunk) {
  const lines = `${state.remainder}${chunk}`.split(/\r?\n/)
  state.remainder = lines.pop() ?? ''
  for (const line of lines) {
    const separator = line.indexOf('=')
    if (separator < 1) continue
    const key = line.slice(0, separator)
    const value = line.slice(separator + 1)
    if (key === 'progress') {
      const rawTime = state.fields.out_time_us ?? state.fields.out_time_ms
      const mediaTimeMs = Number.isFinite(Number(rawTime)) ? Math.round(Number(rawTime) / 1000) : undefined
      const bytesWritten = Number.isFinite(Number(state.fields.total_size)) ? Number(state.fields.total_size) : 0
      const speedMatch = /([0-9.]+)x/.exec(state.fields.speed ?? '')
      const result = {
        mediaTimeMs,
        bytesWritten,
        speed: speedMatch ? Number(speedMatch[1]) : undefined,
        done: value === 'end',
      }
      state.fields = {}
      return result
    }
    state.fields[key] = value
  }
  return null
}

export function safeOutputName(value) {
  return value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, ' ')
    .replace(/[^\p{L}\p{N}._ -]+/gu, '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^\.+|[. ]+$/g, '')
    .slice(0, 120) || 'yoink-video'
}

export async function findExecutable(candidates) {
  for (const candidate of candidates) {
    try {
      await access(candidate, constants.X_OK)
      return candidate
    } catch {
      // Try the next known location.
    }
  }
  return undefined
}

export async function reserveOutputPaths(outputFolder, stem, extension) {
  for (let index = 1; index < 10_000; index += 1) {
    const suffix = index === 1 ? '' : ` (${index})`
    const base = join(outputFolder, `${stem}${suffix}`)
    const paths = {
      partialPath: `${base}.partial.${extension}`,
      finalPath: `${base}.${extension}`,
      stoppedPath: `${base}-partial.${extension}`,
    }
    const occupied = await Promise.all(Object.values(paths).map((path) =>
      access(path).then(() => true, () => false)))
    if (occupied.some(Boolean)) continue
    const lockPath = `${base}.yoink.lock`
    try {
      const lock = await open(lockPath, 'wx', 0o600)
      return {
        ...paths,
        release: async () => {
          await lock.close().catch(() => undefined)
          await rm(lockPath, { force: true })
        },
      }
    } catch (error) {
      if (error && typeof error === 'object' && error.code === 'EEXIST') continue
      throw error
    }
  }
  throw new Error('Could not reserve an unused output filename.')
}

export async function finalizeWithoutOverwrite(partialPath, destination) {
  await link(partialPath, destination)
  await rm(partialPath)
}

function headersArgument(headers) {
  return Object.entries(headers ?? {})
    .filter(([name]) => /^(user-agent|referer|origin|cookie|authorization)$/i.test(name))
    .map(([name, value]) => `${name}: ${String(value).replace(/[\r\n]/g, '')}`)
    .join('\r\n')
}

export async function acquireMedia({
  ffmpegPath,
  source,
  outputFolder,
  title,
  durationMs,
  onProgress,
  onSpawn,
  signal,
}) {
  const stem = safeOutputName(title)
  const reservation = await reserveOutputPaths(outputFolder, stem, 'mp4')
  const { partialPath, finalPath, stoppedPath } = reservation
  try {
    const headers = headersArgument(source.headers)
    const args = ['-hide_banner', '-loglevel', 'warning', '-nostdin', '-n']
    if (headers) args.push('-headers', `${headers}\r\n`)
    args.push(
      '-i', source.url,
      '-map', '0:v:0',
      '-map', '0:a:0?',
      '-map', '0:s:m:language:eng?',
      '-c:v', 'copy',
      '-c:a', 'copy',
      '-c:s', 'mov_text',
      '-movflags', '+faststart',
      '-progress', 'pipe:1',
      partialPath,
    )

    const child = spawn(ffmpegPath, args, { stdio: ['ignore', 'pipe', 'pipe'] })
    onSpawn?.(child, { partialPath, finalPath })
    const parser = { remainder: '', fields: {} }
    let stderr = ''
    const startedAt = Date.now()
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      const parsed = parseProgressChunk(parser, chunk)
      if (!parsed) return
      const elapsedSeconds = Math.max(0.001, (Date.now() - startedAt) / 1000)
      const bytesPerSecond = parsed.bytesWritten / elapsedSeconds
      const estimatedRemainingMs = durationMs && parsed.mediaTimeMs && bytesPerSecond > 0
        ? Math.max(0, durationMs - parsed.mediaTimeMs) / Math.max(parsed.speed ?? 1, 0.01)
        : undefined
      onProgress?.({ ...parsed, bytesPerSecond, estimatedRemainingMs })
    })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => {
      stderr = `${stderr}${chunk}`.slice(-16_384)
    })
    if (signal) {
      if (signal.aborted) child.kill('SIGINT')
      else signal.addEventListener('abort', () => child.kill('SIGINT'), { once: true })
    }

    const result = await new Promise((resolve) => {
      child.once('error', (error) => resolve({ code: -1, error }))
      child.once('close', (code, termSignal) => resolve({ code, termSignal }))
    })
    if (result.error) throw result.error

    const outputStat = await stat(partialPath).catch(() => undefined)
    if (!outputStat || outputStat.size === 0) {
      throw new Error(stderr.trim() || `ffmpeg ended with code ${result.code}.`)
    }
    if (result.code !== 0 && !signal?.aborted) {
      throw new Error(stderr.trim() || `ffmpeg ended with code ${result.code}.`)
    }

    const destination = signal?.aborted ? stoppedPath : finalPath
    await finalizeWithoutOverwrite(partialPath, destination)
    return { outputPath: destination, outputFilename: basename(destination), stopped: Boolean(signal?.aborted) }
  } finally {
    await reservation.release()
  }
}
