#!/bin/bash
# Converts every test video with several settings and checks the results.
set -uo pipefail
cd "$(dirname "$0")"
APP="../Mono Maker.app/Contents/MacOS/MonoMaker"
mkdir -p out
fail=0
run() {
  local file="$1" name="$2" channels="$3" kind="$4"; shift 4
  local out="out/${name}"
  echo "== $file $*"
  if ! "$APP" --selftest "media/$file" "$out" "$@"; then
    echo "  CONVERSION FAILED"; fail=1; return
  fi
  python3 check.py "media/$file" "$out" "$channels" "$kind" || fail=1
}
for f in stereo_aac.mov left_only.mov pcm24_4ch.mov aac_51.mp4 mono_441.mov two_tracks.mov hevc_alac.mov phase.mov mp3.mov opus.mp4; do
  [ -f "media/$f" ] || continue
  base="${f%.*}"; ext="${f##*.}"
  kind=normal; [ "$f" = phase.mov ] && kind=phase
  run "$f" "${base}_mono.${ext}" 1 "$kind"
  run "$f" "${base}_both.${ext}" 2 "$kind" --both
  run "$f" "${base}_eqloud.${ext}" 1 "$kind" --enhance --loud
done
# Noise removal at each strength on the noisy speech clip
for lvl in light medium strong; do
  run stereo_aac.mov "noise_${lvl}.mov" 1 normal --noise $lvl --enhance --loud
done
run hevc_alac.mov "hevc_noise.mov" 2 normal --noise medium --both
exit $fail
