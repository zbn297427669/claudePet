import { StateManager } from "../engine/state.js";
import { awardXp, checkEvolution, nextStageXp, resolveLine } from "../engine/evolution.js";
import { renderPet, renderEvolution } from "../engine/renderer.js";
import { writeLastActivity } from "../engine/activity.js";
import type { CreatureRegistry } from "../types.js";

const ACTIVITY_XP: Record<string, number> = {
  git_commit: 5,
  test_pass: 10,
  pr_merged: 15,
};

interface LogActivityResult {
  xpAwarded: number;
  display: string;
  evolved: boolean;
}

export function handleLogActivity(
  type: string,
  detail: string,
  stateManager: StateManager,
  registry: CreatureRegistry
): LogActivityResult {
  const xp = ACTIVITY_XP[type] ?? 0;

  return stateManager.update((state) => {
    // A commit is not a scored prompt: awardXp leaves totalPromptsScored alone
    awardXp(state, xp);

    const stages = resolveLine(registry, state).stages;
    const evo = checkEvolution(state, stages);

    let display: string;
    let message: string;
    if (evo.evolved) {
      const oldName = stages[state.currentStageIndex].name;
      state.currentStageIndex = evo.newStageIndex;
      state.evolutionHistory.push({
        stageId: stages[evo.newStageIndex].id,
        reachedAt: new Date().toISOString().split("T")[0],
      });
      const newStage = stages[evo.newStageIndex];
      display = renderEvolution(oldName, newStage, state.xp, nextStageXp(stages, evo.newStageIndex));
      message = `${newStage.name} has awakened!`;
    } else {
      message = `+${xp} XP for ${type.replace("_", " ")}!`;
      display = renderPet(
        stages[state.currentStageIndex],
        state.xp,
        nextStageXp(stages, state.currentStageIndex),
        message,
        []
      );
    }

    writeLastActivity(stateManager, xp, message);
    return { xpAwarded: xp, display, evolved: evo.evolved };
  });
}
