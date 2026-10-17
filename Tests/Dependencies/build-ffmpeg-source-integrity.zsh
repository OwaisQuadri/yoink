#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-source-integrity.XXXXXX")
mkdir -p "$work/scripts" "$work/Resources" "$work/vendor/ffmpeg" "$work/bin"
cp scripts/build-ffmpeg.sh "$work/scripts/"
cp Resources/Info.plist "$work/Resources/"
print 'CORRUPTED_SOURCE_ARCHIVE' > "$work/vendor/ffmpeg/ffmpeg-9.0.2.tar.xz"
cat > "$work/bin/curl" <<'MOCK'
#!/bin/zsh
print -u2 'UNEXPECTED_NETWORK_REQUEST'
exit 79
MOCK
chmod +x "$work/bin/curl"
result=0
PATH="$work/bin:$PATH" zsh "$work/scripts/build-ffmpeg.sh" > "$work/result.log" 2>&1 || result=$?
[[ $result == 1 ]]
grep -q FAILED "$work/result.log"
[[ ! -d "$work/vendor/ffmpeg/source-9.0.2" ]]
[[ ! -d "$work/build" ]]
if grep -q UNEXPECTED_NETWORK_REQUEST "$work/result.log"; then
  exit 1
fi
print "PASS: corrupt cached FFmpeg source fails before extraction, compilation, or packaging. Evidence at $work"
