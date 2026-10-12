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

# ── cost tiering ─────────────────────────────────────────────────────────────
# render() above sets PET_PRICING_COST=0, so none of those assertions touch the
# cost python at all. These do, with a pinned clock (PET_NOW_UTC) and a config
# carrying a DeepSeek peak/off-peak card.
CARD_CONFIG='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{
  "tier_mode":"auto","peak_days":[1,2,3,4,5],
  "peak_windows":[["01:00","04:00"],["06:00","10:00"]],
  "off_peak_dates":["2026-10-01"],
  "models":{
    "deepseek-flash":{"source":"deepseek-builtin",
      "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.60,"cache_read_per_mtok":0.003},
      "peak":{"input_per_mtok":0.30,"output_per_mtok":1.20,"cache_read_per_mtok":0.006}},
    "glm-flat":{"input_per_mtok":0.1,"output_per_mtok":0.5,"cache_read_per_mtok":0.03}}}}'

cost_payload() { # $1 = model id
  printf '{"model":{"display_name":"%s","id":"%s"},"session_id":"t",' "$1" "$1"
  printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":10,'
  printf '"context_window_size":200000,"current_usage":{"input_tokens":1000,'
  printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":100000,"output_tokens":2000}},'
  printf '"cost":{"total_cost_usd":18.088}}'
}

cost_render() { # $1=config json  $2=model  $3=PET_NOW_UTC  $4=extra env
  printf '%s' "$1" > "$PET_DIR/config.json"
  rm -f "$PET_DIR/cost-state.json"     # each case starts a fresh accumulator
  HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
    PET_NOW_UTC="$3" ${4:-} \
    bash "$SL" <<< "$(cost_payload "${2:-deepseek-flash}")" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g'
}
cost_of() { grep -o '\$[0-9.]*' <<< "$1" | head -1; }

MON_PEAK=2026-10-12T02:00:00Z     # Monday, inside a peak window
MON_GAP=2026-10-12T05:00:00Z      # Monday, between the two windows
SUNDAY=2026-10-11T02:00:00Z       # weekend: off-peak all day
HOLIDAY=2026-10-01T02:00:00Z      # National Day, a Thursday

out_peak="$(cost_render "$CARD_CONFIG" deepseek-flash "$MON_PEAK")"
out_off="$(cost_render "$CARD_CONFIG" deepseek-flash "$MON_GAP")"
check "peak window is labelled 峰"      "$out_peak" "峰"
check "between windows is labelled 谷"  "$out_off" "谷"
check "weekend is off-peak"             "$(cost_render "$CARD_CONFIG" deepseek-flash "$SUNDAY")" "谷"
check "holiday is off-peak"             "$(cost_render "$CARD_CONFIG" deepseek-flash "$HOLIDAY")" "谷"

# Same request priced on both tariffs: the peak total must be exactly double
python3 - "$(cost_of "$out_off")" "$(cost_of "$out_peak")" <<'PY'
import sys
off, pk = (float(x.lstrip("$")) for x in sys.argv[1:3])
raise SystemExit(0 if abs(pk - 2 * off) < 0.0002 else 1)
PY
if (( $? == 0 )); then ok "peak total is exactly 2x the off-peak total"
else bad "peak total is exactly 2x the off-peak total" "off=$out_off peak=$out_peak"; fi

# A flat catalogue price has no tier to report
out_flat="$(cost_render "$CARD_CONFIG" glm-flat "$MON_PEAK")"
nocheck "flat model shows no tier"      "$out_flat" "峰"
nocheck "flat model shows no tier"      "$out_flat" "谷"
check "flat model still shows a cost"   "$out_flat" "\$"

forced="$(jq -c '.pricing.tier_mode = "off_peak"' <<< "$CARD_CONFIG")"
nocheck "tier_mode pins off-peak at peak hours" \
  "$(cost_render "$forced" deepseek-flash "$MON_PEAK")" "峰"

hidden="$(jq -c '.currency.show_tier = false' <<< "$CARD_CONFIG")"
nocheck "currency.show_tier=false hides the label" \
  "$(cost_render "$hidden" deepseek-flash "$MON_PEAK")" "峰"

noenv="$(cost_render "$CARD_CONFIG" deepseek-flash "$MON_PEAK" PET_COST_TIER_LABEL=0)"
nocheck "PET_COST_TIER_LABEL=0 hides the label" "$noenv" "峰"

# No pricing block at all (what install.sh seeds on a fresh install)
out_bare="$(cost_render '{"display":true}' deepseek-flash "$MON_PEAK")"
check "config without pricing still renders" "$out_bare" "⬡"

# ── context window ───────────────────────────────────────────────────────────
# Claude Code reports 200000 for models it does not recognise as extended-
# context, which understates a gateway model, so the model card's limit wins.
CTX_CONFIG='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "deepseek-flash":{"source":"deepseek-docs","context_tokens":1000000,
    "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.6,"cache_read_per_mtok":0.003},
    "peak":{"input_per_mtok":0.3,"output_per_mtok":1.2,"cache_read_per_mtok":0.006}}}}}'

ctx_payload() { # $1=context_window_size  $2=used_percentage
  printf '{"model":{"display_name":"deepseek-flash","id":"deepseek-flash"},"session_id":"t",'
  printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":%s,' "$2"
  printf '"context_window_size":%s,"current_usage":{"input_tokens":1000,' "$1"
  printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":499000,"output_tokens":10}},'
  printf '"cost":{"total_cost_usd":1}}'
}

ctx_render() { # $1=config  $2=payload window  $3=payload percentage
  printf '%s' "$1" > "$PET_DIR/config.json"
  rm -f "$PET_DIR/cost-state.json"
  HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
    PET_NOW_UTC=2026-10-12T05:00:00Z \
    bash "$SL" <<< "$(ctx_payload "$2" "$3")" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -o '\[.*% [0-9.]*[kM]*/[0-9.]*[kM]*'
}

check "model limit overrides Claude Code's 200k default" \
  "$(ctx_render "$CTX_CONFIG" 200000 250)" "[#####-----] 50% 500.0k/1.0M"
check "keeps a larger size when the payload knows better" \
  "$(ctx_render "$CTX_CONFIG" 2000000 25)" "[##--------] 25% 500.0k/2.0M"
check "explicit context_window_tokens wins" \
  "$(ctx_render '{"display":true,"context_window_tokens":500000}' 200000 250)" \
  "[##########] 100% 500.0k/500.0k"
check "without a price table the payload's size stands" \
  "$(ctx_render '{"display":true}' 200000 250)" "[##########] 250% 500.0k/200.0k"

# ── per-session cost accumulator ─────────────────────────────────────────────
# A single slot keyed by session id meant any id change — resuming, or a second
# session rendering — threw the running total away and looked like a reset.
FLAT1='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "m":{"input_per_mtok":1,"output_per_mtok":2,"cache_read_per_mtok":0.1}}}}'

sess_render() { # $1=config $2=session id $3=input tokens → echoes that session's total
  printf '%s' "$1" > "$PET_DIR/config.json"
  {
    printf '{"model":{"display_name":"m","id":"m"},"session_id":"%s",' "$2"
    printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":10,'
    printf '"context_window_size":200000,"current_usage":{"input_tokens":%s,' "$3"
    printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},'
    printf '"cost":{}}'
  } | HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
      bash "$SL" >/dev/null 2>&1
  jq -r --arg s "$2" '.sessions[$s].total_usd // "none"' "$PET_DIR/cost-state.json" 2>/dev/null
}

rm -f "$PET_DIR/cost-state.json"
check "session accumulates its first request" "$(sess_render "$FLAT1" A 1)" "0.000001"
sess_render "$FLAT1" A 2 >/dev/null
check "session keeps accumulating"            "$(sess_render "$FLAT1" A 3)" "0.000006"
sess_render "$FLAT1" B 9 >/dev/null
check "a second session gets its own total"   "$(jq -r '.sessions.B.total_usd' "$PET_DIR/cost-state.json")" "0.000009"
check "switching sessions does not wipe A"    "$(jq -r '.sessions.A.total_usd' "$PET_DIR/cost-state.json")" "0.000006"

printf '%s' '{"session_id":"OLD","total_usd":1.5,"last_fp":"1|0|0|0","model":"m"}' > "$PET_DIR/cost-state.json"
check "the old single-slot file migrates"     "$(sess_render "$FLAT1" OLD 2)" "1.500002"

python3 - "$PET_DIR/cost-state.json" <<'PY'
import json, sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({"sessions": {
    f"s{i}": {"total_usd": 1, "last_fp": f"{i}|0|0|0",
              "updated_at": f"2026-01-{i + 1:02d}T00:00:00Z"}
    for i in range(20)}}), encoding="utf-8")
PY
sess_render "$FLAT1" NEW 1 >/dev/null
check "the session map is capped"             "$(jq '.sessions | length' "$PET_DIR/cost-state.json")" "20"

# ── peak-tariff alert ────────────────────────────────────────────────────────
# Peak costs double, so past a cost threshold the warning moves to the front of
# the line with a countdown; before peak starts it pre-warns instead. Every knob
# is meant to be configurable, so each one gets a case.
PEAK_CONFIG='{"display":true,"currency":{"code":"CNY","symbol":"¥","usd_rate":6.70036411},
  "peak_alert":{"enabled":true,"countdown":true,"pre_warn_minutes":15,"cost_threshold":1,"show_premium":true},
  "pricing":{"tier_mode":"auto","peak_days":[1,2,3,4,5],
   "peak_windows":[["01:00","04:00"],["06:00","10:00"]],"off_peak_dates":["2026-10-01"],
   "models":{"deepseek-flash":{"context_tokens":1000000,
     "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.6,"cache_read_per_mtok":0.003},
     "peak":{"input_per_mtok":0.3,"output_per_mtok":1.2,"cache_read_per_mtok":0.006}}}}}'

peak_cfg() { jq -c "$1" <<< "$PEAK_CONFIG" > "$PET_DIR/config.json"; }

peak_render() { # $1=now (UTC) $2=cache-read tokens; 30M ≈ ¥1.22 at peak rates
  rm -f "$PET_DIR/cost-state.json"
  {
    printf '{"model":{"display_name":"deepseek-flash","id":"deepseek-flash"},"session_id":"t",'
    printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":50,'
    printf '"context_window_size":200000,"current_usage":{"input_tokens":1000,'
    printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":2000}},' "$2"
    printf '"cost":{"total_cost_usd":49.33}}'
  } | HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_NOW_UTC="$1" \
      bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -1
}
count_in() { grep -c "$1" <<< "$2"; }

MON_PEAK=2026-10-12T02:00:00Z     # Monday, inside a peak window
MON_OFF=2026-10-12T05:00:00Z      # Monday, between the windows
MON_WARN=2026-10-12T05:50:00Z     # ten minutes before peak starts

peak_cfg '.'
line="$(peak_render "$MON_PEAK" 30000000)"
check "peak over the threshold leads the line" "$(count_in '^⚡峰' "$line")" "1"
check "countdown says when off-peak returns"   "$(count_in '⚡峰 2h00m' "$line")" "1"
check "shows what peak has cost extra"         "$(count_in '+¥0\.6' "$line")" "1"
check "the quiet trailing marker steps aside"  "$(count_in '¥1.2242 峰' "$line")" "0"

peak_cfg '.peak_alert.cost_threshold = 99'
check "below the threshold it stays quiet" \
  "$(count_in '¥1.2242 峰' "$(peak_render "$MON_PEAK" 30000000)")" "1"

peak_cfg '.'
check "off-peak raises nothing at all" \
  "$(count_in '⚡' "$(peak_render "$MON_OFF" 30000000)")" "0"
check "pre-warns just before peak"  \
  "$(count_in '⚡峰 10m 后' "$(peak_render "$MON_WARN" 30000000)")" "1"

peak_cfg '.peak_alert.pre_warn_minutes = 0'
check "pre-warning can be switched off" \
  "$(count_in '⚡' "$(peak_render "$MON_WARN" 30000000)")" "0"

peak_cfg '.peak_alert.enabled = false'
check "enabled=false restores the old behaviour" \
  "$(count_in '¥1.2242 峰' "$(peak_render "$MON_PEAK" 30000000)")" "1"

peak_cfg '.peak_alert.countdown = false | .peak_alert.show_premium = false'
check "countdown and premium can be switched off" \
  "$(count_in '^⚡峰 │' "$(peak_render "$MON_PEAK" 30000000)")" "1"

# ── information segments (info.show / info.hide) ─────────────────────────────
# info.show is the master switch for the metrics bar; info.hide drops segments
# while it is on. model is deliberately NOT hideable, so the bar cannot end up
# blank by accident.
INFO_BASE='{"display":true,"currency":{"code":"CNY","symbol":"¥","usd_rate":6.70036411},
  "pricing":{"models":{"deepseek-flash":{"context_tokens":1000000,
    "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.6,"cache_read_per_mtok":0.003},
    "peak":{"input_per_mtok":0.3,"output_per_mtok":1.2,"cache_read_per_mtok":0.006}}}}}'
INFO_PAYLOAD='{"model":{"display_name":"deepseek-flash","id":"deepseek-flash"},"session_id":"i","workspace":{"current_dir":"/home/ada/projects/github/AI/claude/claudePet"},"context_window":{"used_percentage":21.7,"context_window_size":200000,"current_usage":{"input_tokens":120,"cache_creation_input_tokens":800,"cache_read_input_tokens":41180,"output_tokens":1234}},"cost":{"total_cost_usd":0.01234,"total_duration_ms":192000,"total_lines_added":12,"total_lines_removed":3}}'

info_render() { # $1 = config JSON
  printf '%s' "$1" > "$PET_DIR/config.json"
  rm -f "$PET_DIR/cost-state.json"
  HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_NOW_UTC=2026-10-12T05:00:00Z \
    bash "$SL" <<< "$INFO_PAYLOAD" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

bar="$(info_render "$INFO_BASE")"
check "default draws every conditional segment" \
  "$(count_in 'cache 97%' "$bar")" "1"
check "default draws duration and lines" \
  "$(( $(count_in '3m12s' "$bar") + $(count_in '+12/-3' "$bar") ))" "2"

bar="$(info_render "$(jq -c '.info = {hide: ["cache","out","duration","lines"]}' <<< "$INFO_BASE")")"
check "hide drops the named segments"  "$(( $(count_in 'cache 97%' "$bar") + $(count_in '3m12s' "$bar") + $(count_in '+12/-3' "$bar") ))" "0"
check "hide keeps the others"          "$(count_in '⬡ deepseek-flash' "$bar")" "1"
# the card says 1M, so 42.1k of context is 4% — the window override at work
check "hide keeps the context bar"     "$(count_in '4% 42.1k/1.0M' "$bar")" "1"

bar="$(info_render "$(jq -c '.info = {hide: ["model"]}' <<< "$INFO_BASE")")"
check "model is not hideable"          "$(count_in '⬡ deepseek-flash' "$bar")" "1"

bar="$(info_render "$(jq -c '.info = {show: false}' <<< "$INFO_BASE")")"
check "info.show=false drops the bar entirely" "$(count_in '⬡ deepseek-flash' "$bar")" "0"
check "info.show=false keeps the pet"  "$(count_in 'Pet: ◆' "$bar")" "1"

out="$(info_render "$(jq -c '.display = false | .info = {show: false}' <<< "$INFO_BASE")")"
check "both switches off print nothing at all" "${#out}" "0"

echo
if (( FAIL > 0 )); then
  printf '  %d passed, %d FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '  %d passed\n' "$PASS"
