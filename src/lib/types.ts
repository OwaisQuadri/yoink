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

export type HelperJobPhase =
  | 'idle'
  | 'validating'
  | 'queued'
  | 'launching-browser'
  | 'navigating'
  | 'discovering'
  | 'probing'
  | 'acquiring'
  | 'stopping'
  | 'finalizing'
  | 'completed'
  | 'cancelled'
  | 'failed'
  | 'interrupted'

export interface HelperFolder {
  configured: boolean
  name?: string
  writable?: boolean
}

export interface HelperSelection {
  serverLabel?: string
  qualityLabel?: string
  width?: number
  height?: number
  bitrate?: number
  subtitleLabel?: string
  subtitleMode: 'selectable' | 'burned-in-or-none'
  mediaKind: 'mp4' | 'webm' | 'hls' | 'dash'
}

export interface HelperProgress {
  durationMs?: number
  mediaTimeMs?: number
  bytesWritten: number
  bytesPerSecond?: number
  estimatedRemainingMs?: number
}

export type HelperErrorCode =
  | 'HELPER_NOT_INSTALLED'
  | 'HELPER_OFFLINE'
  | 'FOLDER_NOT_CONFIGURED'
  | 'FOLDER_NOT_WRITABLE'
  | 'BROWSER_UNAVAILABLE'
  | 'FFMPEG_UNAVAILABLE'
  | 'NO_PLAYABLE_MEDIA'
  | 'PROTECTED_MEDIA'
  | 'AUTH_EXPIRED'
  | 'DOWNLOAD_ACTIVE'
  | 'DOWNLOAD_FAILED'
  | 'FINALIZE_FAILED'
  | 'INVALID_REQUEST'

export interface HelperJobSnapshot {
  protocolVersion: 1
  revision: number
  jobId: string
  phase: HelperJobPhase
  sourceUrl: string
  sourceTitle: string
  /** The Chrome tab this job was started from; scopes popup status per site. */
  tabId?: number
  selection?: HelperSelection
  progress: HelperProgress
  folder?: HelperFolder
  outputFilename?: string
  outputPath?: string
  warning?: string
  error?: { code: HelperErrorCode; message: string }
  createdAt: number
  updatedAt: number
}

export interface HelperHealth {
  helperVersion: string
  folder: HelperFolder
}

export interface HelperActionResponse {
  ok: boolean
  snapshot?: HelperJobSnapshot
  health?: HelperHealth
  folder?: HelperFolder
  error?: { code: HelperErrorCode; message: string }
}
