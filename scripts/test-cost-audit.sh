#!/usr/bin/env bash
# test-cost-audit.sh — smoke test for pet-cost-audit.py.
#
# The audit tool is the thing we tell people to trust when the status line and
# the provider disagree, so it needs a guard beyond `python3 -m py_compile`,
# which cannot catch a runtime type error. Everything here runs against a
# synthetic transcript built on the spot.
#
# Run: bash scripts/test-cost-audit.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="${PET_COST_AUDIT:-$ROOT/scripts/pet-cost-audit.py}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

# ── fixtures ─────────────────────────────────────────────────────────────────
CONFIG="$WORK/config.json"
cat > "$CONFIG" <<'JSON'
{ "display": true,
  "currency": { "code": "USD", "symbol": "$", "usd_rate": 1 },
  "pricing": { "tier_mode": "off_peak", "models": {
    "deepseek-flash": { "source": "deepseek-builtin", "context_tokens": 1000000,
      "off_peak": { "input_per_mtok": 0.15, "output_per_mtok": 0.60, "cache_read_per_mtok": 0.003 },
      "peak":     { "input_per_mtok": 0.30, "output_per_mtok": 1.20, "cache_read_per_mtok": 0.006 } } } } }
JSON

TRANSCRIPT="$WORK/sess-abc.jsonl"
python3 - "$TRANSCRIPT" <<'PY'
import json, sys
from pathlib import Path

# two API responses, each written twice the way Claude Code does, plus one row
# with no usage at all (a user turn) that must be ignored
msgs = [
    ("msg-1", {"input_tokens": 1000, "cache_creation_input_tokens": 0,
               "cache_read_input_tokens": 100000, "output_tokens": 2000}),
    ("msg-2", {"input_tokens": 500, "cache_creation_input_tokens": 0,
               "cache_read_input_tokens": 200000, "output_tokens": 4000}),
]
rows = []
for i, (mid, usage) in enumerate(msgs):
    for _ in range(2):                      # the transcript repeats each response
        rows.append({"type": "assistant", "timestamp": f"2026-10-11T11:0{i}:00.000Z",
                     "message": {"id": mid, "model": "deepseek-flash", "usage": usage}})
rows.append({"type": "user", "timestamp": "2026-10-11T11:09:00.000Z",
             "message": {"role": "user", "content": "hi"}})
rows.append({"type": "assistant", "timestamp": "2026-10-11T11:10:00.000Z",
             "message": {"id": "msg-3", "model": "deepseek-flash", "usage": {}},
             "costUSD": 9.99})
Path(sys.argv[1]).write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
PY

echo "── pet-cost-audit.py ──"

json_out="$(python3 -I "$AUDIT" --transcript "$TRANSCRIPT" --config "$CONFIG" --json 2>&1)"
if [[ -z "$json_out" ]]; then
  bad "runs against a transcript" "$json_out"
else
  ok "runs against a transcript"
  jq_get() { jq -r "$1" <<< "$json_out"; }
  # 2 responses, 4 usage rows: the duplicates must be dropped
  check "counts requests once each"     "$(jq_get '.requests')" "2"
  check "reports the duplicates skipped" "$(jq_get '.duplicate_records_skipped')" "2"
  check "sums cache reads"              "$(jq_get '.tokens.cr')" "300000"
  check "sums output"                   "$(jq_get '.tokens.out')" "6000"
  check "prices with the off-peak card" "$(jq_get '.cost_usd.off_peak')" "0.004725"
  check "reads Claude Code's own figure" "$(jq_get '.claude_code_usd')" "9.99"
fi

# and the human-readable path, which is what a type error would have broken
human="$(python3 -I "$AUDIT" --transcript "$TRANSCRIPT" --config "$CONFIG" 2>&1)"
if [[ -n "$human" ]]; then ok "renders the report"; else bad "renders the report" "no output"; fi
case "$human" in *"cache reads are"*) ok "reports the cache share" ;;
                 *) bad "reports the cache share" "$human" ;; esac

# --paid reconciles against a billed amount
paid="$(python3 -I "$AUDIT" --transcript "$TRANSCRIPT" --config "$CONFIG" --paid 0.10 2>&1)"
case "$paid" in *"implied"*) ok "--paid reconciles" ;; *) bad "--paid reconciles" "$paid" ;; esac

echo
if (( FAIL > 0 )); then
  printf '  %d passed, %d FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '  %d passed\n' "$PASS"
