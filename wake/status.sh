#!/usr/bin/env bash
# Show pipeline progress: which stage is running, how far along, and an ETA.
# Rates come from the mtimes of recently written files, so it reports instantly
# rather than having to sample over time.
#
#   ./status.sh          once
#   ./status.sh -w       refresh every 30s
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

CFG=config/hey_neon.yml
CLIPS=output/hey_neon/hey_neon

bar() { # bar <done> <total> <width>
  local d=$1 t=$2 w=${3:-28} f
  [ "$t" -le 0 ] && t=1
  f=$(( d * w / t )); [ "$f" -gt "$w" ] && f=$w
  # printf with an empty arg list still emits its format once, so guard both runs
  printf '['
  [ "$f" -gt 0 ] && printf '%0.s#' $(seq 1 "$f")
  [ $((w - f)) -gt 0 ] && printf '%0.s.' $(seq 1 $((w - f)))
  printf ']'
}

count() { ls "$1" 2>/dev/null | wc -l | tr -d ' '; }

# Files/sec, measured across the newest N files in a directory.
rate_of() {
  local d=$1 n newest oldest span
  local files; files=$(ls -t "$d" 2>/dev/null | head -300)
  n=$(printf '%s\n' "$files" | grep -c . )
  [ "$n" -lt 5 ] && { echo 0; return; }
  newest=$(stat -f %m "$d/$(printf '%s\n' "$files" | head -1)" 2>/dev/null || echo 0)
  oldest=$(stat -f %m "$d/$(printf '%s\n' "$files" | tail -1)" 2>/dev/null || echo 0)
  span=$(( newest - oldest ))
  [ "$span" -le 0 ] && { echo 0; return; }
  echo "scale=3; ($n - 1) / $span" | bc
}

human() { # seconds -> "2h 15m"
  local s=${1%.*}
  [ -z "$s" ] || [ "$s" -le 0 ] 2>/dev/null && { echo "--"; return; }
  printf '%dh %02dm' $((s/3600)) $(((s%3600)/60))
}

show() {
  local N NV running stage
  N=$(awk '/^n_samples:/{print $2}' "$CFG")
  NV=$(awk '/^n_samples_val:/{print $2}' "$CFG")

  running=$(container list 2>/dev/null | awk '/hey-neon-/{print $1}' | head -1)
  stage=${running#hey-neon-}

  echo
  if [ -n "$running" ]; then
    echo "  stage: $stage (running)"
  else
    echo "  stage: idle — no hey-neon container running"
  fi
  echo

  # ---- clip generation ----
  local total=0 done_all=0 active="" pct
  for spec in "positive_train:$N" "negative_train:$N" "positive_test:$NV" "negative_test:$NV"; do
    local name=${spec%%:*} target=${spec##*:} c
    c=$(count "$CLIPS/$name")
    total=$((total + target)); done_all=$((done_all + c))
    [ "$c" -lt "$target" ] && [ -z "$active" ] && [ "$c" -gt 0 ] && active="$CLIPS/$name"
    pct=$(( c * 100 / (target > 0 ? target : 1) ))
    printf '  %-15s %s %6d/%-6d %3d%%\n' "$name" "$(bar $c $target)" "$c" "$target" "$pct"
  done

  pct=$(( done_all * 100 / (total > 0 ? total : 1) ))
  echo "  ─────────────────────────────────────────────────────────────"
  printf '  %-15s %s %6d/%-6d %3d%%\n' "clips total" "$(bar $done_all $total)" "$done_all" "$total" "$pct"

  if [ "$stage" = "generate" ] && [ -n "$active" ]; then
    local r; r=$(rate_of "$active")
    if [ "$(echo "$r > 0" | bc)" = "1" ]; then
      local remain eta
      remain=$(( total - done_all ))
      eta=$(echo "scale=0; $remain / $r" | bc)
      printf '\n  rate %.2f clips/s   eta %s\n' "$r" "$(human "$eta")"
    fi
  fi

  # ---- later stages, read from their logs ----
  if [ "$stage" = "augment" ] && [ -f logs/augment.log ]; then
    local p; p=$(tr '\r' '\n' < logs/augment.log | grep -oE '[0-9]+%' | tail -1)
    local nf; nf=$(ls "$CLIPS"/*.npy 2>/dev/null | wc -l | tr -d ' ')
    echo; echo "  augment: feature file $((nf + 1))/4, current file ${p:-0%}"
  fi

  if [ "$stage" = "train" ] && [ -f logs/train.log ]; then
    local step seq
    step=$(tr '\r' '\n' < logs/train.log | grep -oE '[0-9]+/[0-9]+ \[' | tail -1 | tr -d ' [')
    seq=$(grep -c 'Starting training sequence' logs/train.log 2>/dev/null || echo 0)
    echo; echo "  train: sequence $seq, step ${step:-0}"
  fi

  # ---- voice recordings ----
  local vp vn
  vp=$(count data/my_voice/positive); vn=$(count data/my_voice/negative)
  if [ "$vp" -gt 0 ] || [ "$vn" -gt 0 ]; then
    echo; printf '  my voice: %d positive, %d negative recorded\n' "$vp" "$vn"
  fi

  # ---- models ----
  if ls output/hey_neon/*.onnx >/dev/null 2>&1; then
    echo; echo "  models:"
    for m in output/hey_neon/*.onnx output/hey_neon/*.tflite; do
      [ -f "$m" ] && printf '    %s  %sK  %s\n' "$(basename "$m")" \
        "$(( $(stat -f %z "$m") / 1024 ))" "$(stat -f '%Sm' -t '%b %d %H:%M' "$m")"
    done
  fi
  echo
}

if [ "${1:-}" = "-w" ]; then
  while true; do clear; show; sleep 30; done
else
  show
fi
