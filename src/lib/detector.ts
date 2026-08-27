import type { StreamKind } from './types'

const EXT_MAP: Array<[RegExp, StreamKind]> = [
  [/\.m3u8(\?|$)/i, 'hls'],
  [/\.mpd(\?|$)/i, 'dash'],
  [/\.mp4(\?|$)/i, 'mp4'],
  [/\.m4v(\?|$)/i, 'mp4'],
  [/\.webm(\?|$)/i, 'webm'],
]

const CONTENT_TYPE_MAP: Array<[RegExp, StreamKind]> = [
  [/mpegurl/i, 'hls'],
  [/dash\+xml/i, 'dash'],
  [/video\/mp4/i, 'mp4'],
  [/video\/webm/i, 'webm'],
]

/** Resource types worth inspecting; skips images, fonts, css, scripts, etc. */
export const RELEVANT_RESOURCE_TYPES = new Set([
  'media',
  'xmlhttprequest',
  'other',
  'object',
])

export function kindFromUrl(url: string): StreamKind | null {
  for (const [re, kind] of EXT_MAP) {
    if (re.test(url)) return kind
  }
  return null
}

export function kindFromContentType(contentType: string | null | undefined): StreamKind | null {
  if (!contentType) return null
  for (const [re, kind] of CONTENT_TYPE_MAP) {
    if (re.test(contentType)) return kind
  }
  return null
}

/**
 * Last-resort classification for requests the browser itself tagged as a
 * 'media' resource (i.e. a <video>/<audio> element's own network fetch)
 * whose Content-Type/extension we don't recognize. Surfacing these as
 * 'unknown' rather than silently dropping them matters most on sites that
 * serve real media through opaque/obfuscated URLs and non-standard
 * Content-Type headers (octet-stream, empty, etc.) — better to show the
 * user "something was detected, format unclear" than nothing at all.
 * Deliberately gated on resourceType === 'media' so it doesn't turn every
 * octet-stream response on a page (fonts, wasm, protobuf, ...) into a
 * false-positive candidate.
 */
export function kindFromMediaResourceFallback(
  resourceType: string,
  contentType: string | null | undefined
): StreamKind | null {
  if (resourceType !== 'media') return null
  const ct = (contentType ?? '').toLowerCase()
  if (ct === '' || ct.includes('octet-stream')) return 'unknown'
  return null
}

/** Simple, dependency-free string hash for stable candidate ids. */
export function hashUrl(url: string): string {
  let h = 5381
  for (let i = 0; i < url.length; i++) {
    h = (h * 33) ^ url.charCodeAt(i)
  }
  return (h >>> 0).toString(36)
}

function stripExtension(name: string): string {
  const idx = name.lastIndexOf('.')
  return idx > 0 ? name.slice(0, idx) : name
}

/**
 * Extracts a human-readable filename from a Content-Disposition header,
 * handling both the plain `filename="..."` form and the RFC 5987 extended
 * `filename*=UTF-8''...` form (used for non-ASCII names). Returns the name
 * without its extension, or null if nothing usable is present.
 */
export function filenameFromContentDisposition(disposition: string | null | undefined): string | null {
  if (!disposition) return null
  const parts = disposition.split(';').map((p) => p.trim())

  for (const part of parts) {
    const lower = part.toLowerCase()
    if (lower.startsWith("filename*=")) {
      const value = part.slice('filename*='.length)
      const encoded = value.split("''").pop()
      if (encoded) {
        try {
          const decoded = decodeURIComponent(encoded)
          if (decoded) return stripExtension(decoded)
        } catch {
          // malformed percent-encoding; fall through to the plain form below
        }
      }
    }
  }

  for (const part of parts) {
    const lower = part.toLowerCase()
    if (lower.startsWith('filename=')) {
      const raw = part.slice('filename='.length).trim()
      const name = raw.replace(/^["']|["']$/g, '')
      if (name) return stripExtension(name)
    }
  }

  return null
}

/**
 * Known "detail page" URL patterns rewritten to their direct-download
 * equivalents, so a page URL a user might reasonably land on doesn't get
 * treated as unsupported just because it's HTML rather than the media
 * itself. Extend this table as more patterns are discovered.
 */
const DIRECT_URL_REWRITES: Array<{ host: RegExp; rewrite: (url: URL) => URL | null }> = [
  {
    // archive.org: /details/IDENTIFIER/FILE -> /download/IDENTIFIER/FILE
    host: /^(www\.)?archive\.org$/i,
    rewrite: (url) => {
      if (!url.pathname.startsWith('/details/')) return null
      const rewritten = new URL(url.toString())
      rewritten.pathname = '/download/' + url.pathname.slice('/details/'.length)
      return rewritten
    },
  },
]

export function resolveKnownDirectUrl(rawUrl: string): string {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return rawUrl
  }
  for (const { host, rewrite } of DIRECT_URL_REWRITES) {
    if (host.test(url.host)) {
      const rewritten = rewrite(url)
      if (rewritten) return rewritten.toString()
    }
  }
  return rawUrl
}

/**
 * Hosts observed, during hands-on debugging of ad-supported "free\ streaming"
 * embed sites, to be ad/popunder/tracking infrastructure rather than actual
 * media hosts — despite sometimes serving real video files themselves (ad
 * networks serve video creatives too). Candidates whose *initiating frame*
 * is one of these are filtered out, since a real video mp4 is still a false
 * positive if it's an advertisement rather than the page's actual content.
 * This is a denylist of infrastructure, not a guess at content — extend it
 * as new ad networks are identified, but keep it conservative: a false
 * negative here just means "one more candidate to manually ignore", while a
 * false positive silently hides real content.
 */
const KNOWN_AD_INFRASTRUCTURE_HOSTS = [
  /(^|\.)rufiiguta\.com$/i,
  /(^|\.)bvtpk\.com$/i,
  /(^|\.)luugy\.com$/i,
  /(^|\.)sssrr\.org$/i,
]

export function isKnownAdInfrastructureUrl(url: string | null | undefined): boolean {
  if (!url) return false
  let host: string
  try {
    host = new URL(url).host
  } catch {
    return false
  }
  return KNOWN_AD_INFRASTRUCTURE_HOSTS.some((re) => re.test(host))
}
