import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  existsSync,
  renameSync,
  rmSync,
  statSync,
} from "fs";
import { join } from "path";
import type { PetState, PromptHistoryEntry } from "../types.js";

/** Family a fresh pet starts on. install.sh replaces this with a random one. */
export const DEFAULT_LINE_ID = "titan";

export function createDefaultState(lineId: string = DEFAULT_LINE_ID): PetState {
  return {
    currentLineId: lineId,
    currentStageIndex: 0,
    xp: 0,
    totalPromptsScored: 0,
    streakDays: 0,
    lastActiveDate: "",
    milestonesCompleted: [],
    evolutionHistory: [],
  };
}

const MAX_HISTORY = 50;
const LOCK_TIMEOUT_MS = 1000;
const LOCK_STALE_MS = 5000;

/**
 * The hook and the MCP server are separate processes writing the same state file,
 * so every read-modify-write has to be serialised or updates get lost.
 */
export class StateManager {
  private stateFile: string;
  private historyFile: string;
  private lockFile: string;
  /** State held by an in-progress update(), so a nested call reuses it. */
  private inFlight: PetState | null = null;

  constructor(readonly dataDir: string) {
    this.stateFile = join(dataDir, "state.json");
    this.historyFile = join(dataDir, "prompt-history.json");
    this.lockFile = join(dataDir, ".lock");
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true });
    }
  }

  loadState(): PetState {
    if (!existsSync(this.stateFile)) return createDefaultState();
    try {
      // Merge over defaults so a state file written by an older version still loads
      return { ...createDefaultState(), ...JSON.parse(readFileSync(this.stateFile, "utf-8")) };
    } catch {
      return createDefaultState();
    }
  }

  saveState(state: PetState): void {
    writeAtomic(this.stateFile, JSON.stringify(state, null, 2));
  }

  /**
   * Read-modify-write the state while holding the lock. Nested calls share the
   * outer call's in-memory state and let it do the single save — otherwise the
   * inner load would read the not-yet-saved file and clobber the outer write.
   */
  update<T>(mutator: (state: PetState) => T): T {
    if (this.inFlight) return mutator(this.inFlight);

    const release = this.acquireLock();
    try {
      this.inFlight = this.loadState();
      const result = mutator(this.inFlight);
      this.saveState(this.inFlight);
      return result;
    } finally {
      this.inFlight = null;
      release();
    }
  }

  loadPromptHistory(): PromptHistoryEntry[] {
    if (!existsSync(this.historyFile)) return [];
    try {
      return JSON.parse(readFileSync(this.historyFile, "utf-8"));
    } catch {
      return [];
    }
  }

  appendPromptHistory(entry: PromptHistoryEntry): void {
    const release = this.acquireLock();
    try {
      const history = this.loadPromptHistory();
      history.push(entry);
      writeAtomic(this.historyFile, JSON.stringify(history.slice(-MAX_HISTORY), null, 2));
    } finally {
      release();
    }
  }

  private acquireLock(): () => void {
    const deadline = Date.now() + LOCK_TIMEOUT_MS;
    for (;;) {
      try {
        writeFileSync(this.lockFile, `${process.pid}\n`, { flag: "wx" });
        return () => {
          try {
            rmSync(this.lockFile, { force: true });
          } catch {
            /* already gone */
          }
        };
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      }

      // Fail open: a lost update beats hanging the user's prompt
      if (Date.now() >= deadline) return () => {};

      try {
        // Break a lock left behind by a process that died mid-write. Checked
        // before the pid test so a recycled pid can't look like a live holder.
        if (Date.now() - statSync(this.lockFile).mtimeMs > LOCK_STALE_MS) {
          rmSync(this.lockFile, { force: true });
          continue;
        }
        // Held by this process already (a nested appendPromptHistory) — takes
        // milliseconds, so it is never old enough to look stale above
        if (readFileSync(this.lockFile, "utf-8").trim() === String(process.pid)) {
          return () => {};
        }
      } catch {
        continue; // lock disappeared, retry
      }

      sleepSync(10);
    }
  }
}

/** rename(2) is atomic, so readers never observe a half-written file. */
function writeAtomic(file: string, contents: string): void {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, contents);
  renameSync(tmp, file);
}

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
