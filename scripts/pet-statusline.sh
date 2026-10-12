#!/bin/bash
# pet-statusline.sh — Pet Buddy status line for Claude Code
# This script is meant to be sourced/called from a main statusline script,
# or used standalone as the statusline command.
#
# Standalone usage (in ~/.claude/settings.json):
#   "statusLine": { "type": "command", "command": "/path/to/pet-statusline.sh" }
#
# It reads JSON from stdin (Claude Code status line protocol) and outputs
# a status bar with the pet creature displayed above it.

input=$(cat)

PET_DIR="$HOME/.claude/claude-pet"
PET_CONFIG="$PET_DIR/config.json"

# Refresh FX / model pricing in background if cache stale (non-blocking)
FX_UPDATER="${PET_FX_UPDATE_SCRIPT:-$HOME/.claude/claude-pet/update-fx-rate.sh}"
if [[ "${PET_FX_UPDATE:-1}" != "0" && -x "$FX_UPDATER" ]]; then
  "$FX_UPDATER" >/dev/null 2>&1 &
fi
PRICE_UPDATER="${PET_PRICING_UPDATE_SCRIPT:-$HOME/.claude/claude-pet/update-model-pricing.sh}"
if [[ "${PET_PRICING_UPDATE:-1}" != "0" && -x "$PRICE_UPDATER" ]]; then
  "$PRICE_UPDATER" >/dev/null 2>&1 &
fi

# ── Parse JSON ───────────────────────────────────────────────────────────────
# Claude Code statusline protocol: https://code.claude.com/docs/en/statusline
# One jq call for all fields: the status line re-runs constantly and each jq is
# a process. Fields are joined with \x1f, not @tsv — IFS treats tab as a
# whitespace char, so it would collapse an empty field (model.id usually is
# one) and shift every value after it.
parse_status() {
  jq -r '
    def n(x): (x // 0) | if type == "number" then . else 0 end;
    def i(x): n(x) | floor;
    . as $in
    | ($in.context_window.current_usage) as $cu
    | [
        ($in.model.display_name // "Claude"),
        ($in.model.id // ""),
        ($in.session_id // $in.sessionId // ""),
        ($in.workspace.current_dir // $in.cwd // ""),
        i($in.context_window.used_percentage),
        i($in.context_window.context_window_size),
        # Prefer live current_usage (input+cache); fallback to total_input_tokens
        (if $cu != null then
           i($cu.input_tokens) + i($cu.cache_creation_input_tokens) + i($cu.cache_read_input_tokens)
         else i($in.context_window.total_input_tokens) end),
        i($cu.cache_read_input_tokens),
        i($in.context_window.total_output_tokens // $cu.output_tokens),
        i($cu.input_tokens),
        i($cu.cache_creation_input_tokens),
        i($cu.cache_read_input_tokens),
        i($cu.output_tokens),
        n($in.cost.total_cost_usd),
        i($in.cost.total_duration_ms),
        i($in.cost.total_lines_added),
        i($in.cost.total_lines_removed)
      ]
    | map(tostring) | join("\u001f")
  '
}

PARSE=$(parse_status <<< "$input")
# Malformed input: re-parse an empty object so every field still gets a sane default
[[ -n "$PARSE" ]] || PARSE=$(parse_status <<< '{}')

IFS=$'\x1f' read -r \
  MODEL MODEL_ID SESSION_ID DIR PCT CTX_SIZE CTX_USED CACHE_READ OUT_TOK \
  USAGE_IN USAGE_CC USAGE_CR USAGE_OUT COST DUR_MS LINES_ADD LINES_DEL \
  <<< "$PARSE"

# Optional local $/MTok estimate (auto-updated); may undercount — see README
COST_STATE="$PET_DIR/cost-state.json"
COST_TIER=""   # set to peak/off_peak when the model carries a peak/off-peak card
if [[ "${PET_PRICING_COST:-1}" != "0" && -f "$PET_CONFIG" ]] && command -v python3 >/dev/null 2>&1; then
  COST_CUSTOM=$(
    PET_COST_STATE="$COST_STATE" python3 - "$PET_CONFIG" \
      "${MODEL_ID:-}" "${MODEL:-}" "${SESSION_ID:-}" \
      "${USAGE_IN:-0}" "${USAGE_CC:-0}" "${USAGE_CR:-0}" "${USAGE_OUT:-0}" \
      "${COST:-0}" <<'PY'
import json, os, re, sys
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

cfg_path, model_id, model_name, session_id, u_in, u_cc, u_cr, u_out, fallback = sys.argv[1:10]
state_path = Path(os.environ.get("PET_COST_STATE") or Path.home() / ".claude/claude-pet/cost-state.json")

# Fallback schedule if the config carries no schedule (peak windows are UTC)
DEFAULT_PEAK_WINDOWS = [["01:00", "04:00"], ["06:00", "10:00"]]
# Sessions kept in cost-state.json; older ones are dropped as new ones appear
MAX_SESSIONS = 20

def norm(s: str) -> str:
    s = (s or "").lower().strip().split("/")[-1].lstrip("~").split(":")[0]
    return re.sub(r"[^a-z0-9]+", "", s)

try:
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
except Exception:
    print(fallback); raise SystemExit(0)

pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
models = pricing.get("models") if isinstance(pricing.get("models"), dict) else {}
if not models:
    print(fallback); raise SystemExit(0)

candidates = []
for raw in (model_id, model_name):
    if not raw:
        continue
    leaf = raw.split("/")[-1].lstrip("~").split(":")[0]
    candidates.append(leaf)
    candidates.append(norm(leaf))

price = None
# exact key first
for c in candidates:
    if c in models:
        price = models[c]; break
if price is None:
    cn = [norm(c) for c in candidates if c]
    best = None
    for key, info in models.items():
        kn = norm(key)
        for c in cn:
            if not c or not kn:
                continue
            sc = -1
            if c == kn: sc = 100
            elif c in kn or kn in c: sc = 80 - abs(len(c) - len(kn))
            if sc >= 0 and (best is None or sc > best[0]):
                best = (sc, info)
        matched = (info or {}).get("matched") or ""
        mn = norm(matched)
        for c in cn:
            if c and mn and (c == mn or c in mn or mn in c):
                sc = 70 - abs(len(c) - len(mn))
                if best is None or sc > best[0]:
                    best = (sc, info)
    if best:
        price = best[1]

if not isinstance(price, dict):
    print(fallback); raise SystemExit(0)

# The model's context window, when the config knows it. Claude Code reports 200k
# for models it does not recognise as extended-context, which is wrong for a
# gateway alias; the shell uses this to size the bar. Emitted here so the model
# only has to be matched once.
ctx_tokens = price.get("context_tokens")
try:
    ctx_tokens = int(ctx_tokens) if ctx_tokens else 0
except (TypeError, ValueError):
    ctx_tokens = 0


# ── peak / off-peak tier ────────────────────────────────────────────────────
# DeepSeek bills peak hours (UTC, Mon-Fri 01:00-04:00 and 06:00-10:00) at double
# the off-peak rate; every other hour, including weekends and Chinese public
# holidays, is off-peak. Only entries carrying a peak/off_peak card take part.
def utc_now():
    override = os.environ.get("PET_NOW_UTC")
    if override:                     # test hook: pin the clock
        try:
            return datetime.fromisoformat(override.replace("Z", "+00:00")).astimezone(timezone.utc)
        except Exception:
            pass
    return datetime.now(timezone.utc)


def pick_tier(now):
    """'peak' or 'off_peak' for this moment, in UTC.

    isoweekday() is deliberate: Monday is 1, matching peak_days as written.
    The peak windows run 01:00-10:00 UTC = 09:00-18:00 Beijing, so for the
    moments this decision is about, a Chinese holiday date and its UTC date
    always fall on the same day.
    """
    mode = pricing.get("tier_mode")
    if mode in ("peak", "off_peak"):
        return mode
    days = pricing.get("peak_days") or [1, 2, 3, 4, 5]
    if now.isoweekday() not in days:
        return "off_peak"
    if now.date().isoformat() in set(pricing.get("off_peak_dates") or []):
        return "off_peak"
    hhmm = now.strftime("%H:%M")
    for window in pricing.get("peak_windows") or DEFAULT_PEAK_WINDOWS:
        try:
            start, end = window
        except (TypeError, ValueError):
            continue
        if start <= hhmm < end:
            return "peak"
    return "off_peak"


tier = None
if isinstance(price.get("peak"), dict) or isinstance(price.get("off_peak"), dict):
    tier = pick_tier(utc_now())
    chosen = price.get(tier)
    if not isinstance(chosen, dict):
        # a hand-written card with only one tier: use the other rather than nothing
        chosen = price.get("peak" if tier == "off_peak" else "off_peak")
    rates = chosen if isinstance(chosen, dict) else {}
else:
    rates = price      # flat catalogue price, no tiers


def next_switch(now):
    """(seconds, direction) until the next tariff change, for the countdown.

    Peak runs 01:00-04:00 and 06:00-10:00 UTC on configured peak days, so the
    next change is either the end of the window we are in, or the start of the
    next one within the coming week (holidays and weekends are skipped).
    """
    days = pricing.get("peak_days") or [1, 2, 3, 4, 5]
    windows = pricing.get("peak_windows") or DEFAULT_PEAK_WINDOWS
    holidays = set(pricing.get("off_peak_dates") or [])

    def peak_day(d):
        return d.isoweekday() in days and d.isoformat() not in holidays

    def at(d, hhmm):
        return datetime.combine(d, time(int(hhmm[:2]), int(hhmm[3:5])), tzinfo=timezone.utc)

    if peak_day(now.date()):
        for start, end in windows:
            if start <= now.strftime("%H:%M") < end:
                return max(0, int((at(now.date(), end) - now).total_seconds())), "to_off_peak"
    for offset in range(8):
        day = (now + timedelta(days=offset)).date()
        if not peak_day(day):
            continue
        for start, _ in windows:
            target = at(day, start)
            if target > now:
                return int((target - now).total_seconds()), "to_peak"
    return 0, ""


try:
    in_r = float(rates.get("input_per_mtok") or 0)
    out_r = float(rates.get("output_per_mtok") or 0)
    cr_r = float(rates.get("cache_read_per_mtok") or 0)
    tin = float(u_in or 0); tcc = float(u_cc or 0); tcr = float(u_cr or 0); tout = float(u_out or 0)
except Exception:
    print(fallback); raise SystemExit(0)

# last-request USD estimate
delta = (tin * in_r + tcc * in_r + tcr * cr_r + tout * out_r) / 1e6
fp = f"{int(tin)}|{int(tcc)}|{int(tcr)}|{int(tout)}"

# What this request would have cost off-peak: the difference is the peak premium
premium_delta = 0.0
if tier == "peak" and isinstance(price.get("off_peak"), dict):
    try:
        off = price["off_peak"]
        o_in = float(off.get("input_per_mtok") or 0)
        o_out = float(off.get("output_per_mtok") or 0)
        o_cr = float(off.get("cache_read_per_mtok") or 0)
        off_cost = (tin * o_in + tcc * o_in + tcr * o_cr + tout * o_out) / 1e6
        premium_delta = max(0.0, delta - off_cost)
    except (TypeError, ValueError):
        premium_delta = 0.0

try:
    st = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
except Exception:
    st = {}
if not isinstance(st, dict):
    st = {}

# Accumulate per session. A single slot keyed by session id meant any id change
# — resuming, or another session rendering at the same time — threw the running
# total away and the status line appeared to reset.
sid = session_id or "default"
sessions = st.get("sessions") if isinstance(st.get("sessions"), dict) else {}
if not sessions and st.get("session_id"):        # migrate the old single-slot shape
    sessions = {st["session_id"]: {"total_usd": st.get("total_usd") or 0.0,
                                   "last_fp": st.get("last_fp") or "",
                                   "model": st.get("model") or ""}}
entry = sessions.get(sid)
if not isinstance(entry, dict):
    entry = {"total_usd": 0.0, "last_fp": ""}

total = float(entry.get("total_usd") or 0.0)
last_fp = entry.get("last_fp") or ""
if fp != "0|0|0|0" and fp != last_fp:
    total += delta
    entry.update({
        "total_usd": total,
        "last_fp": fp,
        "model": model_id or model_name,
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    if premium_delta:
        entry["premium_usd"] = float(entry.get("premium_usd") or 0.0) + premium_delta
    sessions[sid] = entry
    if len(sessions) > MAX_SESSIONS:               # keep the map from growing forever
        for stale in sorted(sessions, key=lambda k: sessions[k].get("updated_at") or "")[:-MAX_SESSIONS]:
            sessions.pop(stale, None)
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"sessions": sessions}, ensure_ascii=False, indent=2) + "\n",
                       encoding="utf-8")
        tmp.replace(state_path)
    except Exception:
        pass

# If we have no accumulated usage yet, fall back to Claude's number.
# Fields: <usd>|<peak|off_peak|>|<context tokens>|<secs to switch>|<direction>|<premium usd>
# The last four describe the tariff, so they are emitted even when the cost had
# to fall back — the shell decides how loudly to say it.
switch_secs, switch_dir = next_switch(utc_now()) if tier else (0, "")
premium = float(entry.get("premium_usd") or 0.0)
print("|".join([
    f"{total:.8f}" if total > 0 else fallback,
    tier or "",
    str(ctx_tokens or ""),
    str(switch_secs or ""),
    switch_dir or "",
    f"{premium:.6f}" if premium else "",
]))
PY
  )
  if [[ -n "$COST_CUSTOM" ]]; then
    # <usd>|<tier>|<context tokens>|<secs to switch>|<direction>|<premium usd>
    # a bare number means none of it was available
    IFS='|' read -r COST COST_TIER COST_WINDOW COST_SECS COST_DIR COST_PREMIUM <<< "$COST_CUSTOM"
  fi
fi

# Durations for the peak countdown: 1h52m, 15m, <1m
fmt_dur() {
  local s="${1:-0}"
  if (( s >= 3600 )); then
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  elif (( s >= 60 )); then
    printf '%dm' $((s / 60))
  else
    printf '<1m'
  fi
}

# 15500 -> 15.5k, 200000 -> 200.0k, 1000000 -> 1.0M. Pure bash: awk here would be
# a fork per call, four per render. Rounds to one decimal like printf %.1f did.
fmt_tokens() {
  local n=${1:-0} r
  (( n < 0 )) && n=0
  if (( n >= 1000000 )); then
    r=$(( (n + 50000) / 100000 * 100000 ))
    printf '%d.%dM' $(( r / 1000000 )) $(( (r % 1000000) / 100000 ))
  elif (( n >= 1000 )); then
    r=$(( (n + 50) / 100 * 100 ))
    printf '%d.%dk' $(( r / 1000 )) $(( (r % 1000) / 100 ))
  else
    printf '%d' "$n"
  fi
  return 0
}

# ── Dir + git branch (one git call) ──────────────────────────────────────────
# In a repo:  repo root name + subpath            →  claudePet/src/engine
# Otherwise:  last two segments, elision marked   →  ~/…/claude/claudePet
# --show-toplevel goes first: on an unborn branch --abbrev-ref fails (exit 128)
# and aborts the remaining args, which would drop the repo root too.
GIT_DIR="$DIR"
REPO_ROOT=""
BRANCH=""
while IFS= read -r line; do
  if [[ "$line" == /* ]]; then REPO_ROOT="$line"   # toplevel is always absolute
  elif [[ -n "$line" ]]; then BRANCH="$line"; fi
done < <(git -C "$GIT_DIR" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
# Unborn branch (fresh `git init`) reports "HEAD" — resolve the real name
if [[ "$BRANCH" == "HEAD" ]]; then
  BRANCH=$(git -C "$GIT_DIR" symbolic-ref --short HEAD 2>/dev/null) || BRANCH="HEAD"
fi

fmt_dir() {
  local dir="$1" root="$2" rel shown prefix slashes parent leaf
  if [[ -n "$root" ]] && [[ "$dir" == "$root" || "$dir" == "$root"/* ]]; then
    rel="${dir#"$root"}"
    printf '%s%s' "${root##*/}" "$rel"
    return 0
  fi
  # Outside a repo: "~" keeps it readable, "/" keeps it absolute
  if [[ "$dir" == "$HOME" || "$dir" == "$HOME"/* ]]; then
    prefix="~"; shown="${dir#"$HOME"}"
  else
    prefix=""; shown="$dir"
  fi
  # Pure bash (no tr/wc/awk forks): strip every non-slash to count the depth
  slashes="${shown//[!\/]/}"
  if (( ${#slashes} > 2 )); then
    parent="${shown%/*}"; parent="${parent##*/}"
    leaf="${shown##*/}"
    printf '%s/…/%s/%s' "$prefix" "$parent" "$leaf"
  else
    printf '%s%s' "$prefix" "$shown"
  fi
}
DIR_DISPLAY=$(fmt_dir "$GIT_DIR" "$REPO_ROOT")

# ── Cost / duration / lines ──────────────────────────────────────────────────
# Currency: Claude reports USD. Optional FX via env or ~/.claude/claude-pet/config.json:
#   env:  PET_COST_CURRENCY=CNY  PET_USD_RATE=7.2  PET_COST_SHOW_USD=1
#   json: "currency": { "code":"CNY", "symbol":"¥", "usd_rate":7.2, "show_usd":false }
# One read for the whole file: this used to be four jq calls, and the background
# FX updater can rewrite config.json mid-render — a single read is also a
# consistent snapshot. The display toggle comes from the same read.
CFG_DISPLAY="true"; CFG_CODE=""; CFG_RATE=""; CFG_SHOW_USD=""; CFG_SYMBOL=""; CFG_SHOW_TIER=""
CFG_CTX_WINDOW=""; CFG_PK_ENABLED=""; CFG_PK_COUNTDOWN=""; CFG_PK_PREWARN=""; CFG_PK_THRESHOLD=""; CFG_PK_PREMIUM=""
CFG_INFO_SHOW=""; CFG_INFO_HIDE=""
if [[ -f "$PET_CONFIG" ]]; then
  IFS=$'\x1f' read -r CFG_DISPLAY CFG_CODE CFG_RATE CFG_SHOW_USD CFG_SYMBOL CFG_SHOW_TIER CFG_CTX_WINDOW \
    CFG_PK_ENABLED CFG_PK_COUNTDOWN CFG_PK_PREWARN CFG_PK_THRESHOLD CFG_PK_PREMIUM \
    CFG_INFO_SHOW CFG_INFO_HIDE \
    <<< "$(jq -r '[
      (if .display == false then "false" else "true" end),
      (.currency.code // ""),
      (.currency.usd_rate // ""),
      (if .currency.show_usd == true then "1" else "" end),
      (.currency.symbol // ""),
      (if .currency.show_tier == false then "0" else "" end),
      (.context_window_tokens // ""),
      (if .peak_alert.enabled == false then "0" else "1" end),
      (if .peak_alert.countdown == false then "0" else "1" end),
      (.peak_alert.pre_warn_minutes // ""),
      (.peak_alert.cost_threshold // ""),
      (if .peak_alert.show_premium == false then "0" else "1" end),
      (if .info.show == false then "0" else "1" end),
      ((.info.hide // []) | map(select(type == "string")) | join(","))
    ] | map(tostring) | join("\u001f")' "$PET_CONFIG" 2>/dev/null)"
fi
PET_DISPLAY="${CFG_DISPLAY:-true}"
SHOW_TIER="${PET_COST_TIER_LABEL:-${CFG_SHOW_TIER:-1}}"

# ── Which information segments to draw ───────────────────────────────────────
# info.show is the master switch for the whole metrics bar; info.hide drops
# individual segments while it is on. `model` is deliberately not hideable — it
# is the line's identity, so the bar cannot end up blank by accident. To hide
# everything, use info.show: false. Side effect worth knowing: the cost estimate
# keeps running while the bar is hidden, so switching it back on shows a correct
# running total instead of a fresh zero.
INFO_SHOW="${PET_INFO_SHOW:-${CFG_INFO_SHOW:-1}}"
INFO_HIDE=",${PET_INFO_HIDE:-${CFG_INFO_HIDE:-}},"

seg_on() { # $1 = segment name
  [[ "$INFO_SHOW" != "0" ]] || return 1
  [[ "$1" == "model" ]] && return 0
  [[ "$INFO_HIDE" == *",$1,"* ]] && return 1
  return 0
}
# Peak-tariff alert settings (see README). Re-read every render, so editing
# config.json takes effect on the next one — thresholds included.
PK_ENABLED="${PET_PEAK_ALERT:-${CFG_PK_ENABLED:-1}}"
PK_COUNTDOWN="${PET_PEAK_COUNTDOWN:-${CFG_PK_COUNTDOWN:-1}}"
PK_PRE_WARN="${PET_PEAK_PRE_WARN_MINUTES:-${CFG_PK_PREWARN:-15}}"
PK_THRESHOLD="${PET_PEAK_COST_THRESHOLD:-${CFG_PK_THRESHOLD:-1}}"
PK_PREMIUM="${PET_PEAK_PREMIUM:-${CFG_PK_PREMIUM:-1}}"
[[ "$PK_PRE_WARN" =~ ^[0-9]+$ ]] || PK_PRE_WARN=15
[[ "$PK_THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || PK_THRESHOLD=1
COST_CURRENCY="${PET_COST_CURRENCY:-$CFG_CODE}"
USD_RATE="${PET_USD_RATE:-$CFG_RATE}"
COST_SHOW_USD="${PET_COST_SHOW_USD:-$CFG_SHOW_USD}"
COST_SYMBOL="$CFG_SYMBOL"
COST_CURRENCY="${COST_CURRENCY:-USD}"
USD_RATE="${USD_RATE:-1}"
COST_SHOW_USD="${COST_SHOW_USD:-0}"
case "$COST_CURRENCY" in
  CNY|RMB|cny|rmb) COST_SYMBOL="${COST_SYMBOL:-¥}"; COST_CURRENCY="CNY" ;;
  USD|usd|"") COST_SYMBOL="${COST_SYMBOL:-\$}"; COST_CURRENCY="USD"; USD_RATE=1 ;;
  *) COST_SYMBOL="${COST_SYMBOL:-$COST_CURRENCY }" ;;
esac
if [[ "$COST_CURRENCY" = "USD" ]] || [[ "$USD_RATE" = "1" ]] || [[ -z "$USD_RATE" ]]; then
  COST_FMT=$(printf '%s%.4f' "$COST_SYMBOL" "$COST")
else
  COST_LOCAL=$(awk -v c="$COST" -v r="$USD_RATE" 'BEGIN{printf "%.4f", c*r}')
  if [[ "$COST_SHOW_USD" = "1" ]]; then
    COST_FMT=$(printf '%s%s (~$%.4f)' "$COST_SYMBOL" "$COST_LOCAL" "$COST")
  else
    COST_FMT=$(printf '%s%s' "$COST_SYMBOL" "$COST_LOCAL")
  fi
fi
# Which DeepSeek tariff the running total was priced at: 谷 / 峰. Past the cost
# threshold the peak warning moves to the front of the line instead (below), so
# this trailing marker stays quiet then rather than saying it twice.
PK_LOUD=0
if [[ "$PK_ENABLED" != "0" && "$COST_TIER" = "peak" ]]; then
  COST_NUM=$(awk -v c="${COST:-0}" -v r="${USD_RATE:-1}" 'BEGIN{printf "%.6f", c*r}')
  awk -v c="$COST_NUM" -v t="$PK_THRESHOLD" 'BEGIN{exit !(c >= t)}' && PK_LOUD=1
fi
if [[ -n "$COST_TIER" && "$SHOW_TIER" != "0" && "$PK_LOUD" = "0" ]]; then
  case "$COST_TIER" in
    peak)     COST_FMT="${COST_FMT} 峰" ;;
    off_peak) COST_FMT="${COST_FMT} 谷" ;;
  esac
fi
DUR_S=$(( ${DUR_MS:-0} / 1000 ))
if [[ "$DUR_S" -ge 3600 ]]; then
  DUR_FMT=$(printf '%dh%02dm' $((DUR_S/3600)) $(((DUR_S%3600)/60)))
elif [[ "$DUR_S" -ge 60 ]]; then
  DUR_FMT=$(printf '%dm%02ds' $((DUR_S/60)) $((DUR_S%60)))
else
  DUR_FMT="${DUR_S}s"
fi
LINES_FMT="+${LINES_ADD}/-${LINES_DEL}"

# ── Context window size ──────────────────────────────────────────────────────
# Claude Code reports 200000 for models it does not recognise as extended-context,
# which understates a gateway model (deepseek-flash is 1M). Prefer an explicit
# config value, then the limit configured for this model, and only use it when it
# is larger than the payload's. When it wins, recompute the percentage with the
# documented input-only formula so bar, % and numbers stay consistent.
CTX_WINDOW="${CFG_CTX_WINDOW:-}"
[[ "$CTX_WINDOW" =~ ^[0-9]+$ ]] || CTX_WINDOW=""
if [[ -z "$CTX_WINDOW" && -n "${COST_WINDOW:-}" ]] && (( ${COST_WINDOW:-0} > ${CTX_SIZE:-0} )); then
  CTX_WINDOW="$COST_WINDOW"
fi
if (( ${CTX_WINDOW:-0} > 0 )); then
  CTX_SIZE="$CTX_WINDOW"
  PCT=$(( ${CTX_USED:-0} * 100 / CTX_WINDOW ))
fi

# ── Context bar (10 chars) + numeric usage ───────────────────────────────────
# ASCII #/- so terminals missing shade glyphs (▓/░) don't show �.
[[ -z "$PCT" ]] && PCT=0
BAR_W=10
FILLED=$((PCT * BAR_W / 100))
(( FILLED > BAR_W )) && FILLED=$BAR_W
EMPTY=$((BAR_W - FILLED))
# printf -v + parameter expansion: no fork per segment (was two `tr` pipelines)
printf -v BAR '%*s' "$FILLED" ''
printf -v BAR_PAD '%*s' "$EMPTY" ''
BAR="[${BAR// /#}${BAR_PAD// /-}]"
USED_FMT=$(fmt_tokens "$CTX_USED")
SIZE_FMT=$(fmt_tokens "$CTX_SIZE")
CTX_NUM="${USED_FMT}/${SIZE_FMT}"
CACHE_FMT=$(fmt_tokens "$CACHE_READ")
OUT_FMT=$(fmt_tokens "$OUT_TOK")
# Cache hit rate = cache_read / (input + cache_write + cache_read)
# Show % first (intuition), then volume (scale):  cache 99% · 207k
CACHE_DENOM=$(( ${USAGE_IN:-0} + ${USAGE_CC:-0} + ${USAGE_CR:-0} ))
CACHE_SEG=""
if (( CACHE_DENOM > 0 )); then
  CACHE_HIT=$(( ${USAGE_CR:-0} * 100 / CACHE_DENOM ))
  (( CACHE_HIT > 100 )) && CACHE_HIT=100
  if [[ "${USAGE_CR:-0}" != "0" ]]; then
    CACHE_SEG="cache ${CACHE_HIT}% · ${CACHE_FMT}"
  else
    CACHE_SEG="cache 0%"
  fi
fi
BAR_CLR="\033[38;5;245m"

# ── ANSI palette ─────────────────────────────────────────────────────────────
RST="\033[0m"
GRAY="\033[38;5;245m"
DIM="\033[38;5;238m"
SEP="${DIM} │ ${RST}"

# ── Peak-tariff alert ────────────────────────────────────────────────────────
# Peak costs double, so say it where the eye lands first: the start of the line.
# Only past the cost threshold, or it would shout through the ~7h of every
# weekday that is peak. Pre-warning fires just before peak starts, which is the
# actionable half — it is the moment to decide whether to wait.
PK_PREFIX=""
AMBER="\033[1;38;5;214m"
if [[ "$PK_ENABLED" != "0" && "$INFO_SHOW" != "0" ]]; then
  if (( PK_LOUD )); then
    PK_PREFIX="${AMBER}⚡峰"
    if [[ "$PK_COUNTDOWN" != "0" ]] && (( ${COST_SECS:-0} > 0 )); then
      PK_PREFIX="${PK_PREFIX} $(fmt_dur "${COST_SECS:-0}")"
    fi
    if [[ "$PK_PREMIUM" != "0" && -n "${COST_PREMIUM:-}" ]] \
       && awk -v p="$COST_PREMIUM" 'BEGIN{exit !(p > 0.0001)}'; then
      PK_PREFIX="${PK_PREFIX} +$(printf '%s%.2f' "$COST_SYMBOL" \
        "$(awk -v p="$COST_PREMIUM" -v r="$USD_RATE" 'BEGIN{printf "%.2f", p*r}')")"
    fi
    PK_PREFIX="${PK_PREFIX}${RST}${SEP}"
  elif [[ "$COST_TIER" = "off_peak" && "$PK_PRE_WARN" -gt 0 && "${COST_DIR:-}" = "to_peak" ]] \
       && (( ${COST_SECS:-0} > 0 )) && (( ${COST_SECS:-0} <= PK_PRE_WARN * 60 )); then
    PK_PREFIX="${AMBER}⚡峰 $(fmt_dur "${COST_SECS:-0}") 后${RST}${SEP}"
  fi
fi

# ── Assemble status bar ──────────────────────────────────────────────────────
# Example:
#   ⬡ model │ claudePet │ [###-------] 21% 42.1k/200k │ cache 99% · 207k │ out 1.2k │ ¥0.01 │ 3m12s │ +12/-3
# Each segment is gated by seg_on, so info.hide can drop any of them but model.
L="$PK_PREFIX"
seg_on model    && L="${L}${GRAY}⬡ ${MODEL}${RST}"
seg_on dir      && L="${L}${SEP}${GRAY}${DIR_DISPLAY}${RST}"
seg_on branch   && [[ -n "$BRANCH" ]] && L="${L}${SEP}${GRAY}⎇ ${BRANCH}${RST}"
seg_on context  && L="${L}${SEP}${BAR_CLR}${BAR}${RST}${GRAY} ${PCT}% ${CTX_NUM}${RST}"
seg_on cache    && [[ -n "$CACHE_SEG" ]] && L="${L}${SEP}${GRAY}${CACHE_SEG}${RST}"
seg_on out      && [[ "${OUT_TOK:-0}" != "0" ]] && L="${L}${SEP}${GRAY}out ${OUT_FMT}${RST}"
seg_on cost     && L="${L}${SEP}${GRAY}${COST_FMT}${RST}"
seg_on duration && [[ "${DUR_MS:-0}" != "0" ]] && L="${L}${SEP}${GRAY}${DUR_FMT}${RST}"
if seg_on lines && { [[ "${LINES_ADD:-0}" != "0" ]] || [[ "${LINES_DEL:-0}" != "0" ]]; }; then
  L="${L}${SEP}${GRAY}${LINES_FMT}${RST}"
fi

# ── Pet Buddy (monstapix block art) ──────────────────────────────────────────
# PET_DISPLAY came from the config read above
PET_STATE="$PET_DIR/state.json"
PET_SPRITES="$PET_DIR/sprites.json"
PET_ACTIVITY="$PET_DIR/last-activity.json"
PET_CREATURES="$PET_DIR/creatures.json"

if [[ "$PET_DISPLAY" = "true" ]] && [[ -f "$PET_STATE" ]] && [[ -f "$PET_SPRITES" ]] && command -v jq &>/dev/null; then
  IFS=$'\x1f' read -r PET_STAGE_IDX PET_LINE_ID PET_XP \
    <<< "$(jq -r '[
      (.currentStageIndex // 0), (.currentLineId // "titan"), (.xp // 0)
    ] | map(tostring) | join("\u001f")' "$PET_STATE" 2>/dev/null)"

  # Name and next threshold in one pass over creatures.json, family-aware.
  # An unknown family (hand-edited state.json) falls back to the first line.
  # keys[0] must be evaluated against .evolutionLines, not the root — inside the
  # pipeline `.` is evolutionLines, so it picks a real family id.
  IFS=$'\x1f' read -r PET_XP_NEXT PET_NAME \
    <<< "$(jq -r --arg line "${PET_LINE_ID:-titan}" --argjson idx "${PET_STAGE_IDX:-0}" '
      (.evolutionLines | (.[$line] // .[keys[0]]) | .stages) as $s
      | ($s[$idx] // $s[0]) as $cur
      | [
          (if $idx + 1 < ($s | length) then $s[$idx + 1].xpRequired else "MAX" end),
          ($cur.name // "???")
        ] | map(tostring) | join("\u001f")' "$PET_CREATURES" 2>/dev/null)"

  # Read last activity message (within 10 min)
  PET_MSG=""
  if [[ -f "$PET_ACTIVITY" ]]; then
    IFS=$'\x1f' read -r ACT_TS ACT_MSG \
      <<< "$(jq -r '[(.timestamp // 0), (.message // "")] | map(tostring) | join("\u001f")' "$PET_ACTIVITY" 2>/dev/null)"
    ACT_S=$(( ${ACT_TS:-0} / 1000 ))
    AGE=$(( $(date +%s) - ACT_S ))
    (( AGE < 600 )) && PET_MSG="$ACT_MSG"
  fi

  # Read sprite lines and print with message on first, info on last
  SPRITE_LINES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    SPRITE_LINES+=("$line")
  done < <(jq -r --arg line "${PET_LINE_ID:-titan}" --arg idx "${PET_STAGE_IDX:-0}" \
    '((.[$line] // .[keys[0]])[$idx] // [])[]' "$PET_SPRITES" 2>/dev/null)

  if (( ${#SPRITE_LINES[@]} > 0 )); then
    SPRITE_W=0
    for sl in "${SPRITE_LINES[@]}"; do
      [[ ${#sl} -gt "$SPRITE_W" ]] && SPRITE_W=${#sl}
    done
    SPRITE_W=$((SPRITE_W + 1))

    LAST_IDX=$(( ${#SPRITE_LINES[@]} - 1 ))
    for (( i=0; i<${#SPRITE_LINES[@]}; i++ )); do
      PADDED=$(printf "%-${SPRITE_W}s" "${SPRITE_LINES[$i]}")
      if [[ "$i" -eq 0 ]] && [[ -n "$PET_MSG" ]]; then
        printf "%b\n" "${GRAY}${PADDED} ${PET_MSG}${RST}"
      elif [[ "$i" -eq "$LAST_IDX" ]]; then
        printf "%b\n" "${GRAY}${PADDED} Pet: ◆ ${PET_NAME:-???}  ♥ ${PET_XP}/${PET_XP_NEXT} XP${RST}"
      else
        printf "%b\n" "${GRAY}${PADDED}${RST}"
      fi
    done
  fi
fi

# Print the bar unless the information is switched off (info.show: false). A
# missing state/sprites file must still not blank it — that is what the
# pet-display branch used to get wrong. Printing nothing here with both switches
# off leaves an empty status line row (observed): Claude Code reserves that
# region, so it is not something this script can take back.
if [[ -n "$L" ]]; then
  printf "%b\n" "$L"
fi
