export type ScoreDimension =
  | "specificity"
  | "context"
  | "actionability"
  | "scope"
  | "constraints";

export interface PromptScore {
  specificity: number;
  context: number;
  actionability: number;
  scope: number;
  constraints: number;
}

export interface CreatureStage {
  id: string;
  name: string;
  level: number;
  xpRequired: number;
  personality: string;
  speechStyle: string;
  art: string[];
  suggestions: Record<ScoreDimension, string[]>;
}

export interface EvolutionLine {
  stages: CreatureStage[];
}

export interface CreatureRegistry {
  evolutionLines: Record<string, EvolutionLine>;
}

export interface Milestone {
  id: string;
  name: string;
  description: string;
  bonusXp: number;
  repeatable: boolean;
}

export interface PetState {
  currentLineId: string;
  currentStageIndex: number;
  xp: number;
  totalPromptsScored: number;
  streakDays: number;
  lastActiveDate: string;
  milestonesCompleted: string[];
  evolutionHistory: Array<{
    stageId: string;
    reachedAt: string;
  }>;
  /** Hash of the last scored prompt — stops the hook and the MCP tool double-counting it. */
  lastScoredHash?: string;
  lastScoredAt?: number;
}

export interface PromptHistoryEntry {
  timestamp: string;
  promptSnippet: string;
  score: PromptScore;
  totalScore: number;
  xpAwarded: number;
}
