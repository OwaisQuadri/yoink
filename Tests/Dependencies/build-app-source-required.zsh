#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-source-required.XXXXXX")
mkdir -p "$work/scripts"
cp scripts/build-app.sh "$work/scripts/"
cat > "$work/scripts/build-ffmpeg.sh" <<'MOCK'
#!/bin/zsh
print -u2 'VERIFIED_SOURCE_BUILD_REQUIRED'
exit 79
MOCK
for argument in '' --local; do
  arguments=()
  if [[ -n $argument ]]; then arguments=("$argument"); fi
  result=0
  zsh "$work/scripts/build-app.sh" "${arguments[@]}" > "$work/result.log" 2>&1 || result=$?
  [[ $result == 79 ]]
  grep -q VERIFIED_SOURCE_BUILD_REQUIRED "$work/result.log"
  [[ ! -d "$work/build" ]]
done
print "PASS: local and distribution builds require the source pipeline before packaging or signing. Evidence at $work"
