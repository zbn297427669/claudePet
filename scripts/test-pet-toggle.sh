#!/usr/bin/env bash
# test-pet-toggle.sh — pet-toggle.sh, the script /pet on|off|status|reset calls.
#
# The point of these tests is the regression that made this script exist:
# `/pet off` used to be a whole-file write, so it deleted the currency, the peak
# alert settings and everything else in config.json. Every case here runs in a
# throwaway PET_DIR, so nothing touches the real ~/.claude/claude-pet.
#
# Run: bash scripts/test-pet-toggle.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOGGLE="${PET_TOGGLE:-$ROOT/scripts/pet-toggle.sh}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
count_in() { grep -c "$1" <<< "$2"; }

FULL_CONFIG='{
  "display": true,
  "currency": { "code": "CNY", "symbol": "¥", "usd_rate": 6.7, "show_usd": false },
  "peak_alert": { "enabled": true, "cost_threshold": 1 },
  "context_window_tokens": 1000000,
  "pricing": { "tier_mode": "auto", "models": { "m": { "off_peak": { "input_per_mtok": 0.15 } } } }
}'
STATE_TEMPLATE='{ "currentLineId": "aberrant", "currentStageIndex": 1, "xp": 193,
  "totalPromptsScored": 39, "streakDays": 1, "lastActiveDate": "2026-10-12",
  "milestonesCompleted": ["first_75"], "evolutionHistory": [{ "stageId": "aberrant_glitch", "reachedAt": "2026-10-11" }] }'

newdir() { # fresh PET_DIR with the registry + a full config; echoes the path
  local d; d="$(mktemp -d "$WORK/pet.XXXXXX")"
  cp "$ROOT/src/data/creatures.json" "$d/"
  printf '%s' "$FULL_CONFIG" > "$d/config.json"
  printf '%s' "$STATE_TEMPLATE" > "$d/state.json"
  printf '{"xp":8,"message":"hi","timestamp":1}' > "$d/last-activity.json"
  printf '%s' "$d"
}
run_toggle() { local d="$1"; shift; PET_DIR="$d" bash "$TOGGLE" "$@" 2>&1; }
q() { jq -r "$2" "$1" 2>/dev/null || echo "<jq-error>"; }

echo "── pet-toggle.sh ──"

# ── off must merge, not replace: the bug that started this ───────────────────
d="$(newdir)"
run_toggle "$d" off >/dev/null
check "off leaves the currency alone"     "$(q "$d/config.json" '.currency.code')" "CNY"
check "off leaves the peak alert alone"   "$(q "$d/config.json" '.peak_alert.cost_threshold')" "1"
check "off leaves the context window alone" "$(q "$d/config.json" '.context_window_tokens')" "1000000"
check "off leaves the price table alone"  "$(q "$d/config.json" '.pricing.models.m.off_peak.input_per_mtok')" "0.15"
check "off really turns the pet off"      "$(q "$d/config.json" '.display')" "false"
check "off keeps every key count"         "$(jq 'keys | length' "$d/config.json")" "5"

run_toggle "$d" on >/dev/null
check "on turns it back on"               "$(q "$d/config.json" '.display')" "true"
check "on still keeps the other keys"     "$(jq 'keys | length' "$d/config.json")" "5"

# ── creating it when absent ─────────────────────────────────────────────────
d="$(mktemp -d "$WORK/none.XXXXXX")"; cp "$ROOT/src/data/creatures.json" "$d/"
run_toggle "$d" off >/dev/null
check "creates config.json when missing"  "$(q "$d/config.json" '.display')" "false"

# ── an unparseable config must be left alone, not clobbered ─────────────────
d="$(mktemp -d "$WORK/bad.XXXXXX")"; printf '{broken json' > "$d/config.json"
out="$(run_toggle "$d" off)"; rc=$?
check "a bad config.json is left untouched" "$(cat "$d/config.json")" "{broken json"
if (( rc != 0 )); then ok "and the failure is reported"; else bad "and the failure is reported" "exit=$rc"; fi
case "$out" in *"not valid JSON"*) ok "with a clear reason" ;; *) bad "with a clear reason" "$out" ;; esac

# ── status ──────────────────────────────────────────────────────────────────
d="$(newdir)"
out="$(run_toggle "$d" status)"
check "status names the stage"            "$(count_in 'Glitch — aberrant' "$out")" "1"
check "status shows XP and the next level" "$(count_in '193 / 400' "$out")" "1"
check "status shows the prompt count"     "$(count_in '39 scored' "$out")" "1"
check "status shows the display state"    "$(count_in 'Display:  on' "$out")" "1"
run_toggle "$d" off >/dev/null
check "status follows the toggle"         "$(count_in 'Display:  off' "$(run_toggle "$d" status)")" "1"

d="$(mktemp -d "$WORK/empty.XXXXXX")"; cp "$ROOT/src/data/creatures.json" "$d/"
check "status copes with no state yet"    "$(count_in 'No pet yet' "$(run_toggle "$d" status)")" "1"

# ── reset ───────────────────────────────────────────────────────────────────
d="$(newdir)"
out="$(run_toggle "$d" reset)"
check "reset reports a family"            "$(count_in 'Pet reset!' "$out")" "1"
check "reset writes a fresh state"        "$(q "$d/state.json" '.xp')" "0"
check "reset clears the prompt count"     "$(q "$d/state.json" '.totalPromptsScored')" "0"
check "reset clears the milestones"       "$(jq -c '.milestonesCompleted' "$d/state.json")" "[]"
check "reset drops the activity line"     "$([ -f "$d/last-activity.json" ] && echo present || echo gone)" "gone"
line="$(q "$d/state.json" '.currentLineId')"
check "the family comes from the registry" "$(jq -r --arg l "$line" '.evolutionLines | has($l)' "$d/creatures.json")" "true"

# ── info: the metrics bar ───────────────────────────────────────────────────
d="$(newdir)"
run_toggle "$d" info off >/dev/null
check "info off sets the master switch"   "$(q "$d/config.json" '.info.show')" "false"
check "info off keeps the other keys"     "$(q "$d/config.json" '.currency.code')" "CNY"
run_toggle "$d" info on >/dev/null
check "info on turns it back on"          "$(q "$d/config.json" '.info.show')" "true"

run_toggle "$d" info hide cache,out >/dev/null
check "hide sets the list"                "$(jq -c '.info.hide' "$d/config.json")" '["cache","out"]'
run_toggle "$d" info hide lines >/dev/null
check "hide adds to the list"             "$(jq -c '.info.hide' "$d/config.json")" '["cache","lines","out"]'
run_toggle "$d" info hide cache >/dev/null
check "hide does not duplicate"           "$(jq -c '.info.hide' "$d/config.json")" '["cache","lines","out"]'
run_toggle "$d" info unhide cache >/dev/null
check "unhide removes one"                "$(jq -c '.info.hide' "$d/config.json")" '["lines","out"]'
run_toggle "$d" info hide >/dev/null
check "hide with no names clears the list" "$(jq -c '.info.hide' "$d/config.json")" '[]'
check "and the other keys are still there" "$(q "$d/config.json" '.peak_alert.cost_threshold')" "1"

out="$(run_toggle "$d" info hide cache,typo)"; rc=$?
if (( rc != 0 )); then ok "an unknown segment is refused"; else bad "an unknown segment is refused" "exit=$rc"; fi
case "$out" in *"valid segments:"*) ok "and the valid names are listed" ;; *) bad "and the valid names are listed" "$out" ;; esac
out="$(run_toggle "$d" info hide model)"; rc=$?
if (( rc != 0 )); then ok "hiding the model name is refused"; else bad "hiding the model name is refused" "exit=$rc"; fi
case "$out" in *"identity"*) ok "with the reason" ;; *) bad "with the reason" "$out" ;; esac
check "a refused hide changed nothing"    "$(jq -c '.info.hide' "$d/config.json")" '[]'

run_toggle "$d" info hide cache >/dev/null
check "info status reports the hidden list" "$(count_in 'Hidden segments:  cache' "$(run_toggle "$d" info status)")" "1"
check "status lines carry the info state"   "$(count_in 'Info:     on (hiding: cache)' "$(run_toggle "$d" status)")" "1"

# ── misc ────────────────────────────────────────────────────────────────────
d="$(newdir)"
run_toggle "$d" bogus >/dev/null; rc=$?
check "an unknown action exits 2"          "$rc" "2"
run_toggle "$d" >/dev/null; rc=$?
check "no action defaults to status"       "$rc" "0"
check "no lock file is left behind"        "$(ls -a "$d" | grep -c 'lock')" "0"

echo
if (( FAIL > 0 )); then
  printf '  %d passed, %d FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '  %d passed\n' "$PASS"
