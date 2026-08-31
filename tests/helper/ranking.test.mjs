import { describe, expect, it } from 'vitest'
import { rankFrameObservations } from '../../helper/browser-runtime.mjs'
import { rankMediaCandidates } from '../../helper/ranking.mjs'

describe('headless media ranking', () => {
  it('prefers a decoded frame over a higher ignored label', () => {
    const ranked = rankFrameObservations([
      { playable: false, height: 0, selectedQuality: { label: '1080p' } },
      { playable: true, height: 720, selectedQuality: { label: '720p' } },
    ])
    expect(ranked[0].height).toBe(720)
  })

  it('prefers verified resolution over subtitles and bitrate', () => {
    const ranked = rankMediaCandidates([
      { id: 'english-720', playable: true, protected: false, height: 720, bitrate: 5_000_000, hasEnglishSubtitles: true },
      { id: 'plain-1080', playable: true, protected: false, height: 1080, bitrate: 3_000_000, hasEnglishSubtitles: false },
      { id: 'fast-720', playable: true, protected: false, height: 720, bitrate: 8_000_000, hasEnglishSubtitles: false },
    ])
    expect(ranked.map((candidate) => candidate.id)).toEqual(['plain-1080', 'fast-720', 'english-720'])
  })

  it('prefers decoded quality over a higher ignored player label', () => {
    const ranked = rankMediaCandidates([
      { id: 'ignored-1080', playable: true, protected: false, verified: false, height: 0, advertisedHeight: 1080 },
      { id: 'decoded-720', playable: true, protected: false, verified: true, height: 720, advertisedHeight: 720 },
    ])
    expect(ranked[0].id).toBe('decoded-720')
  })

  it('prefers a direct source when verified quality is tied', () => {
    const ranked = rankMediaCandidates([
      { id: 'hls', playable: true, protected: false, height: 720, bitrate: 8_000_000, direct: false },
      { id: 'mp4', playable: true, protected: false, height: 720, bitrate: 3_000_000, direct: true },
    ])
    expect(ranked[0].id).toBe('mp4')
  })

  it('rejects protected and unplayable candidates', () => {
    expect(rankMediaCandidates([
      { id: 'drm', playable: true, protected: true, height: 2160 },
      { id: 'dead', playable: false, protected: false, height: 2160 },
    ])).toEqual([])
  })
})
