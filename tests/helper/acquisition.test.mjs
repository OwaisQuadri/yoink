import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseProgressChunk, reserveOutputPaths, safeOutputName } from '../../helper/acquisition.mjs'

describe('ffmpeg acquisition helpers', () => {
  it('parses machine-readable progress across chunks', () => {
    const state = { remainder: '', fields: {} }
    expect(parseProgressChunk(state, 'out_time_ms=12000000\ntotal_size=1048')).toBeNull()
    const progress = parseProgressChunk(state, '576\nspeed=2.5x\nprogress=continue\n')
    expect(progress).toEqual({ mediaTimeMs: 12000, bytesWritten: 1048576, speed: 2.5, done: false })
  })

  it('reserves distinct names for concurrent transfers', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'yoink-output-reservation-'))
    const [first, second] = await Promise.all([
      reserveOutputPaths(folder, 'Episode', 'mp4'),
      reserveOutputPaths(folder, 'Episode', 'mp4'),
    ])
    expect(first.finalPath).not.toBe(second.finalPath)
    await Promise.all([first.release(), second.release()])
  })

  it('reports end progress and sanitizes filenames', () => {
    const state = { remainder: '', fields: {} }
    expect(parseProgressChunk(state, 'out_time_us=2500000\ntotal_size=20\nspeed=N/A\nprogress=end\n')).toEqual({
      mediaTimeMs: 2500,
      bytesWritten: 20,
      speed: undefined,
      done: true,
    })
    expect(safeOutputName('  Episode: 1 / Finale?!  ')).toBe('Episode 1 Finale')
  })
})
