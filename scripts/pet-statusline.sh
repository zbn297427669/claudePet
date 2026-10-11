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
MODEL=$(echo "$input"    | jq -r '.model.display_name // "Claude"')
MODEL_ID=$(echo "$input" | jq -r '.model.id // empty')
SESSION_ID=$(echo "$input" | jq -r '.session_id // .sessionId // empty')
DIR=$(echo "$input"      | jq -r '.workspace.current_dir // .cwd // ""')
PCT=$(echo "$input"      | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
# Prefer live current_usage (input+cache); fallback to total_input_tokens
CTX_USED=$(echo "$input" | jq -r '
  def n(x): (x // 0);
  if (.context_window.current_usage != null) then
    n(.context_window.current_usage.input_tokens)
    + n(.context_window.current_usage.cache_creation_input_tokens)
    + n(.context_window.current_usage.cache_read_input_tokens)
  else
    n(.context_window.total_input_tokens)
  end
')
CACHE_READ=$(echo "$input"   | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
OUT_TOK=$(echo "$input"      | jq -r '.context_window.total_output_tokens // .context_window.current_usage.output_tokens // 0')
USAGE_IN=$(echo "$input"     | jq -r '.context_window.current_usage.input_tokens // 0')
USAGE_CC=$(echo "$input"     | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
USAGE_CR=$(echo "$input"     | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
USAGE_OUT=$(echo "$input"    | jq -r '.context_window.current_usage.output_tokens // 0')
COST=$(echo "$input"         | jq -r '.cost.total_cost_usd // 0')
DUR_MS=$(echo "$input"       | jq -r '.cost.total_duration_ms // 0')
LINES_ADD=$(echo "$input"    | jq -r '.cost.total_lines_added // 0')
LINES_DEL=$(echo "$input"    | jq -r '.cost.total_lines_removed // 0')

# Optional local $/MTok estimate (auto-updated); may undercount — see README
PET_CONFIG_EARLY="$HOME/.claude/claude-pet/config.json"
COST_STATE="$HOME/.claude/claude-pet/cost-state.json"
if [[ "${PET_PRICING_COST:-1}" != "0" && -f "$PET_CONFIG_EARLY" ]] && command -v python3 >/dev/null 2>&1; then
  COST_CUSTOM=$(
    PET_COST_STATE="$COST_STATE" python3 - "$PET_CONFIG_EARLY" \
      "${MODEL_ID:-}" "${MODEL:-}" "${SESSION_ID:-}" \
      "${USAGE_IN:-0}" "${USAGE_CC:-0}" "${USAGE_CR:-0}" "${USAGE_OUT:-0}" \
      "${COST:-0}" <<'PY'
import json, os, re, sys
from pathlib import Path

cfg_path, model_id, model_name, session_id, u_in, u_cc, u_cr, u_out, fallback = sys.argv[1:10]
state_path = Path(os.environ.get("PET_COST_STATE") or Path.home() / ".claude/claude-pet/cost-state.json")

def norm(s: str) -> str:
    s = (s or "").lower().strip().split("/")[-1].lstrip("~").split(":")[0]
    return re.sub(r"[^a-z0-9]+", "", s)

try:
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
except Exception:
    print(fallback); raise SystemExit(0)

models = ((cfg.get("pricing") or {}).get("models") or {})
if not isinstance(models, dict) or not models:
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

try:
    in_r = float(price.get("input_per_mtok") or 0)
    out_r = float(price.get("output_per_mtok") or 0)
    cr_r = float(price.get("cache_read_per_mtok") or 0)
    tin = float(u_in or 0); tcc = float(u_cc or 0); tcr = float(u_cr or 0); tout = float(u_out or 0)
except Exception:
    print(fallback); raise SystemExit(0)

# last-request USD estimate
delta = (tin * in_r + tcc * in_r + tcr * cr_r + tout * out_r) / 1e6
fp = f"{int(tin)}|{int(tcc)}|{int(tcr)}|{int(tout)}"

try:
    st = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
except Exception:
    st = {}
if not isinstance(st, dict):
    st = {}

sid = session_id or ""
if sid and st.get("session_id") != sid:
    st = {"session_id": sid, "total_usd": 0.0, "last_fp": ""}

total = float(st.get("total_usd") or 0.0)
last_fp = st.get("last_fp") or ""
if fp != "0|0|0|0" and fp != last_fp:
    total += delta
    st["last_fp"] = fp
    st["total_usd"] = total
    st["session_id"] = sid
    st["model"] = model_id or model_name
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(state_path)
    except Exception:
        pass

# If we have no accumulated usage yet, fall back to Claude's number
if total <= 0:
    print(fallback)
else:
    print(f"{total:.8f}")
PY
  )
  [[ -n "$COST_CUSTOM" ]] && COST="$COST_CUSTOM"
fi

fmt_tokens() {
  # 15500 -> 15.5k, 200000 -> 200k, 1000000 -> 1.0M
  local n="${1:-0}"
  awk -v n="$n" 'BEGIN{
    n+=0
    if (n>=1000000) printf "%.1fM", n/1000000
    else if (n>=1000) printf "%.1fk", n/1000
    else printf "%d", n
  }'
  return 0
}

# ── Dir: shorten to ~/parent/dir ─────────────────────────────────────────────
DIR="${DIR/#$HOME/~}"
NSEGS=$(echo "$DIR" | tr -cd '/' | wc -c | tr -d ' ')
if [[ "$NSEGS" -gt 2 ]]; then
  PARENT=$(echo "$DIR" | awk -F/ '{print $(NF-1)}')
  LEAF=$(echo "$DIR"   | awk -F/ '{print $NF}')
  DIR_DISPLAY="~/${PARENT}/${LEAF}"
else
  DIR_DISPLAY="$DIR"
fi

# ── Git branch ───────────────────────────────────────────────────────────────
GIT_DIR="${DIR/#\~/$HOME}"
BRANCH=$(git -C "$GIT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)

# ── Cost / duration / lines ──────────────────────────────────────────────────
# Currency: Claude reports USD. Optional FX via env or ~/.claude/claude-pet/config.json:
#   env:  PET_COST_CURRENCY=CNY  PET_USD_RATE=7.2  PET_COST_SHOW_USD=1
#   json: "currency": { "code":"CNY", "symbol":"¥", "usd_rate":7.2, "show_usd":false }
PET_CONFIG_EARLY="$HOME/.claude/claude-pet/config.json"
COST_CURRENCY="${PET_COST_CURRENCY:-}"
USD_RATE="${PET_USD_RATE:-}"
COST_SHOW_USD="${PET_COST_SHOW_USD:-}"
COST_SYMBOL=""
if [[ -f "$PET_CONFIG_EARLY" ]]; then
  [[ -z "$COST_CURRENCY" ]] && COST_CURRENCY=$(jq -r '.currency.code // empty' "$PET_CONFIG_EARLY" 2>/dev/null)
  [[ -z "$USD_RATE" ]] && USD_RATE=$(jq -r '.currency.usd_rate // empty' "$PET_CONFIG_EARLY" 2>/dev/null)
  [[ -z "$COST_SHOW_USD" ]] && COST_SHOW_USD=$(jq -r 'if .currency.show_usd == true then "1" else empty end' "$PET_CONFIG_EARLY" 2>/dev/null)
  COST_SYMBOL=$(jq -r '.currency.symbol // empty' "$PET_CONFIG_EARLY" 2>/dev/null)
fi
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
DUR_S=$(( ${DUR_MS:-0} / 1000 ))
if [[ "$DUR_S" -ge 3600 ]]; then
  DUR_FMT=$(printf '%dh%02dm' $((DUR_S/3600)) $(((DUR_S%3600)/60)))
elif [[ "$DUR_S" -ge 60 ]]; then
  DUR_FMT=$(printf '%dm%02ds' $((DUR_S/60)) $((DUR_S%60)))
else
  DUR_FMT="${DUR_S}s"
fi
LINES_FMT="+${LINES_ADD}/-${LINES_DEL}"

# ── Plan detection (removed — not relevant for most users) ───────────────────
PLAN=""

# ── Context bar (10 chars) + numeric usage ───────────────────────────────────
# ASCII #/- so terminals missing shade glyphs (▓/░) don't show �.
[[ -z "$PCT" ]] && PCT=0
BAR_W=10
FILLED=$((PCT * BAR_W / 100))
[[ "$FILLED" -gt "$BAR_W" ]] && FILLED=$BAR_W
EMPTY=$((BAR_W - FILLED))
BAR=""
[[ "$FILLED" -gt 0 ]] && BAR=$(printf "%${FILLED}s" | tr ' ' '#')
[[ "$EMPTY"  -gt 0 ]] && BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '-')"
BAR="[${BAR}]"
USED_FMT=$(fmt_tokens "$CTX_USED")
SIZE_FMT=$(fmt_tokens "$CTX_SIZE")
CTX_NUM="${USED_FMT}/${SIZE_FMT}"
CACHE_FMT=$(fmt_tokens "$CACHE_READ")
OUT_FMT=$(fmt_tokens "$OUT_TOK")
# Cache hit rate = cache_read / (input + cache_write + cache_read)
# Show % first (intuition), then volume (scale):  cache 99% · 207k
CACHE_DENOM=$(awk -v a="${USAGE_IN:-0}" -v b="${USAGE_CC:-0}" -v c="${USAGE_CR:-0}" 'BEGIN{printf "%d", a+b+c}')
CACHE_SEG=""
if [[ "${CACHE_DENOM:-0}" -gt 0 ]] 2>/dev/null; then
  CACHE_HIT=$(awk -v r="${USAGE_CR:-0}" -v d="$CACHE_DENOM" 'BEGIN{printf "%d", (r*100)/d}')
  [[ "$CACHE_HIT" -gt 100 ]] && CACHE_HIT=100
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

# ── Assemble status bar ──────────────────────────────────────────────────────
# Example:
#   ⬡ model │ ~/path │ [###-------] 21% 42.1k/200k │ cache 99% · 207k │ out 1.2k │ ¥0.01 │ 3m12s │ +12/-3
L=""
[[ -n "$PLAN" ]] && L="${GRAY}${PLAN}${RST}${SEP}"
L="${L}${GRAY}⬡ ${MODEL}${RST}"
L="${L}${SEP}${GRAY}${DIR_DISPLAY}${RST}"
[[ -n "$BRANCH" ]] && L="${L}${SEP}${GRAY}⎇ ${BRANCH}${RST}"
L="${L}${SEP}${BAR_CLR}${BAR}${RST}${GRAY} ${PCT}% ${CTX_NUM}${RST}"
[[ -n "$CACHE_SEG" ]] && L="${L}${SEP}${GRAY}${CACHE_SEG}${RST}"
[[ "${OUT_TOK:-0}" != "0" ]] && L="${L}${SEP}${GRAY}out ${OUT_FMT}${RST}"
L="${L}${SEP}${GRAY}${COST_FMT}${RST}"
[[ "${DUR_MS:-0}" != "0" ]] && L="${L}${SEP}${GRAY}${DUR_FMT}${RST}"
if [[ "${LINES_ADD:-0}" != "0" ]] || [[ "${LINES_DEL:-0}" != "0" ]]; then
  L="${L}${SEP}${GRAY}${LINES_FMT}${RST}"
fi

# ── Pet Buddy (monstapix block art) ──────────────────────────────────────────
PET_DIR="$HOME/.claude/claude-pet"
PET_STATE="$PET_DIR/state.json"
PET_SPRITES="$PET_DIR/sprites.json"
PET_CONFIG="$PET_DIR/config.json"
PET_ACTIVITY="$PET_DIR/last-activity.json"
PET_DISPLAY=$(jq -r 'if .display == false then "false" else "true" end' "$PET_CONFIG" 2>/dev/null)

if [[ "$PET_DISPLAY" = "true" ]] && [[ -f "$PET_STATE" ]] && [[ -f "$PET_SPRITES" ]] && command -v jq &>/dev/null; then
  PET_STAGE_IDX=$(jq -r '.currentStageIndex // 0' "$PET_STATE")
  PET_LINE_ID=$(jq -r '.currentLineId // "titan"' "$PET_STATE")
  PET_XP=$(jq -r '.xp // 0' "$PET_STATE")

  # Read XP thresholds from creatures.json (family-aware)
  PET_CREATURES="$PET_DIR/creatures.json"
  NEXT_IDX=$((PET_STAGE_IDX + 1))
  TOTAL_STAGES=$(jq -r ".evolutionLines.\"${PET_LINE_ID}\".stages | length" "$PET_CREATURES" 2>/dev/null)
  if [[ -n "$TOTAL_STAGES" ]] && [[ "$NEXT_IDX" -lt "$TOTAL_STAGES" ]]; then
    PET_XP_NEXT=$(jq -r ".evolutionLines.\"${PET_LINE_ID}\".stages[$NEXT_IDX].xpRequired" "$PET_CREATURES")
  else
    PET_XP_NEXT="MAX"
  fi

  PET_NAME=$(jq -r ".evolutionLines.\"${PET_LINE_ID}\".stages[$PET_STAGE_IDX].name" "$PET_CREATURES" 2>/dev/null)

  # Read last activity message (within 10 min)
  PET_MSG=""
  if [[ -f "$PET_ACTIVITY" ]]; then
    ACT_TS=$(jq -r '.timestamp // 0' "$PET_ACTIVITY")
    ACT_MSG=$(jq -r '.message // ""' "$PET_ACTIVITY")
    NOW_S=$(date +%s)
    ACT_S=$((ACT_TS / 1000))
    AGE=$((NOW_S - ACT_S))
    if [[ "$AGE" -lt 600 ]] 2>/dev/null; then
      PET_MSG="$ACT_MSG"
    fi
  fi

  # Read sprite lines and print with message on first, info on last
  if [[ -f "$PET_SPRITES" ]]; then
    SPRITE_LINES=()
    while IFS= read -r line; do
      SPRITE_LINES+=("$line")
    done < <(jq -r ".\"${PET_LINE_ID}\".\"${PET_STAGE_IDX}\"[]" "$PET_SPRITES" 2>/dev/null)

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

  printf "%b\n" "$L"
fi
