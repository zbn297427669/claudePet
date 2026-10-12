#!/usr/bin/env bash
# pet-toggle.sh — the /pet on|off|status|reset actions, in one testable place.
#
# This logic used to live inline in skills/pet/SKILL.md, where `/pet off` was a
# bare `echo '{"display": false}' > config.json`. That is a whole-file write, so
# turning the pet off silently deleted every other key in the file — currency,
# peak_alert, context_window_tokens — and the pricing table only came back
# because the background updater regenerated it. Merging instead of replacing is
# the whole reason this moved into a script (and a script can be tested).
#
# Usage: pet-toggle.sh on|off|status|reset
#
# Env:
#   PET_DIR   pet data dir (default: ~/.claude/claude-pet) — tests redirect it
set -uo pipefail

PET_DIR="${PET_DIR:-$HOME/.claude/claude-pet}"
CONFIG="$PET_DIR/config.json"
STATE="$PET_DIR/state.json"
CREATURES="$PET_DIR/creatures.json"
ACTIVITY="$PET_DIR/last-activity.json"
CONFIG_LOCK="$CONFIG.lock"     # same lock update-model-pricing.sh and update-fx-rate.sh take
STATE_LOCK="$PET_DIR/.lock"    # same lock StateManager (the hook / MCP server) takes

action="${1:-status}"

die() { printf 'pet-toggle: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
mkdir -p "$PET_DIR" 2>/dev/null || die "cannot create $PET_DIR"

# ── lock ─────────────────────────────────────────────────────────────────────
# create-exclusive, break a lock older than a minute, and fail open rather than
# hang: an interactive command must not stall, and a rare lost update beats that.
LOCK_FILE=""
LOCK_HELD=0

acquire_lock() { # $1 = lock path
  LOCK_FILE="$1"
  local deadline=$(( SECONDS + 3 ))
  while true; do
    if ( set -o noclobber; printf '%s\n' "$$" >"$LOCK_FILE" ) 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    if [[ -f "$LOCK_FILE" ]] && [[ -n "$(find "$LOCK_FILE" -mmin +1 2>/dev/null)" ]]; then
      rm -f "$LOCK_FILE"
      continue
    fi
    (( SECONDS >= deadline )) && return 0
    sleep 0.1
  done
}

release_lock() {
  if (( LOCK_HELD )); then rm -f "$LOCK_FILE"; fi
  LOCK_HELD=0
  return 0
}

write_atomic() { # $1 = target, stdin = new contents
  local target="$1" tmp
  tmp="$(mktemp "$target.XXXXXX")" || die "cannot create a temp file next to $target"
  cat >"$tmp"
  mv "$tmp" "$target"
}

# ── on / off ─────────────────────────────────────────────────────────────────
set_display() { # $1 = true|false
  local value="$1"
  acquire_lock "$CONFIG_LOCK"
  local out
  if [[ -f "$CONFIG" ]]; then
    # merge: every other key (currency, peak_alert, pricing, …) must survive
    if ! out="$(jq --arg v "$value" '.display = ($v == "true")' "$CONFIG" 2>&1)"; then
      release_lock
      die "$CONFIG is not valid JSON, leaving it untouched: $out"
    fi
  else
    out="$(jq -n --arg v "$value" '{display: ($v == "true")}')"
  fi
  printf '%s\n' "$out" | write_atomic "$CONFIG"
  release_lock
  if [[ "$value" == "true" ]]; then
    echo "Pet display turned ON."
  else
    echo "Pet display turned OFF (the metrics bar stays)."
  fi
}

# ── info (the metrics bar) ───────────────────────────────────────────────────
# info.show is the master switch; info.hide drops single segments while it is on.
# `model` is not hideable — it is the line's identity, so the bar cannot end up
# blank by accident (to hide everything, use info off).
SEGMENTS="model dir branch context cache out cost duration lines"

set_info_show() { # $1 = true|false
  local value="$1" out
  acquire_lock "$CONFIG_LOCK"
  if [[ -f "$CONFIG" ]]; then
    if ! out="$(jq --arg v "$value" '.info = ((.info // {}) | .show = ($v == "true"))' "$CONFIG" 2>&1)"; then
      release_lock
      die "$CONFIG is not valid JSON, leaving it untouched: $out"
    fi
  else
    out="$(jq -n --arg v "$value" '{info: {show: ($v == "true")}}')"
  fi
  printf '%s\n' "$out" | write_atomic "$CONFIG"
  release_lock
  if [[ "$value" == "true" ]]; then
    echo "Information bar turned ON."
  else
    echo "Information bar turned OFF (the pet is unaffected)."
  fi
}

info_hide() { # $1 = comma-separated names ("" clears), $2 = hide|unhide
  local names="$1" mode="$2" name bad="" out
  local IFS=','
  for name in $names; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "model" ]]; then
      die "the model name cannot be hidden — it is the line's identity (use 'info off' for the whole bar)"
    fi
    [[ " $SEGMENTS " == *" $name "* ]] || bad="$bad $name"
  done
  [[ -z "$bad" ]] || die "unknown segment(s):$bad — valid segments: $SEGMENTS"

  acquire_lock "$CONFIG_LOCK"
  if [[ "$mode" == "hide" && -z "$names" ]]; then
    # no names = clear the list (show every segment again)
    if ! out="$(jq '.info = ((.info // {}) | .hide = [])' "$CONFIG" 2>&1)"; then
      release_lock; die "$CONFIG is not valid JSON, leaving it untouched: $out"
    fi
  elif [[ "$mode" == "hide" ]]; then
    if ! out="$(jq --arg n "$names" \
      '.info = ((.info // {}) | .hide = (((.hide // []) + ($n | split(","))) | map(select(. != "")) | unique))' \
      "$CONFIG" 2>&1)"; then
      release_lock; die "$CONFIG is not valid JSON, leaving it untouched: $out"
    fi
  else
    if ! out="$(jq --arg n "$names" \
      '.info = ((.info // {}) | .hide = ((.hide // []) - ($n | split(","))))' \
      "$CONFIG" 2>&1)"; then
      release_lock; die "$CONFIG is not valid JSON, leaving it untouched: $out"
    fi
  fi
  printf '%s\n' "$out" | write_atomic "$CONFIG"
  release_lock

  local hidden
  hidden="$(jq -r '(.info.hide // []) | join(", ")' "$CONFIG" 2>/dev/null)"
  if [[ -z "$hidden" ]]; then
    echo "Information bar shows every segment."
  else
    echo "Information bar is hiding: $hidden"
  fi
}

info_state() { # on | off
  if [[ -f "$CONFIG" ]] && [[ "$(jq -r 'if .info.show == false then "off" else "on" end' "$CONFIG" 2>/dev/null)" == "off" ]]; then
    printf 'off'
  else
    printf 'on'
  fi
}

info_summary() { # one line for show_status
  local hidden
  hidden="$(jq -r '(.info.hide // []) | join(", ")' "$CONFIG" 2>/dev/null)"
  if [[ -n "$hidden" ]]; then
    printf '%s (hiding: %s)' "$(info_state)" "$hidden"
  else
    info_state
  fi
}

show_info() {
  echo "Information bar: $(info_state)"
  echo "Hidden segments:  $(jq -r '(.info.hide // []) | join(", ")' "$CONFIG" 2>/dev/null | sed 's/^$/none/')"
  echo "Segments:         $SEGMENTS"
}

# ── status ───────────────────────────────────────────────────────────────────
show_status() {
  local display="on"
  [[ -f "$CONFIG" ]] && [[ "$(jq -r 'if .display == false then "off" else "on" end' "$CONFIG" 2>/dev/null)" == "off" ]] && display="off"

  if [[ ! -f "$STATE" ]]; then
    echo "No pet yet — run: pet-toggle.sh reset"
    echo "Display: $display"
    echo "Info:     $(info_summary)"
    return 0
  fi

  local line idx name next xp streak prompts milestones evolutions
  line="$(jq -r '.currentLineId // "titan"' "$STATE" 2>/dev/null)"
  idx="$(jq -r '.currentStageIndex // 0' "$STATE" 2>/dev/null)"
  xp="$(jq -r '.xp // 0' "$STATE" 2>/dev/null)"
  streak="$(jq -r '.streakDays // 0' "$STATE" 2>/dev/null)"
  prompts="$(jq -r '.totalPromptsScored // 0' "$STATE" 2>/dev/null)"
  milestones="$(jq -r '(.milestonesCompleted // []) | join(", ")' "$STATE" 2>/dev/null)"
  evolutions="$(jq -r '(.evolutionHistory // []) | length' "$STATE" 2>/dev/null)"

  name=""
  next=""
  if [[ -f "$CREATURES" ]]; then
    name="$(jq -r --arg l "$line" --argjson i "$idx" \
      '(.evolutionLines | (.[$l] // .[keys[0]]) | .stages) as $s | ($s[$i] // $s[0]).name // "???"' \
      "$CREATURES" 2>/dev/null)"
    next="$(jq -r --arg l "$line" --argjson i "$idx" \
      '(.evolutionLines | (.[$l] // .[keys[0]]) | .stages) as $s
       | if $i + 1 < ($s | length) then $s[$i + 1].xpRequired else "MAX" end' \
      "$CREATURES" 2>/dev/null)"
  fi

  echo "Pet:      ${name:-???} — $line (stage $((idx + 1)) of 5)"
  echo "XP:       $xp${next:+ / $next}"
  echo "Streak:   $streak day(s)"
  echo "Prompts:  $prompts scored"
  echo "Badges:   ${milestones:-none}"
  echo "Evolved:  $evolutions time(s)"
  echo "Display:  $display"
  echo "Info:     $(info_summary)"
}

# ── reset ────────────────────────────────────────────────────────────────────
reset_pet() {
  [[ -f "$CREATURES" ]] || die "no $CREATURES — re-run ./install.sh"

  # families come from the registry, not a list baked into the skill
  local families line stage
  families="$(jq -r '.evolutionLines | keys[]' "$CREATURES" 2>/dev/null)"
  [[ -n "$families" ]] || die "no evolution lines in $CREATURES"

  local lines=()
  while IFS= read -r l; do [[ -n "$l" ]] && lines+=("$l"); done <<< "$families"
  line="${lines[$((RANDOM % ${#lines[@]}))]}"
  stage="$(jq -r --arg l "$line" '.evolutionLines[$l].stages[0].name // "???"' "$CREATURES" 2>/dev/null)"

  acquire_lock "$STATE_LOCK"
  jq -n --arg l "$line" '{
    currentLineId: $l, currentStageIndex: 0, xp: 0, totalPromptsScored: 0,
    streakDays: 0, lastActiveDate: "", milestonesCompleted: [], evolutionHistory: []
  }' | write_atomic "$STATE"
  rm -f "$ACTIVITY"
  release_lock

  echo "$line $stage"
  echo "Pet reset! You got a **$stage** from the **$line** line. Start fresh!"
}

case "$action" in
  on)     set_display true ;;
  off)    set_display false ;;
  status) show_status ;;
  reset)  reset_pet ;;
  info)
    case "${2:-status}" in
      on)     set_info_show true ;;
      off)    set_info_show false ;;
      hide)   info_hide "${3:-}" hide ;;
      unhide) info_hide "${3:-}" unhide ;;
      status|"") show_info ;;
      *)      die "usage: pet-toggle.sh info on|off|hide <a,b,...>|unhide <a,b,...>|status" ;;
    esac ;;
  *)      echo "usage: pet-toggle.sh on|off|status|reset|info <action>" >&2; exit 2 ;;
esac
