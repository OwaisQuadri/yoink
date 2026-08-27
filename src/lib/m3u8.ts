/**
 * Minimal, dependency-free HLS (.m3u8) parser.
 * Supports: master playlists (variant selection by bandwidth) and
 * media playlists (segment URI extraction). Detects EXT-X-KEY as a
 * DRM/encryption signal so callers can bail out per project scope
 * (yoink does not attempt to decrypt protected streams).
 */

export interface MediaPlaylist {
  kind: 'media'
  segmentUrls: string[]
  encrypted: boolean
}

export interface MasterPlaylist {
  kind: 'master'
  variants: Array<{ url: string; bandwidth: number }>
}

export type ParsedPlaylist = MediaPlaylist | MasterPlaylist

function resolveUrl(base: string, ref: string): string {
  try {
    return new URL(ref, base).toString()
  } catch {
    return ref
  }
}

export function parseM3U8(text: string, baseUrl: string): ParsedPlaylist {
  const lines = text.split(/\r?\n/).map((l) => l.trim())
  const isMaster = lines.some((l) => l.startsWith('#EXT-X-STREAM-INF'))

  if (isMaster) {
    const variants: MasterPlaylist['variants'] = []
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue
      const bwMatch = line.match(/BANDWIDTH=(\d+)/i)
      const bandwidth = bwMatch ? parseInt(bwMatch[1], 10) : 0
      const uriLine = lines.slice(i + 1).find((l) => l && !l.startsWith('#'))
      if (uriLine) {
        variants.push({ url: resolveUrl(baseUrl, uriLine), bandwidth })
      }
    }
    return { kind: 'master', variants }
  }

  let encrypted = false
  const segmentUrls: string[] = []
  for (const line of lines) {
    if (line.startsWith('#EXT-X-KEY')) {
      if (!/METHOD=NONE/i.test(line)) encrypted = true
    } else if (line && !line.startsWith('#')) {
      segmentUrls.push(resolveUrl(baseUrl, line))
    }
  }
  return { kind: 'media', segmentUrls, encrypted }
}

/** Picks the highest-bandwidth variant from a master playlist. */
export function pickBestVariant(master: MasterPlaylist): string | null {
  if (master.variants.length === 0) return null
  return master.variants.reduce((best, v) => (v.bandwidth > best.bandwidth ? v : best)).url
}
