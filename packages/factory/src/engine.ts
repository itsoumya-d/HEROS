import type { Bottleneck, Diagnosis, FactoryEvent, FlowMetrics, FlowTargets, MetricConfig } from "./types.ts";

export const DEFAULT_TARGETS: FlowTargets = {
  cycleTimeHours: 48,
  prWaitHours: 4,
  reviewHours: 12,
  deployFrequencyPerWeek: 5,
  issueResponseHours: 8
};

const round = (n: number, p = 2) => Number(n.toFixed(p));
const hours = (a: string, b: string) => (new Date(b).getTime() - new Date(a).getTime()) / 36e5;
const median = (xs: number[]) => {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const first = (events: FactoryEvent[], type: FactoryEvent["type"], predicate: (e: FactoryEvent) => boolean) =>
  events.filter((e) => e.type === type && predicate(e)).sort((a, b) => a.at.localeCompare(b.at))[0];

export function computeFlowMetrics(events: FactoryEvent[], windowDays = 28): FlowMetrics {
  if (windowDays <= 0) throw new Error("Window must be positive.");
  if (events.length === 0) throw new Error("Events are required.");
  const sorted = [...events].sort((a, b) => a.at.localeCompare(b.at));
  const cycle: number[] = [];
  const prWait: number[] = [];
  const review: number[] = [];
  const response: number[] = [];
  const issues = new Set(sorted.map((e) => e.issueId));
  const mergedPrs = new Set(sorted.filter((e) => e.type === "merged" && e.prId).map((e) => e.prId!)).size;
  const deploys = sorted.filter((e) => e.type === "deployed").length;
  const activeEngineers = new Set(sorted.map((e) => e.author).filter(Boolean)).size;
  for (const issueId of issues) {
    const opened = first(sorted, "issue_opened", (e) => e.issueId === issueId);
    if (!opened) continue;
    const deployed = first(sorted, "deployed", (e) => e.issueId === issueId);
    if (deployed) cycle.push(hours(opened.at, deployed.at));
    const pr = first(sorted, "pr_opened", (e) => e.issueId === issueId);
    if (!pr) continue;
    const started = first(sorted, "review_started", (e) => e.issueId === issueId);
    const approved = first(sorted, "approved", (e) => e.issueId === issueId);
    if (started) {
      prWait.push(hours(pr.at, started.at));
      response.push(hours(opened.at, started.at));
    }
    if (started && approved) review.push(hours(started.at, approved.at));
  }
  const weeks = windowDays / 7;
  return {
    cycleTimeHours: round(median(cycle)),
    prWaitHours: round(median(prWait)),
    reviewHours: round(median(review)),
    deployFrequencyPerWeek: round(deploys / weeks),
    issueResponseHours: round(median(response)),
    mergedPrs,
    deploys,
    activeEngineers
  };
}

export function rankBottlenecks(metrics: FlowMetrics, targets: FlowTargets = DEFAULT_TARGETS, config: MetricConfig = {}): Bottleneck[] {
  const weights = { cycleTimeHours: 1, prWaitHours: 1.2, reviewHours: 1, deployFrequencyPerWeek: 0.8, issueResponseHours: 0.9, ...config.weights };
  const improve = { cycleTimeHours: 0.35, prWaitHours: 0.5, reviewHours: 0.4, deployFrequencyPerWeek: 0.3, issueResponseHours: 0.45, ...config.improvement };
  const ratio = (actual: number, target: number, lowerIsBetter: boolean) => Math.min(2, lowerIsBetter ? actual / target : target / Math.max(actual, 0.01));
  const rows: Bottleneck[] = [
    { key: "cycleTimeHours", label: "Cycle time", actual: metrics.cycleTimeHours, target: targets.cycleTimeHours, severity: ratio(metrics.cycleTimeHours, targets.cycleTimeHours, true), impactHours: metrics.cycleTimeHours * improve.cycleTimeHours!, recommendation: "Split large issues and remove hand-off waits before deploy." },
    { key: "prWaitHours", label: "PR wait", actual: metrics.prWaitHours, target: targets.prWaitHours, severity: ratio(metrics.prWaitHours, targets.prWaitHours, true), impactHours: metrics.prWaitHours * improve.prWaitHours!, recommendation: "Add reviewer routing, WIP limits and a first-response SLA." },
    { key: "reviewHours", label: "Review duration", actual: metrics.reviewHours, target: targets.reviewHours, severity: ratio(metrics.reviewHours, targets.reviewHours, true), impactHours: metrics.reviewHours * improve.reviewHours!, recommendation: "Route risky diffs to owners and split reviews above 400 lines." },
    { key: "deployFrequencyPerWeek", label: "Deploy frequency", actual: metrics.deployFrequencyPerWeek, target: targets.deployFrequencyPerWeek, severity: ratio(metrics.deployFrequencyPerWeek, targets.deployFrequencyPerWeek, false), impactHours: 0, recommendation: "Reduce batch size and make the release path boring." },
    { key: "issueResponseHours", label: "Issue response", actual: metrics.issueResponseHours, target: targets.issueResponseHours, severity: ratio(metrics.issueResponseHours, targets.issueResponseHours, true), impactHours: metrics.issueResponseHours * improve.issueResponseHours!, recommendation: "Triage customer issues in a daily queue with one owner." }
  ].map((b) => ({ ...b, severity: round(b.severity * (weights[b.key] ?? 1), 4), impactHours: round(b.impactHours) }));
  return rows.sort((a, b) => b.severity - a.severity);
}

export function simulateFix(metrics: FlowMetrics, bottlenecks: Bottleneck[], key: keyof FlowTargets, improvement = 0.3): Diagnosis {
  if (improvement <= 0 || improvement >= 1) throw new Error("Improvement must be between 0 and 1.");
  if (!bottlenecks.some((b) => b.key === key)) throw new Error("Unknown bottleneck.");
  const target = bottlenecks.find((b) => b.key === key)!;
  const reduction = target.impactHours * improvement;
  const projected = Math.max(1, metrics.cycleTimeHours - reduction);
  return {
    metrics,
    bottlenecks,
    projectedCycleTimeHours: round(projected),
    projectedImprovementPct: round(((metrics.cycleTimeHours - projected) / metrics.cycleTimeHours) * 100)
  };
}

export function diagnoseFactory(events: FactoryEvent[], targets: FlowTargets = DEFAULT_TARGETS, config: MetricConfig = {}, windowDays = 28): Diagnosis {
  const metrics = computeFlowMetrics(events, windowDays);
  const bottlenecks = rankBottlenecks(metrics, targets, config);
  return simulateFix(metrics, bottlenecks, bottlenecks[0].key, 0.3);
}
