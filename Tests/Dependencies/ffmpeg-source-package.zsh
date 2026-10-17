#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

app=build/Yoink.app
package=$app/Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz
work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-ffmpeg-source.XXXXXX")
tar -tvzf $package > "$work/archive-metadata.txt"
if grep -qvE '^[^ ]+ +[0-9]+ +0 +0 +' "$work/archive-metadata.txt"; then
  print -u2 'The source package exposes local archive ownership.'
  exit 1
fi
tar -xzf $package -C "$work"
echo "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e  $work/ffmpeg-9.0.2.tar.xz" | shasum -a 256 -c -
cmp scripts/build-ffmpeg.sh "$work/scripts/build-ffmpeg.sh"
cmp Resources/Info.plist "$work/Resources/Info.plist"
cmp Resources/Patches/ffmpeg-clang-annotations.patch "$work/Resources/Patches/ffmpeg-clang-annotations.patch"
cmp docs/ffmpeg-source.md "$work/README.md"
for file in LICENSE RESPONSIBLE_USE.md THIRD_PARTY_NOTICES.md docs/license-audit.md docs/ffmpeg-source.md Resources/WHISPER-MODEL-LICENSE Resources/Licenses/*; do
  cmp "$file" "$app/Contents/Resources/Legal/$file"
done
for tool in ffmpeg ffprobe; do
  for architecture in arm64 x86_64; do
    /usr/bin/arch -$architecture $app/Contents/Resources/$tool -L > "$work/$tool-$architecture-license.txt" 2>&1
    grep -q 'GNU Lesser General Public' "$work/$tool-$architecture-license.txt"
    grep -q 'version 2.1' "$work/$tool-$architecture-license.txt"
    /usr/bin/arch -$architecture $app/Contents/Resources/$tool -buildconf > "$work/$tool-$architecture-buildconf.txt" 2>&1
    for flag in --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 --enable-securetransport --enable-libxml2; do
      grep -q -- "$flag" "$work/$tool-$architecture-buildconf.txt"
    done
    if grep -Eq -- '--enable-(gpl|nonfree|version3)|--enable-lib(x264|x265|fdk|vpx|opus|dav1d)' "$work/$tool-$architecture-buildconf.txt"; then
      exit 1
    fi
  done
done
print "PASS: both FFmpeg tools and architectures use LGPL 2.1+; bundled source and notices match build inputs. Evidence at $work"
