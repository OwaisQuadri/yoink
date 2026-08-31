import { chromium } from 'playwright'
import { open } from 'node:fs/promises'
import { basename } from 'node:path'
import { activateServer, classifyMediaRequest, enumerateServers, inspectPlayerFrame, verifyPlayerFrame } from './adapters/generic.mjs'
import { finalizeWithoutOverwrite, reserveOutputPaths, safeOutputName } from './acquisition.mjs'
import { rankMediaCandidates } from './ranking.mjs'

const SETTLE_MS = 1_500
const PLAYBACK_VERIFY_MS = 2_000

function sourceHeight(source) {
  return source.height ?? (Number.parseInt(source.label ?? '', 10) || 0)
}

function candidateSource(observation, requests) {
  const advertised = [...(observation.sources ?? [])]
    .sort((a, b) => sourceHeight(b) - sourceHeight(a)
      || (b.bitrate ?? 0) - (a.bitrate ?? 0))[0]
  const url = observation.playable && observation.currentSrc
    ? observation.currentSrc
    : advertised?.url
  if (url) {
    const matching = [...requests].reverse().find((request) => request.url.split('#')[0] === url.split('#')[0])
    return {
      url,
      kind: classifyMediaRequest({ url, contentType: advertised?.type })?.kind ?? 'mp4',
      headers: matching?.headers ?? {},
    }
  }
  const request = [...requests].reverse().map(classifyMediaRequest).find(Boolean)
  return request ? { url: request.url, kind: request.kind, headers: request.headers } : undefined
}

export function rankFrameObservations(observations) {
  return [...observations].sort((a, b) =>
    Number(Boolean(b.playable)) - Number(Boolean(a.playable))
    || (b.height ?? 0) - (a.height ?? 0)
    || sourceHeight(b.selectedQuality ?? {}) - sourceHeight(a.selectedQuality ?? {})
    || (b.selectedQuality?.bitrate ?? 0) - (a.selectedQuality?.bitrate ?? 0))
}

async function probeServer(page, context, server, onPhase) {
  const captured = []
  const onResponse = async (response) => {
    const request = response.request()
    const record = classifyMediaRequest({
      url: response.url(),
      contentType: response.headers()['content-type'] ?? '',
      headers: await request.allHeaders().catch(() => request.headers()),
    })
    if (record) captured.push(record)
  }
  page.on('response', onResponse)
  try {
    await activateServer(page, server)
    await page.waitForTimeout(SETTLE_MS)
    const initial = []
    for (const frame of page.frames()) {
      try {
        const observation = await inspectPlayerFrame(frame)
        if (observation.hasVideo || observation.qualities.length || observation.sources.length) {
          initial.push({ frame, observation })
        }
      } catch {
        // Frames can detach while a server is being activated.
      }
    }
    await page.waitForTimeout(PLAYBACK_VERIFY_MS)
    const verified = []
    for (const item of initial) {
      try {
        verified.push(await verifyPlayerFrame(item.frame, item.observation))
      } catch {
        // Ignore a frame replaced by the player during quality selection.
      }
    }
    const best = rankFrameObservations(verified)[0]
    if (!best) return undefined
    const source = candidateSource(best, captured)
    const cookies = source ? await context.cookies(source.url) : []
    if (source && cookies.length) {
      source.headers = { ...source.headers, cookie: cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ') }
    }
    const userAgent = await page.evaluate(() => navigator.userAgent)
    if (source) {
      source.headers = {
        'user-agent': userAgent,
        referer: best.frameUrl || page.url(),
        ...source.headers,
      }
    }
    const advertisedHeight = best.selectedQuality?.height
      ?? (Number.parseInt(best.selectedQuality?.label ?? '', 10) || 0)
    const verifiedHeight = best.playable ? best.height : 0
    onPhase?.({ detail: `${server.label}: ${verifiedHeight || advertisedHeight || 'unknown'}p` })
    return {
      id: server.id,
      server,
      serverOrder: server.order,
      playable: Boolean(source && (best.playable || best.durationMs || best.qualities.length > 0)),
      protected: Boolean(best.protected),
      verified: Boolean(best.playable && verifiedHeight > 0),
      height: verifiedHeight,
      advertisedHeight,
      width: best.width,
      bitrate: best.selectedQuality?.bitrate,
      hasEnglishSubtitles: Boolean(best.englishCaption),
      subtitleLabel: best.englishCaption?.label,
      durationMs: best.durationMs,
      frameUrl: best.frameUrl,
      direct: source?.kind === 'mp4' || source?.kind === 'webm',
      source,
    }
  } finally {
    page.off('response', onResponse)
  }
}

export async function transferMediaInBrowser({
  frame,
  sourceUrl,
  durationMs,
  outputFolder,
  title,
  onProgress,
  signal,
  onOpen,
  syncOutput = true,
  rangeSize = 4 * 1024 * 1024,
}) {
  const stem = safeOutputName(title)
  const extension = /\.webm(?:#|\?|$)/i.test(sourceUrl) ? 'webm' : 'mp4'
  const reservation = await reserveOutputPaths(outputFolder, stem, extension)
  const { partialPath, finalPath, stoppedPath } = reservation
  try {
  const file = await open(partialPath, 'wx', 0o600)
  onOpen?.({ partialPath, finalPath })
  let offset = 0
  let totalBytes
  const startedAt = Date.now()
  try {
    while (!signal?.aborted && (totalBytes === undefined || offset < totalBytes)) {
      const end = totalBytes === undefined
        ? offset + rangeSize - 1
        : Math.min(totalBytes - 1, offset + rangeSize - 1)
      const chunk = await frame.evaluate(async ({ url, start, endByte }) => {
        const response = await fetch(url, {
          cache: 'no-store',
          credentials: 'include',
          headers: { Range: `bytes=${start}-${endByte}` },
        })
        if (response.status !== 206) throw new Error(`Media server returned HTTP ${response.status}.`)
        const contentRange = response.headers.get('content-range') ?? ''
        const rangeMatch = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(contentRange)
        if (!rangeMatch) throw new Error('Media server returned an invalid Content-Range header.')
        const bytes = new Uint8Array(await response.arrayBuffer())
        let binary = ''
        for (let index = 0; index < bytes.length; index += 32_768) {
          binary += String.fromCharCode(...bytes.subarray(index, index + 32_768))
        }
        return {
          base64: btoa(binary),
          rangeStart: Number(rangeMatch[1]),
          rangeEnd: Number(rangeMatch[2]),
          totalBytes: Number(rangeMatch[3]),
        }
      }, { url: sourceUrl, start: offset, endByte: end })
      if (totalBytes !== undefined && chunk.totalBytes !== totalBytes) {
        throw new Error('Media size changed during transfer.')
      }
      totalBytes = chunk.totalBytes
      const data = Buffer.from(chunk.base64, 'base64')
      if (totalBytes <= 0 || chunk.rangeStart > chunk.rangeEnd || chunk.rangeEnd >= totalBytes) {
        throw new Error('Media server returned an invalid byte range.')
      }
      const expectedEnd = Math.min(end, totalBytes - 1)
      const expectedLength = chunk.rangeEnd - chunk.rangeStart + 1
      if (chunk.rangeStart !== offset || chunk.rangeEnd !== expectedEnd || data.length !== expectedLength) {
        throw new Error('Media server returned a mismatched byte range.')
      }
      await file.write(data, 0, data.length, offset)
      offset += data.length
      const elapsedSeconds = Math.max(0.001, (Date.now() - startedAt) / 1000)
      const ratio = totalBytes ? offset / totalBytes : 0
      const bytesPerSecond = offset / elapsedSeconds
      const mediaTimeMs = durationMs && ratio ? Math.round(durationMs * ratio) : undefined
      onProgress?.({
        bytesWritten: offset,
        bytesPerSecond,
        mediaTimeMs,
        durationMs,
        estimatedRemainingMs: totalBytes && bytesPerSecond
          ? Math.max(0, totalBytes - offset) / bytesPerSecond * 1000
          : undefined,
      })
      if (data.length === 0) break
    }
  } finally {
    if (syncOutput) await file.sync().catch(() => undefined)
    await file.close()
  }
  if (offset === 0) throw new Error('The browser did not return any media bytes.')
  if (!signal?.aborted && offset !== totalBytes) throw new Error('The browser transfer ended before the media was complete.')
  const destination = signal?.aborted ? stoppedPath : finalPath
  await finalizeWithoutOverwrite(partialPath, destination)
  return { outputPath: destination, outputFilename: basename(destination), stopped: Boolean(signal?.aborted) }
  } finally {
    await reservation.release()
  }
}

export async function discoverMedia({ sourceUrl, onPhase, signal }) {
  const browser = await chromium.launch({
    headless: true,
    args: ['--autoplay-policy=no-user-gesture-required', '--disable-background-timer-throttling'],
  })
  const context = await browser.newContext({ viewport: { width: 1920, height: 1080 } })
  const page = await context.newPage()
  try {
    onPhase?.({ phase: 'navigating', detail: 'Opening the episode in the isolated browser.' })
    await page.goto(sourceUrl, { waitUntil: 'domcontentloaded', timeout: 45_000 })
    await page.waitForTimeout(2_000)
    const servers = await enumerateServers(page)
    const candidates = []
    for (let index = 0; index < servers.length; index += 1) {
      if (signal?.aborted) throw new Error('The download was stopped.')
      onPhase?.({
        phase: 'probing',
        detail: `Checking ${servers[index].label} (${index + 1} of ${servers.length}).`,
      })
      try {
        const candidate = await probeServer(page, context, servers[index], onPhase)
        if (signal?.aborted) throw new Error('The download was stopped.')
        if (candidate) candidates.push(candidate)
      } catch (error) {
        if (signal?.aborted) throw error
        onPhase?.({
          phase: 'probing',
          detail: `${servers[index].label} failed: ${error instanceof Error ? error.message : String(error)}`,
        })
      }
    }
    const winner = rankMediaCandidates(candidates)[0]
    if (!winner) {
      const protectedCandidate = candidates.find((candidate) => candidate.protected)
      const error = new Error(protectedCandidate
        ? 'The available media is protected and cannot be downloaded.'
        : 'No playable media source was found on the available servers.')
      error.code = protectedCandidate ? 'PROTECTED_MEDIA' : 'NO_PLAYABLE_MEDIA'
      throw error
    }

    onPhase?.({ phase: 'probing', detail: `Refreshing ${winner.server.label} at the selected quality.` })
    const fresh = await probeServer(page, context, winner.server, onPhase).catch(() => undefined)
    const selected = fresh?.playable && !fresh.protected ? fresh : winner
    const transferFrame = page.frames().find((frame) => frame.url() === selected.frameUrl)
    return {
      source: selected.source,
      durationMs: selected.durationMs,
      browserTransfer: transferFrame && ['mp4', 'webm'].includes(selected.source.kind)
        ? (options) => transferMediaInBrowser({
            frame: transferFrame,
            sourceUrl: selected.source.url,
            durationMs: selected.durationMs,
            ...options,
          })
        : undefined,
      close: async () => {
        await context.close().catch(() => undefined)
        await browser.close().catch(() => undefined)
      },
      selection: {
        serverLabel: selected.server.label,
        qualityLabel: selected.height ? `${selected.height}p` : undefined,
        width: selected.width,
        height: selected.height,
        bitrate: selected.bitrate,
        subtitleLabel: selected.subtitleLabel,
        subtitleMode: selected.hasEnglishSubtitles ? 'selectable' : 'burned-in-or-none',
        mediaKind: selected.source.kind,
      },
    }
  } catch (error) {
    await context.close().catch(() => undefined)
    await browser.close().catch(() => undefined)
    throw error
  }
}
