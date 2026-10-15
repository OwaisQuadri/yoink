(() => {
  if (window.__yoink) return;
  window.__yoink = true;
  const mediaPattern = /\.(m3u8|mpd|mp4|webm|m4v|mov)(\?|#|$)|\/m3u8\?/i;
  const seen = new Set();
  const send = (raw, kind) => {
    let url;
    try { url = new URL(String(raw), location.href).href; } catch { return; }
    if (!/^https?:/.test(url) || seen.has(url)) return;
    seen.add(url);
    window.webkit.messageHandlers.yoink.postMessage({ url, kind, page: location.href, title: document.title });
  };
  const check = (raw) => { if (raw && mediaPattern.test(String(raw))) send(raw, 'net'); };

  const originalFetch = window.fetch;
  window.fetch = function (input, ...rest) {
    const url = input instanceof Request ? input.url : input;
    check(url);
    return originalFetch.call(this, input, ...rest).then((response) => {
      const type = response.headers.get('content-type') || '';
      if (/mpegurl/i.test(type)) send(url, 'hls');
      if (/dash\+xml/i.test(type)) send(url, 'dash');
      return response;
    });
  };

  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    check(url);
    this.addEventListener('load', () => {
      try {
        if ((this.responseType === '' || this.responseType === 'text') && this.responseText.startsWith('#EXTM3U')) send(url, 'hls');
      } catch {}
    });
    return originalOpen.call(this, method, url, ...rest);
  };

  const playSelectors = [
    '.jw-icon-display', '.vjs-big-play-button', '.plyr__control--overlaid', '.bmpui-ui-hugeplaybacktogglebutton',
    '[aria-label="Play" i]', '[aria-label="Play Video" i]', 'button.play', '.play-button', '#play', '.btn-play',
  ];
  let attempts = 0;
  setInterval(() => {
    for (const entry of performance.getEntriesByType('resource')) check(entry.name);
    document.querySelectorAll('video, video source').forEach((element) => {
      const source = element.currentSrc || element.src;
      if (source && !source.startsWith('blob:')) send(source, 'video');
      if (element.tagName === 'VIDEO') {
        element.muted = true;
        if (element.paused) element.play().catch(() => {});
      }
    });
    if (attempts++ % 3 !== 0 || attempts > 30) return;
    for (const selector of playSelectors) document.querySelector(selector)?.click();
    for (const element of document.querySelectorAll('button, a, div[role="button"]')) {
      if (/^\s*(play|watch now)\s*$/i.test(element.textContent || '')) { element.click(); break; }
    }
  }, 1000);
})();
