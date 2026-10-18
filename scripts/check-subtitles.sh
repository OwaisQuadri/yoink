#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

ffmpeg=$PWD/vendor/ffmpeg/ffmpeg
ffprobe=$PWD/vendor/ffmpeg/ffprobe
if [[ ! -x $ffmpeg || ! -x $ffprobe || ! -x vendor/whisper/whisper-cli || ! -f vendor/whisper/ggml-base.bin ]]; then
  print -u2 'Run zsh scripts/build-app.sh --local first.'
  exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/subtitle-check.XXXXXX")
port=${YOINK_CHECK_PORT:-8948}
mkdir -p $work/site/hls $work/site/dash
say -v 'Eddy (Spanish (Spain))' -r 145 -o $work/spanish.aiff 'Hola, buenos días. Hoy vamos a visitar la biblioteca. Me gusta leer libros y aprender idiomas. Después vamos a tomar un café con nuestros amigos.'
say -v 'Eddy (English (US))' -o $work/english.aiff 'Hello, good morning. Today we are going to visit the library. I like reading books and learning new languages. After that we will have coffee with our friends.'
for language in spanish english; do
  $ffmpeg -v error -y -f lavfi -i color=c=navy:s=640x360:r=25 -i $work/$language.aiff -c:v h264_videotoolbox -c:a aac -af apad -t 9 $work/site/$language.mp4
done
$ffmpeg -v error -y -i $work/site/spanish.mp4 -c:v h264_videotoolbox -force_key_frames 'expr:gte(t,n_forced*3)' -c:a copy -f hls -hls_time 3 -hls_list_size 0 -hls_segment_filename $work/site/hls/seg%d.ts $work/site/hls/video.m3u8
$ffmpeg -v error -y -i $work/site/spanish.mp4 -c copy -f dash $work/site/dash/manifest.mpd
video=$work/site/hls/video.m3u8
body=$(sed -n '/#EXTINF:/,$p' $video | sed '/#EXT-X-ENDLIST/d')
sed '/#EXT-X-ENDLIST/d' $video > $video.part
printf '#EXT-X-DISCONTINUITY\n%s\n#EXT-X-ENDLIST\n' "$body" >> $video.part
mv $video.part $video
start=$($ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 $work/site/hls/seg0.ts | head -1)
ticks=$(printf %.0f $((start * 90000)))
for language in es en; do
  manifest=$work/site/hls/$language.m3u8
  printf '#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n' > $manifest
  for index in 0 1 2; do
    printf 'WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:%s\n\n00:00:%02d.500 --> 00:00:%02d.000\nSOURCE CAPTIONS %s %d\n' "$ticks" $((index * 3)) $((index * 3 + 2)) $language $index > $work/site/hls/$language$index.vtt
    duration=3
    printf '#EXTINF:%s,\n%s%d.vtt\n' $duration $language $index >> $manifest
  done
  body=$(sed -n '/#EXTINF:/,$p' $manifest)
  printf '#EXT-X-DISCONTINUITY\n%s\n#EXT-X-ENDLIST\n' "$body" >> $manifest
done
cat > $work/site/hls/master.m3u8 <<'PLAYLIST'
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="es",NAME="Spanish",URI="es.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",URI="en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=500000,SUBTITLES="subs"
video.m3u8
PLAYLIST
cat > $work/site/two-videos.html <<'PAGE'
<!doctype html><title>Two videos</title>
<video src="spanish.mp4"><track kind="subtitles" src="selected.vtt" srclang="es"></video>
<video src="english.mp4"><track kind="subtitles" src="unrelated.vtt" srclang="en"></video>
PAGE
printf 'WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nSelected captions\n' > $work/site/selected.vtt
cp $work/site/selected.vtt $work/site/unrelated.vtt
cat > $work/site/cancel-probe.html <<'PAGE'
<!doctype html><title>Delayed frame probe</title><video src="missing.mp4"></video>
<script>
window.fetch = async () => {
  window.isProbeStarted = true;
  await new Promise(resolve => setTimeout(resolve, 1500));
  return new Response(new Uint8Array(16), { status: 200 });
};
</script>
PAGE
cat > $work/site/shared-header.vtt <<'CAPTIONS'
WEBVTT
X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:1080000
CAPTIONS
printf '00:00:00.500 --> 00:00:01.000\nShared header captions\n' > $work/site/caption-body.vtt
printf '#EXTM3U\n#EXT-X-MAP:URI="shared-header.vtt"\n#EXTINF:4,\ncaption-body.vtt\n#EXT-X-ENDLIST\n' > $work/site/shared-captions.m3u8
for duration in 1e100 -1 nan inf; do
  printf '#EXTM3U\n#EXTINF:%s,\ncaption-body.vtt\n#EXT-X-ENDLIST\n' $duration > $work/site/invalid-$duration.m3u8
done
printf '#EXTM3U\n#EXT-X-MAP:URI="shared-header.vtt"\n#EXTINF:5e15,\ncaption-body.vtt\n#EXTINF:5e15,\ncaption-body.vtt\n#EXT-X-ENDLIST\n' > $work/site/invalid-overflow.m3u8
sed 's/#EXTINF:3.000000,/#EXTINF:1e100,/' $video > $work/site/hls/invalid-video.m3u8
sed 's/video.m3u8/invalid-video.m3u8/' $work/site/hls/master.m3u8 > $work/site/hls/invalid-master.m3u8
python3 -m http.server $port --bind 127.0.0.1 --directory $work/site > $work/http.log 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; print "Evidence retained at $work"' EXIT
sleep 1
kill -0 $server
base=http://127.0.0.1:$port
export YOINK_SUBTITLE_FIXTURE=$work/site/spanish.mp4
export YOINK_ENGLISH_FIXTURE=$work/site/english.mp4
export YOINK_SUBTITLE_OUTPUT=$work/spanish-subtitled.mp4
export YOINK_MEDIA_FIXTURE_URL=$base/spanish.mp4
export YOINK_MEDIA_OUTPUT=$work/direct-subtitled.mp4
swift test --force-resolved-versions 2>&1 | tee $work/tests.log
for kind in hls dash; do
  if [[ $kind == hls ]]; then
    address=$base/hls/master.m3u8
    export YOINK_MEDIA_EXPECTED_DURATION=18
    export YOINK_MEDIA_SOURCE_MARKER='SOURCE CAPTIONS es'
  else
    address=$base/dash/manifest.mpd
    unset YOINK_MEDIA_EXPECTED_DURATION YOINK_MEDIA_SOURCE_MARKER
  fi
  YOINK_MEDIA_FIXTURE_URL=$address YOINK_MEDIA_OUTPUT=$work/$kind-subtitled.mp4 swift test --force-resolved-versions --filter DownloaderSubtitleTests.testAcquiredMediaSavesOriginalAndEnglishAtExpectedTimes 2>&1 | tee $work/$kind.log
done
if [[ ${YOINK_CHECK_LONG:-0} == 1 ]]; then
  $ffmpeg -v error -y -stream_loop -1 -i $work/site/spanish.mp4 -t 610 -c copy $work/long.mp4
  YOINK_SUBTITLE_FIXTURE=$work/long.mp4 YOINK_SUBTITLE_OUTPUT=$work/long-subtitled.mp4 swift test --force-resolved-versions --filter SubtitlePipelineTests.testNonEnglishSpeechProducesOriginalAndEnglishSoftTracks 2>&1 | tee $work/long.log
  $ffmpeg -v error -i $work/long-subtitled.mp4 -map 0:s:1 -f srt $work/long-english.srt
  grep -q '00:10:0' $work/long-english.srt
fi
for file in $work/*subtitled.mp4; do
  $ffprobe -v error -show_streams -show_format -of json $file > $file.json
done
