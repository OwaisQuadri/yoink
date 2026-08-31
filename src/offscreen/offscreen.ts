import { FFmpeg } from '@ffmpeg/ffmpeg'
import { fetchFile, toBlobURL } from '@ffmpeg/util'
import type { ExtensionMessage } from '../lib/messages'
import { parseM3U8, pickBestVariant } from '../lib/m3u8'
import type { StreamCandidate } from '../lib/types'

const FFMPEG_CORE_VERSION = '0.12.10'
const FFMPEG_CORE_BASE = `https://unpkg.com/@ffmpeg/core@${FFMPEG_CORE_VERSION}/dist/esm`
let ffmpegPromise: Promise<FFmpeg> | null = null

async function getFFmpeg(): Promise<FFmpeg> {
  if (!ffmpegPromise) {
    ffmpegPromise = (async () => {
      const ffmpeg = new FFmpeg()
      await ffmpeg.load({
        coreURL: await toBlobURL(`${FFMPEG_CORE_BASE}/ffmpeg-core.js`, 'text/javascript'),
        wasmURL: await toBlobURL(`${FFMPEG_CORE_BASE}/ffmpeg-core.wasm`, 'application/wasm'),
      })
      return ffmpeg
    })()
  }
  return ffmpegPromise
}

chrome.runtime.onMessage.addListener((message: ExtensionMessage, _sender, sendResponse) => {
  if (message.type !== 'OFFSCREEN_RUN_JOB') return undefined
  void runJob(message.candidate)
    .then((blobUrl) => sendResponse({ ok: true, blobUrl }))
    .catch((error) => sendResponse({ ok: false, error: String(error?.message ?? error) }))
  return true
})

async function runJob(candidate: StreamCandidate): Promise<string> {
  if (candidate.kind === 'hls') return runHlsJob(candidate)
  throw new Error(`Unsupported stream kind: ${candidate.kind}`)
}

async function runHlsJob(candidate: StreamCandidate): Promise<string> {
  let manifestUrl = candidate.url
  let manifestText = await (await fetch(manifestUrl)).text()
  let parsed = parseM3U8(manifestText, manifestUrl)

  if (parsed.kind === 'master') {
    const best = pickBestVariant(parsed)
    if (!best) throw new Error('No playable variant found in master playlist')
    manifestUrl = best
    manifestText = await (await fetch(manifestUrl)).text()
    parsed = parseM3U8(manifestText, manifestUrl)
  }

  if (parsed.kind !== 'media') throw new Error('Failed to resolve media playlist')
  if (parsed.encrypted) {
    throw new Error('Stream is DRM/encrypted (EXT-X-KEY present) — unsupported by design')
  }
  if (parsed.segmentUrls.length === 0) throw new Error('No segments found in playlist')

  const ffmpeg = await getFFmpeg()
  const listFileLines: string[] = []
  for (let i = 0; i < parsed.segmentUrls.length; i++) {
    const segName = `seg${String(i).padStart(5, '0')}.ts`
    const data = await fetchFile(parsed.segmentUrls[i])
    await ffmpeg.writeFile(segName, data)
    listFileLines.push(`file '${segName}'`)
  }
  await ffmpeg.writeFile('list.txt', listFileLines.join('\n'))
  await ffmpeg.exec(['-f', 'concat', '-safe', '0', '-i', 'list.txt', '-c', 'copy', 'out.mp4'])

  const output = await ffmpeg.readFile('out.mp4')
  const blob = new Blob([new Uint8Array(output as Uint8Array).buffer], { type: 'video/mp4' })
  return URL.createObjectURL(blob)
}
