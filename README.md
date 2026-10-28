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
- **Richer status line metrics** — the turn's reasoning effort (`high`, `xhigh`, …), ASCII context bar with used/size tokens, cache hit rate (`cache 99% · 207k`), output tokens, output rate (`148.0 tok/s`), session duration, and lines changed
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
- `/pet off` — hide pet (the metrics bar stays)
- `/pet status` — check XP, level, streak, display state
- `/pet reset` — reset with a random new family
- `/pet info off` — hide the whole metrics bar (pet unaffected)
- `/pet info on` — show it again
- `/pet info hide cache,out,duration` — drop single segments, keep the rest
- `/pet info unhide cache` — bring one back; `/pet info hide` with no names resets to everything
- `/pet info` — report what is shown and hidden

The pet and the information are independent switches: `/pet off` hides the
creature only, `/pet info off` hides the numbers only, and both off prints
nothing at all — which leaves **one empty status line row**, because Claude Code
reserves that region for whatever the configured statusLine command prints. That
blank row is the interface's, not the script's: reclaiming it means removing the
`statusLine` setting rather than hiding more segments. Segments you can hide are `model effort dir branch context cache out rate
cost duration lines`; `model` is deliberately not hideable — it is the identity
of the line — so hiding everything is `/pet info off` rather than a long list.
`effort` is the current turn's reasoning effort (`low`/`medium`/`high`/`xhigh`/`max`),
shown right after the model; it is absent on a model that does not support the
effort parameter, not blank.
Hiding the bar does **not** stop the cost estimate accumulating, so switching it
back on shows the session's running total instead of a fresh zero.

The same settings live in `config.json` for hand-editing, and are re-read every
render:

```json
{ "display": true, "info": { "show": true, "hide": ["cache", "out"], "wrap": true } }
```

`info.wrap` (default `true`) fits the bar to the terminal: Claude Code renders
the status line with truncation, so a bar wider than the window lost its tail —
cost and line counts. With wrapping on, the bar splits at segment boundaries into
as many lines as it needs, and the last line is padded to the full window width,
so it sits flush right on the row directly above Claude Code's own `auto mode on`
footer instead of reading as a left-aligned block stacked on top of it. Nothing
is dropped and no segment is cut in half. Set it to `false` to keep one line and
let Claude Code truncate it.

The width comes from `COLUMNS`, which Claude Code passes to the command (it runs
from a terminal, so the variable is set); `tput cols` is the second source. With
neither, the bar is printed unchanged rather than guessed at. `PET_INFO_WIDTH`
overrides both — set it to pin a width by hand, or to `0` to turn fitting off in
a context where `tput` would otherwise answer.

## Requirements

- Node.js 20+
- Claude Code CLI (`claude`)
- `jq` (for status line rendering)
- Python 3 — optional; without it the bar shows Claude Code's own cost figure and omits the output rate
- **Dark terminal theme** — pixel creatures use Unicode block characters that are invisible on light backgrounds

## Windows and WSL

Works on macOS, Linux, WSL and native Windows. One set of bash scripts, no
platform branch at runtime — the differences are handled where they exist, so a
fix on one platform does not have to be repeated on the other.

### Windows

Needs **Git Bash** (from [Git for Windows](https://git-scm.com/download/win)) and
`jq`. Run `./install.sh` from Git Bash. See
[docs/WINDOWS-INSTALL.md](docs/WINDOWS-INSTALL.md) for the failure modes that
look like success — a missing `jq` renders an empty bar rather than an error,
and CRLF line endings break the hook while it still exits 0.

Claude Code runs status line and hook commands through Git Bash when it is
installed, so the scripts run unchanged; what the installer adapts is the paths
it writes into `settings.json`.

- **Paths are written with forward slashes** (`C:/Users/you/.claude/...`). A
  backslash path is mangled before it reaches the shell — Git Bash reads `\U`,
  `\a`, `\c` as escapes, so `C:\Users\ada\.claude\settings.json` arrives as
  `C:Usersada.claudesettings.json`. Claude Code's own docs warn about the same
  thing for `statusLine.command`.
- **jq**: `winget install jqlang.jq` or `choco install jq`. It is a hard
  dependency, and it fails quietly — without it the bar still renders, with every
  field empty rather than an error.
- **Python** is the dependency most likely to be a stub: the Microsoft Store
  `python3` answers `command -v`, prints "Python was not found" and exits 0. The
  probe asks for a marker on stdout and walks every `python3`/`python` on `PATH`,
  so one stub does not hide a working interpreter behind it.
- **Terminal encoding**: the bar uses `│`, `⬡` and block characters. Windows
  Terminal defaults to UTF-8; a legacy console on code page 936 shows `?` instead.
  Run `chcp 65001` if you see that.
- **Symbolic links**: the installer links the data and helper files so they follow
  the checkout. Windows refuses symlinks to a normal user without Developer Mode,
  so it falls back to a directory junction (`mklink /J`, which needs no elevation
  and covers the `/pet` skill directory) and then to a copy — and lists the ones
  it copied, since those need a reinstall to pick up changes.

### WSL

Treated as Linux throughout. Paths under `/mnt/c/...` are real Linux paths and are
never reinterpreted as Windows drive letters — the normalisation below only
touches paths that begin with a drive letter.

### What the code does about it

The status line folds the three ways Windows spells one directory
(`C:\Users\me\proj`, `C:/Users/me/proj`, `/c/Users/me`) into one form before
comparing, which is what makes the repo-relative and `~` prefixes work there. On
Linux and WSL nothing is rewritten. Two bugs fixed along the way apply everywhere:

- the hook read its stdin from `/dev/stdin`, which does not exist on Windows, so
  the open failed, the error was swallowed and no prompt was ever scored — it
  reads fd 0 now;
- the status line printed through `printf %b`, which interprets escapes, so a
  `C:\tmp` path came out as `C:<TAB>mp`. The palette holds real escape bytes and
  the final print is `%s`.

### Concurrency

The cost and rate accumulators share one state file, and a render rewrites it.
Two renders at once — a second session, or the status line refreshing while
another one starts — would otherwise load the same map, both save, and the
second save would drop the first session's cost and rate. A lock serialises
them: `flock` on POSIX, `msvcrt.locking` on Windows. Both are advisory locks
between cooperating processes, which is all this needs.

That lock is held across the whole render — load, transcript scan, save — because
holding it only around the save would still let a second render load, save, and
then be overwritten by a stale copy. Both accumulators write one entry and the
file is written once per render, not twice.

The one thing that can still lose an update is a platform with neither locking
primitive, where the code proceeds unlocked rather than failing the render.

The general risk here is failure that looks like success: a wrong-looking path
that nobody reads closely, a hook that exits 0 without scoring, a stub
interpreter that exits 0 without running. Each of those shipped once. The tests
for this area therefore assert on an observable effect (a file written, a rate
displayed) rather than on the absence of an error message.

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

### Output rate

The `rate` segment (`172.0 tok/s`) is output tokens divided by the API time they took to produce, so it measures generation speed rather than throughput over the session's whole life — idle time, tool calls and the time you spend reading don't count against it. It needs no price card, so it keeps working for a model the pricing table doesn't know; disable it with `PET_OUTPUT_RATE=0`.

Both terms are read from the session transcript, and only the bytes appended since the last render, which keeps a render at a few tens of milliseconds.

- **The tokens** cannot come from `current_usage.output_tokens`: that describes only the last response, and the status line renders every ~30s, so sampling it drops every response that finishes in between — in a tool-calling turn that is most of them, and it read about 4x low.
- **The API time** cannot come from the payload's `total_api_duration_ms` either. That counter is not confined to the transcript: after a resume, `/clear`, or an **auto-compaction** it still counts API time for history that is no longer here. One session had discarded 758,966 tokens of history and read 26.4 tok/s this way, against a real ~184.

Instead each assistant record's `requestRef` is matched to the `api-request` record that produced it, and the wait is that pair's timestamp difference — no estimation. Because a dropped history takes its `api-request` records with it, the pairs that survive are exactly the window both terms can see, so the two always agree. Responses whose request record is gone (compaction, or a resume whose earlier transcript is elsewhere) are skipped rather than counted with a guessed wait, and a wait over 600s is ignored as a resume or a stalled connection rather than generation time.

This is a Claude Code record format, not a model feature, so it works the same for any model or gateway — but it does need **Claude Code 2.1.301 or later**, which is where `requestRef` appears. A transcript from 2.1.296 or earlier has no `api-request` records at all and simply shows no rate, rather than a wrong one; a session spanning the upgrade shows a rate over the responses it can pair. Run `claude --version` if the segment never appears.

What remains is that this is an average over the session, not the speed of the response you are watching: a long fast session and a short slow one smooth into the same line. A heavily compacted session's figure covers only the surviving window, so it describes recent speed rather than the whole session — arguably the more useful reading. Disabling and re-enabling the segment does not reset it: the accumulation is keyed by session in `cost-state.json`, so `rm ~/.claude/claude-pet/cost-state.json` is what starts a session over.

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
npm run test:scripts  # status line, pricing updater, cost audit, /pet toggle — no jest, temp $HOME, no network
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
