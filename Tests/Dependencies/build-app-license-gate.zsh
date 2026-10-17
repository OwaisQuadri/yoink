#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/yoink-license-gate.XXXXXX")
mkdir -p "$work/scripts" "$work/bin"
cp scripts/build-app.sh "$work/scripts/"
cat > "$work/bin/curl" <<'MOCK'
#!/bin/zsh
print -u2 'LOCAL_DOWNLOAD_REACHED'
exit 79
MOCK
chmod +x "$work/bin/curl"

for argument in '' --release; do
  arguments=()
  if [[ -n $argument ]]; then arguments=("$argument"); fi
  result=0
  PATH="$work/bin:$PATH" zsh "$work/scripts/build-app.sh" "${arguments[@]}" > "$work/distribution.log" 2>&1 || result=$?
  [[ $result == 1 ]]
  grep -q 'Distribution build blocked: matching FFmpeg/ffprobe and static dependency corresponding source is unverified' "$work/distribution.log"
  [[ ! -d "$work/vendor" ]]
done

result=0
PATH="$work/bin:$PATH" zsh "$work/scripts/build-app.sh" --local > "$work/local.log" 2>&1 || result=$?
[[ $result == 79 ]]
grep -q LOCAL_DOWNLOAD_REACHED "$work/local.log"
if grep -q 'Distribution build blocked' "$work/local.log"; then
  exit 1
fi
print "PASS: distribution stops before downloads; --local reaches dependency preparation. Evidence at $work"
