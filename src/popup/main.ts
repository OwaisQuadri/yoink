import type { StreamCandidate } from '../lib/types'
import type { GetCandidatesMsg, StartDownloadMsg, CandidatesListResp } from '../lib/messages'

const listEl = document.getElementById('candidate-list') as HTMLUListElement
const emptyEl = document.getElementById('empty-state') as HTMLParagraphElement

function render(candidates: StreamCandidate[]) {
  listEl.innerHTML = ''
  emptyEl.style.display = candidates.length === 0 ? 'block' : 'none'

  for (const c of candidates) {
    const li = document.createElement('li')
    li.className = 'candidate'

    const meta = document.createElement('div')
    meta.className = 'meta'
    const kindTag = document.createElement('span')
    kindTag.className = 'kind'
    kindTag.textContent = c.kind
    meta.appendChild(kindTag)
    meta.appendChild(document.createTextNode(c.url))

    const btn = document.createElement('button')
    btn.textContent = 'Download'
    btn.addEventListener('click', () => download(c, btn))

    li.appendChild(meta)
    li.appendChild(btn)
    listEl.appendChild(li)
  }
}

async function download(candidate: StreamCandidate, btn: HTMLButtonElement) {
  btn.disabled = true
  btn.textContent = 'Working…'
  const msg: StartDownloadMsg = {
    type: 'START_DOWNLOAD',
    candidateId: candidate.id,
    tabId: candidate.tabId,
  }
  try {
    const res = await chrome.runtime.sendMessage(msg)
    if (res?.ok) {
      btn.textContent = 'Downloading…'
    } else {
      btn.textContent = 'Failed'
      btn.title = res?.error ?? 'Unknown error'
      btn.disabled = false
    }
  } catch (err) {
    btn.textContent = 'Failed'
    btn.title = String(err)
    btn.disabled = false
  }
}

async function init() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true })
  if (!tab?.id) return
  const msg: GetCandidatesMsg = { type: 'GET_CANDIDATES', tabId: tab.id }
  const res = (await chrome.runtime.sendMessage(msg)) as CandidatesListResp
  render(res?.candidates ?? [])
}

void init()
