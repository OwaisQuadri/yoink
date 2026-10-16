#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

plist=build/Yoink.app/Contents/Info.plist
tools=.build/artifacts/sparkle/Sparkle/bin
account=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $plist)
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $plist)
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' $plist)
feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' $plist)

if [[ $($tools/generate_keys --account "$account" -p) != "$public_key" ]]; then
  echo "The Keychain signing key does not match SUPublicEDKey." >&2
  exit 1
fi
codesign --verify --deep --strict build/Yoink.app
codesign --verify --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' build/Yoink.dmg

output=build/updates/$version-$build
archive=Yoink-$version-$build.dmg
mkdir -p "$output"
cp build/Yoink.dmg "$output/$archive"
CFFIXED_USER_HOME="$PWD/build/sparkle-home" $tools/generate_appcast --account "$account" --maximum-deltas 0 \
  --download-url-prefix "${feed_url%/latest/download/*}/download/v$version/" "$output"

feed=$output/appcast.xml
actual_build=$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="version"])' "$feed")
if [[ $actual_build != "$build" ]]; then
  echo "The disk image is stale. Rebuild it before generating the appcast." >&2
  exit 1
fi
$tools/sign_update --account "$account" --verify "$feed"
signature=$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$feed")
$tools/sign_update --account "$account" --verify "$output/$archive" "$signature"
echo "Generated $feed and $output/$archive locally. Nothing was published."
