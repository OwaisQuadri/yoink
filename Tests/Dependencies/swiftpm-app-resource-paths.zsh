#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

rg -q -- '-Xswiftc -D -Xswiftc YOINK_APP_BUNDLE' scripts/build-app.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-swiftpm-paths.XXXXXX")
minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
for architecture in arm64 x86_64; do
  triple=$architecture-apple-macosx$minimum_system
  swift build --build-system native --force-resolved-versions -c release --triple "$triple" -Xswiftc -warnings-as-errors -Xswiftc -D -Xswiftc YOINK_APP_BUNDLE > "$work/$architecture.log" 2>&1
  bin=$(swift build --build-system native --force-resolved-versions -c release --triple "$triple" --show-bin-path)
  cp "$bin/Yoink" "$work/Yoink-$architecture"
  xcrun strip -S "$work/Yoink-$architecture"
  scan_status=0
  LC_ALL=C grep -aEq '/Users/|/private/var/folders/|/tmp/yoink' "$work/Yoink-$architecture" || scan_status=$?
  if (( scan_status == 0 )); then
    print -u2 "FAIL: $architecture app retains a private SwiftPM resource path. Evidence at $work"
    exit 1
  elif (( scan_status != 1 )); then
    exit "$scan_status"
  fi
done
print "PASS: both native SwiftPM app architectures exclude private resource paths. Evidence at $work"
