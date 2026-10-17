# License audit

## Result and scope

Audit date: 2026-10-17. Baseline source: `995bee9d517fdc62fdd116fe94dc1bb1fbd61d33`. Previously published release: [v0.0.2](https://github.com/OwaisQuadri/yoink/releases/tag/v0.0.2), displayed version 0.0.2, build 3.

**Distribution remains blocked.** The bundled FFmpeg and ffprobe report GPL-3.0-or-later, but their exact corresponding source and static dependency notices are not established. Adding MIT for Yoink's own code and copying license texts does not resolve that gap.

This audit covers the repository, pinned download archives, the retained release app, and the app inside the release disk image. The disk image was mounted read-only. Its SHA-256 matches the published GitHub asset digest. This implementation did not change the installed app, release asset bytes, source version, or build number. The owner separately directed withdrawal of unverified public binaries. The retained v0.0.2 release is now draft, verified through GitHub release metadata. This report is an engineering inventory, not legal advice, a legal certification, or a patent clearance opinion.

The source repository previously contained no project license. This change adds the owner-approved MIT license and separate [responsible-use guidance](../RESPONSIBLE_USE.md). It adds verified dependency texts and bundles the documents in future local builds. It does not retroactively insert notices into the published app.

## Artifact identity

The inspected `Yoink-0.0.2-3.dmg` has SHA-256:

```text
e859c9cc39115f033e51b34c4e0c7ed323d7d638165bb0abbe766a328b7b684b
```

The retained signed app contains these universal tool hashes. Signing changes binary bytes, so these identify the inspected artifact, not a rebuild.

| Resource | SHA-256 |
| --- | --- |
| `ffmpeg` | `f6ae0f260f210d632c61514c0bfc31489a81668882c615690019b7d2bbd1f1a8` |
| `ffprobe` | `61c862d0d5a6b0dd8f589eea5fb76b4ddd2d9455aa57be285ac670f789bbabf7` |
| `whisper-cli` | `523ef257414d4af83d0abefbad48cb09562387e4d7aecfaf1197707a200076c3` |

GitHub's release metadata identifies the same baseline commit. Both the retained app and mounted disk-image app contain only `WHISPER-LICENSE` and `WHISPER-MODEL-LICENSE` as named license files. Neither contains a project MIT license, a full Sparkle license file, an FFmpeg GPL text, or a corresponding-source package.

## Pinned components

### FFmpeg and ffprobe

`scripts/build-app.sh` pins these archives from `https://ffmpeg.martin-riedl.de/download/macos/{architecture}/{revision}/{tool}.zip`. Archive contents were inspected. Each ZIP contains only its named executable, without source or license files. Cached archive SHA-256 values match the script.

| Architecture | Provider revision | Tool | Archive SHA-256 |
| --- | --- | --- | --- |
| arm64 | `1789931890_9.0.2` | ffmpeg | `c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924` |
| arm64 | `1789931890_9.0.2` | ffprobe | `fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6` |
| amd64 | `1789931006_9.0.2` | ffmpeg | `7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4` |
| amd64 | `1789931006_9.0.2` | ffprobe | `2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd` |

All four executable slices were run with `-version`, `-L`, and `-buildconf`, using `arch -arm64` and `arch -x86_64`. They report version `9.0.2-https://www.martin-riedl.de`. `-L` states GNU GPL version 3 or later for both tools. arm64 reports Apple clang 14.0.0 `clang-1400.0.29.102`. x86_64 reports `clang-1400.0.29.202`.

Both tools and architectures report these shared configure flags, excluding the architecture-specific build prefix:

```text
--pkg-config-flags=--static
--extra-version=https://www.martin-riedl.de
--enable-gray --enable-libxml2 --enable-version3 --enable-gpl --enable-openssl
--enable-libfreetype --enable-fontconfig --enable-libharfbuzz --enable-libbluray
--enable-libsnappy --enable-libsrt --enable-libvmaf --enable-libass
--enable-libklvanc --enable-libzimg --enable-libzvbi --enable-libaom
--enable-libdav1d --enable-libopenh264 --enable-libopenjpeg --enable-librav1e
--enable-libsvtav1 --enable-libvpx --enable-libvvenc --enable-libwebp
--enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus
--enable-libvorbis --enable-libtheora
```

No `--enable-nonfree` appears. That absence does not prove compliance or establish all dependency licenses. `otool -L` reports system libraries and frameworks, not separate external codec dylibs. Together with the provider's static-build description, this supports treating the external codecs as part of each tool's source and notice review.

Yoink invokes these executables through `Process` in `Sources/Yoink/Subtitles/MediaCommand.swift`. It does not link FFmpeg libraries in `Package.swift`. The [FFmpeg legal page](https://ffmpeg.org/legal.html) distinguishes GPL-enabled builds from its LGPL linking checklist. That checklist is not a compliance recipe for these GPL binaries. MIT on the caller does not relicense the tools or settle the combined distribution's legal classification.

### FFmpeg source and dependency blocker

The [provider page](https://ffmpeg.martin-riedl.de/) links its [public build scripts](https://git.martin-riedl.de/ffmpeg/build-script). Investigation found [commit `6a611e19870e197bc37c6e4c7fccddebd3715466`](https://git.martin-riedl.de/ffmpeg/build-script/commit/6a611e19870e197bc37c6e4c7fccddebd3715466), which sets `version/ffmpeg` to 9.0.2. This is a candidate recipe, not verified provenance for either binary revision.

At that commit, `script/build-ffmpeg.sh` downloads the FFmpeg release tarball. `script/build-x264.sh` downloads `x264-master.tar.gz` from a mutable master branch without a source checksum. The recipe alone cannot recover the exact historical x264 input. The provider's main branch inspected during this audit instead points to 9.0.1 at `f63b8aab8f5ce1a067da86ba69e34a36a7e217e5`. A current branch link is therefore insufficient evidence for these 9.0.2 binaries.

The two pinned download directories returned HTTP 403 to directory-index requests. The page and inspected build scripts did not establish a matching complete source bundle or an archive-to-recipe mapping. This finding does not assert that the provider has no source. It records what this audit could verify. No provider contact or source request was sent.

Unresolved inputs include the exact FFmpeg source, any modifications, every statically included dependency's revision and license notices, transitive dependencies, and the scripts and settings needed to build them. Codec version labels and upstream homepages cannot fill those gaps. In particular, OpenSSL, x264, x265, VVenC, and the other enabled libraries require version-specific review, not an assumed license list.

Before distribution, obtain and preserve the actual corresponding source and build materials for both architectures, including static dependencies and modifications. Verify their mapping to all four downloaded archives. Review all notices and license compatibility from those exact materials. Then provide recipients the source through a valid GPLv3 section 6 distribution method, with clear directions alongside the binaries. For download distribution, accompanying equivalent source access is an option to assess. This report makes no written offer and does not substitute a generic upstream URL for corresponding source.

If the provider cannot supply those materials, the alternative is a separately approved, reproducible FFmpeg build from pinned, retained source and dependency inputs. A smaller dependency set may reduce the review work. This audit does not change codecs, versions, or build provenance to claim a repair that did not occur.

### Sparkle

`Package.resolved` pins Sparkle 2.10.0 at `eef1a539a373c1f1a320624b1130fc5de7b2e100`. Its [package manifest](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/Package.swift) pins `Sparkle-for-Swift-Package-Manager.zip` with checksum `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`.

The artifact's top-level `LICENSE` matches the [source license](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/LICENSE) byte for byte. It includes Sparkle's MIT terms, bsdiff's BSD terms, sais-lite's MIT terms, Ed25519's zlib-style terms, and the BSD notice for `SUSignatureVerifier.m`.

The baseline build copies only `Sparkle.framework`, not the artifact's top-level license. The inspected framework resources do not contain that complete license. The update-alert and permission-prompt nibs contain `Copyright Apple Inc., 2012`, which is not a substitute for the Sparkle and external notices. The framework and Updater plists identify Sparkle 2.10.0/build 2064, without `NSHumanReadableCopyright`. Future local packaging includes the verified complete license outside the framework, before signing.

### whisper.cpp and embedded code

`scripts/build-subtitles.sh` pins v1.8.2 at `4979e04f5dcaccb36057e059bbaed8a2f5288315`. Source archive SHA-256 is `ec8e33f4c838ed459ad0a23da255c0262f150a6f54839a17e504ddf1495305d5`, verified against the cached archive. [The source license](https://github.com/ggml-org/whisper.cpp/blob/4979e04f5dcaccb36057e059bbaed8a2f5288315/LICENSE) is MIT, copyright 2023-2024 The ggml authors. The existing bundle includes this text.

The CLI's `examples/common-whisper.cpp` includes `stb_vorbis.c` and `miniaudio.h`. Their license blocks are in those exact pinned files, not in the top-level MIT text. The new copies preserve both alternatives verbatim, excluding only the C comment delimiters. Yoink selects MIT for stb_vorbis and MIT No Attribution for miniaudio. The existing build patch changes only stb_vorbis's offset bounds check, with the regression test in `Tests/Dependencies/stb-vorbis-bounds.c`.

`ggml/src/ggml-cpu/ops.cpp` attributes its YaRN algorithm to Jeffrey Quesnelle and Bowen Peng under MIT. The included YaRN text comes from [revision `995db5b575e75230b3384d658f8b944c9662f775`](https://github.com/jquesnelle/yarn/blob/995db5b575e75230b3384d658f8b944c9662f775/LICENSE), matching that attribution. The original borrowed-code revision is not specified by ggml. This is notice preservation, not a claim to recover that revision.

Both retained CMake caches have `GGML_LLAMAFILE=OFF` and `GGML_CPU_KLEIDIAI=OFF`. Their optional source notices do not describe shipped backends in this build. `examples/json.hpp` is used by the unshipped server and LSP examples, not this CLI. CPU-only tools link system libraries, including Accelerate. Reaudit optional code if build settings or shipped targets change.

### Whisper model

The model revision is `5359861c739e955e79d9a303bcbc70fb988958b1` in `ggerganov/whisper.cpp` on Hugging Face. The pinned [model card](https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/README.md) declares MIT. `ggml-base.bin` SHA-256 is `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`, checked by the build.

`Resources/WHISPER-MODEL-LICENSE` matches the [OpenAI Whisper license](https://github.com/openai/whisper/blob/7858aa9c08d98f75575035ecd6481f462d66ca27/LICENSE) byte for byte. The existing app already includes it. No separate rights in recordings or generated subtitles follow from licensing the model.

## Verified text copies

These hashes identify the preserved license texts. The FFmpeg GPL copy is from [FFmpeg commit `32b9574ae41e2821fab823f56dec45ba1244fc14`](https://github.com/FFmpeg/FFmpeg/blob/32b9574ae41e2821fab823f56dec45ba1244fc14/COPYING.GPLv3). The canonical GPL text does not identify the missing binary source.

| File under `Resources/` | SHA-256 |
| --- | --- |
| `Licenses/FFMPEG-COPYING.GPLv3` | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |
| `Licenses/SPARKLE-LICENSE` | `389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe` |
| `Licenses/WHISPER-LICENSE` | `e562a2ddfaf8280537795ac5ecd34e3012b6582a147ef69ba6a6a5c08c84757d` |
| `Licenses/WHISPER-STB-VORBIS-LICENSE` | `9407f57d550d1d36974de15c7aad3dbf21e59c4b3312fc762157f05fdea6ff41` |
| `Licenses/WHISPER-MINIAUDIO-LICENSE` | `1d13e0cd56bb6bff8c66eb67084765fbefddcfd931922d2a75c072a9efb7cde9` |
| `Licenses/WHISPER-YARN-LICENSE` | `c3ec00ded224ebaaa673373961babc2d79f3081914897f3325cb7927a76234c1` |
| `WHISPER-MODEL-LICENSE` | `b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d` |

## Distribution hold and remediation

`scripts/build-app.sh` rejects every invocation except `--local` before dependency downloads, compilation, signing, or notarization. There is no bypass flag. Local builds are for development, not distribution. Removing the stop requires a reviewed source-compliance repair, not merely adding license files.

Before any new release:

1. Resolve the FFmpeg source and dependency blocker above.
2. Check the full source and notices against the final binaries for both architectures.
3. Verify the source-access method and license compatibility, with qualified legal review where needed.
4. Inspect the final app and disk image for all notices and source directions.
5. Increase both version values and complete the existing signing and update checks.

The existing 0.0.2/build 3 distribution has the recorded gaps. The owner withdrew it to draft without deleting assets or its tag. Do not republish it or silently relabel or replace its assets. The authorized next-version repair must use a new version and verified source provenance.

## Reproduce the checks

Set `app` to the app under inspection and `dmg` to the retained release image. Keep release artifacts read-only.

```sh
shasum -a 256 "$dmg"
for tool in ffmpeg ffprobe; do
  for architecture in arm64 x86_64; do
    arch -"$architecture" "$app/Contents/Resources/$tool" -version
    arch -"$architecture" "$app/Contents/Resources/$tool" -L
    arch -"$architecture" "$app/Contents/Resources/$tool" -buildconf
  done
done
fd -HI 'LICENSE|COPYING|NOTICE' "$app"
otool -L "$app/Contents/Resources/ffmpeg"
otool -L "$app/Contents/Resources/whisper-cli"
shasum -a 256 Resources/Licenses/* Resources/WHISPER-MODEL-LICENSE
zsh -n scripts/build-app.sh Tests/Dependencies/build-app-license-gate.zsh
zsh Tests/Dependencies/build-app-license-gate.zsh
```

The gate regression check uses a temporary script copy and a mocked downloader. It verifies that distribution invocations stop before downloads and `--local` reaches dependency preparation. It does not notarize or publish anything.

## Other rights and limits

The [Open Source Definition](https://opensource.org/osd) does not permit a field-of-use restriction in an open-source license. Responsible-use guidance therefore remains separate from MIT and adds no license condition. Download authorization concerns content rights, not who may use Yoink's code.

Copyright compliance does not establish trademark permission, codec patent clearance, or permission to bypass access controls. The MIT license has no express patent grant. Applicable laws can limit warranty disclaimers and exclusions of liability. No document here promises absolute immunity or determines the outcome of a dispute.
