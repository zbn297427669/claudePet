# Claude Pet

[![Known Vulnerabilities](https://snyk.io/test/github/cs17/claudePet/badge.svg)](https://snyk.io/test/github/cs17/claudePet)

> Claude removed the `/buddy` feature — *"April Fools feature and has been removed in the latest release, so closing this as not planned."* So I built my own. An evolving pixel-art pet companion for Claude Code that lives in your status line, scores your prompts, and grows stronger as you write better code.

```
▄█▄█▄
█▄█▄█     Pet: Probe  ♥ 42/100 XP
▀█▀█▀
```

![Status line preview](docs/statusline-preview.png)

## Quick Start

```bash
git clone https://github.com/cs17/claudePet.git
cd claudePet
./install.sh
```

Then restart Claude Code. Your pet appears in the status line.

## What You Get

- **Pixel creature** in your status line that evolves through 5 stages
- **Richer status line metrics** — ASCII context bar with used/size tokens, cache hit rate (`cache 99% · 207k`), output tokens, session duration, and lines changed
- **Prompt scoring** across 5 dimensions (specificity, context, actionability, scope, constraints)
- **XP system** — better prompts = more XP = faster evolution
- **9 creature families** — randomly assigned, each with unique personality and voice
- **Streak tracking** — consecutive daily usage earns bonus XP
- **Milestones** — achievements like "Perfect Prompt" award bonus XP
- **`/pet` command** — toggle display on/off, check status, reset with random family

## Evolution Map

9 families, 5 stages each. You're randomly assigned a family on install. XP thresholds: **0 → 100 → 400 → 1,600 → 6,400**

![Evolution Map](docs/evolution-map.png)

| Family | Stages | Voice |
|--------|--------|-------|
| **Titan** | Larva → Juvenile → Warrior → Elder → Titan | Deep rumble → earth-shaking |
| **Swarm** | Spore → Nymph → Worker → Sentinel → Hive | Faint buzz → omnipresent drone |
| **Golem** | Pebble → Boulder → Golem → Colossus → Monolith | Grinding stone → mountain |
| **Invader** | Probe → Scout → Drone → Soldier → Commander | Static → fleet commander |
| **Crawler** | Mite → Beetle → Crawler → Stalker → Behemoth | Tiny clicks → silence then strike |
| **Brute** | Seed → Sprout → Grunt → Hunter → Brute | Tiny grunt → thunderous roar |
| **Phantom** | Wisp → Shade → Phantom → Wraith → Spectre | Faint whisper → the void speaks |
| **Aberrant** | Flicker → Glitch → Anomaly → Aberrant → Nexus | Corrupted static → omnidimensional |
| **Raptor** | Hatchling → Swooper → Talon → Raptor → Apex | Tiny chirps → thunder from above |

## Scoring Dimensions

Each prompt is scored 0-20 per dimension (max 100 total):

- **Specificity** — file paths, function names, line numbers
- **Context** — background info, expected vs actual behavior
- **Actionability** — clear verbs, imperative instructions
- **Scope** — focused vs overly broad requests
- **Constraints** — tech preferences, style rules, limits

## Commands

- `/pet on` — show pet in status line
- `/pet off` — hide pet
- `/pet status` — check XP, level, streak
- `/pet reset` — reset with a random new family

## Requirements

- Node.js 20+
- Claude Code CLI (`claude`)
- `jq` (for status line rendering)
- **Dark terminal theme** — pixel creatures use Unicode block characters that are invisible on light backgrounds

## Uninstall

```bash
claude mcp remove claude-pet
rm -rf ~/.claude/claude-pet ~/.claude/skills/pet
```

Remove the `UserPromptSubmit` hook and `statusLine` entries from `~/.claude/settings.json`.

<details>
<summary>What install.sh does</summary>

1. Checks prerequisites (Node.js, jq)
2. `npm install && npm run build`
3. Registers MCP server via `claude mcp add`
4. Adds prompt-scoring hook to `~/.claude/settings.json`
5. Sets up status line with creature display
6. Copies data files and `/pet` skill to `~/.claude/`
7. Randomly assigns a creature family

</details>

<details>
<summary>MCP Tools (advanced)</summary>

| Tool | Description |
|------|-------------|
| `analyze_prompt` | Score a prompt, award XP, get suggestions |
| `get_pet_status` | See level, XP, personality |
| `log_activity` | Bonus XP for commits, tests, PRs |
| `get_evolution_history` | View evolution timeline |

The `UserPromptSubmit` hook already scores every prompt you send, so `analyze_prompt` will not award XP a second time for the same prompt within a minute — it just re-shows the score. `log_activity` awards XP but is deliberately not counted as a scored prompt, so commits and test runs never inflate the 100-prompts milestone.

</details>



<details>
<summary>Model pricing estimates (optional)</summary>

For non-Anthropic / gateway models, Claude Code's built-in USD cost may be wrong or zero. Optionally maintain a local `$/MTok` table:

```bash
# discover models from CCR config.sqlite when present, or set:
export PET_PRICING_WATCH=my-model,other-model
~/.claude/claude-pet/update-model-pricing.sh --force
```

Prices are fetched from the **OpenRouter public catalog** as an approximation — not official vendor billing. Matched rates land in `config.json` under `pricing.models`.

When a match exists, the status line may recompute an **estimate** from recent `current_usage` snapshots. This can undercount (for example if the session started before pricing was enabled). Disable with `PET_PRICING_COST=0` to keep Claude's `total_cost_usd`.

### DeepSeek peak / off-peak

DeepSeek charges two tariffs: peak is Mon–Fri **01:00–04:00 and 06:00–10:00 UTC** (09:00–12:00 and 14:00–18:00 Beijing), and everything else — including all weekends and Chinese public holidays — is off-peak at exactly half the peak rate. OpenRouter publishes a single price per model and cannot express this, so DeepSeek models get an official card instead, scraped from the [DeepSeek pricing page](https://api-docs.deepseek.com/quick_start/pricing/) and validated structurally before use (rates must be positive, off-peak exactly half of peak, and Flash cheaper than Pro in every category — the last check catches a column swap). If the page cannot be read, a card built in to `update-model-pricing.sh` is used instead. Holiday dates come from [holiday-cn](https://github.com/NateScarlet/holiday-cn).

The status line prices each request at the tariff in force and marks the running total with **谷** (off-peak) or **峰** (peak). Hide the marker with `"currency": { "show_tier": false }` or `PET_COST_TIER_LABEL=0`.

If your gateway does **not** follow DeepSeek's schedule, override it — either pin the tariff, or replace a model's card with your own flat or tiered rates (`"source": "user"` entries are never overwritten by a refresh):

```json
{ "pricing": {
    "tier_mode": "off_peak",
    "models": {
      "deepseek-flash": { "source": "user",
        "off_peak": { "input_per_mtok": 0.15, "output_per_mtok": 0.60, "cache_read_per_mtok": 0.003 },
        "peak":     { "input_per_mtok": 0.30, "output_per_mtok": 1.20, "cache_read_per_mtok": 0.006 } } } } }
```

### Context window size

Claude Code reports `context_window_size` as **200000** for any model it does not recognise as extended-context, which understates a gateway model — DeepSeek Flash is 1M. So the bar prefers the limit recorded on the model's entry: the `CONTEXT LENGTH` row of the DeepSeek page, or OpenRouter's `context_length` for other models. It wins only when it is **larger** than the payload's value, and when it wins the percentage is recomputed with the same input-only formula Claude Code documents (`input + cache_creation + cache_read`), so the bar, the percentage and the `used/size` numbers agree. Set `"context_window_tokens": 1000000` in `config.json` to override both.

### Peak-tariff alert

Peak costs exactly double, so once the session passes a cost threshold the warning moves to where the eye lands first — the start of the line — with a countdown to the cheaper rate:

```
⚡峰 1h52m +¥0.61 │ ⬡ deepseek-flash │ claudePet │ [#####-----] 53% 530.0k/1.0M │ cache 99% · 529.7k │ ¥1.2242 │ 2h00m
```

- `⚡峰 1h52m` — in peak, and the off-peak rate returns in 1h52m (peak windows, weekends and holidays are all taken from the same config the prices use)
- `+¥0.61` — what the peak tariff has cost **extra** this session, versus having run entirely off-peak

Below the threshold it stays quiet — a plain grey `峰` after the cost, exactly as before — so it does not shout through the ~7 peak hours of every weekday. Just before peak starts it pre-warns instead (`⚡峰 15m 后`), which is the actionable moment: decide whether to wait.

Every knob is optional and re-read on every render, so an edit applies to the next one — threshold included:

```json
{ "peak_alert": {
    "enabled": true,          // false = never raise, keep the quiet marker
    "countdown": true,        // time until the rate next changes
    "pre_warn_minutes": 15,   // 0 = no pre-warning before peak
    "cost_threshold": 1,      // in the display currency; below it, stay quiet
    "show_premium": true      // what peak has cost extra this session
} }
```

Env overrides for one-off use: `PET_PEAK_ALERT=0`, `PET_PEAK_COUNTDOWN=0`, `PET_PEAK_PRE_WARN_MINUTES=0`, `PET_PEAK_COST_THRESHOLD=5`, `PET_PEAK_PREMIUM=0`.

### Checking the estimate against your bill

`scripts/pet-cost-audit.py` replays a session transcript and prices every request by its own timestamp's tariff. It deduplicates by message id first — Claude Code writes the same API response into the transcript 2–4 times, so summing the records naively overstates tokens by ~2.5x:

```bash
python3 scripts/pet-cost-audit.py                 # newest transcript for this project
python3 scripts/pet-cost-audit.py --last-hours 2  # just the recent stretch
python3 scripts/pet-cost-audit.py --paid 2.00     # compare against what you were billed
```

It also prints Claude Code's own `costUSD` and the status line's accumulator, so an over- or under-count is easy to spot.

</details>

<details>
<summary>Local currency (optional)</summary>

Claude Code reports cost in USD. To show a local currency in the status line, set `~/.claude/claude-pet/config.json`:

```json
{
  "display": true,
  "currency": {
    "code": "CNY",
    "symbol": "¥",
    "usd_rate": 7.2,
    "show_usd": false
  }
}
```

`./install.sh` symlinks `update-fx-rate.sh` into `~/.claude/claude-pet/`. The status line refreshes the USD→local rate in the background when the cache is older than 24h (override with `PET_FX_TTL_HOURS`, disable with `PET_FX_UPDATE=0`).

Manual refresh:

```bash
~/.claude/claude-pet/update-fx-rate.sh --force
```

</details>

<details>
<summary>Data files</summary>

Pet state persists in `~/.claude/claude-pet/`:
- `state.json` — XP, level, streaks, milestones, assigned family
- `sprites.json` — block-art creature sprites
- `creatures.json` — creature registry
- `config.json` — display toggle and optional `currency` settings
- `prompt-history.json` — last 50 scored prompts
- `last-error.log` — written only if the hook hits an error, so it fails quietly in your prompt flow but still leaves a trace

</details>

## Development

```bash
npm test              # unit tests (jest) + script tests (bash)
npm run test:unit     # jest only
npm run test:scripts  # status line + pricing updater, no jest, temp $HOME, no network
npm run build         # tsc + copy data/ into dist/
```

`test-pricing.sh` drives `update-model-pricing.sh` entirely from injected fixture files (`PET_PRICING_*_FILE`, `PET_PRICING_OFFLINE=1`), so the merge, validation and fallback paths are covered without touching the network or your real config.

CI runs typecheck, unit tests, build, `bash -n` on every shell script, `py_compile` on the Python tool, and both script test suites on Node 20 and 22, alongside the Semgrep scan.

## Credits

Creature pixel art derived from [MonstaPix](http://fontstruct.com/fontstructions/show/475298) by **Ken Bruce**, licensed under [CC BY-NC-SA 3.0](http://creativecommons.org/licenses/by-nc-sa/3.0/).

## License

This project is non-commercial and open source.

- **Code:** [MIT License](LICENSE)
- **Creature sprites:** [CC BY-NC-SA 3.0](http://creativecommons.org/licenses/by-nc-sa/3.0/) — derived from MonstaPix by Ken Bruce
