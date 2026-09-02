import type { HelperActionResponse, HelperErrorCode, HelperHealth, HelperJobSnapshot } from '../lib/types'
import type { HelperCache } from '../lib/messages'

const HOST_NAME = 'com.owaisquadri.yoink'
const CACHE_KEY = 'yoinkHelperCache'
const ACTIVE_PHASES = new Set([
  'validating', 'queued', 'launching-browser', 'navigating', 'discovering',
  'probing', 'acquiring', 'stopping', 'finalizing',
])

interface NativeResponse {
  v: 1
  id: string
  ok: boolean
  revision: number
  snapshot?: HelperJobSnapshot
  result?: unknown
  error?: { code: HelperErrorCode; message: string }
}

async function nativeRequest(op: string, fields: Record<string, unknown> = {}): Promise<NativeResponse> {
  const id = crypto.randomUUID()
  try {
    return await chrome.runtime.sendNativeMessage(HOST_NAME, { v: 1, id, op, ...fields }) as NativeResponse
  } catch (error) {
    return {
      v: 1,
      id,
      ok: false,
      revision: 0,
      error: {
        code: 'HELPER_NOT_INSTALLED',
        message: error instanceof Error ? error.message : String(error),
      },
    }
  }
}

async function readCache(): Promise<HelperCache> {
  const stored = await chrome.storage.local.get(CACHE_KEY)
  return (stored[CACHE_KEY] as HelperCache | undefined) ?? {}
}

async function cacheSnapshot(snapshot?: HelperJobSnapshot) {
  if (!snapshot) return
  const cache: HelperCache = {
    lastJobId: snapshot.jobId,
    lastRevision: snapshot.revision,
    lastSnapshot: snapshot,
  }
  await chrome.storage.local.set({ [CACHE_KEY]: cache })
  await updateHelperBadge(snapshot)
}

// Scoped to the tab the job started from. Without a tabId here, this badge
// call (no `tabId` option) sets Chrome's action badge globally, so a
// completed download on one site's tab kept showing "✓" on every other
// tab, including a different episode that hadn't been downloaded yet.
async function updateHelperBadge(snapshot: HelperJobSnapshot) {
  if (snapshot.tabId == null) return
  const tabId = snapshot.tabId
  if (ACTIVE_PHASES.has(snapshot.phase)) {
    await chrome.action.setBadgeBackgroundColor({ tabId, color: '#7c3aed' })
    await chrome.action.setBadgeText({ tabId, text: '↓' })
    return
  }
  if (snapshot.phase === 'completed') {
    await chrome.action.setBadgeBackgroundColor({ tabId, color: '#15803d' })
    await chrome.action.setBadgeText({ tabId, text: '✓' })
    return
  }
  if (snapshot.phase === 'failed' || snapshot.phase === 'interrupted') {
    await chrome.action.setBadgeBackgroundColor({ tabId, color: '#b91c1c' })
    await chrome.action.setBadgeText({ tabId, text: '!' })
  }
}

function action(response: NativeResponse): HelperActionResponse {
  return response.ok
    ? { ok: true, snapshot: response.snapshot }
    : { ok: false, error: response.error ?? { code: 'HELPER_OFFLINE', message: 'The helper did not respond.' } }
}

export async function pingHelper(): Promise<HelperActionResponse> {
  const response = await nativeRequest('ping')
  if (!response.ok) return action(response)
  return { ok: true, health: response.result as HelperHealth }
}

export async function chooseHelperFolder(): Promise<HelperActionResponse> {
  const response = await nativeRequest('choose-folder')
  if (!response.ok) return action(response)
  return { ok: true, folder: (response.result as { folder: HelperHealth['folder'] }).folder }
}

export async function startHelperJob(
  sourceUrl: string,
  sourceTitle: string,
  tabId: number
): Promise<HelperActionResponse> {
  const response = await nativeRequest('start', {
    idempotencyKey: crypto.randomUUID(),
    sourceUrl,
    sourceTitle,
    tabId,
    options: { preferResolution: true, preferredSubtitleLanguage: 'en' },
  })
  if (response.snapshot) await cacheSnapshot(response.snapshot)
  if (response.ok) await chrome.alarms.create('yoink-helper-poll', { periodInMinutes: 0.5 })
  return action(response)
}

// jobId/tabId come from the caller, not from the global cache, whenever the
// caller knows which tab it's asking about (the popup always does). Falling
// back to `cache.lastJobId` is reserved for the tabId-less alarm poll below,
// which must keep tracking whichever job is actually running regardless of
// which tab the user currently has focused.
export async function getHelperStatus(jobId?: string, tabId?: number): Promise<HelperActionResponse> {
  const cache = await readCache()
  const fields: Record<string, unknown> = {}
  if (jobId) fields.jobId = jobId
  else if (tabId != null) fields.tabId = tabId
  else if (cache.lastJobId) fields.jobId = cache.lastJobId
  const response = await nativeRequest('status', fields)
  if (!response.ok) {
    // Only fall back to the cached snapshot when it's actually for the tab
    // being asked about (or no tab was specified) — otherwise a helper
    // hiccup on episode 3's tab would surface episode 2's cached snapshot,
    // recreating the exact cross-tab leak this fix removes.
    const cacheMatchesTab = tabId == null || cache.lastSnapshot?.tabId === tabId
    return {
      ok: false,
      snapshot: cacheMatchesTab ? cache.lastSnapshot : undefined,
      error: response.error ?? { code: 'HELPER_OFFLINE', message: 'The helper did not respond.' },
    }
  }
  if (response.snapshot) {
    await cacheSnapshot(response.snapshot)
    if (!ACTIVE_PHASES.has(response.snapshot.phase)) await chrome.alarms.clear('yoink-helper-poll')
  }
  return action(response)
}

export async function stopHelperJob(jobId: string): Promise<HelperActionResponse> {
  const response = await nativeRequest('stop', { jobId })
  if (response.snapshot) await cacheSnapshot(response.snapshot)
  return action(response)
}

export async function revealHelperOutput(jobId: string): Promise<HelperActionResponse> {
  const response = await nativeRequest('reveal', { jobId })
  if (response.snapshot) await cacheSnapshot(response.snapshot)
  return action(response)
}

export function pollHelperStatus() {
  void getHelperStatus()
}
