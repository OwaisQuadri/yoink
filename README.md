# Yoink

Yoink is a Chrome extension with a local macOS helper for background video downloads. It detects streams in the current page and can inspect an episode in a separate headless browser without changing the visible Chrome tab.

## Features

- Detects direct MP4/WebM files, HLS playlists, and DASH manifests.
- Starts an isolated Playwright Chromium process for background jobs.
- Scans visible `SERVER N` controls inside the isolated browser.
- Selects the highest verified resolution, then prefers a direct source.
- Selects English subtitles when the player exposes a usable track.
- Downloads direct media through the isolated browser session.
- Uses ffmpeg for supported HLS/DASH transfers and final files.
- Reports selected server, quality, bytes, speed, media time, and estimated time.
- Keeps a job running when the popup or extension worker closes.
- Saves to a folder chosen through the macOS folder picker.
- Yoink can stop an active direct transfer and keep its completed part.
- Retains the existing detected-stream download buttons.

Yoink does not support DRM-protected media, CENC, SAMPLE-AES, authentication bypasses, paywall bypasses, or inaccessible encrypted streams.

## What stays untouched

A background job does not navigate, mute, style, play, record, or enter fullscreen in the visible Chrome tab. The extension sends only the current page URL and title to the local helper. The helper launches a separate headless browser with its own temporary profile.

## Requirements

- Yoink currently supports macOS.
- Yoink requires Google Chrome 116 or newer.
- The build requires Node.js and npm.
- The helper requires `ffmpeg` and `ffprobe`.
- The helper requires Playwright Chromium.

Install ffmpeg with Homebrew when needed:

```sh
brew install ffmpeg
```

## Build and install

```sh
npm install
npx playwright install chromium
npm run build
npm run helper:install
```

The helper installer prints the stable extension ID and the `dist/` path. Then:

1. Open `chrome://extensions`.
2. Turn on **Developer mode**.
3. Remove an older Yoink development build if its ID differs.
4. Select **Load unpacked**.
5. Choose this project's `dist/` folder.
6. Pin Yoink from Chrome's Extensions menu.

The unpacked extension has the stable ID `jojmbolliopfkecelobmepihmhlppceb`. The helper installer registers only that extension ID.

Run these commands after a code change:

```sh
npm run build
npm run helper:install
```

Then reload Yoink on `chrome://extensions`.

## Download an episode in the background

1. Open the episode page in Chrome.
2. Open Yoink.
3. Select **Choose folder** and pick the destination.
4. Select **Download in background**.
5. Close the popup or switch to another tab or application.
6. Reopen Yoink to check progress or stop the job.
7. Select **Show file** after completion.

The source page can close after the helper accepts the job. The helper performs discovery and playback in its isolated browser.

## Source selection

For each safe visible server control, the helper:

1. Activates the server in the isolated page.
2. Reads JW Player and native video quality choices.
3. Selects the highest advertised quality.
4. Starts playback in the isolated player.
5. Confirms decoded dimensions and duration.
6. Collects the matching MP4/WebM/HLS/DASH request.

Yoink ranks verified resolution first. A direct MP4/WebM source wins a tie because it avoids an unnecessary remux. Bitrate and stable server order break later ties. Subtitle availability does not outrank resolution.

The helper never clicks external links as server controls.

## Transfer behavior

Direct MP4/WebM sources are read in bounded byte ranges through the isolated browser session. This preserves access that depends on the browser session without sending media through extension messages. The helper writes each range to disk and keeps only one bounded chunk in memory.

Supported HLS/DASH sources use `ffmpeg` with the selected request headers. The `ffmpeg` process receives the media URL and required origin-scoped headers. Yoink does not write cookies, authorization values, or signed URLs to its normal status messages.

Active files use a `.partial` name. A completed file receives its final MP4/WebM name. Stopping a direct transfer keeps a `-partial` file after Yoink writes at least one media chunk.

## Local helper

Chrome Native Messaging connects the extension to `com.owaisquadri.yoink`. The Chrome-launched bridge forwards bounded JSON commands to a detached daemon over a private Unix socket. Media bytes never cross Native Messaging.

Helper files live under:

```text
~/Library/Application Support/Yoink/
```

The daemon stores atomic job snapshots under `jobs/<job-id>/job.json`. If the daemon restarts during a transfer, Yoink marks the job as interrupted. It does not claim that an interrupted transfer resumed.

The development installer writes Native Messaging manifests for Google Chrome and Chrome for Testing. A signed and notarized public macOS package is not included yet.

Remove the registered helper with:

```sh
npm run helper:uninstall
```

This command keeps completed downloads and job history.

## Existing stream downloads

- Direct MP4/WebM cards use `chrome.downloads`.
- HLS cards use the extension offscreen document and ffmpeg.wasm.
- The offscreen HLS path selects the highest-bandwidth variant.
- The offscreen HLS path rejects `#EXT-X-KEY` encryption.
- DASH detection exists, but the offscreen card path does not remux DASH.

## Development checks

```sh
npm test
npm run typecheck
npm run build
```

The helper tests cover protocol validation, secret redaction, atomic job storage, media ranking, filename safety, and ffmpeg progress parsing.

## Live test page

`https://www1.yoturkish.com/sevdigim-sensin-episode-1/`

The page currently exposes four server controls. Yoink must probe them at runtime and must not assume that Server 4 is the best choice. The headless helper completed the full episode from a verified 1280×720 MP4 source. The output contains H.264 video and AAC audio, and the visible Chrome page stayed untouched.
