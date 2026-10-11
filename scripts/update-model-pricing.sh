#!/usr/bin/env bash
# update-model-pricing.sh — refresh per-model $/MTok in ~/.claude/claude-pet/config.json
#
# Prices come from OpenRouter public catalog (approximate; not official vendor billing).
#
# Usage:
#   ./update-model-pricing.sh           # update if older than TTL (default 24h)
#   ./update-model-pricing.sh --force   # always fetch
#
# Env:
#   PET_PRICING_TTL_HOURS   cache TTL hours (default 24)
#   PET_PRICING_TIMEOUT     curl timeout seconds (default 5)
#   PET_CONFIG              override config path
#   PET_PRICING_WATCH       comma-separated model aliases to price
#   CCR_DIR                 optional CCR data dir (config.sqlite) for model watchlist
#
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

CONFIG="${PET_CONFIG:-$HOME/.claude/claude-pet/config.json}"
TTL_HOURS="${PET_PRICING_TTL_HOURS:-24}"
TIMEOUT="${PET_PRICING_TIMEOUT:-5}"

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

TMP_OR=$(mktemp)
trap 'rm -f "$TMP_OR"' EXIT

if ! curl -fsS -m "$TIMEOUT" \
  -H 'Accept: application/json' \
  'https://openrouter.ai/api/v1/models' \
  -o "$TMP_OR" 2>/dev/null
then
  exit 0
fi

python3 - "$CONFIG" "$TMP_OR" "${CCR_DIR_FOUND:-}" "${PET_PRICING_WATCH:-}" <<'PY'
import json, os, re, sys, shutil, sqlite3, tempfile
from datetime import datetime, timezone
from pathlib import Path

config_path, catalog_path, ccr_dir, watch_env = sys.argv[1:5]

def norm(s: str) -> str:
    s = (s or "").lower().strip()
    s = s.split("/")[-1]
    s = s.lstrip("~")
    s = s.split(":")[0]
    return re.sub(r"[^a-z0-9]+", "", s)

def leaf_name(s: str) -> str:
    s = (s or "").strip()
    s = s.split("/")[-1].lstrip("~").split(":")[0]
    return s

with open(catalog_path, "r", encoding="utf-8") as f:
    catalog = json.load(f).get("data") or []

entries = []
for m in catalog:
    mid = m.get("id") or ""
    if not mid:
        continue
    leaf = leaf_name(mid)
    if leaf.endswith("batch") or ":batch" in mid:
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
        "id": mid,
        "leaf": leaf,
        "n": norm(leaf),
        "input_per_mtok": prompt * 1e6,
        "output_per_mtok": completion * 1e6,
        "cache_read_per_mtok": cache_read * 1e6,
    })

def score_alias(alias: str, e: dict) -> int:
    an = norm(alias)
    ln = e["n"]
    if not an or not ln:
        return -1
    if an == ln:
        return 10000
    # prefer deepseek-flash-latest for alias deepseek-flash
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
    # token-ish: require both vendor stem and a distinctive suffix (flash/pro/…)
    for tag in ("flashx", "flash", "pro", "reasoner", "chat", "prime", "turbo"):
        if tag in an and tag in ln:
            # strip tag and compare stems
            astem = an.replace(tag, "")
            lstem = ln.replace(tag, "")
            if astem and lstem and (astem in lstem or lstem in astem):
                return 5000 - abs(len(ln) - len(an))
    return -1

def best_match(alias: str):
    best = None
    for e in entries:
        sc = score_alias(alias, e)
        if sc < 0:
            continue
        if best is None or sc > best[0] or (sc == best[0] and len(e["leaf"]) < len(best[1]["leaf"])):
            best = (sc, e)
    return best[1] if best else None

watch = []

# 1) env override
if watch_env.strip():
    watch.extend([x.strip() for x in watch_env.split(",") if x.strip()])

# 2) config.pricing.watch + existing keys
try:
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
for x in pricing.get("watch") or []:
    if isinstance(x, str) and x.strip():
        watch.append(x.strip())
for k in (pricing.get("models") or {}):
    if isinstance(k, str) and k.strip():
        watch.append(k.strip())

# 3) CCR Providers models
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

# 4) no vendor-specific defaults — rely on CCR / config.watch / env
#    Example: PET_PRICING_WATCH=deepseek-flash,glm-5.3-flash

# de-dupe preserve order
seen = set()
aliases = []
for a in watch:
    a = leaf_name(a)
    if not a or a in seen:
        continue
    # skip junk
    if a.isdigit() or len(norm(a)) < 3:
        continue
    seen.add(a)
    aliases.append(a)

models = {}
matched = 0
for alias in aliases:
    e = best_match(alias)
    if not e:
        continue
    matched += 1
    models[alias] = {
        "matched": e["id"],
        "input_per_mtok": round(e["input_per_mtok"], 6),
        "output_per_mtok": round(e["output_per_mtok"], 6),
        "cache_read_per_mtok": round(e["cache_read_per_mtok"], 6),
    }

if not models:
    raise SystemExit(0)

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
cfg["pricing"] = {
    "updated_at": now,
    "source": "openrouter",
    "watch": aliases,
    "models": models,
}

tmp = config_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, config_path)

print(f"Pricing updated: {matched}/{len(aliases)} models from openrouter", file=sys.stderr)
for alias, info in list(models.items())[:8]:
    print(
        f"  {alias} → {info['matched']}  "
        f"in=${info['input_per_mtok']}/MTok out=${info['output_per_mtok']}/MTok",
        file=sys.stderr,
    )
PY
