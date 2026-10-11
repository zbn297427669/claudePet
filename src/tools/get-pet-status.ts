import { StateManager } from "../engine/state.js";
import { nextStageXp, resolveLine } from "../engine/evolution.js";
import type { CreatureRegistry } from "../types.js";

interface PetStatusResult {
  name: string;
  level: number;
  xp: number;
  xpNext: number;
  personality: string;
  streakDays: number;
  totalPromptsScored: number;
}

export function handleGetPetStatus(
  stateManager: StateManager,
  registry: CreatureRegistry
): PetStatusResult {
  const state = stateManager.loadState();
  const stages = resolveLine(registry, state).stages;
  const stage = stages[state.currentStageIndex];
  const xpNext = nextStageXp(stages, state.currentStageIndex);

  return {
    name: stage.name,
    level: stage.level,
    xp: state.xp,
    xpNext,
    personality: stage.personality,
    streakDays: state.streakDays,
    totalPromptsScored: state.totalPromptsScored,
  };
}
