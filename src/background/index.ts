import type { StreamCandidate } from '../lib/types'
import {
  kindFromUrl,
  kindFromContentType,
  kindFromMediaResourceFallback,
  filenameFromContentDisposition,
  resolveKnownDirectUrl,
  isKnownAdInfrastructureUrl,
  hashUrl,
  RELEVANT_RESOURCE_TYPES,
} from '../lib/detector'
import type { ExtensionMessage } from '../lib/messages'
import {
  chooseHelperFolder,
  getHelperStatus,
  pingHelper,
  pollHelperStatus,
  revealHelperOutput,
  startHelperJob,
  stopHelperJob,
} from './helper'

// tabId -> (candidateId -> candidate)
const candidatesByTab = new Map<number, Map<string, StreamCandidate>>()

function getTabMap(tabId: number): Map<string, StreamCandidate> {
  let map = candidatesByTab.get(tabId)
  if (!map) {
    map = new Map()
    candidatesByTab.set(tabId, map)
  }
  return map
}

function addCandidate(tabId: number, frameId: number, rawUrl: string, opts: Partial<StreamCandidate> = {}) {
  const url = resolveKnownDirectUrl(rawUrl)
  const kind = opts.kind ?? kindFromUrl(url)
  if (!kind) return
  const id = hashUrl(url)
  const map = getTabMap(tabId)
  if (map.has(id)) return
  const candidate: StreamCandidate = {
    id,
    url,
    kind,
    tabId,
    frameId,
    firstSeen: Date.now(),
    ...opts,
  }
  map.set(id, candidate)
  updateBadge(tabId)
  void persistDebugLog(candidate)
}

/**
 * Debug-only: persists every detected candidate to chrome.storage.local so
 * it survives tab navigation (unlike the in-memory candidatesByTab map,
 * which is cleared on top-frame navigation). Lets us inspect what was
 * detected from any extension-context page, even after moving on.
 */
async function persistDebugLog(candidate: StreamCandidate) {
  const { yoinkDebugLog } = await chrome.storage.local.get('yoinkDebugLog')
  const log: StreamCandidate[] = Array.isArray(yoinkDebugLog) ? yoinkDebugLog : []
  log.push(candidate)
  await chrome.storage.local.set({ yoinkDebugLog: log.slice(-200) })
}

function updateBadge(tabId: number) {
  const count = candidatesByTab.get(tabId)?.size ?? 0
  chrome.action.setBadgeText({ tabId, text: count > 0 ? String(count) : '' })
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#2563eb' })
}

// --- Network sniffing across all frames, all origins ---
chrome.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (details.tabId < 0) return
    if (!RELEVANT_RESOURCE_TYPES.has(details.type)) return
    if (isKnownAdInfrastructureUrl(details.initiator) || isKnownAdInfrastructureUrl(details.url)) return
    const kind = kindFromUrl(details.url)
    if (!kind) return
    addCandidate(details.tabId, details.frameId, details.url, { kind, initiator: details.initiator })
  },
  { urls: ['<all_urls>'] }
)

// Catches responses whose Content-Type identifies a stream even without a
// tell-tale file extension (many CDNs serve HLS/DASH from opaque paths).
chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0) return
    if (!RELEVANT_RESOURCE_TYPES.has(details.type)) return
    if (isKnownAdInfrastructureUrl(details.url)) return
    const headerValue = (name: string) =>
      details.responseHeaders?.find((h) => h.name.toLowerCase() === name)?.value
    const ct = headerValue('content-type')
    const kind =
      kindFromContentType(ct) ?? kindFromUrl(details.url) ?? kindFromMediaResourceFallback(details.type, ct)
    if (!kind) return
    const suggestedFilename = filenameFromContentDisposition(headerValue('content-disposition')) ?? undefined
    addCandidate(details.tabId, details.frameId, details.url, { kind, contentType: ct, suggestedFilename })
  },
  { urls: ['<all_urls>'] },
  ['responseHeaders']
)

chrome.tabs.onRemoved.addListener((tabId) => {
  candidatesByTab.delete(tabId)
  void chrome.alarms.clear(debuggerDetachAlarmName(tabId))
  void detachDebugger(tabId)
})

chrome.webNavigation.onCommitted.addListener((details) => {
  // Top-level navigation to a new page: reset candidates for that tab, and
  // drop the CDP debugger — attaching it fresh, if still needed, happens
  // lazily (see attachDebuggerBriefly) rather than on every page load. A
  // debugger attached to every tab you merely browse to is what threw the
  // "Yoink is debugging this browser" banner up constantly; it should only
  // show while Yoink is actually inspecting a page for you.
  if (details.frameId === 0) {
    candidatesByTab.delete(details.tabId)
    updateBadge(details.tabId)
    void chrome.alarms.clear(debuggerDetachAlarmName(details.tabId))
    void detachDebugger(details.tabId)
  }
})

// --- Fallback: CDP Network domain via chrome.debugger ---
//
// webRequest sees a request's URL, resource type, and headers, but nothing
// about what actually happens inside heavily-obfuscated or anti-bot-hardened
// embed pages (some sites detect automation and swap out real media
// requests for decoys, or route media through requests whose type/headers
// don't match our filters). chrome.debugger + CDP's Network domain gives a
// second, lower-level vantage point: every request the renderer makes,
// tagged with Chrome's own resource-type classification (Media, XHR,
// Fetch, WebSocket, etc.), independent of the webRequest API entirely.
// This is diagnostic/fallback only — intentionally verbose so we can see
// what a hardened site is really doing, not just what our regexes expect.
const debuggerAttachedTabs = new Set<number>()
const DEBUGGER_DETACH_ALARM_PREFIX = 'yoink-debugger-detach:'
// How long the CDP fallback stays attached before releasing itself. Long
// enough to catch a hardened embed's requests around initial player load;
// short enough that the "being debugged" banner isn't a permanent fixture.
const DEBUGGER_ATTACH_WINDOW_MINUTES = 0.5

function debuggerDetachAlarmName(tabId: number): string {
  return `${DEBUGGER_DETACH_ALARM_PREFIX}${tabId}`
}

// Attaches the CDP fallback only when there's an actual reason to — the
// popup was opened on a tab whose candidates webRequest hasn't already
// found — and schedules its own detach shortly after, instead of staying
// attached for as long as the tab is open. Called from GET_CANDIDATES, i.e.
// the moment a person actually opens Yoink to try to download something.
async function attachDebuggerBriefly(tabId: number) {
  await attachDebugger(tabId)
  await chrome.alarms.create(debuggerDetachAlarmName(tabId), { delayInMinutes: DEBUGGER_ATTACH_WINDOW_MINUTES })
}

async function attachDebugger(tabId: number) {
  if (debuggerAttachedTabs.has(tabId)) return
  try {
    await chrome.debugger.attach({ tabId }, '1.3')
    debuggerAttachedTabs.add(tabId)
    await chrome.debugger.sendCommand({ tabId }, 'Network.enable', {})
    // Cross-origin iframes (the actual video embeds we care about) run in
    // their own renderer process under site isolation. Network.enable on
    // the top-level tab target alone is blind to that traffic entirely —
    // auto-attach (flatten mode) is required to see it.
    await chrome.debugger.sendCommand({ tabId }, 'Target.setAutoAttach', {
      autoAttach: true,
      waitForDebuggerOnStart: false,
      flatten: true,
    })
  } catch (err) {
    // Tab may already have a debugger attached (e.g. real DevTools open),
    // or may have closed mid-attach. Not fatal to the rest of the extension.
    console.warn('yoink: debugger attach failed', tabId, err)
  }
}

async function detachDebugger(tabId: number) {
  debuggerAttachedTabs.delete(tabId)
  // Deliberately unconditional: `debuggerAttachedTabs` is in-memory state
  // that an evicted MV3 service worker restarts empty, but the real CDP
  // session Chrome is showing the "being debugged" banner for survives
  // that restart untouched. The 30s auto-detach alarm (see
  // attachDebuggerBriefly) is exactly the kind of event likely to wake a
  // freshly-restarted worker — gating this call on the (now-empty) Set
  // would silently skip the real detach and leave the banner up
  // indefinitely. chrome.debugger.detach on an already-detached tab just
  // rejects, which the catch below absorbs.
  try {
    await chrome.debugger.detach({ tabId })
  } catch {
    // already detached
  }
}

interface CdpRequestWillBeSentParams {
  requestId: string
  request: { url: string; headers: Record<string, string> }
  type?: string
  documentURL?: string
}

async function persistRawNetworkLog(entry: Record<string, unknown>) {
  const { yoinkRawNetworkLog } = await chrome.storage.local.get('yoinkRawNetworkLog')
  const log: unknown[] = Array.isArray(yoinkRawNetworkLog) ? yoinkRawNetworkLog : []
  log.push(entry)
  await chrome.storage.local.set({ yoinkRawNetworkLog: log.slice(-500) })
}

interface CdpAttachedToTargetParams {
  sessionId: string
  targetInfo: { type: string }
}

// @types/chrome's Debuggee type predates flatten-mode sessionId targeting,
// which Chrome itself has supported since ~M116.
type DebuggeeWithSession = chrome.debugger.Debuggee & { sessionId?: string }

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (method === 'Target.attachedToTarget' && source.tabId != null) {
    const p = params as CdpAttachedToTargetParams
    // Enable Network domain on this child session too (e.g. the cross-
    // origin video-embed iframe's own renderer target).
    const target: DebuggeeWithSession = { tabId: source.tabId, sessionId: p.sessionId }
    void chrome.debugger
      .sendCommand(target, 'Network.enable', {})
      .catch((err) => console.warn('yoink: child-target Network.enable failed', err))
    // Target.setAutoAttach does not cascade to grandchild targets on its
    // own — an iframe nested inside this one (e.g. the real player nested
    // inside an ad/embed wrapper iframe) needs auto-attach re-issued on
    // *this* session too, or its traffic stays invisible just like the
    // top-level tab was before the first attach.
    void chrome.debugger
      .sendCommand(target, 'Target.setAutoAttach', {
        autoAttach: true,
        waitForDebuggerOnStart: false,
        flatten: true,
      })
      .catch((err) => console.warn('yoink: child-target setAutoAttach failed', err))
    return
  }

  if (method !== 'Network.requestWillBeSent' || source.tabId == null) return
  const p = params as CdpRequestWillBeSentParams
  const url = p.request?.url
  if (!url) return

  // Log everything for inspection, filtered only enough to stay readable.
  void persistRawNetworkLog({
    tabId: source.tabId,
    url,
    cdpType: p.type,
    documentURL: p.documentURL,
    time: Date.now(),
  })

  // Also feed the real candidate pipeline: CDP's own type classification
  // ('Media', 'XHR', 'Fetch', etc.) catches cases webRequest's resourceType
  // filter might miss. Filter out known ad infrastructure by *frame*
  // origin (documentURL) — an ad network can serve a genuinely valid mp4
  // file that's still not the content the user actually wants.
  if (isKnownAdInfrastructureUrl(p.documentURL) || isKnownAdInfrastructureUrl(url)) return
  const kind = kindFromUrl(url)
  if (kind) {
    addCandidate(source.tabId, 0, url, { kind })
  }
})

// --- Messaging ---
chrome.runtime.onMessage.addListener((message: ExtensionMessage, sender, sendResponse) => {
  if (message.type === 'CANDIDATE_FOUND') {
    const tabId = sender.tab?.id
    if (tabId == null) return
    addCandidate(tabId, sender.frameId ?? 0, message.candidate.url, {
      kind: message.candidate.kind,
      pageTitle: message.candidate.pageTitle,
    })
    return
  }

  if (message.type === 'DEBUG_CLICK_AT') {
    const tabId = sender.tab?.id
    if (tabId == null) return
    void (async () => {
      await attachDebuggerBriefly(tabId)
      await chrome.debugger.sendCommand({ tabId }, 'Input.dispatchMouseEvent', {
        type: 'mousePressed',
        x: message.x,
        y: message.y,
        button: 'left',
        clickCount: 1,
      })
      await chrome.debugger.sendCommand({ tabId }, 'Input.dispatchMouseEvent', {
        type: 'mouseReleased',
        x: message.x,
        y: message.y,
        button: 'left',
        clickCount: 1,
      })
      sendResponse({ ok: true })
    })()
    return true
  }

  if (message.type === 'DEBUG_DUMP_ALL') {
    const dump: Record<number, StreamCandidate[]> = {}
    for (const [tabId, map] of candidatesByTab) {
      dump[tabId] = Array.from(map.values())
    }
    sendResponse(dump)
    return true
  }

  if (message.type === 'GET_CANDIDATES') {
    const list = Array.from(getTabMap(message.tabId).values())
    sendResponse({ candidates: list })
    // Nothing found through webRequest yet — this is the one moment the CDP
    // fallback earns the "being debugged" banner: the person just opened
    // Yoink specifically to look for something to download here.
    if (list.length === 0) void attachDebuggerBriefly(message.tabId)
    return true
  }

  if (message.type === 'START_DOWNLOAD') {
    const candidate = getTabMap(message.tabId).get(message.candidateId)
    if (!candidate) {
      sendResponse({ ok: false, error: 'Candidate not found' })
      return true
    }
    void startDownload(candidate).then(
      () => sendResponse({ ok: true }),
      (err) => sendResponse({ ok: false, error: String(err?.message ?? err) })
    )
    return true
  }

  if (message.type === 'HELPER_PING') {
    void pingHelper().then(sendResponse)
    return true
  }

  if (message.type === 'HELPER_CHOOSE_FOLDER') {
    void chooseHelperFolder().then(sendResponse)
    return true
  }

  if (message.type === 'HELPER_START') {
    void startHelperJob(message.sourceUrl, message.sourceTitle, message.tabId).then(sendResponse)
    return true
  }

  if (message.type === 'HELPER_STATUS') {
    void getHelperStatus(message.jobId, message.tabId).then(sendResponse)
    return true
  }

  if (message.type === 'HELPER_STOP') {
    void stopHelperJob(message.jobId).then(sendResponse)
    return true
  }

  if (message.type === 'HELPER_REVEAL') {
    void revealHelperOutput(message.jobId).then(sendResponse)
    return true
  }

  return undefined
})

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'yoink-helper-poll') {
    pollHelperStatus()
    return
  }
  if (alarm.name.startsWith(DEBUGGER_DETACH_ALARM_PREFIX)) {
    const tabId = Number(alarm.name.slice(DEBUGGER_DETACH_ALARM_PREFIX.length))
    if (Number.isInteger(tabId)) void detachDebugger(tabId)
  }
})

async function ensureOffscreenDocument() {
  const existing = await chrome.runtime.getContexts({
    contextTypes: [chrome.runtime.ContextType.OFFSCREEN_DOCUMENT],
  })
  if (existing.length > 0) return
  await chrome.offscreen.createDocument({
    url: 'src/offscreen/offscreen.html',
    reasons: [chrome.offscreen.Reason.BLOBS],
    justification: 'Remux downloaded HLS streams.',
  })
}

async function startDownload(candidate: StreamCandidate) {
  const extension = candidate.kind === 'webm' ? 'webm' : 'mp4'
  const filename = `yoink/${(candidate.pageTitle ?? 'video').replace(/[\\/:*?"<>|]/g, '_')}.${extension}`
  if (candidate.kind === 'mp4' || candidate.kind === 'webm') {
    await chrome.downloads.download({ url: candidate.url, filename, saveAs: false })
    return
  }

  await ensureOffscreenDocument()
  const response = await chrome.runtime.sendMessage({
    type: 'OFFSCREEN_RUN_JOB',
    candidate,
    filename,
  }) as { ok: boolean; blobUrl?: string; error?: string }
  if (!response?.ok || !response.blobUrl) {
    throw new Error(response?.error ?? 'The offscreen download job did not return a file.')
  }
  await chrome.downloads.download({ url: response.blobUrl, filename, saveAs: false })
}
