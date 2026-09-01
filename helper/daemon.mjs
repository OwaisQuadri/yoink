#!/usr/bin/env node
import { createServer } from 'node:net'
import { chmod, rm } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { acquireMedia, findExecutable } from './acquisition.mjs'
import { discoverMedia } from './browser-runtime.mjs'
import { JOBS_ROOT, SOCKET_PATH, ensureAppRoot, readConfig } from './config.mjs'
import { chooseFolder, folderMetadata } from './folder-picker.mjs'
import { JobStore } from './job-store.mjs'
import { parseRequest, response } from './protocol.mjs'

const ACTIVE_PHASES = new Set([
  'validating', 'queued', 'launching-browser', 'navigating', 'discovering',
  'probing', 'acquiring', 'stopping', 'finalizing',
])
const store = new JobStore(JOBS_ROOT)
const controllers = new Map()
const updateQueues = new Map()
const sockets = new Set()
let startInProgress = false
let closing = false

function helperError(code, message) {
  const error = new Error(message)
  error.code = code
  return error
}

function errorPayload(error) {
  return {
    code: typeof error?.code === 'string' ? error.code : 'DOWNLOAD_FAILED',
    message: error instanceof Error ? error.message : String(error),
  }
}

function queueUpdate(jobId, patch) {
  const previous = updateQueues.get(jobId) ?? Promise.resolve()
  const next = previous.then(() => store.update(jobId, patch))
  updateQueues.set(jobId, next.catch(() => undefined))
  return next
}

async function currentSnapshot(jobId) {
  return jobId ? store.read(jobId) : store.latest()
}

async function runJob(jobId, request) {
  const controller = new AbortController()
  controllers.set(jobId, controller)
  let lastProgressAt = 0
  let discovered
  try {
    await queueUpdate(jobId, { phase: 'launching-browser' })
    discovered = await discoverMedia({
      sourceUrl: request.sourceUrl,
      signal: controller.signal,
      onPhase: ({ phase, detail }) => {
        void queueUpdate(jobId, { phase: phase ?? 'discovering', warning: detail })
      },
    })
    if (controller.signal.aborted) throw helperError('CANCELLED', 'The download was stopped.')

    const config = await readConfig()
    if (!config.outputFolder) throw helperError('FOLDER_NOT_CONFIGURED', 'Choose a download folder first.')
    const ffmpegPath = await findExecutable([
      process.env.YOINK_FFMPEG,
      '/opt/homebrew/bin/ffmpeg',
      '/usr/local/bin/ffmpeg',
      '/usr/bin/ffmpeg',
    ].filter(Boolean))
    if (!ffmpegPath) throw helperError('FFMPEG_UNAVAILABLE', 'Install ffmpeg before starting a download.')

    await queueUpdate(jobId, {
      phase: 'acquiring',
      selection: discovered.selection,
      warning: undefined,
      progress: { durationMs: discovered.durationMs, bytesWritten: 0, mediaTimeMs: 0 },
    })
    const progress = (value) => {
      const now = Date.now()
      if (!value.done && now - lastProgressAt < 500) return
      lastProgressAt = now
      void queueUpdate(jobId, { progress: value })
    }
    const ffmpegTransfer = () => acquireMedia({
      ffmpegPath,
      source: discovered.source,
      outputFolder: config.outputFolder,
      title: request.sourceTitle,
      durationMs: discovered.durationMs,
      signal: controller.signal,
      onSpawn: (child, paths) => {
        void queueUpdate(jobId, {
          process: { kind: 'ffmpeg', pid: child.pid, startedAt: Date.now() },
          partialOutputPath: paths.partialPath,
        })
      },
      onProgress: progress,
    })
    let acquired
    if (discovered.browserTransfer) {
      try {
        acquired = await discovered.browserTransfer({
          outputFolder: config.outputFolder,
          title: request.sourceTitle,
          signal: controller.signal,
          onOpen: (paths) => {
            void queueUpdate(jobId, { partialOutputPath: paths.partialPath })
          },
          onProgress: progress,
        })
      } catch (error) {
        if (controller.signal.aborted) throw error
        await queueUpdate(jobId, { warning: 'Browser transfer failed. Trying ffmpeg.' })
        acquired = await ffmpegTransfer()
      }
    } else {
      acquired = await ffmpegTransfer()
    }
    await queueUpdate(jobId, { phase: 'finalizing' })
    const completed = await queueUpdate(jobId, {
      phase: acquired.stopped ? 'cancelled' : 'completed',
      process: undefined,
      outputPath: acquired.outputPath,
      outputFilename: acquired.outputFilename,
      finalizedOutputPath: acquired.outputPath,
    })
    return completed
  } catch (error) {
    const current = await currentSnapshot(jobId)
    const stopped = controller.signal.aborted || error?.code === 'CANCELLED'
    return queueUpdate(jobId, {
      phase: stopped ? 'cancelled' : 'failed',
      process: undefined,
      error: stopped ? undefined : errorPayload(error),
      warning: stopped ? 'The download was stopped.' : current?.warning,
    })
  } finally {
    await discovered?.close?.()
    controllers.delete(jobId)
    updateQueues.delete(jobId)
  }
}

async function startJob(request) {
  if (startInProgress) throw helperError('DOWNLOAD_ACTIVE', 'Another background download is already starting.')
  startInProgress = true
  try {
  const latest = await store.latest()
  if (latest?.idempotencyKey === request.idempotencyKey) return latest
  if (latest && ACTIVE_PHASES.has(latest.phase)) {
    throw helperError('DOWNLOAD_ACTIVE', 'Another background download is already active.')
  }
  const folder = await folderMetadata()
  if (!folder.configured) throw helperError('FOLDER_NOT_CONFIGURED', 'Choose a download folder first.')
  if (!folder.writable) throw helperError('FOLDER_NOT_WRITABLE', 'The selected download folder is not writable.')

  const jobId = randomUUID()
  const snapshot = await store.create({
    jobId,
    idempotencyKey: request.idempotencyKey,
    phase: 'queued',
    sourceUrl: request.sourceUrl,
    sourceTitle: request.sourceTitle,
    folder,
    progress: { bytesWritten: 0 },
  })
  void runJob(jobId, request)
  return snapshot
  } finally {
    startInProgress = false
  }
}

async function handleRequest(raw) {
  let request
  try {
    request = parseRequest(raw)
    if (request.op === 'ping') {
      return response(request.id, { result: { helperVersion: '0.1.0', folder: await folderMetadata() } })
    }
    if (request.op === 'shutdown') {
      if (controllers.size > 0 || startInProgress) {
        throw helperError('DOWNLOAD_ACTIVE', 'Stop the active download before uninstalling or upgrading the helper.')
      }
      setTimeout(closeDaemon, 50)
      return response(request.id, { result: { shuttingDown: true } })
    }
    if (request.op === 'choose-folder') {
      return response(request.id, { result: { folder: await chooseFolder() } })
    }
    if (request.op === 'start') {
      const snapshot = await startJob(request)
      return response(request.id, { snapshot, revision: snapshot.revision })
    }
    if (request.op === 'status') {
      const snapshot = await currentSnapshot(request.jobId)
      return response(request.id, { snapshot, revision: snapshot?.revision ?? 0 })
    }
    if (request.op === 'stop') {
      const snapshot = await store.read(request.jobId)
      if (!snapshot) throw helperError('INVALID_REQUEST', 'Job not found.')
      controllers.get(request.jobId)?.abort()
      const stopping = ACTIVE_PHASES.has(snapshot.phase)
        ? await queueUpdate(request.jobId, { phase: 'stopping', stopRequested: true })
        : snapshot
      return response(request.id, { snapshot: stopping, revision: stopping.revision })
    }
    const snapshot = await store.read(request.jobId)
    if (!snapshot?.outputPath) throw helperError('INVALID_REQUEST', 'The job has no completed output file.')
    spawn('/usr/bin/open', ['-R', snapshot.outputPath], { detached: true, stdio: 'ignore' }).unref()
    return response(request.id, { snapshot, revision: snapshot.revision })
  } catch (error) {
    return response(raw?.id ?? 'invalid', { error: errorPayload(error) })
  }
}

async function recoverInterruptedJob() {
  const latest = await store.latest()
  if (latest && ACTIVE_PHASES.has(latest.phase)) {
    await store.update(latest.jobId, {
      phase: 'interrupted',
      process: undefined,
      error: { code: 'HELPER_OFFLINE', message: 'The helper restarted before the download completed.' },
    })
  }
}

await ensureAppRoot()
await rm(SOCKET_PATH, { force: true })
await recoverInterruptedJob()
const server = createServer((socket) => {
  sockets.add(socket)
  socket.once('close', () => sockets.delete(socket))
  socket.setEncoding('utf8')
  let buffer = ''
  socket.on('data', (chunk) => {
    buffer += chunk
    if (buffer.length > 1_048_576) {
      socket.destroy(new Error('Request too large.'))
      return
    }
    const newline = buffer.indexOf('\n')
    if (newline < 0) return
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    void (async () => {
      let raw
      try {
        raw = JSON.parse(line)
      } catch {
        raw = { id: 'invalid' }
      }
      socket.end(`${JSON.stringify(await handleRequest(raw))}\n`)
    })()
  })
})
server.listen(SOCKET_PATH, async () => {
  await chmod(SOCKET_PATH, 0o600)
  process.stderr.write(`Yoink helper listening at ${SOCKET_PATH}\n`)
})

function closeDaemon() {
  if (closing) return
  closing = true
  for (const socket of sockets) socket.destroy()
  server.close(() => {
    void rm(SOCKET_PATH, { force: true }).finally(() => process.exit(0))
  })
}

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, closeDaemon)
}
