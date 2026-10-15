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

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/Yoink $app/Contents/MacOS/Yoink
cp Sources/Yoink/Sniffer.js $app/Contents/Resources/Sniffer.js
cp $vendor/ffmpeg $app/Contents/Resources/ffmpeg
cp Resources/Info.plist $app/Contents/Info.plist
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [[ -z $identity ]]; then
  codesign --force --deep --sign - $app
  echo "Built $app (ad-hoc signed)"
  exit 0
fi
codesign --force --options runtime --timestamp --sign "$identity" $app/Contents/Resources/ffmpeg
codesign --force --options runtime --timestamp --sign "$identity" $app

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
