import type { StreamCandidate, DownloadStatus } from './types'

// --- content script -> background ---
export interface CandidateFoundMsg {
  type: 'CANDIDATE_FOUND'
  candidate: Omit<StreamCandidate, 'id' | 'tabId' | 'frameId' | 'firstSeen'>
}

// --- popup -> background ---
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
export interface DebugDumpAllMsg {
  type: 'DEBUG_DUMP_ALL'
}
export interface DebugClickAtMsg {
  type: 'DEBUG_CLICK_AT'
  x: number
  y: number
}

// --- background -> popup (response) ---
export interface CandidatesListResp {
  candidates: StreamCandidate[]
}

// --- background <-> offscreen ---
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
  | DebugDumpAllMsg
  | DebugClickAtMsg
  | OffscreenRunJobMsg
  | OffscreenStatusMsg
