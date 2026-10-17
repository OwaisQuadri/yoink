# Yoink

Yoink is a Mac app that saves the video from a web page as an MP4 file for offline playback.

## Use

1. Open Yoink.
2. Paste the link of the page that plays the video.
3. Click **Download**. The first time, choose the folder for your videos.
4. When the row shows **Saved**, click **Play**, or open the file from the folder.

## Subtitles

Yoink keeps source text captions and generates missing original-language and English subtitles from the selected audio. English audio gets one English track, not a second translated copy. Forced-only captions do not replace full subtitles.

HTML captions must belong to the selected video. If a blob player hides that ownership, Yoink uses manifest captions or audio generation instead of guessing.

Subtitles are selectable MP4 tracks, never burned into the picture. In QuickTime Player, choose **View > Subtitles** to turn them on or off and select a language. Other players have their own subtitle controls.

The app includes the multilingual Whisper `base` model and runs transcription and English translation on your Mac. It needs no account, API key, first-use model download, or speech service. Generated text can contain recognition and translation errors. Language detection uses the first audio chunk with detected speech. The selected language stays fixed for the rest of the video.

If a subtitle track fails, Yoink saves the playable video and any usable tracks. The row shows **Saved with subtitle warning** and names the unavailable track. Hover over the warning to read the full reason. Bitmap captions cannot become MP4 text tracks, so Yoink reports them as unavailable and tries to generate replacements. Source styling becomes plain text.

Generation runs one job at a time in five-minute audio chunks. Downloading other videos can continue. **Stop** cancels processing and waits for the active tool to exit before **Try Again** becomes available.

## How it works

Yoink loads the page in a hidden web view inside the app. A script in every frame records the video requests that the player makes, and it starts playback with the sound muted. Yoink ignores ad videos and selects the HLS (HTTP Live Streaming) playlist, the DASH (Dynamic Adaptive Streaming over HTTP) manifest, or the direct file. It then gives that address, with the page's referrer and cookies, to the bundled `ffmpeg`. `ffmpeg` copies the highest quality stream into one MP4 file without re-encoding.

All work runs on the Mac. Yoink has no server.

Yoink does not save DRM-protected (Digital Rights Management) video.

## Build

Requires macOS 14 or newer, Xcode command-line tools, and CMake. Build dependencies download over HTTPS.

```sh
./scripts/build-app.sh
```

The script caches pinned `ffmpeg`, `ffprobe`, whisper.cpp source, and the multilingual model in `vendor/`. It verifies archive and model SHA-256 checksums, builds a universal CPU-only `whisper-cli`, and writes `build/Yoink.app`. The model adds 147,951,465 bytes to the bundle. The engine links only system libraries and does not require Homebrew on the playback Mac.

Use `./scripts/build-app.sh --local` for an ad-hoc signed app without notarization or a disk image. This does not install the app.

Without `--local`, a Developer ID certificate in Keychain enables signing and creation of `build/Yoink.dmg`. The script submits an app ZIP for notarization using the `yoink` Keychain profile, then staples and validates the app before packaging it. It validates the staged app's ticket, creates the disk image, then notarizes, staples, and validates the disk image. A failed notarization or ticket check fails the build. Set `YOINK_NOTARY_PROFILE` only to use a different `notarytool` Keychain profile.

The app embeds Sparkle from the version pinned in `Package.resolved`. The build script signs its framework, updater, installer, and downloader before signing the app.

## Check subtitles locally

Build with `./scripts/build-app.sh --local`, then run `swift test`. Live inference and HTTP downloader tests require fixtures. Run `zsh scripts/check-subtitles.sh` to create Spanish and English speech fixtures, exercise direct files, DASH, and HLS source captions with a timestamp discontinuity, and retain the output files for playback inspection. The check script requires Python 3 for a loopback HTTP server and uses macOS speech voices. Set `YOINK_CHECK_LONG=1` to include a 610-second chunk-boundary check.

Open a saved MP4 in QuickTime Player. Select the original language, select English, and turn subtitles off. Check that the picture stays unchanged and the subtitles follow the speech. A successful subtitle test does not prove a model's accuracy for every language or recording.

`scripts/build-subtitles.sh` pins whisper.cpp v1.8.2 and the model revision and checksums. Its narrow `stb_vorbis.c` patch compares an integer offset with the buffer length before pointer arithmetic. `Tests/Dependencies/stb-vorbis-bounds.c` checks the first byte, last byte, end of buffer, and `UINT_MAX` with undefined-behavior sanitization. The patch avoids an upstream pointer-overflow warning without removing the bounds check.

Whisper and its model use the MIT license. The bundle includes `WHISPER-LICENSE` and `WHISPER-MODEL-LICENSE`. See the [whisper.cpp CLI documentation](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/examples/cli/README.md) and [OpenAI Whisper model license](https://github.com/openai/whisper/blob/main/LICENSE). FFmpeg and ffprobe retain their upstream licensing requirements.

## Prepare an update locally

1. For every release, increase both `CFBundleShortVersionString` (the displayed version) and `CFBundleVersion` (the build number) in `Resources/Info.plist`. Both must be greater than in the preceding release. Never reuse a release version or build number, or relabel an existing artifact. Sparkle compares the build number, not the displayed version.
2. Build the final app with `./scripts/build-app.sh` and wait for notarization and ticket validation to succeed.
3. Run `./scripts/generate-appcast.sh` on the signing Mac. It writes a versioned disk image and signed `appcast.xml` under `build/updates/`. It publishes nothing.
4. Before distribution, validate the original disk image with `xcrun stapler validate build/Yoink.dmg`. Generate the appcast again after any change to the disk image, including stapling.

The script uses the per-app Keychain account matching `CFBundleIdentifier`, under the service `https://sparkle-project.org`. It checks the public key against `SUPublicEDKey` before signing. Keep this Keychain item safe and backed up. Do not regenerate or replace it for each release, and do not put private keys in the repository.

The generated feed and archive both carry EdDSA signatures. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require verification before trusting feed content or extracting an archive. Do not edit a signed appcast without regenerating its signature.

## Publish an approved update

Publication is separate from the local scripts and requires release approval.

1. Complete the update checks below on the final artifact. Verify that both version values increased against the preceding release's verified signed appcast, or the pre-release source history for the first published release. This is a required manual publication check; the local generator does not query published releases.
2. Create a GitHub release with the tag `v` followed by `CFBundleShortVersionString`.
3. Attach both generated files from the versioned `build/updates/` directory. Keep their filenames unchanged. The appcast points to this specific tag's archive, not the mutable latest archive.
4. Publish the release as the latest stable release. `SUFeedURL` in `Resources/Info.plist` resolves its `appcast.xml` asset.
5. Download both assets from their published URLs and verify them with Sparkle's `sign_update --verify`, using the per-app `--account`. For the archive, supply the `sparkle:edSignature` from the appcast as the final argument.

Do not publish a new latest release without its appcast. Until the first release exists, manual checks report an update retrieval error. Existing copies without Sparkle need one manual installation of the first updater-enabled release.

## Check an update before release

Use disposable app copies with a unique test bundle identifier in both source and destination apps. Do not change the installed app or production feed. Isolating the home directory alone does not isolate macOS preferences.

1. Verify the bundle with `codesign --verify --deep --strict build/Yoink.app`. Inspect `otool -L` and `otool -l` on its executable for Sparkle and `@executable_path/../Frameworks` in both architectures.
2. Launch the app and choose **Yoink > Check for Updates…**. Verify that Sparkle opens and that the menu disables while a check is in progress.
3. With fresh preferences, launch twice and verify the automatic-check consent prompt. Decline and confirm that automatic checks stay disabled. Repeat with consent enabled.
4. Create older and newer test copies in writable directories. Lower the older copy's build number, set the same test bundle identifier on both, and point their `SUFeedURL` at a loopback feed. Permit local networking only in the test plists when using HTTP. Re-sign both copies.
5. Archive the newer test copy and generate its feed with Sparkle's `generate_appcast`, using the real signing account and a loopback `--download-url-prefix`. Serve the directory locally. Retain `SUPublicEDKey` and both signature-enforcement settings in the test copies.
6. Trigger a scheduled check in the older copy. Verify that only the newer-build banner appears, including during an active video download. Click **View Update…** and verify that Sparkle presents the update.
7. Accept the update in the disposable copy. Verify download, signature validation, installation, relaunch, and the new build number. With automatic downloads enabled by the user, also verify staging and installation after a normal quit without a forced restart.
8. Change one byte inside the signed feed content and verify rejection. Repeat with a changed archive and its original signature. Restore valid artifacts and verify that a same-build feed offers no update.

Keep screenshots, updater logs, build numbers, and signature verification results with the release review. Repeat the installation test with notarized source and destination apps before publication. See Sparkle's [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/), and [manual signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing).
