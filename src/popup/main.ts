import type {
  CandidatesListResp,
  GetCandidatesMsg,
  HelperActionResp,
  StartDownloadMsg,
} from '../lib/messages'
import type { HelperFolder, HelperJobSnapshot, StreamCandidate } from '../lib/types'

const ACTIVE_PHASES = new Set([
  'validating', 'queued', 'launching-browser', 'navigating', 'discovering',
  'probing', 'acquiring', 'stopping', 'finalizing',
])

const listEl = document.getElementById('candidate-list') as HTMLUListElement
const emptyEl = document.getElementById('empty-state') as HTMLParagraphElement
const folderStatusEl = document.getElementById('folder-status') as HTMLParagraphElement
const helperStatusEl = document.getElementById('helper-status') as HTMLParagraphElement
const selectionDetailsEl = document.getElementById('selection-details') as HTMLDListElement
const selectedServerEl = document.getElementById('selected-server') as HTMLElement
const selectedQualityEl = document.getElementById('selected-quality') as HTMLElement
const selectedSubtitlesEl = document.getElementById('selected-subtitles') as HTMLElement
const warningEl = document.getElementById('helper-warning') as HTMLParagraphElement
const progressContainer = document.getElementById('helper-progress') as HTMLDivElement
const progressBar = document.getElementById('progress-bar') as HTMLProgressElement
const progressText = document.getElementById('progress-text') as HTMLParagraphElement
const startButton = document.getElementById('start-button') as HTMLButtonElement
const stopButton = document.getElementById('stop-button') as HTMLButtonElement
const revealButton = document.getElementById('reveal-button') as HTMLButtonElement
const folderButton = document.getElementById('folder-settings') as HTMLButtonElement

let activeTab: chrome.tabs.Tab | undefined
let helperAvailable = false
let currentFolder: HelperFolder = { configured: false }
let currentJob: HelperJobSnapshot | undefined

function renderCandidates(candidates: StreamCandidate[]) {
  listEl.innerHTML = ''
  emptyEl.style.display = candidates.length === 0 ? 'block' : 'none'
  for (const candidate of candidates) {
    const li = document.createElement('li')
    li.className = 'candidate'
    const meta = document.createElement('div')
    meta.className = 'meta'
    const kindTag = document.createElement('span')
    kindTag.className = 'kind'
    kindTag.textContent = candidate.kind
    meta.append(kindTag, document.createTextNode(candidate.url))
    const button = document.createElement('button')
    button.textContent = 'Download'
    button.addEventListener('click', () => void downloadCandidate(candidate, button))
    li.append(meta, button)
    listEl.appendChild(li)
  }
}

async function downloadCandidate(candidate: StreamCandidate, button: HTMLButtonElement) {
  button.disabled = true
  button.textContent = 'Working…'
  const message: StartDownloadMsg = {
    type: 'START_DOWNLOAD',
    candidateId: candidate.id,
    tabId: candidate.tabId,
  }
  try {
    const response = await chrome.runtime.sendMessage(message)
    button.textContent = response?.ok ? 'Downloading…' : 'Failed'
    if (!response?.ok) {
      button.title = response?.error ?? 'Unknown error'
      button.disabled = false
    }
  } catch (error) {
    button.textContent = 'Failed'
    button.title = String(error)
    button.disabled = false
  }
}

function formatTime(milliseconds: number): string {
  const totalSeconds = Math.max(0, Math.floor(milliseconds / 1000))
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  return [hours, minutes, seconds].map((part) => String(part).padStart(2, '0')).join(':')
}

function formatBytes(bytes: number): string {
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

function renderFolder(folder: HelperFolder) {
  currentFolder = folder
  if (!folder.configured) folderStatusEl.textContent = 'Choose a folder before starting.'
  else if (!folder.writable) folderStatusEl.textContent = `The helper cannot write to “${folder.name}”.`
  else folderStatusEl.textContent = `Saving to “${folder.name}”.`
  folderButton.textContent = folder.configured ? 'Change folder' : 'Choose folder'
  updateStartButton()
}

function renderProgress(job?: HelperJobSnapshot) {
  const visible = Boolean(job && (ACTIVE_PHASES.has(job.phase) || job.phase === 'completed' || job.phase === 'cancelled'))
  progressContainer.hidden = !visible
  if (!job || !visible) return
  const progress = job.progress
  const details: string[] = []
  if (progress.durationMs && progress.mediaTimeMs !== undefined) {
    const percent = Math.min(100, progress.mediaTimeMs / progress.durationMs * 100)
    progressBar.value = percent
    details.push(`${percent.toFixed(1)}%`)
    details.push(`${formatTime(progress.mediaTimeMs)} / ${formatTime(progress.durationMs)}`)
  } else {
    progressBar.removeAttribute('value')
  }
  details.push(formatBytes(progress.bytesWritten))
  if (progress.bytesPerSecond) details.push(`${formatBytes(progress.bytesPerSecond)}/s`)
  if (progress.estimatedRemainingMs) details.push(`${formatTime(progress.estimatedRemainingMs)} left`)
  progressText.textContent = details.join(' · ')
}

function updateStartButton() {
  const validPage = /^https?:/i.test(activeTab?.url ?? '')
  const active = Boolean(currentJob && ACTIVE_PHASES.has(currentJob.phase))
  startButton.disabled = !helperAvailable || !currentFolder.configured || !currentFolder.writable || !validPage || active
}

function renderJob(job?: HelperJobSnapshot) {
  currentJob = job
  const active = Boolean(job && ACTIVE_PHASES.has(job.phase))
  startButton.hidden = active
  stopButton.hidden = !active
  stopButton.disabled = job?.phase === 'stopping' || job?.phase === 'finalizing'
  revealButton.hidden = job?.phase !== 'completed' && job?.phase !== 'cancelled'
  selectionDetailsEl.hidden = !job?.selection
  if (job?.selection) {
    selectedServerEl.textContent = job.selection.serverLabel ?? 'Best verified source'
    selectedQualityEl.textContent = job.selection.qualityLabel ?? 'Best verified quality'
    selectedSubtitlesEl.textContent = job.selection.subtitleLabel ?? 'Built in or unavailable'
  }
  renderProgress(job)
  warningEl.hidden = !job?.warning && !job?.error
  warningEl.textContent = job?.error?.message ?? job?.warning ?? ''

  if (!job) helperStatusEl.textContent = 'Ready to start a background download.'
  else if (job.phase === 'queued') helperStatusEl.textContent = 'Queued in the local helper.'
  else if (job.phase === 'launching-browser') helperStatusEl.textContent = 'Launching the isolated browser…'
  else if (job.phase === 'navigating') helperStatusEl.textContent = 'Opening the episode in the isolated browser…'
  else if (job.phase === 'discovering') helperStatusEl.textContent = 'Finding the available servers…'
  else if (job.phase === 'probing') helperStatusEl.textContent = job.warning ?? 'Checking server quality…'
  else if (job.phase === 'acquiring') helperStatusEl.textContent = 'Downloading the selected source…'
  else if (job.phase === 'stopping') helperStatusEl.textContent = 'Stopping and saving the completed part…'
  else if (job.phase === 'finalizing') helperStatusEl.textContent = 'Finalizing the video file…'
  else if (job.phase === 'completed') helperStatusEl.textContent = `Saved ${job.outputFilename ?? 'the video'}.`
  else if (job.phase === 'cancelled') helperStatusEl.textContent = job.outputFilename
    ? `Saved ${job.outputFilename}.`
    : 'The background download was stopped.'
  else if (job.phase === 'failed' || job.phase === 'interrupted') {
    helperStatusEl.textContent = job.error?.message ?? 'The background download failed.'
  }
  updateStartButton()
}

async function refreshStatus() {
  const response = await chrome.runtime.sendMessage({
    type: 'HELPER_STATUS',
    jobId: currentJob?.jobId,
  }) as HelperActionResp
  if (response.snapshot) renderJob(response.snapshot)
  if (!response.ok) {
    warningEl.hidden = false
    warningEl.textContent = response.error?.message ?? 'The local helper is offline.'
  }
}

folderButton.addEventListener('click', async () => {
  folderButton.disabled = true
  helperStatusEl.textContent = 'Opening the macOS folder picker…'
  const response = await chrome.runtime.sendMessage({ type: 'HELPER_CHOOSE_FOLDER' }) as HelperActionResp
  folderButton.disabled = false
  if (!response.ok) {
    helperStatusEl.textContent = response.error?.message ?? 'Could not choose a folder.'
    return
  }
  if (response.folder) renderFolder(response.folder)
  helperStatusEl.textContent = 'Ready to start a background download.'
})

startButton.addEventListener('click', async () => {
  if (!activeTab?.url || !/^https?:/i.test(activeTab.url)) return
  startButton.disabled = true
  helperStatusEl.textContent = 'Sending the episode to the local helper…'
  const response = await chrome.runtime.sendMessage({
    type: 'HELPER_START',
    sourceUrl: activeTab.url,
    sourceTitle: activeTab.title ?? 'video',
  }) as HelperActionResp
  if (!response.ok) {
    helperStatusEl.textContent = response.error?.message ?? 'The helper could not start the download.'
    updateStartButton()
    return
  }
  renderJob(response.snapshot)
})

stopButton.addEventListener('click', async () => {
  if (!currentJob) return
  stopButton.disabled = true
  const response = await chrome.runtime.sendMessage({ type: 'HELPER_STOP', jobId: currentJob.jobId }) as HelperActionResp
  if (response.snapshot) renderJob(response.snapshot)
  if (!response.ok) helperStatusEl.textContent = response.error?.message ?? 'Could not stop the download.'
})

revealButton.addEventListener('click', async () => {
  if (!currentJob) return
  const response = await chrome.runtime.sendMessage({ type: 'HELPER_REVEAL', jobId: currentJob.jobId }) as HelperActionResp
  if (!response.ok) helperStatusEl.textContent = response.error?.message ?? 'Could not show the file.'
})

async function init() {
  ;[activeTab] = await chrome.tabs.query({ active: true, currentWindow: true })
  if (activeTab?.id) {
    const candidateMessage: GetCandidatesMsg = { type: 'GET_CANDIDATES', tabId: activeTab.id }
    const candidates = await chrome.runtime.sendMessage(candidateMessage) as CandidatesListResp
    renderCandidates(candidates?.candidates ?? [])
  }

  const health = await chrome.runtime.sendMessage({ type: 'HELPER_PING' }) as HelperActionResp
  helperAvailable = health.ok
  if (!health.ok) {
    folderStatusEl.textContent = 'The local helper is not installed.'
    helperStatusEl.textContent = health.error?.message ?? 'Run npm run helper:install, then reload Yoink.'
    folderButton.disabled = true
    updateStartButton()
    return
  }
  if (health.health) renderFolder(health.health.folder)
  await refreshStatus()
  window.setInterval(() => void refreshStatus(), 1_000)
}

void init()
