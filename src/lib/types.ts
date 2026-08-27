export type StreamKind = 'mp4' | 'webm' | 'hls' | 'dash' | 'unknown'

export interface StreamCandidate {
  /** Stable id: hash of url */
  id: string
  url: string
  kind: StreamKind
  tabId: number
  frameId: number
  /** Page title at time of detection, best-effort */
  pageTitle?: string
  /** Filename derived from a Content-Disposition response header, if present */
  suggestedFilename?: string
  /** Origin the request was made from, for Referer/Origin header replay */
  initiator?: string
  contentType?: string
  firstSeen: number
  /** Set once we've inspected an HLS/DASH manifest and found ENCRYPTED content */
  drmSuspected?: boolean
}

export interface DownloadJob {
  candidate: StreamCandidate
  suggestedFilename: string
}

export type DownloadStatus =
  | { state: 'idle' }
  | { state: 'fetching-manifest' }
  | { state: 'downloading-segments'; done: number; total: number }
  | { state: 'remuxing' }
  | { state: 'saving' }
  | { state: 'done'; filename: string }
  | { state: 'error'; message: string }
