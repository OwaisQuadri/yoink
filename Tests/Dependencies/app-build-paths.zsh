#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

app=${1:-build/Yoink.app}
work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-app-paths.XXXXXX")
for tool in Yoink ffmpeg ffprobe whisper-cli; do
  binary=$app/Contents/Resources/$tool
  if [[ $tool == Yoink ]]; then binary=$app/Contents/MacOS/Yoink; fi
  for architecture in arm64 x86_64; do
    thin=$work/$tool-$architecture
    lipo "$binary" -thin $architecture -output "$thin"
    scan_status=0
    LC_ALL=C grep -aEq '/Users/|/private/var/folders/|/tmp/yoink' "$thin" || scan_status=$?
    if (( scan_status == 0 )); then
      print -u2 "The $architecture $tool binary exposes a local build path, including its symbol table."
      exit 1
    elif (( scan_status != 1 )); then
      print -u2 "The $architecture $tool privacy scan failed with status $scan_status."
      exit "$scan_status"
    fi
  done
done
print "PASS: both architectures of the app and bundled tools contain no local build paths in raw bytes. Evidence at $work"
