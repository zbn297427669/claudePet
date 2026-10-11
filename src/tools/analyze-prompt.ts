import { createHash, randomInt } from "node:crypto";
import { scorePrompt, xpForScore } from "../engine/scorer.js";
import {
  awardPromptXp,
  checkEvolution,
  checkMilestones,
  nextStageXp,
  resolveLine,
} from "../engine/evolution.js";
import { renderPet, renderEvolution } from "../engine/renderer.js";
import { StateManager } from "../engine/state.js";
import { writeLastActivity } from "../engine/activity.js";
import type {
  CreatureRegistry,
  CreatureStage,
  PromptScore,
  ScoreDimension,
} from "../types.js";

/** The hook and the MCP tool can both score one prompt — the second within this window is ignored. */
const DUPLICATE_WINDOW_MS = 60_000;

interface AnalyzeResult {
  display: string;
  score: PromptScore;
  totalScore: number;
  xpAwarded: number;
  evolved: boolean;
  duplicate: boolean;
}

export function handleAnalyzePrompt(
  text: string,
  stateManager: StateManager,
  registry: CreatureRegistry,
  now: number = Date.now()
): AnalyzeResult {
  const score = scorePrompt(text);
  const totalScore = Object.values(score).reduce((a, b) => a + b, 0);
  const xp = xpForScore(totalScore);
  const hash = hashPrompt(text);

  return stateManager.update((state) => {
    const stages = resolveLine(registry, state).stages;
    const stage = stages[state.currentStageIndex];

    if (isDuplicate(state.lastScoredHash, state.lastScoredAt, hash, now)) {
      const speech = "Already scored that one — no double XP!";
      return {
        display: renderPet(stage, state.xp, nextStageXp(stages, state.currentStageIndex), speech, []),
        score,
        totalScore,
        xpAwarded: 0,
        evolved: false,
        duplicate: true,
      };
    }

    awardPromptXp(state, xp, dateStr(now));
    const milestones = checkMilestones(state, totalScore, score);
    let bonusXp = 0;
    for (const m of milestones) {
      bonusXp += m.bonusXp;
      if (!state.milestonesCompleted.includes(m.id)) {
        state.milestonesCompleted.push(m.id);
      }
    }
    state.xp += bonusXp;
    state.lastScoredHash = hash;
    state.lastScoredAt = now;

    const xpAwarded = xp + bonusXp;
    const evo = checkEvolution(state, stages);

    let display: string;
    let message: string;
    if (evo.evolved) {
      state.currentStageIndex = evo.newStageIndex;
      state.evolutionHistory.push({
        stageId: stages[evo.newStageIndex].id,
        reachedAt: dateStr(now),
      });
      const newStage = stages[evo.newStageIndex];
      display = renderEvolution(
        stage.name,
        newStage,
        state.xp,
        nextStageXp(stages, evo.newStageIndex)
      );
      message = `${newStage.name} has awakened!`;
    } else {
      message = suggestion(stage, score);
      display = renderPet(
        stage,
        state.xp,
        nextStageXp(stages, state.currentStageIndex),
        message,
        milestones
      );
    }

    stateManager.appendPromptHistory({
      timestamp: new Date(now).toISOString(),
      promptSnippet: text.slice(0, 80),
      score,
      totalScore,
      xpAwarded,
    });
    writeLastActivity(stateManager, xpAwarded, message);

    return { display, score, totalScore, xpAwarded, evolved: evo.evolved, duplicate: false };
  });
}

function hashPrompt(text: string): string {
  return createHash("sha256").update(text).digest("hex").slice(0, 16);
}

function dateStr(now: number): string {
  return new Date(now).toISOString().split("T")[0];
}

function isDuplicate(
  lastHash: string | undefined,
  lastAt: number | undefined,
  hash: string,
  now: number
): boolean {
  return lastHash === hash && now - (lastAt ?? 0) < DUPLICATE_WINDOW_MS;
}

/** Coach the weakest scoring dimension. */
function suggestion(stage: CreatureStage, score: PromptScore): string {
  const dims = Object.entries(score) as [ScoreDimension, number][];
  dims.sort((a, b) => a[1] - b[1]);
  const lines = stage.suggestions[dims[0][0]];
  return lines[randomInt(lines.length)];
}
