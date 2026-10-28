---
name: pet
description: Toggle pet display on/off, check status, or reset. Usage - /pet on, /pet off, /pet status, /pet reset
user_invocable: true
---

# Pet display and status

The logic lives in the installed helper, `~/.claude/claude-pet/pet-toggle.sh`.
It merges `config.json` instead of overwriting it — turning the pet off must not
delete the currency, pricing or peak-alert settings — and it is covered by
`scripts/test-pet-toggle.sh`. Do not inline those file writes here again: an
`echo '{...}' > config.json` in this file is what caused that bug.

Map the argument to an action and run it:

| Argument | Run |
|---|---|
| `on`, or none | `~/.claude/claude-pet/pet-toggle.sh on` |
| `off` | `~/.claude/claude-pet/pet-toggle.sh off` |
| `status` | `~/.claude/claude-pet/pet-toggle.sh status` |
| `reset` | `~/.claude/claude-pet/pet-toggle.sh reset` |
| `info on` / `info off` | `~/.claude/claude-pet/pet-toggle.sh info on` / `... info off` |
| `info hide a,b` | `~/.claude/claude-pet/pet-toggle.sh info hide a,b` |
| `info unhide a,b` | `~/.claude/claude-pet/pet-toggle.sh info unhide a,b` |
| `info` | `~/.claude/claude-pet/pet-toggle.sh info status` |
| anything else | run `... info status`, and mention the valid arguments |

`on`/`off` are about the **creature**; `info` is about the **metrics bar** (model,
effort, directory, branch, context bar, cache, output tokens, output rate, cost,
duration, lines changed). They are independent, so "hide the pet but keep the
numbers" is `off` alone.
`hide`/`unhide` take comma-separated segment names, and `info hide` with no names
shows every segment again. The `model` segment is deliberately not hideable — it
is the identity of the line — so use `info off` to hide the whole bar.

Then show the command's output to the user as it is — it already contains the
sentence to reply with (for `reset`, the family and stage it picked).

If the helper is missing (the checkout was moved or deleted), tell the user to
re-run `./install.sh` from the claudePet checkout rather than writing the files
by hand.
