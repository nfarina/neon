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

# Generation progress counts only Piper's clips. Injected myvoice_* copies would
# otherwise push the bars past 100% and make a finished run look overshot.
count_generated() { ls "$1" 2>/dev/null | grep -vc '^myvoice_' || echo 0; }

# Files/sec over the last WINDOW seconds only. Measuring across "the newest N
# files" instead would silently span any idle gap — after a crash and restart
# that reads as a near-zero rate and a nonsense ETA.
WINDOW=900
rate_of() {
  local d=$1 now cutoff n=0 oldest span mt
  now=$(date +%s); cutoff=$(( now - WINDOW )); oldest=$now

  local files; files=$(ls -t "$d" 2>/dev/null | head -600)
  [ -z "$files" ] && { echo 0; return; }

  local paths=()
  while IFS= read -r f; do [ -n "$f" ] && paths+=("$d/$f"); done <<< "$files"
  [ ${#paths[@]} -eq 0 ] && { echo 0; return; }

  while read -r mt; do
    if [ -n "$mt" ] && [ "$mt" -ge "$cutoff" ]; then
      n=$(( n + 1 ))
      [ "$mt" -lt "$oldest" ] && oldest=$mt
    fi
  done < <(stat -f %m "${paths[@]}" 2>/dev/null)

  span=$(( now - oldest ))
  if [ "$n" -lt 5 ] || [ "$span" -le 0 ]; then echo 0; return; fi
  echo "scale=3; $n / $span" | bc
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
    c=$(count_generated "$CLIPS/$name")
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
      printf '\n  rate %.2f clips/s   eta %s   (last %dm)\n' "$r" "$(human "$eta")" $((WINDOW / 60))
    else
      printf '\n  rate: measuring (needs a few minutes of output)\n'
    fi
  fi

  # ---- later stages, read from their logs ----
  if [ "$stage" = "augment" ] && [ -f logs/augment.log ]; then
    local p; p=$(tr '\r' '\n' < logs/augment.log | grep -oE '[0-9]+%' | tail -1)
    local nf; nf=$(ls "$CLIPS"/*.npy 2>/dev/null | wc -l | tr -d ' ')
    echo; echo "  augment: feature file $((nf + 1))/4, current file ${p:-0%}"
  fi

  if [ "$stage" = "train" ] && [ -f logs/train.log ]; then
    # tqdm already carries both the rate and its own remaining estimate on the
    # progress line; parsing them beats re-deriving from file mtimes, which is
    # what the generate stage has to do because it writes no progress line.
    local tq step seq rate rem
    tq=$(tr '\r' '\n' < logs/train.log | grep -oE 'Training: +[0-9]+%.*' | tail -1)
    step=$(printf '%s' "$tq" | grep -oE '[0-9]+/[0-9]+' | head -1)
    rate=$(printf '%s' "$tq" | grep -oE '[0-9.]+it/s' | tail -1)
    rem=$(printf '%s' "$tq" | grep -oE '<[0-9:]+' | tr -d '<')
    seq=$(grep -c 'Starting training sequence' logs/train.log 2>/dev/null || echo 0)
    echo
    echo "  train: sequence $seq, step ${step:-0}"
    if [ -n "${rem:-}" ]; then
      # Only this sequence. auto_train runs extra short sequences afterwards,
      # ratcheting negative weight until it hits the false-positive target.
      echo "         ${rate:-?} — ${rem} left in this sequence (more may follow)"
    fi
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
