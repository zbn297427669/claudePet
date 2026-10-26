#!/usr/bin/env bash
# test-pricing.sh — behavioural tests for update-model-pricing.sh, offline.
#
# The updater fetches three sources before any logic runs, so each source can be
# injected as a file (PET_PRICING_*_FILE) and the merge/write path exercised
# without the network. What matters here: an official card always beats a
# guessed OpenRouter match, a hand-pinned price is never overwritten, and a
# failure never wipes the table.
#
# Run: bash scripts/test-pricing.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATER="${PET_PRICING_UPDATER:-$ROOT/scripts/update-model-pricing.sh}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"
mkdir -p "$FIX"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { # label, actual, expected
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}

# ── fixtures ─────────────────────────────────────────────────────────────────
cat > "$FIX/catalog.json" <<'JSON'
{ "data": [
  { "id": "z-ai/glm-5.3-flash", "context_length": 131072, "pricing": { "prompt": 0.00000015, "completion": 0.0000005, "input_cache_read": 0.00000003 } },
  { "id": "~deepseek/deepseek-flash-latest", "context_length": 1048576, "pricing": { "prompt": 0.0000000348, "completion": 0.0000001392, "input_cache_read": 0.000000000696 } }
] }
JSON

# Same shape as the real page: the PRICING row group, then the schedule sentence.
# Peak is always exactly 2x off-peak (the docs say so, and the parser enforces it).
write_docs() { # $1=out $2=flash_cache_hit_off $3=flash_cache_miss_off $4=flash_output_off
  python3 - "$@" <<'PY'
import sys
from pathlib import Path
out = sys.argv[1]
hit, miss, gen = (float(x) for x in sys.argv[2:5])
PRO = 4.4   # pro sits 4.4x above flash in every category, as in the real card


def money(v: float) -> str:
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    return s or "0"


rows = [("1M INPUT TOKENS<br>(CACHE HIT)", hit),
        ("1M INPUT TOKENS<br>(CACHE MISS)", miss),
        ("1M OUTPUT TOKENS", gen)]
body = ['<tr><td colspan="3">CONTEXT LENGTH</td><td colspan="2">1M</td></tr>']
for i, (label, off) in enumerate(rows):
    lead = '<td rowspan="6">PRICING<sup>(2)</sup></td>' if i == 0 else ""
    body.append(f'<tr>{lead}<td rowspan="2">{label}</td><td>OFF-PEAK</td>'
                f'<td>${money(off)}</td><td>${money(off * PRO)}</td></tr>')
    body.append(f'<tr><td>PEAK</td><td>${money(2 * off)}</td>'
                f'<td>${money(2 * off * PRO)}</td></tr>')
Path(out).write_text("\n".join(body) + """
<p>(2) Off-peak rates are half of the peak rates. Peak hours are 01:00 - 04:00 and
06:00 - 10:00 UTC, Monday through Friday, excluding Chinese public holidays. All
other hours are off-peak, including weekends and Chinese public holidays in full.</p>
""", encoding="utf-8")
PY
}
write_docs "$FIX/docs.html" 0.003 0.15 0.60          # matches the official card
write_docs "$FIX/docs-changed.html" 0.004 0.20 0.80  # vendor raised prices

cat > "$FIX/holiday2026.json" <<'JSON'
{ "$schema": "x", "year": 2026, "days": [
  { "name": "元旦", "date": "2026-01-01", "isOffDay": true },
  { "name": "春节", "date": "2026-02-17", "isOffDay": true },
  { "name": "调休", "date": "2026-02-28", "isOffDay": false }
] }
JSON
cat > "$FIX/holiday-empty.json" <<'JSON'
{ "year": 2026, "days": [] }
JSON

mkconfig() {
  cat > "$1" <<'JSON'
{
  "display": true,
  "currency": { "code": "CNY", "usd_rate": 7.0 },
  "pricing": {
    "updated_at": "2020-01-01T00:00:00Z",
    "watch": ["glm-5.3-flash", "deepseek-flash"],
    "tier_mode": "off_peak",
    "models": {
      "hand-pinned": { "source": "user", "input_per_mtok": 1, "output_per_mtok": 2, "cache_read_per_mtok": 0.1 }
    }
  }
}
JSON
}

run_updater() { # $1=config  $2=docs file  $3=holiday file
  # OFFLINE=1 keeps the suite deterministic: only the injected files are used
  PET_CONFIG="$1" \
  PET_PRICING_OFFLINE=1 \
  PET_PRICING_CATALOG_FILE="$FIX/catalog.json" \
  PET_PRICING_DOCS_FILE="$2" \
  PET_PRICING_HOLIDAY_FILE="$3" \
    bash "$UPDATER" --force 2>&1
}
q() { jq -r "$2" "$1" 2>/dev/null || echo "<jq-error>"; }

echo "── update-model-pricing.sh ──"

# 1. happy path: official card wins, tier schedule + holidays land, settings intact
CFG="$WORK/1.json"; mkconfig "$CFG"
out="$(run_updater "$CFG" "$FIX/docs.html" "$FIX/holiday2026.json")"
check "uses the scraped official card" "$(q "$CFG" '.pricing.models["deepseek-flash"].source')" "deepseek-docs"
check "flash cache-hit = official"     "$(q "$CFG" '.pricing.models["deepseek-flash"].off_peak.cache_read_per_mtok')" "0.003"
check "flash cache-miss = official"    "$(q "$CFG" '.pricing.models["deepseek-flash"].off_peak.input_per_mtok')" "0.15"
check "flash output = official"        "$(q "$CFG" '.pricing.models["deepseek-flash"].off_peak.output_per_mtok')" "0.6"
check "peak is 2x off-peak"            "$(q "$CFG" '.pricing.models["deepseek-flash"].peak.output_per_mtok')" "1.2"
check "flags the openrouter mismatch"  "$(q "$CFG" '.pricing.models["deepseek-flash"].price_mismatch')" "true"
check "openrouter price kept for audit" "$(q "$CFG" '.pricing.models["deepseek-flash"].openrouter_per_mtok.cache_read_per_mtok')" "0.000696"
check "flat model still priced by openrouter" "$(q "$CFG" '.pricing.models["glm-5.3-flash"].source')" "openrouter"
check "writes the peak windows"        "$(q "$CFG" '.pricing.peak_windows | length')" "2"
check "writes the peak days"           "$(q "$CFG" '.pricing.peak_days | length')" "5"
check "context length from the page"   "$(q "$CFG" '.pricing.models["deepseek-flash"].context_tokens')" "1000000"
check "context length from the catalog" "$(q "$CFG" '.pricing.models["glm-5.3-flash"].context_tokens')" "131072"
check "parses holiday off-days"        "$(q "$CFG" '.pricing.off_peak_dates | length')" "2"
check "keeps the user's tier_mode"     "$(q "$CFG" '.pricing.tier_mode')" "off_peak"
check "never overwrites a user pin"    "$(q "$CFG" '.pricing.models["hand-pinned"].input_per_mtok')" "1"
check "keeps unrelated settings"       "$(q "$CFG" '.currency.code')" "CNY"

# 2. vendor raises prices: the page wins over the built-in card
CFG="$WORK/2.json"; mkconfig "$CFG"
run_updater "$CFG" "$FIX/docs-changed.html" "$FIX/holiday2026.json" >/dev/null
check "follows a price change on the page" "$(q "$CFG" '.pricing.models["deepseek-flash"].off_peak.input_per_mtok')" "0.2"

# 3. page unrecognisable: fall back to the built-in card, still write good prices
CFG="$WORK/3.json"; mkconfig "$CFG"
printf '<html><body>We redesigned the docs!</body></html>' > "$FIX/docs-broken.html"
out="$(run_updater "$CFG" "$FIX/docs-broken.html" "$FIX/holiday2026.json")"
check "broken page falls back to built-in" "$(q "$CFG" '.pricing.models["deepseek-flash"].source')" "deepseek-builtin"
check "built-in card is still the official price" "$(q "$CFG" '.pricing.models["deepseek-flash"].off_peak.cache_read_per_mtok')" "0.003"
case "$out" in *"built-in card"*) ok "says why it fell back" ;; *) bad "says why it fell back" "$out" ;; esac

# 4. holiday file present but unpublished: keep the dates we already had
CFG="$WORK/4.json"; mkconfig "$CFG"
run_updater "$CFG" "$FIX/docs.html" "$FIX/holiday2026.json" >/dev/null
before="$(q "$CFG" '.pricing.off_peak_dates | length')"
run_updater "$CFG" "$FIX/docs.html" "$FIX/holiday-empty.json" >/dev/null
check "unpublished holiday year keeps prior dates" "$(q "$CFG" '.pricing.off_peak_dates | length')" "$before"

# 5. nothing reachable: do not touch the file at all
CFG="$WORK/5.json"; mkconfig "$CFG"
run_updater "$CFG" "$FIX/docs.html" "$FIX/holiday2026.json" >/dev/null
before="$(cat "$CFG")"
out="$(PET_CONFIG="$CFG" \
  PET_PRICING_OFFLINE=1 \
  PET_PRICING_CATALOG_FILE="$WORK/nope-catalog.json" \
  PET_PRICING_DOCS_FILE="$WORK/nope-docs.html" \
  PET_PRICING_HOLIDAY_FILE="$WORK/nope-holiday.json" \
  bash "$UPDATER" --force 2>&1)"
check "offline leaves the config byte-identical" "$(cat "$CFG")" "$before"
case "$out" in *"no pricing source reachable"*) ok "offline says so" ;; *) bad "offline says so" "$out" ;; esac

# 6. swapped columns must be rejected rather than trusted
CFG="$WORK/6.json"; mkconfig "$CFG"
python3 - "$FIX/docs-swapped.html" <<'PY'
import sys
from pathlib import Path
# flash dearer than pro in every row = the parser picked the wrong column
Path(sys.argv[1]).write_text('''<tr><td rowspan="6">PRICING</td><td rowspan="2">1M INPUT TOKENS<br>(CACHE HIT)</td><td>OFF-PEAK</td><td>$0.022</td><td>$0.003</td></tr>
<tr><td>PEAK</td><td>$0.044</td><td>$0.006</td></tr>
<tr><td rowspan="2">1M INPUT TOKENS<br>(CACHE MISS)</td><td>OFF-PEAK</td><td>$0.66</td><td>$0.15</td></tr>
<tr><td>PEAK</td><td>$1.32</td><td>$0.30</td></tr>
<tr><td rowspan="2">1M OUTPUT TOKENS</td><td>OFF-PEAK</td><td>$1.98</td><td>$0.60</td></tr>
<tr><td>PEAK</td><td>$3.96</td><td>$1.20</td></tr>
<p>Peak hours are 01:00 - 04:00 and 06:00 - 10:00 UTC, Monday through Friday.</p>''', encoding="utf-8")
PY
run_updater "$CFG" "$FIX/docs-swapped.html" "$FIX/holiday2026.json" >/dev/null
check "swapped columns rejected" "$(q "$CFG" '.pricing.models["deepseek-flash"].source')" "deepseek-builtin"
check "rejected page did not corrupt prices" "$(q "$CFG" '.pricing.models["deepseek-flash"].off_peak.input_per_mtok')" "0.15"

# ── python detection ─────────────────────────────────────────────────────────
# On Windows the Microsoft Store stub answers `command -v`, prints "Python was
# not found" and exits 0. The updater used to bail on that check alone, so it
# exited 0 having done nothing — invisible, because a background updater that
# does nothing looks exactly like one with nothing to update.
# Both updaters share the probe, so both are checked.
STUB="$WORK/stub"; CORE="$WORK/core"
mkdir -p "$STUB" "$CORE"
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store"\nexit 0\n' \
  > "$STUB/python3"
cp "$STUB/python3" "$STUB/python"
chmod +x "$STUB/python3" "$STUB/python"
# Only the utilities the probe itself needs — no python anywhere.
for u in bash which sed grep cat; do
  p=$(command -v "$u" 2>/dev/null) || continue
  [[ "$p" == /* && -f "$p" ]] && cp "$p" "$CORE/" 2>/dev/null
done

probe_of() { # $1 = script → prints the resolved interpreter, or "rejected"
  env -i PATH="$1" bash -c '
    source <(sed -n "/^have_python()/,/^}/p" "'"$2"'")
    have_python || echo rejected
  '
}
for script in "$UPDATER" "$ROOT/scripts/update-fx-rate.sh"; do
  name=$(basename "$script")
  check "$name: the Store stub is rejected" \
    "$(probe_of "$STUB:$CORE" "$script")" "rejected"
  check "$name: a real python behind the stub is still found" \
    "$(probe_of "$STUB:$CORE:/usr/bin" "$script")" "/usr/bin/python3"
done

echo
if (( FAIL > 0 )); then
  printf '  %d passed, %d FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '  %d passed\n' "$PASS"
