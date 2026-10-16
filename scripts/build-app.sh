#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

app=build/Yoink.app
vendor=vendor/ffmpeg

if [[ ! -x $vendor/ffmpeg ]]; then
  mkdir -p $vendor
  for arch in arm64 amd64; do
    curl -fsSL -o $vendor/$arch.zip "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$arch/release/ffmpeg.zip"
    unzip -oq $vendor/$arch.zip -d $vendor/$arch
  done
  lipo -create $vendor/arm64/ffmpeg $vendor/amd64/ffmpeg -output $vendor/ffmpeg
fi

minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
mkdir -p build/bin
for arch in arm64 x86_64; do
  triple=$arch-apple-macosx$minimum_system
  swift build -c release --triple $triple -Xswiftc -warnings-as-errors
  bin=$(swift build -c release --triple $triple --show-bin-path)
  cp $bin/Yoink build/bin/Yoink-$arch
done
sparkle=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources $app/Contents/Frameworks
ditto $sparkle $app/Contents/Frameworks/Sparkle.framework
lipo -create build/bin/Yoink-arm64 build/bin/Yoink-x86_64 -output $app/Contents/MacOS/Yoink
cp Sources/Yoink/Sniffer.js $app/Contents/Resources/Sniffer.js
cp $vendor/ffmpeg $app/Contents/Resources/ffmpeg
cp Resources/Info.plist $app/Contents/Info.plist
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
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
codesign $signing $app/Contents/Resources/ffmpeg
codesign $signing $app
codesign --verify --deep --strict --verbose=2 $app
if [[ -z $identity ]]; then
  echo "Built $app (ad-hoc signed; not for distribution)"
  exit 0
fi

dmg=build/Yoink.dmg
stage=build/dmg
rm -rf $stage $dmg
mkdir -p $stage
cp -R $app $stage/
ln -s /Applications $stage/Applications
hdiutil create -quiet -volname Yoink -srcfolder $stage -format UDZO $dmg
codesign --force --timestamp --sign "$identity" $dmg
rm -rf $stage

if [[ -n ${YOINK_NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit $dmg --keychain-profile "$YOINK_NOTARY_PROFILE" --wait
  xcrun stapler staple $dmg
fi
echo "Built $dmg"
