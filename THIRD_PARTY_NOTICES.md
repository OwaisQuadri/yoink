# Third-party notices

Yoink's [MIT license](LICENSE) covers its own code. It does not replace these licenses or grant rights to downloaded content. This inventory covers the pinned build described in the [license audit](docs/license-audit.md). The FFmpeg dependency inventory and corresponding source remain incomplete. These notices alone do not make an app distributable.

Local builds include these documents under `Yoink.app/Contents/Resources/Legal/`. No notices in the published 0.0.2/build 3 app or disk image change through this repository update.

## FFmpeg and ffprobe

Both bundled tools identify themselves as FFmpeg 9.0.2 from Martin Riedl's static builds. Both architectures report GNU GPL version 3 or later. See the [GPL text](Resources/Licenses/FFMPEG-COPYING.GPLv3) and [FFmpeg legal information](https://ffmpeg.org/legal.html).

FFmpeg reports copyright 2000-2026 the FFmpeg developers. ffprobe reports copyright 2007-2026 the FFmpeg developers.

The bundle includes many static codec and support libraries. Their exact source revisions and full notices are not verified. A generic FFmpeg source link is not a substitute for matching corresponding source, dependency notices, or build scripts. Distribution builds stop until the [source blocker](docs/license-audit.md#ffmpeg-source-and-dependency-blocker) is resolved. This document is not a written source offer.

Yoink invokes these tools as separate processes. MIT on Yoink's own code does not remove GPL obligations for the tools or decide the legal classification of the combined distribution.

## Sparkle 2.10.0

Sparkle provides the updater framework. Its [complete license](Resources/Licenses/SPARKLE-LICENSE) includes its MIT terms and external notices for bsdiff, sais-lite, Ed25519, and `SUSignatureVerifier.m`. The file is a byte-for-byte copy from the pinned Sparkle artifact, verified against its source revision. Retain the entire file, not just its first MIT section.

## whisper.cpp v1.8.2 and ggml

The CPU-only `whisper-cli` uses whisper.cpp revision `4979e04f5dcaccb36057e059bbaed8a2f5288315`. Its [MIT license](Resources/Licenses/WHISPER-LICENSE) names The ggml authors, copyright 2023-2024.

The bundled CLI also incorporates these components:

- Sean Barrett's `stb_vorbis.c` v1.22. Yoink uses the MIT alternative and retains [both upstream alternatives](Resources/Licenses/WHISPER-STB-VORBIS-LICENSE). The build applies the bounds-check patch in `scripts/build-subtitles.sh`.
- David Reid's `miniaudio.h`. Yoink uses the MIT No Attribution alternative and retains [both upstream alternatives](Resources/Licenses/WHISPER-MINIAUDIO-LICENSE).
- The YaRN algorithm in ggml CPU operations. The source attributes copyright 2023 to Jeffrey Quesnelle and Bowen Peng. Their [MIT license](Resources/Licenses/WHISPER-YARN-LICENSE) is included.

The audited build disables llamafile and KleidiAI. This inventory does not cover optional backends or other whisper.cpp executables that the build does not ship. Recheck notices if those settings change.

## Whisper multilingual base model

The bundled `ggml-base.bin` comes from `ggerganov/whisper.cpp` model revision `5359861c739e955e79d9a303bcbc70fb988958b1`. Its model card declares MIT. The [OpenAI Whisper MIT license](Resources/WHISPER-MODEL-LICENSE) names OpenAI, copyright 2022.

## System software

The app and tools also link macOS system libraries and frameworks. They are not copied into the app as third-party framework distributions. This notice does not relicense Apple's software or establish patent clearance for codecs.
