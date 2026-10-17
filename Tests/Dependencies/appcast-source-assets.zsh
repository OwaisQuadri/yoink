#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-appcast-source.XXXXXX")
tools=$work/.build/artifacts/sparkle/Sparkle/bin
mkdir -p "$tools" "$work/scripts" "$work/bin" "$work/build/Yoink.app/Contents/Resources/Legal/FFmpeg"
cp scripts/generate-appcast.sh "$work/scripts/"
cp Resources/Info.plist "$work/build/Yoink.app/Contents/Info.plist"
print 'TEST_DISK_IMAGE' > "$work/build/Yoink.dmg"
print 'TEST_SOURCE_ARCHIVE' > "$work/build/Yoink.app/Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz"
cat > "$work/bin/codesign" <<'MOCK'
#!/bin/zsh
exit 0
MOCK
cat > "$tools/generate_keys" <<'MOCK'
#!/bin/zsh
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/Yoink.app/Contents/Info.plist
MOCK
cat > "$tools/sign_update" <<'MOCK'
#!/bin/zsh
exit 0
MOCK
cat > "$tools/generate_appcast" <<'MOCK'
#!/bin/zsh
set -euo pipefail
directory=${@[-1]}
files=("$directory"/*(N))
[[ ${#files} == 1 && ${files[1]} == *.dmg ]]
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/Yoink.app/Contents/Info.plist)
print "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:version>$build</sparkle:version><enclosure sparkle:edSignature=\"TEST_SIGNATURE\"/></item></channel></rss>" > "$directory/appcast.xml"
MOCK
chmod +x "$work/bin/codesign" "$tools/"*
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
for attempt in 1 2; do
  PATH="$work/bin:$PATH" zsh "$work/scripts/generate-appcast.sh"
  (
    cd "$work/build/updates/$version-$build"
    shasum -a 256 -c SHA256SUMS
    cmp "Yoink-$version-$build-FFmpeg-source.tar.gz" "$work/build/Yoink.app/Contents/Resources/Legal/FFmpeg/Yoink-FFmpeg-9.0.2-source.tar.gz"
  )
done
print "PASS: repeated appcast generation keeps source outside update scanning and includes matching source and checksums. Signing is mocked. Evidence at $work"
