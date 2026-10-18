#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
umask 077

[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_EVENT_NAME:-} == push && ${GITHUB_REF:-} == refs/heads/main ]]
[[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ && ${PUSH_BEFORE:-} =~ ^[0-9a-f]{40}$ && $PUSH_BEFORE != 0000000000000000000000000000000000000000 ]]
[[ $(git rev-parse HEAD) == $GITHUB_SHA ]]
export GH_REPO=$GITHUB_REPOSITORY
helper=$PWD/build/release-helper
plist=Resources/Info.plist
feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")
[[ $feed_url == "https://github.com/$GH_REPO/releases/latest/download/appcast.xml" ]]
tools=$PWD/.build/artifacts/sparkle/Sparkle/bin
mkdir -p build
swiftc -warnings-as-errors scripts/release/Release.swift -o "$helper"
work=$(mktemp -d "$RUNNER_TEMP/yoink-release.XXXXXX")
mountpoint=$work/mount
cleanup() {
  if [[ -d $mountpoint ]]; then hdiutil detach "$mountpoint" -quiet || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

git merge-base --is-ancestor "$PUSH_BEFORE" "$GITHUB_SHA"
git show "$PUSH_BEFORE:$plist" > "$work/before.plist"
"$helper" candidate "$plist" "$work/before.plist" > "$work/candidate"
cat "$work/candidate"
if [[ ${1:-} == candidate ]]; then
  cat "$work/candidate" >> "$GITHUB_OUTPUT"
  exit 0
fi
[[ ${1:-} == publish ]]
grep -qx is_release=true "$work/candidate"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
account=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")
[[ $("$tools/generate_keys" --account "$account" -p) == $public_key ]]
tag=v$version
output=$PWD/build/updates/$version-$build
archive=Yoink-$version-$build.dmg
source_archive=Yoink-$version-$build-FFmpeg-source.tar.gz

check_head() {
  [[ $(gh api "repos/$GH_REPO/git/ref/heads/main" --jq .object.sha) == $GITHUB_SHA ]]
}
check_unused_tag() {
  local tags
  tags=$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")
  [[ -z $tags ]]
}
verify_assets() {
  local directory=$1
  local signature
  signature=$("$helper" verify "$plist" "$directory" "$GH_REPO")
  (cd "$directory"; shasum -a 256 -c SHA256SUMS)
  "$tools/sign_update" --account "$account" --verify "$directory/appcast.xml"
  "$tools/sign_update" --account "$account" --verify "$directory/$archive" "$signature"
  cmp "$directory/$source_archive" build/Yoink.app/Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz
  codesign --verify --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$directory/$archive"
  xcrun stapler validate "$directory/$archive"
}
verify_download() {
  local directory=$1
  mkdir "$directory"
  gh release download "$tag" --dir "$directory"
  verify_assets "$directory"
  for asset in "$archive" appcast.xml "$source_archive" SHA256SUMS; do
    cmp "$output/$asset" "$directory/$asset"
  done
}

check_head
check_unused_tag
gh api "repos/$GH_REPO/releases/latest" > "$work/latest.json"
latest_id=$(gh api "repos/$GH_REPO/releases/latest" --jq .id)
gh api --paginate --slurp "repos/$GH_REPO/releases?per_page=100" > "$work/releases.json"
"$helper" inventory "$plist" "$work/releases.json" "$work/latest.json" > "$work/previous-releases"
while read -r release_id asset_id previous_tag; do
  gh api "repos/$GH_REPO/releases/assets/$asset_id" -H 'Accept: application/octet-stream' > "$work/previous.xml"
  "$tools/sign_update" --account "$account" --verify "$work/previous.xml"
  "$helper" previous "$plist" "$work/previous.xml" "$previous_tag" "$GH_REPO"
done < "$work/previous-releases"

for regression in build-app-source-required build-ffmpeg-source-integrity appcast-source-assets; do
  zsh "Tests/Dependencies/$regression.zsh"
done
zsh scripts/release/test.zsh
zsh scripts/build-app.sh
[[ -f build/Yoink.dmg ]]
zsh scripts/check-subtitles.sh
for regression in ffmpeg-source-package whisper-build-paths app-build-paths; do
  zsh "Tests/Dependencies/$regression.zsh"
done
codesign --verify --deep --strict build/Yoink.app
xcrun stapler validate build/Yoink.app
xcrun stapler validate build/Yoink.dmg
mkdir "$mountpoint"
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" build/Yoink.dmg -quiet
codesign --verify --deep --strict "$mountpoint/Yoink.app"
xcrun stapler validate "$mountpoint/Yoink.app"
diff -qr build/Yoink.app "$mountpoint/Yoink.app"
hdiutil detach "$mountpoint" -quiet
rmdir "$mountpoint"
[[ ! -e $output ]]
zsh scripts/generate-appcast.sh
verify_assets "$output"

check_head
[[ $(gh api "repos/$GH_REPO/releases/latest" --jq .id) == $latest_id ]]
check_unused_tag
gh release create "$tag" "$output/$archive" "$output/appcast.xml" "$output/$source_archive" "$output/SHA256SUMS" \
  --draft --target "$GITHUB_SHA" --title "Yoink $version" \
  --notes "Source-built universal macOS release. Matching FFmpeg source and dependency notices accompany the app. Commit: $GITHUB_SHA"
gh api "repos/$GH_REPO/releases/tags/$tag" > "$work/draft.json"
release_id=$("$helper" assets "$plist" "$work/draft.json" "$GH_REPO" draft)
verify_download "$work/staged"
check_head
[[ $(gh api "repos/$GH_REPO/releases/latest" --jq .id) == $latest_id ]]
[[ $(gh api "repos/$GH_REPO/releases/$release_id" --jq .id) == $release_id ]]
gh api "repos/$GH_REPO/releases/$release_id" > "$work/final-draft.json"
"$helper" assets "$plist" "$work/final-draft.json" "$GH_REPO" draft
check_unused_tag
gh api --method PATCH "repos/$GH_REPO/releases/$release_id" -F draft=false -F prerelease=false -f make_latest=true > "$work/published.json"
"$helper" assets "$plist" "$work/published.json" "$GH_REPO" published
[[ $(gh api "repos/$GH_REPO/git/ref/tags/$tag" --jq .object.sha) == $GITHUB_SHA ]]
[[ $(gh api "repos/$GH_REPO/releases/latest" --jq .id) == $release_id ]]
verify_download "$work/published"
print "Published and re-verified $tag at $GITHUB_SHA."
