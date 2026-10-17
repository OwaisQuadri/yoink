#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-whisper-paths.XXXXXX")
for architecture in arm64 x86_64; do
  lipo vendor/whisper/whisper-cli -thin $architecture -output "$work/whisper-cli-$architecture"
  strings "$work/whisper-cli-$architecture" > "$work/strings-$architecture.txt"
  if grep -Fq '/Users/' "$work/strings-$architecture.txt"; then
    print -u2 "The $architecture Whisper binary exposes a local build path."
    exit 1
  fi
  grep -Fq './vendor/whisper/source-' "$work/strings-$architecture.txt"
done
print "PASS: both Whisper architectures retain source diagnostics without local user paths. Evidence at $work"
