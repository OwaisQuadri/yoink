#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

app=build/Yoink.app
vendor=vendor/ffmpeg
is_local=0
if [[ ${1:-} == --local ]]; then is_local=1; fi

while read -r arch revision tool sha; do
  directory=$vendor/$revision
  mkdir -p $directory
  archive=$directory/$tool-$arch.zip
  if [[ ! -f $archive ]]; then
    curl -fsSL -o $archive.part "https://ffmpeg.martin-riedl.de/download/macos/$arch/$revision/$tool.zip"
    echo "$sha  $archive.part" | shasum -a 256 -c -
    mv $archive.part $archive
  fi
  echo "$sha  $archive" | shasum -a 256 -c -
  unzip -oq $archive -d $directory
done <<'ASSETS'
arm64 1789931890_9.0.2 ffmpeg c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924
arm64 1789931890_9.0.2 ffprobe fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6
amd64 1789931006_9.0.2 ffmpeg 7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4
amd64 1789931006_9.0.2 ffprobe 2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd
ASSETS
for tool in ffmpeg ffprobe; do
  lipo -create $vendor/1789931890_9.0.2/$tool $vendor/1789931006_9.0.2/$tool -output $vendor/$tool
done
zsh scripts/build-subtitles.sh

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
cp $vendor/ffmpeg $vendor/ffprobe $app/Contents/Resources/
cp vendor/whisper/whisper-cli vendor/whisper/ggml-base.bin vendor/whisper/WHISPER-LICENSE Resources/WHISPER-MODEL-LICENSE $app/Contents/Resources/
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
