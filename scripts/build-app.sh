#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

app=build/Yoink.app
vendor=vendor/ffmpeg
is_local=0
if [[ ${1:-} == --local ]]; then is_local=1; fi
zsh scripts/build-ffmpeg.sh
zsh scripts/build-subtitles.sh

minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
mkdir -p build/bin
for arch in arm64 x86_64; do
  triple=$arch-apple-macosx$minimum_system
  swift build --force-resolved-versions -c release --triple $triple -Xswiftc -warnings-as-errors -Xswiftc -D -Xswiftc YOINK_APP_BUNDLE
  bin=$(swift build --force-resolved-versions -c release --triple $triple --show-bin-path)
  cp $bin/Yoink build/bin/Yoink-$arch
done
sparkle=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
cmp Resources/Licenses/SPARKLE-LICENSE .build/artifacts/sparkle/Sparkle/LICENSE
cmp Resources/Licenses/WHISPER-LICENSE vendor/whisper/WHISPER-LICENSE

rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources $app/Contents/Frameworks
ditto $sparkle $app/Contents/Frameworks/Sparkle.framework
lipo -create build/bin/Yoink-arm64 build/bin/Yoink-x86_64 -output $app/Contents/MacOS/Yoink
xcrun strip -S $app/Contents/MacOS/Yoink
cp Sources/Yoink/Sniffer.js $app/Contents/Resources/Sniffer.js
cp $vendor/ffmpeg $vendor/ffprobe $app/Contents/Resources/
cp vendor/whisper/whisper-cli vendor/whisper/ggml-base.bin vendor/whisper/WHISPER-LICENSE Resources/WHISPER-MODEL-LICENSE $app/Contents/Resources/
mkdir -p $app/Contents/Resources/Legal/Resources $app/Contents/Resources/Legal/docs
cp LICENSE RESPONSIBLE_USE.md THIRD_PARTY_NOTICES.md $app/Contents/Resources/Legal/
cp -R Resources/Licenses $app/Contents/Resources/Legal/Resources/
cp Resources/WHISPER-MODEL-LICENSE $app/Contents/Resources/Legal/Resources/
cp docs/license-audit.md docs/ffmpeg-source.md $app/Contents/Resources/Legal/docs/
mkdir -p $app/Contents/Resources/Legal/FFmpeg
cp build/Yoink-FFmpeg-9.0.2-source.tar.gz $app/Contents/Resources/Legal/FFmpeg/
cp Resources/Info.plist $app/Contents/Info.plist
identity=""
if (( ! is_local )); then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
fi
signing=(--force --sign "${identity:--}")
if [[ -n $identity ]]; then
  signing+=(--options runtime --timestamp)
fi
framework=$app/Contents/Frameworks/Sparkle.framework
codesign $signing $framework/Versions/B/XPCServices/Installer.xpc
codesign $signing --preserve-metadata=entitlements $framework/Versions/B/XPCServices/Downloader.xpc
codesign $signing $framework/Versions/B/Autoupdate
codesign $signing $framework/Versions/B/Updater.app
codesign $signing $framework
for tool in ffmpeg ffprobe whisper-cli; do
  codesign $signing $app/Contents/Resources/$tool
done
codesign $signing $app
codesign --verify --deep --strict --verbose=2 $app
if [[ -z $identity ]]; then
  echo "Built $app (ad-hoc signed; not for distribution)"
  exit 0
fi

notary_profile="${YOINK_NOTARY_PROFILE:-yoink}"
notary_archive=build/Yoink-notarization.zip
ditto -c -k --sequesterRsrc --keepParent $app $notary_archive
xcrun notarytool submit $notary_archive --keychain-profile "$notary_profile" --wait
xcrun stapler staple $app
xcrun stapler validate $app

dmg=build/Yoink.dmg
stage=build/dmg
rm -rf $stage $dmg
mkdir -p $stage
cp -R $app $stage/
xcrun stapler validate $stage/Yoink.app
ln -s /Applications $stage/Applications
hdiutil create -quiet -volname Yoink -srcfolder $stage -format UDZO $dmg
codesign --force --timestamp --sign "$identity" $dmg
rm -rf $stage

xcrun notarytool submit $dmg --keychain-profile "$notary_profile" --wait
xcrun stapler staple $dmg
xcrun stapler validate $dmg
echo "Built and notarized $app and $dmg"
