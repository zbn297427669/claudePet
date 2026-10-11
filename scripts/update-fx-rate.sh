#!/usr/bin/env bash
# update-fx-rate.sh — refresh USD→local rate in ~/.claude/claude-pet/config.json
#
# Usage:
#   ./update-fx-rate.sh           # update if older than TTL (default 24h)
#   ./update-fx-rate.sh --force   # always fetch
#
# Env:
#   PET_FX_TTL_HOURS   cache TTL hours (default 24)
#   PET_FX_TIMEOUT     curl timeout seconds (default 3)
#   PET_CONFIG         override config path
#
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

CONFIG="${PET_CONFIG:-$HOME/.claude/claude-pet/config.json}"
TTL_HOURS="${PET_FX_TTL_HOURS:-24}"
TIMEOUT="${PET_FX_TIMEOUT:-3}"

command -v curl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[[ -f "$CONFIG" ]] || exit 0

CODE=$(jq -r '.currency.code // "USD"' "$CONFIG" 2>/dev/null || echo USD)
CODE=$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]')
case "$CODE" in
  USD|"") exit 0 ;;
  RMB) CODE=CNY ;;
  *) ;;
esac

needs_update() {
  [[ "$FORCE" == "1" ]] && return 0
  local updated
  updated=$(jq -r '.currency.updated_at // empty' "$CONFIG" 2>/dev/null || true)
  [[ -z "$updated" ]] && return 0
  python3 - "$updated" "$TTL_HOURS" <<'PY'
import sys, datetime as dt
raw, hours = sys.argv[1], float(sys.argv[2])
try:
    then = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if then.tzinfo is None:
        then = then.replace(tzinfo=dt.timezone.utc)
    now = dt.datetime.now(dt.timezone.utc)
    age_h = (now - then.astimezone(dt.timezone.utc)).total_seconds() / 3600.0
    raise SystemExit(0 if age_h >= hours else 1)
except SystemExit:
    raise
except Exception:
    raise SystemExit(0)
PY
}

needs_update || exit 0

CODE_LC=$(printf '%s' "$CODE" | tr '[:upper:]' '[:lower:]')
RATE=""

RATE=$(curl -fsS -m "$TIMEOUT" \
  "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json" \
  2>/dev/null | jq -r --arg c "$CODE_LC" '.usd[$c] // empty' || true)

if [[ -z "$RATE" ]]; then
  RATE=$(curl -fsS -m "$TIMEOUT" \
    "https://open.er-api.com/v6/latest/USD" \
    2>/dev/null | jq -r --arg c "$CODE" '.rates[$c] // empty' || true)
fi

if [[ -z "$RATE" ]]; then
  RATE=$(curl -fsS -m "$TIMEOUT" \
    "https://api.exchangerate-api.com/v4/latest/USD" \
    2>/dev/null | jq -r --arg c "$CODE" '.rates[$c] // empty' || true)
fi

[[ -n "$RATE" ]] || exit 0
awk -v r="$RATE" 'BEGIN{exit !(r+0 > 0 && r+0 < 1000)}' || exit 0

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp)
jq --argjson rate "$RATE" --arg now "$NOW" --arg code "$CODE" '
  .currency = (.currency // {})
  | .currency.code = $code
  | .currency.usd_rate = $rate
  | .currency.updated_at = $now
  | if (.currency.symbol == null or .currency.symbol == "") then
      .currency.symbol = (if $code == "CNY" then "¥" else $code end)
    else . end
' "$CONFIG" >"$TMP" && mv "$TMP" "$CONFIG"

echo "FX updated: 1 USD = $RATE $CODE" >&2
