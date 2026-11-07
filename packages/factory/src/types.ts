export type EventType = "issue_opened" | "pr_opened" | "review_started" | "approved" | "merged" | "deployed" | "issue_closed";
export type FactoryEvent = { id: string; type: EventType; at: string; issueId: string; prId?: string; author?: string };
export type FlowTargets = { cycleTimeHours: number; prWaitHours: number; reviewHours: number; deployFrequencyPerWeek: number; issueResponseHours: number };
export type FlowMetrics = { cycleTimeHours: number; prWaitHours: number; reviewHours: number; deployFrequencyPerWeek: number; issueResponseHours: number; mergedPrs: number; deploys: number; activeEngineers: number };
export type Bottleneck = { key: keyof FlowTargets; label: string; actual: number; target: number; severity: number; impactHours: number; recommendation: string };
export type Diagnosis = { metrics: FlowMetrics; bottlenecks: Bottleneck[]; projectedCycleTimeHours: number; projectedImprovementPct: number };
export type MetricConfig = { weights?: Partial<Record<keyof FlowTargets, number>>; improvement?: Partial<Record<keyof FlowTargets, number>> };
