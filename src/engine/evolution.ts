import type {
  PetState,
  CreatureStage,
  CreatureRegistry,
  EvolutionLine,
  PromptScore,
  Milestone,
} from "../types.js";

interface EvolutionResult {
  evolved: boolean;
  newStageIndex: number;
  previousStageId?: string;
}

const MILESTONES: Milestone[] = [
  { id: "first_75", name: "Prompt Master", description: "First prompt scoring over 75", bonusXp: 50, repeatable: false },
  { id: "streak_10", name: "On Fire", description: "10-day streak", bonusXp: 100, repeatable: false },
  { id: "100_prompts", name: "Centurion", description: "100 prompts scored", bonusXp: 75, repeatable: false },
  { id: "perfect_prompt", name: "Perfect Form", description: "All 5 dimensions scored 15+", bonusXp: 30, repeatable: true },
];

export function checkEvolution(
  state: PetState,
  stages: CreatureStage[]
): EvolutionResult {
  let newIndex = state.currentStageIndex;
  for (let i = state.currentStageIndex + 1; i < stages.length; i++) {
    if (state.xp >= stages[i].xpRequired) {
      newIndex = i;
    } else {
      break;
    }
  }

  if (newIndex > state.currentStageIndex) {
    return {
      evolved: true,
      newStageIndex: newIndex,
      previousStageId: stages[state.currentStageIndex].id,
    };
  }

  return { evolved: false, newStageIndex: state.currentStageIndex };
}

/** The pet's evolution line, repairing a currentLineId the registry doesn't know. */
export function resolveLine(
  registry: CreatureRegistry,
  state: PetState
): EvolutionLine {
  const line = registry.evolutionLines[state.currentLineId];
  if (line) return line;
  const fallbackId = Object.keys(registry.evolutionLines)[0];
  state.currentLineId = fallbackId;
  return registry.evolutionLines[fallbackId];
}

/** XP required by the stage after `index`, or -1 once the pet is fully evolved. */
export function nextStageXp(stages: CreatureStage[], index: number): number {
  return index + 1 < stages.length ? stages[index + 1].xpRequired : -1;
}

/**
 * Add XP and roll the daily streak. This does not count a scored prompt —
 * commits and test runs go through here too.
 */
export function awardXp(
  state: PetState,
  xp: number,
  today?: string
): void {
  state.xp += xp;

  const dateStr = today ?? new Date().toISOString().split("T")[0];

  if (state.lastActiveDate) {
    const last = new Date(state.lastActiveDate);
    const current = new Date(dateStr);
    const diffDays = Math.floor(
      (current.getTime() - last.getTime()) / (1000 * 60 * 60 * 24)
    );
    if (diffDays === 1) {
      state.streakDays += 1;
    } else if (diffDays > 1) {
      state.streakDays = 1;
    }
  } else {
    state.streakDays = 1;
  }

  state.lastActiveDate = dateStr;
}

/** Award XP for one scored prompt — the only place totalPromptsScored moves. */
export function awardPromptXp(
  state: PetState,
  xp: number,
  today?: string
): void {
  state.totalPromptsScored += 1;
  awardXp(state, xp, today);
}

export function checkMilestones(
  state: PetState,
  totalScore: number,
  score?: PromptScore
): Milestone[] {
  const earned: Milestone[] = [];

  for (const milestone of MILESTONES) {
    if (!milestone.repeatable && state.milestonesCompleted.includes(milestone.id)) {
      continue;
    }

    let qualifies = false;
    switch (milestone.id) {
      case "first_75":
        qualifies = totalScore > 75;
        break;
      case "streak_10":
        qualifies = state.streakDays >= 10;
        break;
      case "100_prompts":
        qualifies = state.totalPromptsScored >= 100;
        break;
      case "perfect_prompt":
        if (score) {
          qualifies = Object.values(score).every((v) => v >= 15);
        }
        break;
    }

    if (qualifies) earned.push(milestone);
  }

  return earned;
}
