#!/usr/bin/env bash
# test-statusline.sh — smoke tests for the status line.
#
# The bash side has no jest coverage, and the two bugs worth remembering both
# lived here, so these assertions are deliberately about behaviour the status
# line must keep: the metrics bar always prints, and a broken or missing pet
# data file must not take it down with it.
#
# Run: bash scripts/test-statusline.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the suite can be pointed at another build of the script
SL="${PET_STATUSLINE:-$ROOT/scripts/pet-statusline.sh}"
DATA="$ROOT/src/data"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PET_DIR="$TMP/.claude/claude-pet"
mkdir -p "$PET_DIR"
cp "$DATA/sprites.json" "$DATA/creatures.json" "$PET_DIR/"

STATE_GOOD='{"currentLineId":"invader","currentStageIndex":2,"xp":450,"totalPromptsScored":9,"streakDays":3,"lastActiveDate":"2026-10-11","milestonesCompleted":[],"evolutionHistory":[]}'
STATE_BAD='{"currentLineId":"no-such-family","currentStageIndex":0,"xp":10,"totalPromptsScored":1,"streakDays":1,"lastActiveDate":"2026-10-11","milestonesCompleted":[],"evolutionHistory":[]}'
PAYLOAD='{"model":{"display_name":"Sonnet","id":"claude-sonnet-5-5"},"session_id":"s1","workspace":{"current_dir":"/home/ada/projects/claudePet"},"context_window":{"used_percentage":21.7,"context_window_size":200000,"total_input_tokens":42100,"total_output_tokens":1234,"current_usage":{"input_tokens":120,"cache_creation_input_tokens":800,"cache_read_input_tokens":41180,"output_tokens":1234}},"cost":{"total_cost_usd":0.01234,"total_duration_ms":192000,"total_lines_added":12,"total_lines_removed":3}}'

# render [state-json|""] [config-json|""]
render() {
  rm -f "$PET_DIR/state.json" "$PET_DIR/config.json"
  [[ -n "${1:-}" ]] && printf '%s' "$1" > "$PET_DIR/state.json"
  [[ -n "${2:-}" ]] && printf '%s' "$2" > "$PET_DIR/config.json"
  HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
    bash "$SL" <<< "$PAYLOAD" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { # label, haystack, needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "expected to contain: $3"; fi
}
nocheck() { # label, haystack, needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "expected NOT to contain: $3"; fi
}

echo "── status line smoke tests ──"

out="$(render "$STATE_GOOD" '{"display":true}')"
check "renders the model name"        "$out" "⬡ Sonnet"
check "renders the context bar"       "$out" "[##--------] 21%"
check "renders token counters"        "$out" "42.1k/200.0k"
check "renders the cache hit rate"    "$out" "cache 97%"
check "renders duration and lines"    "$out" "+12/-3"
check "renders the creature"          "$out" "Pet: ◆ Drone"
check "creature reports next level"   "$out" "♥ 450/1600 XP"

out="$(render "$STATE_GOOD" '{"display":false}')"
check "pet off keeps the metrics bar" "$out" "⬡ Sonnet"
nocheck "pet off hides the creature"  "$out" "Pet: ◆"

out="$(render "$STATE_GOOD" '')"
check "missing config defaults to on" "$out" "Pet: ◆"

out="$(render "" '{"display":true}')"
check "missing state.json keeps bar"  "$out" "⬡ Sonnet"

out="$(render "$STATE_BAD" '{"display":true}')"
check "unknown family keeps the bar"  "$out" "⬡ Sonnet"

# Malformed stdin must still leave a usable bar rather than nothing at all
out="$(HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" <<< 'not json' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "malformed stdin falls back to defaults" "$out" "⬡ Claude"

echo
if (( FAIL > 0 )); then
  printf '  %d passed, %d FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '  %d passed\n' "$PASS"
