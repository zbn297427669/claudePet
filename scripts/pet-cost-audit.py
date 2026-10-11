#!/usr/bin/env python3
"""pet-cost-audit.py — reconcile the status line's cost against real usage and the bill.

The status line estimates cost from the *last* request it can see, priced with the
local table. This tool instead replays the session transcript: every API response
Claude Code recorded, deduplicated, priced per request by the DeepSeek peak /
off-peak schedule.

Deduplication is not optional. Claude Code writes the same API response into the
transcript 2-4 times: one session had 389 usage-bearing records but only 157
distinct message ids, so a naive sum overstates tokens by ~2.5x.

Usage:
  python3 scripts/pet-cost-audit.py                    # newest transcript, this project
  python3 scripts/pet-cost-audit.py --session e52551fa-ca56-4417-8ca9-75b9e6b6c272
  python3 scripts/pet-cost-audit.py --last-hours 2     # just the recent stretch
  python3 scripts/pet-cost-audit.py --paid 2.00        # compare against what you were billed
  python3 scripts/pet-cost-audit.py --json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Mirrors pet-statusline.sh: peak windows are UTC, and only these days/hours are peak
DEFAULT_PEAK_DAYS = [1, 2, 3, 4, 5]
DEFAULT_PEAK_WINDOWS = [["01:00", "04:00"], ["06:00", "10:00"]]
RATE_KEYS = ("input_per_mtok", "output_per_mtok", "cache_read_per_mtok")


def projects_root() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "projects"


def project_dir_for(cwd: str) -> Path:
    """Claude Code names a project dir by replacing every '/' in the cwd with '-'."""
    return projects_root() / cwd.replace("/", "-")


def find_transcript(session: str | None, project: str | None) -> Path:
    if session:
        for cand in projects_root().glob(f"*/{session}.jsonl"):
            return cand
        raise SystemExit(f"no transcript found for session {session}")
    pdir = Path(project) if project else project_dir_for(os.getcwd())
    files = sorted(pdir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        raise SystemExit(f"no transcripts in {pdir}")
    return files[0]


def parse_ts(raw):
    if not isinstance(raw, str):
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def load_requests(path: Path, since: datetime | None):
    """Deduplicated (timestamp, usage, model) per API response, oldest first."""
    seen = set()
    order = []
    duplicates = 0
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = rec.get("message") or {}
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue
            key = msg.get("id") or rec.get("uuid")
            if key is None:
                continue
            if key in seen:
                duplicates += 1
                continue
            ts = parse_ts(rec.get("timestamp"))
            if since and ts and ts < since:
                # still mark as seen: the same response may reappear later in the file
                continue
            counters = {
                "in": int(usage.get("input_tokens") or 0),
                "cc": int(usage.get("cache_creation_input_tokens") or 0),
                "cr": int(usage.get("cache_read_input_tokens") or 0),
                "out": int(usage.get("output_tokens") or 0),
            }
            if not any(counters.values()):
                continue        # a usage object with no numbers is not a billed request
            seen.add(key)
            order.append((ts, counters, str(msg.get("model") or "")))
    return order, duplicates


def claude_cost_usd(path: Path):
    """Claude Code's own running total, if the transcript carries one."""
    total = None
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.search(r'"costUSD"\s*:\s*([0-9.]+)', line)
            if m:
                total = float(m.group(1))
    return total


# ── pricing ─────────────────────────────────────────────────────────────────
def load_config(path: Path) -> dict:
    for cand in (path, Path.home() / ".claude/claude-pet/config.json"):
        try:
            cfg = json.loads(cand.read_text(encoding="utf-8"))
            if isinstance(cfg, dict):
                return cfg
        except Exception:
            continue
    return {}


def pick_model_entry(pricing: dict, model: str):
    models = pricing.get("models") if isinstance(pricing.get("models"), dict) else {}
    if not models or not model:
        return None, None
    leaf = model.split("/")[-1].lstrip("~").split(":")[0]
    if leaf in models:
        return leaf, models[leaf]
    needle = re.sub(r"[^a-z0-9]+", "", leaf.lower())
    best = None
    for key, entry in models.items():
        hay = re.sub(r"[^a-z0-9]+", "", key.lower())
        matched = re.sub(r"[^a-z0-9]+", "", str((entry or {}).get("matched") or "").lower())
        score = -1
        if needle and hay and (needle == hay or needle in hay or hay in needle):
            score = 100 - abs(len(needle) - len(hay))
        if needle and matched and (needle == matched or needle in matched or matched in needle):
            score = max(score, 90 - abs(len(needle) - len(matched)))
        if score >= 0 and (best is None or score > best[0]):
            best = (score, entry)
    return (leaf, best[1]) if best else (None, None)


def tier_at(ts: datetime, pricing: dict) -> str:
    """'peak' or 'off_peak' for a moment, in UTC. Mirrors pet-statusline.sh."""
    mode = pricing.get("tier_mode")
    if mode in ("peak", "off_peak"):
        return mode
    ts = ts or datetime.now(timezone.utc)
    days = pricing.get("peak_days") or DEFAULT_PEAK_DAYS
    if ts.isoweekday() not in days:
        return "off_peak"
    if ts.date().isoformat() in set(pricing.get("off_peak_dates") or []):
        return "off_peak"
    hhmm = ts.strftime("%H:%M")
    for window in pricing.get("peak_windows") or DEFAULT_PEAK_WINDOWS:
        try:
            start, end = window
        except (TypeError, ValueError):
            continue
        if start <= hhmm < end:
            return "peak"
    return "off_peak"


def rates_for(entry: dict | None, tier: str | None):
    """(input, output, cache_read) per MTok for this entry, or None if unusable."""
    if not isinstance(entry, dict):
        return None
    if "peak" in entry or "off_peak" in entry:
        block = entry.get(tier or "off_peak") or entry.get("peak") or entry.get("off_peak")
        if not isinstance(block, dict):
            return None
    else:
        block = entry
    try:
        return tuple(float(block.get(k) or 0) for k in RATE_KEYS)
    except (TypeError, ValueError):
        return None


def cost_usd(tokens: dict, rates) -> float:
    in_r, out_r, cr_r = rates
    return (tokens["in"] * in_r + tokens["cc"] * in_r
            + tokens["cr"] * cr_r + tokens["out"] * out_r) / 1e6


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--session", help="session id (transcript file name without .jsonl)")
    ap.add_argument("--project", help="project transcript dir (default: this cwd)")
    ap.add_argument("--transcript", help="explicit transcript path")
    ap.add_argument("--last-hours", type=float, help="only requests from the last N hours")
    ap.add_argument("--paid", type=float, help="amount you were actually billed, in display currency")
    ap.add_argument("--config", default=str(Path.home() / ".claude/claude-pet/config.json"))
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    path = Path(args.transcript) if args.transcript else find_transcript(args.session, args.project)
    since = (datetime.now(timezone.utc) - timedelta(hours=args.last_hours)) if args.last_hours else None
    requests, duplicates = load_requests(path, since)
    if not requests:
        raise SystemExit("no usage records found (wrong session or too narrow a window)")

    totals = {k: 0 for k in ("in", "cc", "cr", "out")}
    by_model: dict[str, dict] = {}
    for _, u, mdl in requests:
        for k in totals:
            totals[k] += u[k]
        bucket = by_model.setdefault(mdl or "?", {k: 0 for k in totals})
        for k in bucket:
            bucket[k] += u[k]
    model = max(by_model, key=lambda m: sum(by_model[m].values())) if by_model else None

    cfg = load_config(Path(args.config))
    pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
    alias, entry = pick_model_entry(pricing, model or "")
    if not entry:
        raise SystemExit(f"no price entry for model {model!r} in {args.config}")

    tiered = "peak" in entry or "off_peak" in entry
    per_request = None
    if tiered:
        # price each request by the tariff in force when it ran
        per_request = sum(
            cost_usd(u, rates_for(entry, tier_at(ts, pricing))) for ts, u, _ in requests
        )
    bounds = {}
    for tier in ("off_peak", "peak"):
        rates = rates_for(entry, tier)
        if rates:
            bounds[tier] = cost_usd(totals, rates)

    cur = cfg.get("currency") if isinstance(cfg.get("currency"), dict) else {}
    rate = float(cur.get("usd_rate") or 1) or 1
    symbol = cur.get("symbol") or "$"
    code = cur.get("code") or "USD"
    def money(usd: float) -> str:
        return f"{symbol}{usd * rate:,.2f}" if code != "USD" else f"${usd:,.4f}"

    if per_request is None:
        head = bounds.get("off_peak")
        per_request = head
    else:
        head = per_request

    payload = {
        "transcript": str(path),
        "requests": len(requests),
        "duplicate_records_skipped": duplicates,
        "tokens": totals,
        "model": model,
        "price_entry": alias,
        "tiered": tiered,
        "cost_usd": {"per_request_tariff": per_request, **bounds},
        "claude_code_usd": claude_cost_usd(path),
        "currency": {"code": code, "symbol": symbol, "usd_rate": rate},
        "paid": args.paid,
    }
    acc = None
    try:
        state = json.loads((Path(args.config).parent / "cost-state.json").read_text(encoding="utf-8"))
        # per-session map; fall back to the older single-slot shape
        sessions = state.get("sessions") if isinstance(state.get("sessions"), dict) else {}
        entry = sessions.get(path.stem) if isinstance(sessions, dict) else None
        acc = (entry or {}).get("total_usd") if isinstance(entry, dict) else state.get("total_usd")
        payload["statusline_accumulator_usd"] = acc
    except Exception:
        pass

    if args.json:
        json.dump(payload, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0

    first, last = requests[0][0], requests[-1][0]
    span = f"{first:%Y-%m-%d %H:%M} → {last:%H:%M} UTC" if first and last else "unknown"
    print(f"transcript   {path}")
    print(f"span         {span}   ({len(requests)} requests"
          + (f", {duplicates} duplicate records skipped" if duplicates else "") + ")")
    print(f"model        {model}   priced as {alias!r}"
          + (" (peak/off-peak card)" if tiered else " (flat price)"))
    print()
    print("tokens")
    print(f"  input cache miss {totals['in']:>13,}")
    print(f"  cache write      {totals['cc']:>13,}")
    print(f"  cache read       {totals['cr']:>13,}")
    print(f"  output           {totals['out']:>13,}")
    billable_in = totals["in"] + totals["cc"] + totals["cr"]
    if billable_in:
        print(f"  → cache reads are {100 * totals['cr'] / billable_in:.1f}% of all input tokens")
    print()
    print("cost")
    if per_request is not None:
        label = "priced per request by its own tariff" if tiered else "flat price"
        print(f"  {label:<38} ${per_request:.4f}  {money(per_request)}")
    for tier in ("off_peak", "peak"):
        if tier in bounds and bounds[tier] is not None:
            print(f"  if every request were {tier:<16} ${bounds[tier]:.4f}  {money(bounds[tier])}")
    claude_usd = payload["claude_code_usd"]
    if claude_usd:
        print(f"  {'Claude Code’s own number':<38} ${claude_usd:.4f}  "
              f"(priced as Anthropic; not meaningful on a gateway)")
    if acc:
        print(f"  {'status line accumulator':<38} ${acc:.4f}  {money(acc)}")

    if args.paid is not None and head:
        paid_usd = args.paid / rate
        print()
        print(f"reconciliation against {args.paid:g} {code}")
        print(f"  implied cost    ${paid_usd:.4f}")
        print(f"  vs per-tariff   ×{paid_usd / head:.2f}")
        for tier in ("off_peak", "peak"):
            if bounds.get(tier):
                print(f"  vs all-{tier:<9} ×{paid_usd / bounds[tier]:.2f}")
        # cache reads dominate, so solve for the cache-hit rate that explains the bill
        rates = rates_for(entry, "off_peak")
        if rates and totals["cr"]:
            in_r, out_r, _ = rates
            fixed = (totals["in"] * in_r + totals["cc"] * in_r + totals["out"] * out_r) / 1e6
            implied_cr = (paid_usd - fixed) / totals["cr"] * 1e6
            print(f"  implied cache-hit rate ${implied_cr:.4f}/MTok "
                  f"(card says ${rates[2]}/MTok off-peak)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
