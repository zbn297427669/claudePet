#!/bin/bash
# pet-hook.sh — called by Claude Code on UserPromptSubmit.
# Claude Code hands hooks JSON on stdin; score-prompt.js pulls out .prompt and
# runs the same pipeline as the MCP tool. Always exit 0: a scoring failure must
# never block or noise up the user's prompt.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

node "$SCRIPT_DIR/score-prompt.js" 2>/dev/null

exit 0
