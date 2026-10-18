#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-release-tests.XXXXXX")
trap 'result=$?; if (( result != 0 )); then cat "$work/"*.log(N); if [[ -f $work/commands ]]; then cat "$work/commands"; fi; fi; rm -rf "$work"' EXIT
swiftc -warnings-as-errors scripts/release/Release.swift -o "$work/helper"
cp Resources/Info.plist "$work/current.plist"
cp Resources/Info.plist "$work/before.plist"
set_version() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" "$1"
}
set_version "$work/current.plist" 0.0.10 11
set_version "$work/before.plist" 0.0.9 10
"$work/helper" candidate "$work/current.plist" "$work/before.plist" | grep -qx is_release=true
"$work/helper" candidate "$work/current.plist" "$work/current.plist" | grep -qx is_release=false
for pair in '0.0.10 10' '0.0.9 11' '0.0.8 12' '0.0.11 9' '0.0.010 11' '0.0.11 18446744073709551616'; do
  fields=(${=pair})
  cp "$work/current.plist" "$work/invalid.plist"
  set_version "$work/invalid.plist" "$fields[1]" "$fields[2]"
  if "$work/helper" candidate "$work/invalid.plist" "$work/before.plist" > /dev/null 2>&1; then
    print -u2 "Accepted rollback, reuse, or malformed version: $pair"
    exit 1
  fi
done

fixture=$work/repository
mkdir -p "$fixture/scripts/release" "$fixture/Resources" "$fixture/Tests/Dependencies" "$fixture/bin" "$fixture/.build/artifacts/sparkle/Sparkle/bin" "$work/runner"
cp scripts/release/run.sh scripts/release/Release.swift "$fixture/scripts/release/"
cp "$work/current.plist" "$fixture/Resources/Info.plist"
cp "$work/before.plist" "$fixture/before.plist"
for plist in "$fixture/Resources/Info.plist" "$fixture/before.plist"; do
  /usr/libexec/PlistBuddy -c 'Set :SUFeedURL https://github.com/test-owner/test-repo/releases/latest/download/appcast.xml' "$plist"
done
for name in build-app-source-required build-ffmpeg-source-integrity appcast-source-assets ffmpeg-source-package whisper-build-paths app-build-paths; do
  print '#!/bin/zsh\nexit 0' > "$fixture/Tests/Dependencies/$name.zsh"
done
print '#!/bin/zsh\nexit 0' > "$fixture/scripts/release/test.zsh"
print '#!/bin/zsh\nexit 0' > "$fixture/scripts/check-subtitles.sh"
cat > "$fixture/scripts/build-app.sh" <<'MOCK'
#!/bin/zsh
set -euo pipefail
[[ $TEST_MODE != build-failure ]]
mkdir -p build/Yoink.app/Contents/Resources/Legal/FFmpeg
cp Resources/Info.plist build/Yoink.app/Contents/Info.plist
print 'DISK_IMAGE' > build/Yoink.dmg
print 'SOURCE_PACKAGE' > build/Yoink.app/Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz
MOCK
cat > "$fixture/scripts/generate-appcast.sh" <<'MOCK'
#!/bin/zsh
set -euo pipefail
output=build/updates/0.0.10-11
mkdir -p "$output"
cp build/Yoink.dmg "$output/Yoink-0.0.10-11.dmg"
cp build/Yoink.app/Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz "$output/Yoink-0.0.10-11-FFmpeg-source.tar.gz"
cp current.xml "$output/appcast.xml"
(cd "$output"; shasum -a 256 Yoink-0.0.10-11.dmg appcast.xml Yoink-0.0.10-11-FFmpeg-source.tar.gz > SHA256SUMS)
MOCK
signature=$(printf '%086d==' 0)
for kind in current previous; do
  if [[ $kind == current ]]; then version=0.0.10; build=11; else version=0.0.8; build=9; fi
  cat > "$fixture/$kind.xml" <<FEED
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>$build</sparkle:version><sparkle:shortVersionString>$version</sparkle:shortVersionString><enclosure url="https://github.com/test-owner/test-repo/releases/download/v$version/Yoink-$version-$build.dmg" length="11" sparkle:edSignature="$signature"/></item></channel></rss>
FEED
done
cat > "$fixture/bin/git" <<'MOCK'
#!/bin/zsh
set -euo pipefail
case $1 in
  rev-parse) print "$GITHUB_SHA" ;;
  merge-base) exit 0 ;;
  show) cat before.plist ;;
  ls-remote)
    [[ $TEST_MODE != tag-query-failure ]] || exit 94
    if [[ $TEST_MODE == existing-tag ]]; then print "$GITHUB_SHA refs/tags/v0.0.10"; fi ;;
  *) exit 91 ;;
esac
MOCK
cat > "$fixture/bin/gh" <<'MOCK'
#!/bin/zsh
set -euo pipefail
print -r -- "$*" >> "$TEST_LOG"
metadata() {
  local state=$1
  local asset_tag=v0.0.10
  if [[ $state == true ]]; then asset_tag=untagged-0123456789abcdef0123; fi
  print -n '{"id":200,"tag_name":"v0.0.10","draft":'
  print -n "$state"
  print -n ',"prerelease":false,"target_commitish":"'"$GITHUB_SHA"'","assets":['
  local separator=''
  for name in Yoink-0.0.10-11.dmg appcast.xml Yoink-0.0.10-11-FFmpeg-source.tar.gz SHA256SUMS; do
    print -n "$separator"'{"id":201,"name":"'"$name"'","size":11,"browser_download_url":"https://github.com/test-owner/test-repo/releases/download/'"$asset_tag"'/'"$name"'"}'
    separator=,
  done
  print ']}'
}
previous='{"id":100,"tag_name":"v0.0.8","draft":false,"prerelease":false,"target_commitish":"old","assets":[{"id":101,"name":"appcast.xml","size":11,"browser_download_url":"unused"}]}'
if [[ $1 == api ]]; then
  if [[ "$*" == *'--method PATCH'* ]]; then
    print PUBLISHED > published
    metadata false
  elif [[ "$*" == *git/ref/heads/main* ]]; then
    if [[ $TEST_MODE == stale-main && -f draft ]]; then print stale; else print "$GITHUB_SHA"; fi
  elif [[ "$*" == *git/ref/tags/* ]]; then
    print "$GITHUB_SHA"
  elif [[ "$*" == *releases/latest* ]]; then
    if [[ "$*" == *'--jq'* ]]; then
      if [[ -f published ]]; then print 200; elif [[ $TEST_MODE == changed-latest && -f draft ]]; then print 999; else print 100; fi
    else print -r -- "$previous"; fi
  elif [[ "$*" == *'releases?per_page=100'* ]]; then
    if [[ $TEST_MODE == existing-release ]]; then
      print '[['"${previous/v0.0.8/v0.0.10}"']]'
    else print '[['"$previous"']]'; fi
  elif [[ "$*" == *releases/assets/101* ]]; then
    if [[ $TEST_MODE == reused-build ]]; then
      sed -e 's/<sparkle:version>9</<sparkle:version>11</' -e 's/Yoink-0.0.8-9.dmg/Yoink-0.0.8-11.dmg/' previous.xml
    else cat previous.xml; fi
  elif [[ "$*" == *releases/tags/* ]]; then
    exit 44
  elif [[ "$*" == *releases/200* ]]; then
    if [[ "$*" == *'--jq'* ]]; then print 200; else metadata true; fi
  else exit 92; fi
elif [[ $1 == release && $2 == create ]]; then
  [[ "$*" == *'--draft'* && "$*" == *"--target $GITHUB_SHA"* ]]
  print DRAFT > draft
  [[ $TEST_MODE != upload-failure ]]
elif [[ $1 == release && $2 == view ]]; then
  [[ -f draft ]]
  print 200
elif [[ $1 == release && $2 == download ]]; then
  destination=${@[-1]}
  cp build/updates/0.0.10-11/* "$destination/"
  if [[ $TEST_MODE == corrupt-staged ]]; then print CORRUPTED >> "$destination/Yoink-0.0.10-11.dmg"; fi
else exit 93; fi
MOCK
cat > "$fixture/bin/hdiutil" <<'MOCK'
#!/bin/zsh
set -euo pipefail
if [[ $1 == attach ]]; then
  cp -R build/Yoink.app "${@[-3]}/"
else
  rm -rf "$2/Yoink.app"
fi
MOCK
print '#!/bin/zsh\nexit 0' > "$fixture/bin/codesign"
print '#!/bin/zsh\nexit 0' > "$fixture/bin/xcrun"
cat > "$fixture/.build/artifacts/sparkle/Sparkle/bin/generate_keys" <<'MOCK'
#!/bin/zsh
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist
MOCK
cat > "$fixture/.build/artifacts/sparkle/Sparkle/bin/sign_update" <<'MOCK'
#!/bin/zsh
[[ $TEST_MODE != invalid-previous-signature || "$*" != *previous.xml* ]]
MOCK
chmod +x "$fixture/bin/"* "$fixture/.build/artifacts/sparkle/Sparkle/bin/"*
export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
export GITHUB_REPOSITORY=test-owner/test-repo GITHUB_SHA=1111111111111111111111111111111111111111 PUSH_BEFORE=2222222222222222222222222222222222222222
export RUNNER_TEMP=$work/runner TEST_LOG=$work/commands GH_TOKEN=invalid-local-test-token
for mode in build-failure existing-tag tag-query-failure existing-release reused-build invalid-previous-signature upload-failure corrupt-staged stale-main changed-latest success; do
  rm -rf "$fixture/build" "$fixture/draft" "$fixture/published"
  : > "$TEST_LOG"
  result=0
  TEST_MODE=$mode PATH="$fixture/bin:$PATH" /bin/zsh -f "$fixture/scripts/release/run.sh" publish > "$work/$mode.log" 2>&1 || result=$?
  [[ -s $TEST_LOG ]]
  if [[ $mode == success ]]; then
    if (( result != 0 )); then cat "$work/$mode.log"; exit 1; fi
    [[ -f "$fixture/published" ]]
    [[ $(grep -c 'release download' "$TEST_LOG") == 2 ]]
  else
    if (( result == 0 )); then print -u2 "Unexpected success: $mode"; exit 1; fi
    [[ ! -f "$fixture/published" ]]
    if [[ $mode == reused-build ]]; then grep -q 'Both display version and build must increase' "$work/$mode.log"; fi
    if [[ $mode == upload-failure || $mode == corrupt-staged || $mode == stale-main || $mode == changed-latest ]]; then
      [[ -f "$fixture/draft" ]]
    else
      [[ ! -f "$fixture/draft" ]]
    fi
  fi
  print "PASS: $mode"
done
(cd "$fixture"; TEST_MODE=success ./bin/gh api repos/test-owner/test-repo/releases/200) > "$work/pending-draft.json"
"$work/helper" assets "$fixture/Resources/Info.plist" "$work/pending-draft.json" test-owner/test-repo draft > /dev/null
sed 's/untagged-0123456789abcdef0123/arbitrary/' "$work/pending-draft.json" > "$work/invalid-draft.json"
if "$work/helper" assets "$fixture/Resources/Info.plist" "$work/invalid-draft.json" test-owner/test-repo draft > /dev/null 2>&1; then exit 1; fi
sed 's/"draft":true/"draft":false/' "$work/pending-draft.json" > "$work/invalid-published.json"
if "$work/helper" assets "$fixture/Resources/Info.plist" "$work/invalid-published.json" test-owner/test-repo published > /dev/null 2>&1; then exit 1; fi
print 'PASS: draft placeholder asset URLs are accepted only for drafts; arbitrary and published placeholder URLs are rejected.'
cat > "$fixture/bin/security" <<'MOCK'
#!/bin/zsh -f
set -euo pipefail
if [[ $1 == -i ]]; then
  [[ $# == 1 ]]
  read -r command
  words=(${(z)command})
  words=(${(Q)words})
  print -r -- "$words[1]" >> "$TEST_LOG"
  case $words[1] in
    create-keychain) touch "$words[-1]" ;;
    import) [[ -f $words[2] ]] ;;
    delete-keychain) rm "$words[2]" ;;
  esac
else
  [[ $1 == list-keychains || $1 == default-keychain ]]
  print '"/original.keychain-db"'
fi
MOCK
cat > "$fixture/bin/xcrun" <<'MOCK'
#!/bin/zsh -f
set -euo pipefail
[[ $# == 5 && $1 == notarytool && $2 == store-credentials && $3 == yoink-ci && $4 == --keychain ]]
[[ $TEST_MODE != notary-failure ]] || exit 17
printf 'Path to App Store Connect API private key:'
read -r unused
printf 'Developer Apple ID:'
read -r apple_id
[[ $apple_id == $YOINK_NOTARY_APPLE_ID ]]
printf 'App-specific password for test:'
read -r password
[[ $password == $YOINK_NOTARY_PASSWORD ]]
printf 'Developer Team ID:'
read -r team_id
[[ $team_id == $YOINK_NOTARY_TEAM_ID ]]
MOCK
chmod +x "$fixture/bin/security" "$fixture/bin/xcrun"
sed -e "s|/usr/bin/security|$fixture/bin/security|g" -e "s|/usr/bin/xcrun|$fixture/bin/xcrun|g" scripts/release/Release.swift > "$fixture/Credentials.swift"
swiftc -warnings-as-errors "$fixture/Credentials.swift" -o "$fixture/credential-helper"
export GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1
export MACOS_SIGNING_P12_BASE64=VEVTVA== MACOS_SIGNING_P12_PASSWORD=test-p12-password
export SPARKLE_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
export APPLE_NOTARY_CREDENTIALS_JSON='{"appleID":"test-apple-id","appSpecificPassword":"test-notary-password","teamID":"test-team-id"}'
: > "$TEST_LOG"
(
  cd "$fixture"
  export TEST_MODE=credentials
  ./credential-helper credentials > "$work/credentials.log" 2>&1
  [[ ! -s $work/credentials.log ]]
  [[ -f $RUNNER_TEMP/yoink-signing-123-1/release.keychain-db ]]
  [[ ! -f $RUNNER_TEMP/yoink-signing-123-1/certificate.p12 ]]
  ./credential-helper cleanup
  [[ ! -e $RUNNER_TEMP/yoink-signing-123-1 ]]
  [[ $(grep -c '^default-keychain$' "$TEST_LOG") == 2 && $(grep -c '^list-keychains$' "$TEST_LOG") == 2 ]]
  if TEST_MODE=notary-failure ./credential-helper credentials > "$work/credentials-failure.log" 2>&1; then exit 1; fi
  [[ ! -e $RUNNER_TEMP/yoink-signing-123-1 ]]
  [[ $(grep -c '^delete-keychain$' "$TEST_LOG") == 2 ]]
  if APPLE_NOTARY_CREDENTIALS_JSON='{"appleID":"test-apple-id"}' ./credential-helper credentials > "$work/schema-failure.log" 2>&1; then exit 1; fi
  [[ ! -e $RUNNER_TEMP/yoink-signing-123-1 ]]
)
print 'PASS: env credential schema, hidden notary prompts, secret-free process arguments, and keychain cleanup on success and failure with mocked signing tools.'
print 'PASS: numeric version gates, unchanged versions, staged failure isolation, stale publication protection, and two download verifications. Remote and signing tools were mocked.'
