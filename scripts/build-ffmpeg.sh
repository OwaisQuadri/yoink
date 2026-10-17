#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

vendor=$PWD/vendor/ffmpeg
version=9.0.2
archive=$vendor/ffmpeg-$version.tar.xz
archive_sha=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
source=$vendor/source-$version
sdk=$(xcrun --show-sdk-path)
minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
mkdir -p $vendor/pkgconfig
if [[ ! -f $archive ]]; then
  curl -fL "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o $archive.part
  echo "$archive_sha  $archive.part" | shasum -a 256 -c -
  mv $archive.part $archive
fi
echo "$archive_sha  $archive" | shasum -a 256 -c -
mkdir -p $source
tar -xf $archive -C $source --strip-components=1
patch -s -d $source -p1 < Resources/Patches/ffmpeg-clang-annotations.patch
xml_version=$(sed -n 's/^#define LIBXML_DOTTED_VERSION "\([^"]*\)"/\1/p' "$sdk/usr/include/libxml2/libxml/xmlversion.h")
cat > $vendor/pkgconfig/libxml-2.0.pc <<EOF
Name: system libxml2
Description: macOS SDK libxml2, dynamically linked
Version: $xml_version
Libs: -lxml2
Cflags: -I$sdk/usr/include/libxml2
EOF

for arch in arm64 x86_64; do
  directory=$vendor/build-$version-$arch
  mkdir -p $directory
  (
    cd $directory
    PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=$vendor/pkgconfig ../source-$version/configure \
      --prefix=/usr/local --extra-version=yoink --target-os=darwin --arch=$arch --enable-cross-compile \
      --cc="$(xcrun -f clang)" --sysroot="$sdk" \
      --extra-cflags="-arch $arch -mmacosx-version-min=$minimum_system -Qunused-arguments" \
      --extra-ldflags="-arch $arch -mmacosx-version-min=$minimum_system" --extra-libs=-liconv \
      --fatal-warnings --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 \
      --enable-static --disable-shared --disable-doc --disable-debug --disable-ffplay \
      --disable-x86asm --disable-response-files --enable-securetransport --enable-libxml2 --enable-zlib \
      --enable-bzlib --enable-iconv --enable-audiotoolbox --enable-videotoolbox
    make -j 8 ECFLAGS='-Werror -Wno-deprecated-declarations' EOBJCFLAGS=-Werror ffmpeg ffprobe
  )
done
for tool in ffmpeg ffprobe; do
  lipo -create $vendor/build-$version-arm64/$tool $vendor/build-$version-x86_64/$tool -output $vendor/$tool
done

package=build/ffmpeg-source
mkdir -p $package/scripts $package/Resources/Patches
cp Resources/Patches/ffmpeg-clang-annotations.patch $package/Resources/Patches/
cp $archive $package/
cp scripts/build-ffmpeg.sh $package/scripts/
cp Resources/Info.plist $package/Resources/
cp docs/ffmpeg-source.md $package/README.md
{
  print "macOS $(sw_vers -productVersion)"
  xcrun clang --version | head -1
  print "macOS SDK $(xcrun --show-sdk-version)"
  print "pkg-config $(pkg-config --version)"
  print "FFmpeg source SHA-256 $archive_sha"
} > $package/BUILD-ENVIRONMENT.txt
COPYFILE_DISABLE=1 tar -czf build/Yoink-FFmpeg-$version-source.tar.gz -C $package .
