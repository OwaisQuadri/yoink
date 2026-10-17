# Third-party notices

Yoink's [MIT license](LICENSE) covers its own code. It does not replace these licenses or grant rights to downloaded content. This inventory covers the next-version build described in the [license audit](docs/license-audit.md). Release review must verify the final binaries, notices, and source access.

Builds include these documents under `Yoink.app/Contents/Resources/Legal/`. No notices in the withdrawn 0.0.2/build 3 app or disk image change through this repository update.

## FFmpeg and ffprobe

The next-version tools build from the official FFmpeg 9.0.2 source with [Yoink's documented compiler-annotation patch](docs/ffmpeg-source.md) with GPL, nonfree, and version-3-only components disabled. FFmpeg's code and Yoink's patch use GNU LGPL version 2.1 or later, not the project's MIT license. See the [LGPL text](Resources/Licenses/FFMPEG-COPYING.LGPLv2.1), [upstream license summary](Resources/Licenses/FFMPEG-LICENSE.md), and [FFmpeg legal information](https://ffmpeg.org/legal.html).

FFmpeg identifies copyright 2000-2026 the FFmpeg developers. ffprobe identifies copyright 2007-2026 the FFmpeg developers. This software is based in part on the work of the Independent JPEG Group. Yoink does not modify FFmpeg's IJG-derived files.

The exact source archive, patch, all embedded source notices, and build recipe accompany the app in `Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz`. The release download must also include the source package. See the [rebuild instructions](docs/ffmpeg-source.md). The build uses macOS system libraries, not statically included third-party codec libraries. Recipients may modify and rebuild the tools under their upstream license. No restriction on reverse engineering for debugging those modifications is added.

Yoink invokes these tools as separate processes. MIT does not remove their LGPL obligations or decide the combined distribution's legal classification. The old provider binaries in withdrawn 0.0.2/build 3 instead report GPL version 3 or later. Their [GPL text](Resources/Licenses/FFMPEG-COPYING.GPLv3) is retained for the historical audit, not as the license of the new build. Their unresolved [source blocker](docs/license-audit.md#ffmpeg-source-and-dependency-blocker) still prevents redistributing those old binaries. This document makes no written source offer.

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
