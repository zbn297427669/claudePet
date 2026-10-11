#!/usr/bin/env bash
# update-model-pricing.sh — refresh per-model $/MTok in ~/.claude/claude-pet/config.json
#
# Three independent sources, each optional:
#   1. DeepSeek official pricing page — peak/off-peak card. OpenRouter publishes a
#      single price per model and cannot express DeepSeek's tiers, and its slug
#      match for a `~`-prefixed stealth model was 4.31x below the official card.
#   2. OpenRouter public catalog — flat $/MTok for models with no official card
#      (approximate; not official vendor billing).
#   3. holiday-cn — Chinese public holidays, which DeepSeek bills at off-peak.
#
# Usage:
#   ./update-model-pricing.sh           # update if older than TTL (default 24h)
#   ./update-model-pricing.sh --force   # always fetch
#
# Env:
#   PET_PRICING_TTL_HOURS      cache TTL hours (default 24)
#   PET_PRICING_TIMEOUT        curl timeout seconds (default 5)
#   PET_CONFIG                 override config path
#   PET_PRICING_WATCH          comma-separated model aliases to price
#   CCR_DIR                    optional CCR data dir (config.sqlite) for model watchlist
#   PET_PRICING_CATALOG_FILE   use a local file instead of fetching OpenRouter
#   PET_PRICING_DOCS_FILE      use a local file instead of fetching the DeepSeek page
#   PET_PRICING_HOLIDAY_FILE   use a local file instead of fetching holiday-cn
#   PET_PRICING_OFFLINE=1      never hit the network (file overrides still apply)
#
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

CONFIG="${PET_CONFIG:-$HOME/.claude/claude-pet/config.json}"
TTL_HOURS="${PET_PRICING_TTL_HOURS:-24}"
TIMEOUT="${PET_PRICING_TIMEOUT:-5}"
UA='Mozilla/5.0 (compatible; claude-pet)'

command -v curl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Ensure config exists (minimal) so first-run can seed pricing
if [[ ! -f "$CONFIG" ]]; then
  mkdir -p "$(dirname "$CONFIG")"
  printf '%s\n' '{}' >"$CONFIG"
fi

needs_update() {
  [[ "$FORCE" == "1" ]] && return 0
  local updated
  updated=$(jq -r '.pricing.updated_at // empty' "$CONFIG" 2>/dev/null || true)
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

# ── config lock ──────────────────────────────────────────────────────────────
# update-fx-rate.sh rewrites this same config file whole, and the status line
# launches both updaters in the background, so concurrent runs could drop one of
# the two tables. Same lock file for both scripts; a lock older than a minute is
# treated as dead, and we fail open rather than stall a background refresh.
CONFIG_LOCK="${CONFIG}.lock"
LOCK_HELD=0

acquire_lock() {
  local deadline=$(( SECONDS + 5 ))
  while true; do
    if ( set -o noclobber; printf '%s\n' "$$" >"$CONFIG_LOCK" ) 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    if [[ -f "$CONFIG_LOCK" ]] && [[ -n "$(find "$CONFIG_LOCK" -mmin +1 2>/dev/null)" ]]; then
      rm -f "$CONFIG_LOCK"
      continue
    fi
    if (( SECONDS >= deadline )); then
      return 0   # fail open: a lost refresh beats a hung one
    fi
    sleep 0.1
  done
}

release_lock() {
  if (( LOCK_HELD )); then rm -f "$CONFIG_LOCK"; fi
  return 0
}

# Discover CCR dir (same heuristics as ccr-claude)
discover_ccr_dir() {
  if [[ -n "${CCR_DIR:-}" && -f "${CCR_DIR}/config.sqlite" ]]; then
    printf '%s' "$CCR_DIR"
    return 0
  fi
  local c d
  for c in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/claude-code-router" \
    "$HOME/.claude-code-router" \
    "$HOME/AppData/Roaming/claude-code-router"
  do
    [[ -f "$c/config.sqlite" ]] && { printf '%s' "$c"; return 0; }
  done
  for d in /mnt/c/Users/*/AppData/Roaming/claude-code-router; do
    [[ -f "$d/config.sqlite" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

CCR_DIR_FOUND="$(discover_ccr_dir 2>/dev/null || true)"

WORK="$(mktemp -d)"
trap 'release_lock; rm -rf "$WORK"' EXIT

# Fetch one source into $out. An empty result means "unavailable, keep what we have".
pet_fetch() { # $1=out $2=override-file (empty → fetch) $3=url, remaining args → curl
  local out="$1" override="$2" url="$3"
  shift 3
  if [[ -n "$override" ]]; then
    [[ -f "$override" ]] || return 1
    cp -- "$override" "$out"
    return 0
  fi
  [[ "${PET_PRICING_OFFLINE:-0}" == "1" ]] && return 1
  curl -fsS -m "$TIMEOUT" -A "$UA" "$@" -o "$out" "$url" 2>/dev/null
}

CATALOG=""
DOCS=""
HOLIDAY_CUR=""
HOLIDAY_NEXT=""
CUR_YEAR="$(date -u +%Y)"
NEXT_YEAR="$(( CUR_YEAR + 1 ))"

pet_fetch "$WORK/catalog.json" "${PET_PRICING_CATALOG_FILE:-}" \
  'https://openrouter.ai/api/v1/models' -H 'Accept: application/json' \
  && CATALOG="$WORK/catalog.json" || true

pet_fetch "$WORK/docs.html" "${PET_PRICING_DOCS_FILE:-}" \
  'https://api-docs.deepseek.com/quick_start/pricing/' \
  && DOCS="$WORK/docs.html" || true

pet_fetch "$WORK/holiday-$CUR_YEAR.json" "${PET_PRICING_HOLIDAY_FILE:-}" \
  "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/$CUR_YEAR.json" \
  && HOLIDAY_CUR="$WORK/holiday-$CUR_YEAR.json" || true

# Next year is only published late in the current one; a 404 here is normal
pet_fetch "$WORK/holiday-$NEXT_YEAR.json" "" \
  "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/$NEXT_YEAR.json" \
  && HOLIDAY_NEXT="$WORK/holiday-$NEXT_YEAR.json" || true

acquire_lock

python3 - "$CONFIG" "$CATALOG" "$DOCS" "$HOLIDAY_CUR" "$HOLIDAY_NEXT" \
  "${CCR_DIR_FOUND:-}" "${PET_PRICING_WATCH:-}" "$CUR_YEAR" "$NEXT_YEAR" <<'PY'
import json, os, re, sys, shutil, sqlite3, tempfile
from datetime import datetime, timezone
from pathlib import Path

(config_path, catalog_path, docs_path, holiday_cur, holiday_next,
 ccr_dir, watch_env, cur_year, next_year) = sys.argv[1:10]
cur_year, next_year = int(cur_year), int(next_year)

# ── Built-in DeepSeek card ───────────────────────────────────────────────────
# Verified 2026-10-11 against https://api-docs.deepseek.com/quick_start/pricing/
# Used only when the page cannot be scraped — a successful scrape always wins,
# because the page is the authority and this table goes stale.
BUILTIN_CHECKED_ON = "2026-10-11"
BUILTIN_PEAK_DAYS = [1, 2, 3, 4, 5]
BUILTIN_PEAK_WINDOWS = [["01:00", "04:00"], ["06:00", "10:00"]]
# The docs list one context length for both card models ("CONTEXT LENGTH 1M")
BUILTIN_CONTEXT_TOKENS = 1_000_000
BUILTIN_CARD = {
    "deepseek-flash": {
        "matched": "DeepSeek-V4.1-Flash",
        "context_tokens": BUILTIN_CONTEXT_TOKENS,
        "off_peak": {"input_per_mtok": 0.15, "output_per_mtok": 0.60, "cache_read_per_mtok": 0.003},
        "peak":     {"input_per_mtok": 0.30, "output_per_mtok": 1.20, "cache_read_per_mtok": 0.006},
    },
    "deepseek-v4-pro": {
        "matched": "DeepSeek-V4-Pro-0813",
        "context_tokens": BUILTIN_CONTEXT_TOKENS,
        "off_peak": {"input_per_mtok": 0.66, "output_per_mtok": 1.98, "cache_read_per_mtok": 0.022},
        "peak":     {"input_per_mtok": 1.32, "output_per_mtok": 3.96, "cache_read_per_mtok": 0.044},
    },
}
# Aliases the docs say are routed to a card model (legacy ids bill at Flash rates)
CARD_ALIASES = {
    "deepseek-flash": ["deepseek-flash", "deepseek-flash-latest", "deepseek-v4-flash",
                       "deepseek-v4-flash-vision-exp"],
    "deepseek-v4-pro": ["deepseek-v4-pro"],
}
RATE_KEYS = ("input_per_mtok", "output_per_mtok", "cache_read_per_mtok")
# the scraped row key for each rate key
ROW_FOR_RATE = {"input_per_mtok": "input", "output_per_mtok": "output",
                "cache_read_per_mtok": "cache_read"}


def norm(s: str) -> str:
    s = (s or "").lower().strip().split("/")[-1].lstrip("~").split(":")[0]
    return re.sub(r"[^a-z0-9]+", "", s)


def leaf_name(s: str) -> str:
    return (s or "").strip().split("/")[-1].lstrip("~").split(":")[0]


# ── 1. DeepSeek official card ────────────────────────────────────────────────
def flatten(html: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html)).strip()


def parse_money(s: str):
    try:
        v = float(s.replace("$", "").replace(",", ""))
    except (TypeError, ValueError):
        return None
    return v if v > 0 else None


ROW_RE = {
    "cache_read": re.compile(
        r"1M INPUT TOKENS \(CACHE HIT\) OFF-PEAK \$([\d.,]+) \$([\d.,]+) "
        r"PEAK \$([\d.,]+) \$([\d.,]+)", re.I),
    "input": re.compile(
        r"1M INPUT TOKENS \(CACHE MISS\) OFF-PEAK \$([\d.,]+) \$([\d.,]+) "
        r"PEAK \$([\d.,]+) \$([\d.,]+)", re.I),
    "output": re.compile(
        r"1M OUTPUT TOKENS OFF-PEAK \$([\d.,]+) \$([\d.,]+) "
        r"PEAK \$([\d.,]+) \$([\d.,]+)", re.I),
}


def parse_docs(text: str):
    """Return (card, peak_days, peak_windows, context_tokens) from the pricing page."""
    rows = {}
    for key, rx in ROW_RE.items():
        m = rx.search(text)
        if not m:
            return None, None, None, None
        off_f, off_p, pk_f, pk_p = (parse_money(g) for g in m.groups())
        if None in (off_f, off_p, pk_f, pk_p):
            return None, None, None, None
        # column order: docs list deepseek-flash then deepseek-v4-pro
        rows[key] = {"off_f": off_f, "off_p": off_p, "pk_f": pk_f, "pk_p": pk_p}

    context_tokens = None
    m = re.search(r"CONTEXT LENGTH\s+([0-9.]+)\s*([KM]?)", text, re.I)
    if m:
        scale = {"M": 1_000_000, "K": 1_000, "": 1}[m.group(2).upper()]
        context_tokens = int(float(m.group(1)) * scale)

    card = {}
    for alias in BUILTIN_CARD:
        builtin = BUILTIN_CARD[alias]
        card[alias] = {"matched": builtin["matched"], "off_peak": {}, "peak": {},
                       "context_tokens": context_tokens or BUILTIN_CONTEXT_TOKENS}
        suffix = "_f" if alias == "deepseek-flash" else "_p"
        for key in RATE_KEYS:
            row = rows[ROW_FOR_RATE[key]]
            card[alias]["off_peak"][key] = row["off" + suffix]
            card[alias]["peak"][key] = row["pk" + suffix]

    m = re.search(r"[Pp]eak hours are\s+([\d:]{4,5})\s*-\s*([\d:]{4,5})\s+and\s+"
                  r"([\d:]{4,5})\s*-\s*([\d:]{4,5})\s*UTC", text)
    windows = [[m.group(1), m.group(2)], [m.group(3), m.group(4)]] if m else None
    days = BUILTIN_PEAK_DAYS if re.search(r"Monday\s+(?:through|to)\s+Friday", text, re.I) else None
    return card, days, windows, context_tokens


def card_is_plausible(card: dict) -> bool:
    """Structural checks, so a re-rendered page cannot silently corrupt prices.

    The docs state off-peak is exactly half of peak, and Flash is cheaper than
    Pro in every category — the latter also catches swapped columns.
    """
    if not card:
        return False
    for entry in card.values():
        for key in RATE_KEYS:
            off, pk = entry.get("off_peak", {}).get(key), entry.get("peak", {}).get(key)
            if not isinstance(off, (int, float)) or not isinstance(pk, (int, float)):
                return False
            if off <= 0 or pk <= 0 or abs(pk - 2 * off) > 1e-9:
                return False
    flash, pro = card.get("deepseek-flash"), card.get("deepseek-v4-pro")
    if flash and pro:
        for tier in ("off_peak", "peak"):
            for key in RATE_KEYS:
                if not flash[tier][key] < pro[tier][key]:
                    return False
    return True


card = None
card_source = None
peak_days, peak_windows = BUILTIN_PEAK_DAYS, BUILTIN_PEAK_WINDOWS
if docs_path and os.path.exists(docs_path):
    parse_error = None
    try:
        scraped, days_seen, windows_seen, ctx_seen = parse_docs(flatten(Path(docs_path).read_text(
            encoding="utf-8", errors="replace")))
    except Exception as exc:
        parse_error = exc
        scraped, days_seen, windows_seen, ctx_seen = None, None, None, None
    if scraped and card_is_plausible(scraped):
        card, card_source = scraped, "deepseek-docs"
        if days_seen:
            peak_days = days_seen
        if windows_seen:
            peak_windows = windows_seen
        if card != BUILTIN_CARD:
            print("note: official page differs from the built-in card; using the page",
                  file=sys.stderr)
    elif scraped:
        print("note: deepseek page failed validation; using built-in card", file=sys.stderr)
    elif parse_error is not None:
        # Say why: silently falling back once hid a KeyError in here for a while
        print(f"note: deepseek pricing page unreadable ({parse_error!r}); using built-in card",
              file=sys.stderr)
    else:
        print("note: deepseek page layout not recognised; using built-in card", file=sys.stderr)
if card is None:
    card, card_source = BUILTIN_CARD, "deepseek-builtin"


def card_for(alias: str):
    an = norm(alias)
    if not an:
        return None
    for card_alias, entry in card.items():
        for candidate in CARD_ALIASES.get(card_alias, [card_alias]):
            cn = norm(candidate)
            if an == cn or cn in an or an in cn:
                return entry
    return None


# ── 2. OpenRouter catalog (flat prices) ─────────────────────────────────────
def load_catalog(path):
    entries = []
    with open(path, "r", encoding="utf-8") as f:
        catalog = json.load(f).get("data") or []
    for m in catalog:
        mid = m.get("id") or ""
        if not mid or leaf_name(mid).endswith("batch") or ":batch" in mid:
            continue
        p = m.get("pricing") or {}
        try:
            prompt = float(p.get("prompt") or 0)
            completion = float(p.get("completion") or 0)
        except (TypeError, ValueError):
            continue
        if prompt <= 0 and completion <= 0:
            continue
        try:
            cache_read = float(p.get("input_cache_read") or 0)
        except (TypeError, ValueError):
            cache_read = 0.0
        entries.append({
            "id": mid, "leaf": leaf_name(mid), "n": norm(leaf_name(mid)),
            "input_per_mtok": prompt * 1e6,
            "output_per_mtok": completion * 1e6,
            "cache_read_per_mtok": cache_read * 1e6,
            # the status line uses this to size the context bar for models whose
            # window Claude Code does not know (gateway aliases fall back to 200k)
            "context_tokens": m.get("context_length") or None,
        })
    return entries


def score_alias(alias: str, e: dict) -> int:
    an, ln = norm(alias), e["n"]
    if not an or not ln:
        return -1
    if an == ln:
        return 10000
    if ln.startswith(an) and (ln[len(an):].startswith("latest") or ln == an + "latest"):
        return 9500 - (len(ln) - len(an))
    if ln.startswith(an):
        return 9000 - (len(ln) - len(an))
    if an.startswith(ln) and len(ln) >= 6:
        return 8500 - (len(an) - len(ln))
    if an in ln:
        return 7000 - (len(ln) - len(an))
    if ln in an and len(ln) >= 6:
        return 6500 - (len(an) - len(ln))
    for tag in ("flashx", "flash", "pro", "reasoner", "chat", "prime", "turbo"):
        if tag in an and tag in ln:
            astem, lstem = an.replace(tag, ""), ln.replace(tag, "")
            if astem and lstem and (astem in lstem or lstem in astem):
                return 5000 - abs(len(ln) - len(an))
    return -1


def best_match(alias: str, entries):
    best = None
    for e in entries:
        sc = score_alias(alias, e)
        if sc < 0:
            continue
        if best is None or sc > best[0] or (sc == best[0] and len(e["leaf"]) < len(best[1]["leaf"])):
            best = (sc, e)
    return best[1] if best else None


or_entries = []
if catalog_path and os.path.exists(catalog_path):
    try:
        or_entries = load_catalog(catalog_path)
    except Exception:
        or_entries = []
or_ok = bool(or_entries)

# Nothing reached us: leave updated_at alone so the next render retries, and
# never rewrite the table from stale in-memory data.
if not (catalog_path or docs_path or holiday_cur or holiday_next):
    print("note: no pricing source reachable; keeping the existing table", file=sys.stderr)
    raise SystemExit(0)

# ── watch list: env, then config, then CCR ──────────────────────────────────
watch = []
if watch_env.strip():
    watch.extend(x.strip() for x in watch_env.split(",") if x.strip())

try:
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
if not isinstance(cfg, dict):
    cfg = {}
pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
prev_models = pricing.get("models") if isinstance(pricing.get("models"), dict) else {}
for x in pricing.get("watch") or []:
    if isinstance(x, str) and x.strip():
        watch.append(x.strip())
for k in prev_models:
    if isinstance(k, str) and k.strip():
        watch.append(k.strip())

if ccr_dir:
    try:
        src = Path(ccr_dir)
        td = Path(tempfile.mkdtemp())
        for n in ("config.sqlite", "config.sqlite-wal", "config.sqlite-shm"):
            p = src / n
            if p.exists():
                shutil.copy2(p, td / n)
        con = sqlite3.connect(f"file:{td / 'config.sqlite'}?mode=ro", uri=True)
        row = con.execute("select value_json from app_config where key='default'").fetchone()
        con.close()
        if row:
            data = json.loads(row[0])
            for prov in data.get("Providers") or []:
                if not isinstance(prov, dict):
                    continue
                for m in prov.get("models") or []:
                    if isinstance(m, str) and m.strip():
                        watch.append(leaf_name(m))
                    elif isinstance(m, dict):
                        name = m.get("name") or m.get("id") or ""
                        if name:
                            watch.append(leaf_name(str(name)))
    except Exception:
        pass

seen = set()
aliases = []
for a in watch:
    a = leaf_name(a)
    if not a or a in seen or a.isdigit() or len(norm(a)) < 3:
        continue
    seen.add(a)
    aliases.append(a)

# ── 3. Chinese public holidays (DeepSeek bills them at off-peak) ─────────────
def holidays_for(path, year):
    """None = nothing usable (keep whatever we had); a list = that year's off-days.

    A file that exists but has no `days` means the State Council has not published
    that year yet (holiday-cn ships the file early), which is not the same as "no
    holidays" — treat it like a failed fetch so prior data survives.
    """
    if not path or not os.path.exists(path):
        return None
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict) or data.get("year") != year:
        return None
    days = data.get("days")
    if not isinstance(days, list) or not days:
        return None
    out = []
    for d in days:
        if isinstance(d, dict) and d.get("isOffDay") and isinstance(d.get("date"), str):
            out.append(d["date"])
    return sorted(set(out)) or None


prev_dates = [d for d in (pricing.get("off_peak_dates") or []) if isinstance(d, str)]
by_year = {}
for d in prev_dates:
    by_year.setdefault(d[:4], []).append(d)

scraped_years, fresh = [], []
for year, path in ((cur_year, holiday_cur), (next_year, holiday_next)):
    got = holidays_for(path, year)
    if got is None:
        continue                    # fetch failed → carry the previous year's list over
    scraped_years.append(str(year))
    fresh.extend(got)

carried = [d for y, ds in by_year.items() if y not in scraped_years for d in ds]
off_peak_dates = sorted(d for d in set(fresh + carried) if d[:4] >= str(cur_year))

# ── merge models: card first, OpenRouter only as a fallback ─────────────────
models = {}
matched_or = 0
for alias in aliases:
    prev = prev_models.get(alias) if isinstance(prev_models.get(alias), dict) else {}
    if prev.get("source") == "user":
        models[alias] = prev        # hand-pinned prices are never overwritten
        continue
    entry = card_for(alias)
    if entry:
        merged = {
            "source": card_source,
            "checked_on": BUILTIN_CHECKED_ON if card_source == "deepseek-builtin" else None,
            "matched": entry["matched"],
            "context_tokens": entry.get("context_tokens"),
            "peak": entry["peak"],
            "off_peak": entry["off_peak"],
        }
        if merged["checked_on"] is None:
            del merged["checked_on"]
        if merged["context_tokens"] is None:
            del merged["context_tokens"]
        e = best_match(alias, or_entries) if or_ok else None
        if e:
            flat = {k: round(e[k], 6) for k in RATE_KEYS}
            merged["openrouter_per_mtok"] = flat
            off = entry["off_peak"]
            if any(flat[k] and abs(flat[k] - off[k]) > 0.2 * off[k] for k in RATE_KEYS):
                merged["price_mismatch"] = True
        models[alias] = merged
    elif or_ok:
        e = best_match(alias, or_entries)
        if e:
            matched_or += 1
            models[alias] = {
                "source": "openrouter",
                "matched": e["id"],
                "context_tokens": e.get("context_tokens"),
                "input_per_mtok": round(e["input_per_mtok"], 6),
                "output_per_mtok": round(e["output_per_mtok"], 6),
                "cache_read_per_mtok": round(e["cache_read_per_mtok"], 6),
            }
            if models[alias]["context_tokens"] is None:
                del models[alias]["context_tokens"]

# Keep entries for models that dropped out of the watch list, so a config edit
# cannot silently unprice a model the status line is still asked about.
for alias, entry in prev_models.items():
    models.setdefault(alias, entry)

if not models and not off_peak_dates:
    raise SystemExit(0)

# ── write: merge into the existing pricing block, never replace it ──────────
pricing["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
pricing["source"] = card_source + ("+openrouter" if or_ok else "")
pricing["watch"] = aliases
pricing["models"] = models
pricing.setdefault("tier_mode", "auto")
pricing["peak_days"] = peak_days
pricing["peak_windows"] = peak_windows
if off_peak_dates or scraped_years:
    pricing["off_peak_dates"] = off_peak_dates
    pricing["off_peak_dates_source"] = (
        "holiday-cn@" + ",".join(scraped_years) if scraped_years else
        pricing.get("off_peak_dates_source"))
    if not scraped_years:
        del pricing["off_peak_dates_source"]
cfg["pricing"] = pricing

tmp = config_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, config_path)

print(f"Pricing updated: card={card_source} ({len(card)} models), "
      f"openrouter={matched_or} matched, holidays={len(off_peak_dates)} days", file=sys.stderr)
for alias, info in list(models.items())[:10]:
    if "off_peak" in info:
        off, pk = info["off_peak"], info["peak"]
        flag = "  [MISMATCH vs openrouter]" if info.get("price_mismatch") else ""
        print(f"  {alias} → {info['matched']}  "
              f"off-peak in=${off['input_per_mtok']}/MTok hit=${off['cache_read_per_mtok']} "
              f"out=${off['output_per_mtok']} | peak out=${pk['output_per_mtok']} "
              f"| ctx={info.get('context_tokens') or '?'}{flag}",
              file=sys.stderr)
    else:
        print(f"  {alias} → {info.get('matched', '?')}  "
              f"in=${info.get('input_per_mtok')}/MTok out=${info.get('output_per_mtok')} "
              f"| ctx={info.get('context_tokens') or '?'}",
              file=sys.stderr)
PY
