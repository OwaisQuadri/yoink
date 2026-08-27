# yoink

Chrome extension (Manifest V3) that detects video streams on the current page —
direct MP4/WebM files, HLS (`.m3u8`), and DASH (`.mpd`) manifests — across the
top-level page and any embedded iframes, and downloads them as a single
playable file.

## Scope

- Detection is generic: network sniffing (`webRequest`) across all frames,
  plus a DOM fallback content script for `<video>`/`<source>` elements.
- HLS streams are downloaded segment-by-segment and remuxed into a single
  `.mp4` in-browser using `ffmpeg.wasm`, run inside an offscreen document
  (service workers can be killed mid-job, offscreen documents are not).
- Direct MP4/WebM URLs are downloaded as-is via `chrome.downloads`.
- **DRM-protected streams are out of scope.** If an HLS playlist advertises
  `#EXT-X-KEY` with a non-`NONE` method, yoink reports it as unsupported
  rather than attempting decryption.
- DASH (`.mpd`) detection exists but remuxing is not yet implemented.

## Status

Initial scaffold. Not yet validated end-to-end against the target test case.

## Dev setup

```sh
npm install
npm run dev     # starts Vite in watch mode, writes to dist/
```

Then in Chrome: `chrome://extensions` → enable Developer mode → **Load
unpacked** → select the `dist/` folder. Reload the extension after each
change (Vite HMR handles most UI changes live; background/content script
changes need a manual extension reload).

For a one-off production build: `npm run build`.

## Test case

`https://www1.yoturkish.com/sevdigim-sensin-episode-1/` — page offers
"SERVER 1–4" tabs, each presumably loading a different third-party embed.
Stream format(s) served by each are not yet confirmed; needs live
devtools/network inspection once the extension is loaded.
