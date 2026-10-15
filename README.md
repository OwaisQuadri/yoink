# Yoink

Yoink is a Mac app that saves the video from a web page as an MP4 file for offline playback.

## Use

1. Open Yoink.
2. Paste the link of the page that plays the video.
3. Click **Download**. The first time, choose the folder for your videos.
4. When the row shows **Saved**, click **Play**, or open the file from the folder.

## How it works

Yoink loads the page in a hidden web view inside the app. A script in every frame records the video requests that the player makes, and it starts playback with the sound muted. Yoink ignores ad videos and selects the HLS (HTTP Live Streaming) playlist, the DASH (Dynamic Adaptive Streaming over HTTP) manifest, or the direct file. It then gives that address, with the page's referrer and cookies, to the bundled `ffmpeg`. `ffmpeg` copies the highest quality stream into one MP4 file without re-encoding.

All work runs on the Mac. Yoink has no server.

Yoink does not save DRM-protected (Digital Rights Management) video.

## Build

Requires macOS 14 or newer and Xcode command-line tools.

```sh
./scripts/build-app.sh
```

The script downloads a static universal `ffmpeg` once into `vendor/` and writes `build/Yoink.app`. Copy that app to the Applications folder on the other Mac. The app is ad-hoc signed, so on first launch, right-click it and choose **Open**.
