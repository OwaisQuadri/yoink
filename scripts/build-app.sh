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
codesign --force --deep --sign - $app
echo "Built $app"
