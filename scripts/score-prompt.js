#!/usr/bin/env node
// score-prompt.js — called by pet-hook.sh on UserPromptSubmit.
//
// Claude Code hands a command hook JSON on stdin: { ..., "prompt": "..." }.
// Reading the whole payload as the prompt would score the envelope (its
// transcript_path/cwd inflate the specificity score), so pull out `.prompt`
// and fall back to raw stdin only so the script still works when run by hand.
//
// This delegates to the same handler the MCP tool uses — the two paths used to
// be separate copies of the pipeline and had already drifted apart.

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DIST_DIR = resolve(__dirname, "..", "dist");
const DATA_DIR = resolve(homedir(), ".claude", "claude-pet");

function readPrompt() {
  let raw = "";
  try {
    raw = readFileSync("/dev/stdin", "utf-8").trim();
  } catch {
    return "";
  }
  if (!raw) return "";
  try {
    const payload = JSON.parse(raw);
    if (payload && typeof payload.prompt === "string") return payload.prompt.trim();
  } catch {
    // not JSON — treat stdin as the prompt itself
  }
  return raw;
}

// Never break the user's prompt flow — but leave a trace instead of failing mute
function logError(err) {
  try {
    mkdirSync(DATA_DIR, { recursive: true });
    writeFileSync(
      resolve(DATA_DIR, "last-error.log"),
      `[${new Date().toISOString()}] score-prompt failed: ${err?.stack ?? err}\n`
    );
  } catch {
    /* nothing else we can do */
  }
}

const prompt = readPrompt();

if (prompt) {
  try {
    const { StateManager } = await import(resolve(DIST_DIR, "engine", "state.js"));
    const { handleAnalyzePrompt } = await import(resolve(DIST_DIR, "tools", "analyze-prompt.js"));
    const registry = JSON.parse(
      readFileSync(resolve(DIST_DIR, "data", "creatures.json"), "utf-8")
    );
    mkdirSync(DATA_DIR, { recursive: true });
    handleAnalyzePrompt(prompt, new StateManager(DATA_DIR), registry);
  } catch (err) {
    logError(err);
  }
}
