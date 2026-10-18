# Yoink

Yoink is a Mac app that saves the video from a web page as an MP4 file for offline playback.

## License and responsible use

Yoink's own code uses the [MIT license](LICENSE). Anyone can use, modify, and redistribute it, including commercially. Download only content you own or are authorized to save. Read the [responsible-use guidance](RESPONSIBLE_USE.md).

Bundled dependencies keep their own licenses. The [third-party notices](THIRD_PARTY_NOTICES.md) and [license audit](docs/license-audit.md) describe their obligations and unresolved distribution blockers. MIT does not relicense the bundled LGPL FFmpeg tools.

## Use

1. Open Yoink.
2. Paste the link of the page that plays the video.
3. Use **Subtitle options** beside **Download** to choose subtitles for this download. Then click **Download**. The first time, choose the folder for your videos.
4. When the row shows **Saved**, click **Play**, or open the file from the folder.

## Subtitles

Choose **None**, **Source captions**, **Original only**, or **Original + English** beside the Download button. **None** skips subtitle downloads and processing. **Source captions** keeps available captions without generation. The two language choices include a **Generate missing subtitles** switch. Each download keeps its settings when queued or retried.

The default is **Original + English** with generation enabled. Yoink keeps matching source text captions and generates missing tracks from the selected audio. English audio gets one English track, not a second translated copy. Forced-only captions do not replace full subtitles.

With generation disabled, Yoink never runs speech recognition, including language detection. The language choices use the selected audio's language metadata. If that metadata is missing, Yoink reports a warning rather than guessing from captions. **Source captions** does not need audio language metadata.

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

Version 0.0.3/build 4 introduced source-built FFmpeg tools to replace the unverified binaries in withdrawn 0.0.2/build 3. Do not redistribute the withdrawn binaries. Before bumping versions on `main`, complete independent review and the human release checks below.

Requires macOS 14 or newer, Xcode command-line tools, CMake, and `pkg-config`. Build dependencies download over HTTPS.

```sh
./scripts/build-app.sh
```

The script caches pinned FFmpeg source, whisper.cpp source, and the multilingual model in `vendor/`. It verifies archive and model SHA-256 checksums. It builds universal LGPL `ffmpeg` and `ffprobe` from the official FFmpeg 9.0.2 source, plus a universal CPU-only `whisper-cli`, and writes `build/Yoink.app`. FFmpeg uses native codecs and macOS system libraries rather than unverified prebuilt codec libraries. See the [FFmpeg source and rebuild instructions](docs/ffmpeg-source.md). The model adds 147,951,465 bytes to the bundle. The engine links only system libraries and does not require Homebrew on the playback Mac.

Use `./scripts/build-app.sh --local` for an ad-hoc signed app without notarization or a disk image. This does not install the app.

Without `--local`, a Developer ID certificate in Keychain enables signing and creation of `build/Yoink.dmg`. The script submits an app ZIP for notarization using the `yoink` Keychain profile, then staples and validates the app before packaging it. It validates the staged app's ticket, creates the disk image, then notarizes, staples, and validates the disk image. A failed notarization or ticket check fails the build. Set `YOINK_NOTARY_PROFILE` only to use a different `notarytool` Keychain profile.

The app embeds Sparkle from the version pinned in `Package.resolved`. The build script signs its framework, updater, installer, and downloader before signing the app.

## Check subtitles locally

Build with `./scripts/build-app.sh --local`, then run `swift test`. Live inference and HTTP downloader tests require fixtures. Run `zsh scripts/check-subtitles.sh` to create Spanish and English speech fixtures, exercise direct files, DASH, and HLS source captions with a timestamp discontinuity, and retain the output files for playback inspection. The check script requires Python 3 for a loopback HTTP server and uses macOS speech voices. Set `YOINK_CHECK_LONG=1` to include a 610-second chunk-boundary check.

Open a saved MP4 in QuickTime Player. Select the original language, select English, and turn subtitles off. Check that the picture stays unchanged and the subtitles follow the speech. A successful subtitle test does not prove a model's accuracy for every language or recording.

`scripts/build-subtitles.sh` pins whisper.cpp v1.8.2 and the model revision and checksums. Its narrow `stb_vorbis.c` patch compares an integer offset with the buffer length before pointer arithmetic. `Tests/Dependencies/stb-vorbis-bounds.c` checks the first byte, last byte, end of buffer, and `UINT_MAX` with undefined-behavior sanitization. The patch avoids an upstream pointer-overflow warning without removing the bounds check.

Whisper and its model use the MIT license. The bundle includes `WHISPER-LICENSE` and `WHISPER-MODEL-LICENSE`. `Contents/Resources/Legal/` also contains Yoink's MIT license, responsible-use guidance, full Sparkle and embedded Whisper notices, and the FFmpeg source package. See the [whisper.cpp CLI documentation](https://github.com/ggml-org/whisper.cpp/blob/v1.8.2/examples/cli/README.md) and [OpenAI Whisper model license](https://github.com/openai/whisper/blob/main/LICENSE). FFmpeg and ffprobe retain their upstream licensing requirements.

## Prepare an update locally

1. For every release, increase both `CFBundleShortVersionString` (the displayed version) and `CFBundleVersion` (the build number) in `Resources/Info.plist`. Both must be greater than in the preceding release. Never reuse a release version or build number, or relabel an existing artifact. Sparkle compares the build number, not the displayed version.
2. Build the final app with `./scripts/build-app.sh` and wait for notarization and ticket validation to succeed.
3. Run `./scripts/generate-appcast.sh` on the signing Mac. It writes a versioned disk image, signed `appcast.xml`, FFmpeg source package, and `SHA256SUMS` under `build/updates/`. It publishes nothing.
4. Before distribution, validate the original disk image with `xcrun stapler validate build/Yoink.dmg`. Generate the appcast again after any change to the disk image, including stapling.

The script uses the per-app Keychain account matching `CFBundleIdentifier`, under the service `https://sparkle-project.org`. It checks the public key against `SUPublicEDKey` before signing. Keep this Keychain item safe and backed up. Do not regenerate or replace it for each release, and do not put private keys in the repository.

The generated feed and archive both carry EdDSA signatures. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require verification before trusting feed content or extracting an archive. Do not edit a signed appcast without regenerating its signature.

## Automatic releases

A push to `main` that changes `Resources/Info.plist` automatically publishes a stable Sparkle update when **both** version values increase. A nonversion plist edit skips publication. A partial bump, rollback, reused version/build, existing release (including a draft), or existing tag fails closed. Local build, generator, and test commands never publish.

`.github/workflows/release.yml` runs on standard GitHub-hosted `macos-15`, not a container or self-hosted machine. Standard hosted runners are free for this public repository. The workflow checks the push-before plist and verifies existing release appcasts with the unchanged per-app Sparkle key before comparing their versions. It requires a preceding stable release; there is no unsigned first-release fallback. It also checks withdrawn drafts, without republishing them.

The workflow resolves `Package.resolved`, uses the pinned source-built dependency pipeline with warnings as errors, runs dependency regressions and the subtitle fixture suite, and signs/notarizes the app and disk image. It checks notices and matching FFmpeg source with `Tests/Dependencies/ffmpeg-source-package.zsh`, then inspects the mounted disk image. It stages all four generated assets in a draft, downloads and verifies them, and automatically publishes that draft as latest stable at the exact triggering commit. No approval click is required. It downloads all four published assets again, checks checksums, Sparkle signatures, Developer ID signing and stapling, and compares every asset and the source package to the built copies. The source recipe and original archive are checked before publication and remain alongside each download.

Runs are serialized without canceling an active signing job. Immediately before publication they recheck the `main` head and preceding latest release. A stale run fails instead of promoting an older update. Reruns do not replace releases, tags, or assets. Avoid concurrent manual release publication; GitHub has no atomic compare-and-publish operation across its branch and release APIs.

### Signing secrets

An owner must separately approve and configure these four GitHub Actions secrets. They are not supplied by this change. No signing secrets are accessible through a pull-request trigger.

| Secret | Value |
| --- | --- |
| `MACOS_SIGNING_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as PKCS#12. |
| `MACOS_SIGNING_P12_PASSWORD` | Password protecting that export. |
| `SPARKLE_PRIVATE_KEY` | Existing per-app Sparkle private-key export, as base64 text. Use the Keychain account matching `CFBundleIdentifier` under `https://sparkle-project.org`. Never generate or replace the key for CI. |
| `APPLE_NOTARY_CREDENTIALS_JSON` | JSON object with `appleID`, `appSpecificPassword`, and `teamID` string fields. |

The notary JSON schema is:

```json
{"appleID":"<developer-apple-id>","appSpecificPassword":"<app-specific-password>","teamID":"<developer-team-id>"}
```

The Swift helper parses secrets from environment variables. It creates a temporary keychain, imports the certificate and existing Sparkle key, and verifies the key against `SUPublicEDKey`. Passwords travel through standard input or hidden interactive prompts, not command arguments. The notary profile is `yoink-ci`. Cleanup restores the original keychain configuration and deletes temporary credentials even after failure. No credential artifacts or caches are uploaded. A forcibly terminated hosted runner relies on the hosted VM's disposal as the final cleanup boundary.

### Failure recovery and human checks

Before pushing a version bump, complete the [license distribution checks](docs/license-audit.md#distribution-hold-and-remediation). Review source/notices against both architectures, recipients' source access, and license compatibility. Automation checks package consistency, not legal compliance. Changes to dependencies or notices need renewed review before a release-triggering push.

The interactive update checks below, QuickTime playback, real authorized HTTPS HLS/DASH media, and minimum-supported **macOS 14 runtime testing** remain human requirements. A macOS 15 runner does not prove macOS 14 compatibility or the full Sparkle installation/relaunch experience. Complete those checks before a release-triggering bump; retain the results separately. Do not treat the workflow's synthetic fixture tests as a substitute.

If a run fails before draft creation, inspect its log and correct the cause. A rerun is safe only while its triggering commit is still the `main` head and its version/tag remains unused. Otherwise push a fresh increase of both version values. If a draft or tag was left behind, an owner must inspect it and explicitly resolve the abandoned unpublished state before retrying. The workflow never deletes or overwrites it, and an incomplete draft without an appcast blocks subsequent releases. Never reuse a published version/build or remove a published tag to make a rerun pass.

If postpublication verification fails, the release may already be public. Investigate immediately. An owner can withdraw it and restore a previously verified latest release, then fix forward with higher version/build values. Do not silently replace published assets. A network error after publication does not imply that nothing was published.

`SUFeedURL` resolves the latest release's signed `appcast.xml`. The appcast's enclosure points to its versioned tag URL, not a mutable latest archive. Existing copies without Sparkle need one manual installation of an updater-enabled release.

Run the isolated release regression checks with `zsh scripts/release/test.zsh`. They use mocked GitHub and signing tools, including failed uploads, corrupt staged assets, stale heads, changed latest releases, and successful staged/public download verification. They make no remote mutations.

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
