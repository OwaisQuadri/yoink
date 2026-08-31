import type {
  DownloadStatus,
  HelperActionResponse,
  HelperJobSnapshot,
  StreamCandidate,
} from './types'

// Content script -> background.
export interface CandidateFoundMsg {
  type: 'CANDIDATE_FOUND'
  candidate: Omit<StreamCandidate, 'id' | 'tabId' | 'frameId' | 'firstSeen'>
}

// Popup -> background.
export interface GetCandidatesMsg {
  type: 'GET_CANDIDATES'
  tabId: number
}

export interface StartDownloadMsg {
  type: 'START_DOWNLOAD'
  candidateId: string
  tabId: number
}

export interface GetDownloadStatusMsg {
  type: 'GET_DOWNLOAD_STATUS'
  candidateId: string
}

export interface HelperPingMsg {
  type: 'HELPER_PING'
}

export interface HelperChooseFolderMsg {
  type: 'HELPER_CHOOSE_FOLDER'
}

export interface HelperStartMsg {
  type: 'HELPER_START'
  sourceUrl: string
  sourceTitle: string
}

export interface HelperStatusMsg {
  type: 'HELPER_STATUS'
  jobId?: string
}

export interface HelperStopMsg {
  type: 'HELPER_STOP'
  jobId: string
}

export interface HelperRevealMsg {
  type: 'HELPER_REVEAL'
  jobId: string
}

export interface DebugDumpAllMsg {
  type: 'DEBUG_DUMP_ALL'
}

export interface DebugClickAtMsg {
  type: 'DEBUG_CLICK_AT'
  x: number
  y: number
}

export interface CandidatesListResp {
  candidates: StreamCandidate[]
}

export type HelperActionResp = HelperActionResponse

// Background <-> offscreen direct-stream downloads.
export interface OffscreenRunJobMsg {
  type: 'OFFSCREEN_RUN_JOB'
  candidate: StreamCandidate
  filename: string
}

export interface OffscreenStatusMsg {
  type: 'OFFSCREEN_STATUS'
  candidateId: string
  status: DownloadStatus
}

export type ExtensionMessage =
  | CandidateFoundMsg
  | GetCandidatesMsg
  | StartDownloadMsg
  | GetDownloadStatusMsg
  | HelperPingMsg
  | HelperChooseFolderMsg
  | HelperStartMsg
  | HelperStatusMsg
  | HelperStopMsg
  | HelperRevealMsg
  | DebugDumpAllMsg
  | DebugClickAtMsg
  | OffscreenRunJobMsg
  | OffscreenStatusMsg

export interface HelperCache {
  lastJobId?: string
  lastRevision?: number
  lastSnapshot?: HelperJobSnapshot
}
