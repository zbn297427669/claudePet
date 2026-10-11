import {
  mkdtempSync,
  rmSync,
  readFileSync,
  writeFileSync,
  existsSync,
  utimesSync,
} from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { StateManager } from "../engine/state.js";
import type { PetState, PromptHistoryEntry } from "../types.js";

describe("StateManager", () => {
  let tempDir: string;
  let manager: StateManager;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "claude-pet-test-"));
    manager = new StateManager(tempDir);
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  describe("loadState", () => {
    it("should return default state when no file exists", () => {
      const state = manager.loadState();
      expect(state.xp).toBe(0);
      expect(state.currentLineId).toBe("titan");
      expect(state.currentStageIndex).toBe(0);
      expect(state.totalPromptsScored).toBe(0);
    });

    it("should load existing state from file", () => {
      const custom: PetState = {
        currentLineId: "default",
        currentStageIndex: 3,
        xp: 750,
        totalPromptsScored: 42,
        streakDays: 5,
        lastActiveDate: "2026-04-08",
        milestonesCompleted: ["first_75"],
        evolutionHistory: [
          { stageId: "wobble_egg", reachedAt: "2026-04-01" },
        ],
      };
      manager.saveState(custom);
      const loaded = manager.loadState();
      expect(loaded.xp).toBe(750);
      expect(loaded.currentStageIndex).toBe(3);
    });
  });

  describe("saveState", () => {
    it("should persist state to disk", () => {
      const state = manager.loadState();
      state.xp = 100;
      manager.saveState(state);
      const raw = JSON.parse(
        readFileSync(join(tempDir, "state.json"), "utf-8")
      );
      expect(raw.xp).toBe(100);
    });
  });

  describe("update", () => {
    it("should persist what the mutator changed and return its value", () => {
      const result = manager.update((state) => {
        state.xp += 25;
        return "done";
      });
      expect(result).toBe("done");
      expect(manager.loadState().xp).toBe(25);
    });

    it("should let a nested update run without deadlocking", () => {
      manager.update((state) => {
        state.xp = 5;
        manager.update((inner) => {
          inner.xp += 1;
        });
      });
      expect(manager.loadState().xp).toBe(6);
    });

    it("should break a lock left behind by a dead process", () => {
      const lockFile = join(tempDir, ".lock");
      writeFileSync(lockFile, "999999\n");
      const longAgo = new Date(Date.now() - 60_000);
      utimesSync(lockFile, longAgo, longAgo);

      manager.update((state) => {
        state.xp = 7;
      });

      expect(manager.loadState().xp).toBe(7);
      expect(existsSync(lockFile)).toBe(false);
    });
  });

  describe("forward compatibility", () => {
    it("should fill in fields an older state file lacks", () => {
      writeFileSync(
        join(tempDir, "state.json"),
        JSON.stringify({ currentLineId: "swarm", xp: 300 })
      );
      const state = manager.loadState();
      expect(state.xp).toBe(300);
      expect(state.currentLineId).toBe("swarm");
      expect(state.evolutionHistory).toEqual([]);
      expect(state.totalPromptsScored).toBe(0);
    });
  });

  describe("prompt history", () => {
    it("should append entries and cap at 50", () => {
      for (let i = 0; i < 55; i++) {
        manager.appendPromptHistory({
          timestamp: new Date().toISOString(),
          promptSnippet: `prompt ${i}`,
          score: {
            specificity: 10,
            context: 10,
            actionability: 10,
            scope: 10,
            constraints: 10,
          },
          totalScore: 50,
          xpAwarded: 8,
        });
      }
      const history = manager.loadPromptHistory();
      expect(history).toHaveLength(50);
      expect(history[49].promptSnippet).toBe("prompt 54");
    });
  });
});
