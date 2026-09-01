import type { HelperActionResp } from '../lib/messages'
import type { HelperFolder } from '../lib/types'

const helperStatusEl = document.getElementById('helper-status') as HTMLParagraphElement
const folderStatusEl = document.getElementById('folder-status') as HTMLParagraphElement
const chooseButton = document.getElementById('choose-folder') as HTMLButtonElement

function renderFolder(folder: HelperFolder) {
  folderStatusEl.className = ''
  if (!folder.configured) {
    folderStatusEl.textContent = 'No download folder selected.'
    folderStatusEl.classList.add('warning')
    chooseButton.textContent = 'Choose folder'
  } else if (!folder.writable) {
    folderStatusEl.textContent = `The helper cannot write to “${folder.name}”.`
    folderStatusEl.classList.add('warning')
    chooseButton.textContent = 'Change folder'
  } else {
    folderStatusEl.textContent = `Background downloads will be saved to “${folder.name}”.`
    folderStatusEl.classList.add('success')
    chooseButton.textContent = 'Change folder'
  }
}

chooseButton.addEventListener('click', async () => {
  chooseButton.disabled = true
  const response = await chrome.runtime.sendMessage({ type: 'HELPER_CHOOSE_FOLDER' }) as HelperActionResp
  chooseButton.disabled = false
  if (!response.ok) {
    folderStatusEl.textContent = response.error?.message ?? 'Could not select the folder.'
    folderStatusEl.className = 'error'
    return
  }
  if (response.folder) renderFolder(response.folder)
})

async function init() {
  const response = await chrome.runtime.sendMessage({ type: 'HELPER_PING' }) as HelperActionResp
  if (!response.ok) {
    helperStatusEl.textContent = response.error?.message ?? 'The local helper is not installed.'
    helperStatusEl.className = 'error'
    folderStatusEl.textContent = 'Install the helper before choosing a folder.'
    chooseButton.disabled = true
    return
  }
  helperStatusEl.textContent = `Connected to Yoink helper ${response.health?.helperVersion ?? ''}.`
  helperStatusEl.className = 'success'
  if (response.health) renderFolder(response.health.folder)
}

void init()
