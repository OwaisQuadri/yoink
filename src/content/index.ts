import { kindFromUrl } from '../lib/detector'
import type { CandidateFoundMsg } from '../lib/messages'

/**
 * DOM-level fallback detector. Network sniffing in the background service
 * worker catches most cases, but some players set `video.src` from a blob
 * or set it late without a matching network request we can attribute
 * cleanly (e.g. MSE-driven players). This scans <video>/<source> elements
 * as a secondary signal.
 */
function scan() {
  const els = document.querySelectorAll<HTMLVideoElement | HTMLSourceElement>('video, source')
  for (const el of els) {
    const src = (el as HTMLVideoElement).currentSrc || el.getAttribute('src')
    if (!src || src.startsWith('blob:')) continue
    const kind = kindFromUrl(src)
    if (!kind) continue
    const msg: CandidateFoundMsg = {
      type: 'CANDIDATE_FOUND',
      candidate: {
        url: src,
        kind,
        pageTitle: document.title,
      },
    }
    chrome.runtime.sendMessage(msg).catch(() => {})
  }
}

// Debug-only: relays a page-triggered postMessage into a background
// message so a click can be dispatched via chrome.debugger's CDP Input
// domain (trusted, unlike a script-invoked .click(), which some players
// gate on event.isTrusted). The page itself can't reach chrome.runtime;
// this content script bridges the isolated/main-world boundary.
window.addEventListener('message', (event) => {
  if (event.source !== window) return
  const data = event.data as { type?: string; x?: number; y?: number }
  if (data?.type !== 'YOINK_DEBUG_CLICK_AT') return
  if (typeof data.x !== 'number' || typeof data.y !== 'number') return
  chrome.runtime.sendMessage({ type: 'DEBUG_CLICK_AT', x: data.x, y: data.y }).catch(() => {})
})

scan()
const observer = new MutationObserver(() => scan())
observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true })

// Re-scan periodically for a short window after load, since some players
// attach video sources asynchronously after their own network calls settle.
let ticks = 0
const interval = setInterval(() => {
  scan()
  ticks++
  if (ticks > 20) clearInterval(interval)
}, 1000)
