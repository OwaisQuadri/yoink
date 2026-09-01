function mediaKind(url, contentType = '') {
  const value = `${url} ${contentType}`.toLowerCase()
  if (value.includes('.m3u8') || value.includes('mpegurl')) return 'hls'
  if (value.includes('.mpd') || value.includes('dash+xml')) return 'dash'
  if (value.includes('.webm') || value.includes('video/webm')) return 'webm'
  if (value.includes('.mp4') || value.includes('video/mp4')) return 'mp4'
  return undefined
}

export async function enumerateServers(page) {
  const servers = await page.locator('a, button, [role="tab"]').evaluateAll((elements) => elements
    .map((element, index) => {
      const text = (element.textContent ?? '').trim().replace(/\s+/g, ' ')
      const rect = element.getBoundingClientRect()
      const style = getComputedStyle(element)
      const href = element.tagName === 'A' ? element.getAttribute('href') : null
      const visible = rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden'
      const safe = element.tagName !== 'A' || (href ?? '').startsWith('#')
      return { text, index, href, id: element.id, visible, safe }
    })
    .filter((item) => item.visible && item.safe && /^server\s*\d+/i.test(item.text)))
  if (servers.length === 0) return [{ id: 'implicit', label: 'Current player', order: 0 }]
  return servers.map((server, order) => ({
    id: server.id ? `#${server.id}` : server.href || `index:${server.index}`,
    label: server.text,
    order,
  }))
}

export async function activateServer(page, server) {
  if (server.id === 'implicit') return
  const activated = await page.evaluate(({ id, label }) => {
    const controls = [...document.querySelectorAll('a, button, [role="tab"]')]
    const target = controls.find((element) => {
      const text = (element.textContent ?? '').trim().replace(/\s+/g, ' ')
      const rect = element.getBoundingClientRect()
      const style = getComputedStyle(element)
      const href = element.tagName === 'A' ? element.getAttribute('href') : null
      const visible = rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden'
      const safe = element.tagName !== 'A' || (href ?? '').startsWith('#')
      const identityMatches = id.startsWith('#') ? element.id === id.slice(1) : false
      return visible && safe && (identityMatches || text.toLowerCase() === label.toLowerCase())
    })
    if (!target) return false
    target.click()
    return true
  }, { id: server.id, label: server.label })
  if (!activated) throw new Error(`Could not activate ${server.label}.`)
}

export async function inspectPlayerFrame(frame) {
  return frame.evaluate(async () => {
    const visible = (element) => {
      if (!element) return false
      const rect = element.getBoundingClientRect()
      const style = getComputedStyle(element)
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden'
    }
    const video = [...document.querySelectorAll('video')]
      .filter(visible)
      .sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0]
    let player
    try {
      player = typeof window.jwplayer === 'function' ? window.jwplayer() : undefined
    } catch {
      player = undefined
    }
    const qualities = (player?.getQualityLevels?.() ?? []).map((quality, index) => ({
      index,
      label: quality.label ?? `Quality ${index + 1}`,
      height: quality.height,
      bitrate: quality.bitrate,
    }))
    const bestQuality = [...qualities].sort((a, b) =>
      (b.height ?? Number.parseInt(b.label, 10) ?? 0) - (a.height ?? Number.parseInt(a.label, 10) ?? 0)
      || (b.bitrate ?? 0) - (a.bitrate ?? 0))[0]
    try {
      if (bestQuality && player?.setCurrentQuality) player.setCurrentQuality(bestQuality.index)
    } catch {
      // Some JW builds throw while rebuilding their quality menu.
    }

    const captions = (player?.getCaptionsList?.() ?? []).map((caption, index) => ({
      index,
      id: caption.id,
      label: caption.label ?? caption.language ?? `Subtitle ${index + 1}`,
      language: caption.language,
    }))
    const english = captions.find((caption) =>
      /(^|[-_])en(g)?($|[-_])/i.test(caption.language ?? '') || /english/i.test(caption.label))
    try {
      if (english && player?.setCurrentCaptions) player.setCurrentCaptions(english.index)
    } catch {
      // Subtitle selection remains optional.
    }

    let playlistItem
    try {
      playlistItem = player?.getPlaylistItem?.()
    } catch {
      playlistItem = undefined
    }
    const sources = (playlistItem?.sources ?? []).map((source, index) => ({
      url: source.file,
      label: source.label ?? `Source ${index + 1}`,
      height: source.height,
      bitrate: source.bitrate,
      type: source.type,
    })).filter((source) => /^https?:/i.test(source.url ?? ''))
    const sourceHeight = (source) => source.height ?? (Number.parseInt(source.label ?? '', 10) || 0)
    const bestSource = [...sources].sort((a, b) => sourceHeight(b) - sourceHeight(a)
      || (b.bitrate ?? 0) - (a.bitrate ?? 0))[0]

    try {
      if (video && bestSource?.url && video.currentSrc.split('#')[0] !== bestSource.url.split('#')[0]) {
        video.src = bestSource.url
        video.load()
        await video.play()
      } else if (player?.play) {
        player.play(true)
      } else {
        await video?.play()
      }
    } catch {
      // The caller verifies whether playback actually starts.
    }

    return {
      frameUrl: location.href,
      hasVideo: Boolean(video),
      qualities,
      selectedQuality: bestQuality,
      captions,
      englishCaption: english,
      sources,
      protected: Boolean(video?.mediaKeys),
    }
  })
}

export async function verifyPlayerFrame(frame, initial) {
  return frame.evaluate((before) => {
    const videos = [...document.querySelectorAll('video')]
    const video = videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0]
    return {
      ...before,
      playable: Boolean(video && video.readyState >= 2 && Number.isFinite(video.duration)),
      width: video?.videoWidth ?? 0,
      height: video?.videoHeight ?? 0,
      durationMs: video && Number.isFinite(video.duration) ? Math.round(video.duration * 1000) : undefined,
      currentTime: video?.currentTime ?? 0,
      currentSrc: /^https?:/i.test(video?.currentSrc ?? '') ? video.currentSrc : undefined,
      protected: before.protected || Boolean(video?.mediaKeys),
    }
  }, initial)
}

export function classifyMediaRequest(request) {
  const kind = mediaKind(request.url, request.contentType)
  return kind ? { ...request, kind } : undefined
}
