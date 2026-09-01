import { writeFileSync } from 'node:fs'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { transferMediaInBrowser } from '../../helper/browser-runtime.mjs'

function fakeFrame(source) {
  return {
    async evaluate(_function, { start, endByte }) {
      const data = source.subarray(start, Math.min(source.length, endByte + 1))
      return {
        base64: data.toString('base64'),
        rangeStart: start,
        rangeEnd: start + data.length - 1,
        totalBytes: source.length,
      }
    },
  }
}

describe('isolated browser transfer', () => {
  it('writes bounded ranges into a completed file', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-browser-transfer-'))
    const source = Buffer.alloc(300 * 1024, 7)
    const progress = []
    const result = await transferMediaInBrowser({
      frame: fakeFrame(source),
      sourceUrl: 'https://media.test/video.mp4',
      durationMs: 90_000,
      outputFolder: folder,
      title: 'Episode 1',
      syncOutput: false,
      rangeSize: 128 * 1024,
      onProgress: (value) => progress.push(value),
    })
    expect(result.stopped).toBe(false)
    expect(await readFile(result.outputPath)).toEqual(source)
    expect(progress.at(-1)).toMatchObject({ bytesWritten: source.length, mediaTimeMs: 90_000 })
  })

  it('does not overwrite an existing output filename', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-browser-transfer-'))
    await writeFile(join(folder, 'Episode 1.mp4'), 'existing')
    const result = await transferMediaInBrowser({
      frame: fakeFrame(Buffer.alloc(128 * 1024, 4)),
      sourceUrl: 'https://media.test/video.mp4',
      outputFolder: folder,
      title: 'Episode 1',
      syncOutput: false,
      rangeSize: 128 * 1024,
    })
    expect(result.outputFilename).toBe('Episode 1 (2).mp4')
    expect(await readFile(join(folder, 'Episode 1.mp4'), 'utf8')).toBe('existing')
  })

  it('does not replace a destination created after reservation', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-browser-transfer-'))
    const destination = join(folder, 'Reservation race.mp4')
    await expect(transferMediaInBrowser({
      frame: fakeFrame(Buffer.alloc(128 * 1024, 5)),
      sourceUrl: 'https://media.test/video.mp4',
      outputFolder: folder,
      title: 'Reservation race',
      syncOutput: false,
      rangeSize: 128 * 1024,
      onOpen: () => writeFileSync(destination, 'created later'),
    })).rejects.toMatchObject({ code: 'EEXIST' })
    expect(await readFile(destination, 'utf8')).toBe('created later')
  })

  it('rejects a mismatched Content-Range response', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-browser-transfer-'))
    const frame = fakeFrame(Buffer.alloc(256 * 1024, 3))
    const originalEvaluate = frame.evaluate.bind(frame)
    frame.evaluate = async (...args) => ({ ...(await originalEvaluate(...args)), rangeStart: 99 })
    await expect(transferMediaInBrowser({
      frame,
      sourceUrl: 'https://media.test/video.mp4',
      outputFolder: folder,
      title: 'Corrupt range',
      syncOutput: false,
      rangeSize: 128 * 1024,
    })).rejects.toThrow('mismatched byte range')
  })

  it('rejects a range that extends beyond the declared total', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-browser-transfer-'))
    const frame = fakeFrame(Buffer.from([1, 2, 3, 4]))
    const originalEvaluate = frame.evaluate.bind(frame)
    frame.evaluate = async (...args) => ({ ...(await originalEvaluate(...args)), totalBytes: 1 })
    await expect(transferMediaInBrowser({
      frame,
      sourceUrl: 'https://media.test/video.mp4',
      outputFolder: folder,
      title: 'Bad total',
      syncOutput: false,
      rangeSize: 4,
    })).rejects.toThrow('invalid byte range')
  })

  it('keeps a partial file after stop', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-browser-transfer-'))
    const source = Buffer.alloc(300 * 1024, 9)
    const controller = new AbortController()
    const result = await transferMediaInBrowser({
      frame: fakeFrame(source),
      sourceUrl: 'https://media.test/video.mp4',
      outputFolder: folder,
      title: 'Episode 2',
      syncOutput: false,
      rangeSize: 128 * 1024,
      signal: controller.signal,
      onProgress: () => controller.abort(),
    })
    expect(result.stopped).toBe(true)
    expect(result.outputFilename).toBe('Episode 2-partial.mp4')
    expect((await readFile(result.outputPath)).length).toBe(128 * 1024)
  })
})
