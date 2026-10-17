# FFmpeg source for Yoink

This package supplies the complete original FFmpeg 9.0.2 source archive, Yoink's patch, and the build recipe for Yoink's FFmpeg and ffprobe. FFmpeg's code and Yoink's patch use LGPL version 2.1 or later. The source archive includes all upstream license and copyright notices. Yoink's own application code remains MIT-licensed.

Source archive: `ffmpeg-9.0.2.tar.xz`.

Source URL: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>.

SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.

Yoink applies `Resources/Patches/ffmpeg-clang-annotations.patch`, dated 2026-10-17. It adds six `av_fallthrough` annotations for existing switch fallthroughs in `libavformat/jvdec.c`, `nspdec.c`, `nuv.c`, `tls_securetransport.c`, and `libavcodec/lcevc_parser.c`. It also marks four conditionally unused helpers in `libavcodec/adpcm.c` with `av_unused`. Each changed file carries a dated modification notice. These annotations preserve behavior and fix Clang's warning-as-error build. No other FFmpeg source files are modified.

This software is based in part on the work of the Independent JPEG Group. The FFmpeg release's IJG-derived files are unchanged by Yoink.

## Rebuild the tools

Use macOS with Xcode command-line tools, `make`, and `pkg-config`. `BUILD-ENVIRONMENT.txt` records the compiler and SDK used for the accompanying binaries. The recipe builds arm64 and x86_64 tools and combines them with `lipo`.

From the package root:

```sh
mkdir -p vendor/ffmpeg docs
cp ffmpeg-9.0.2.tar.xz vendor/ffmpeg/
cp README.md docs/ffmpeg-source.md
zsh scripts/build-ffmpeg.sh
```

The rebuilt universal tools are `vendor/ffmpeg/ffmpeg` and `vendor/ffmpeg/ffprobe`. Both report their license through `-L` and their configure flags through `-buildconf`. A reproducible recipe does not imply bit-identical code signatures across machines.

The build disables GPL, nonfree, version-3-only components, and external library autodetection. It retains FFmpeg's native codecs, formats, and protocols rather than imposing a format whitelist. It enables only macOS system dependencies. SecureTransport supplies HTTPS. System libxml2 supplies DASH parsing. System compression, iconv, AudioToolbox, and VideoToolbox supply their corresponding features. No Homebrew codec library is statically included.

The recipe passes `-Werror` through FFmpeg's build-only `ECFLAGS` and `EOBJCFLAGS`. Configure's feature probes intentionally compile invalid or warning-producing snippets, so they do not use a global `-Werror`. Configure itself uses `--fatal-warnings`.

The C build suppresses deprecated-declaration diagnostics because FFmpeg's macOS SecureTransport backend uses Apple's deprecated TLS API. Other build warnings remain errors. `-Qunused-arguments` permits framework linker flags during compile checks. Darwin's archiver does not accept response files, so the recipe disables them. These settings do not modify FFmpeg source.

The source package accompanies the app under `Contents/Resources/Legal/FFmpeg/` and must also accompany release downloads. Users may modify and rebuild these tools under their upstream license. No restriction on reverse engineering for debugging modifications is added here.
