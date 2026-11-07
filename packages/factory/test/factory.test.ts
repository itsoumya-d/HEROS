import test from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_TARGETS, computeFlowMetrics, diagnoseFactory, rankBottlenecks, simulateFix } from "../src/engine.ts";
import type { FactoryEvent } from "../src/types.ts";

const events: FactoryEvent[] = [
  { id: "1", type: "issue_opened", at: "2026-11-01T09:00:00Z", issueId: "A", author: "ana" },
  { id: "2", type: "pr_opened", at: "2026-11-01T10:00:00Z", issueId: "A", prId: "P1", author: "ana" },
  { id: "3", type: "review_started", at: "2026-11-01T16:00:00Z", issueId: "A", prId: "P1", author: "ben" },
  { id: "4", type: "approved", at: "2026-11-02T04:00:00Z", issueId: "A", prId: "P1", author: "ben" },
  { id: "5", type: "merged", at: "2026-11-02T05:00:00Z", issueId: "A", prId: "P1", author: "ana" },
  { id: "6", type: "deployed", at: "2026-11-02T09:00:00Z", issueId: "A", prId: "P1", author: "ana" }
];

test("computes median cycle time", () => assert.equal(computeFlowMetrics(events).cycleTimeHours, 24));
test("computes PR wait", () => assert.equal(computeFlowMetrics(events).prWaitHours, 6));
test("computes review duration", () => assert.equal(computeFlowMetrics(events).reviewHours, 12));
test("computes issue response", () => assert.equal(computeFlowMetrics(events).issueResponseHours, 7));
test("counts merged PRs", () => assert.equal(computeFlowMetrics(events).mergedPrs, 1));
test("counts deploys", () => assert.equal(computeFlowMetrics(events).deploys, 1));
test("counts active engineers", () => assert.equal(computeFlowMetrics(events).activeEngineers, 2));
test("deploy frequency uses window", () => assert.equal(computeFlowMetrics(events, 7).deployFrequencyPerWeek, 1));
test("rejects empty events", () => assert.throws(() => computeFlowMetrics([]), /Events/));
test("rejects invalid window", () => assert.throws(() => computeFlowMetrics(events, 0), /positive/));
test("rankBottlenecks ranks PR wait highly", () => {
  const ranked = rankBottlenecks(computeFlowMetrics(events));
  assert.equal(ranked[0].key, "prWaitHours");
});
test("bottleneck includes recommendation", () => assert.match(rankBottlenecks(computeFlowMetrics(events))[0].recommendation, /reviewer|SLA/));
test("bottleneck weights alter severity", () => {
  const base = rankBottlenecks(computeFlowMetrics(events)).find((b) => b.key === "cycleTimeHours")!;
  const heavy = rankBottlenecks(computeFlowMetrics(events), DEFAULT_TARGETS, { weights: { cycleTimeHours: 4 } }).find((b) => b.key === "cycleTimeHours")!;
  assert.ok(heavy.severity > base.severity);
});
test("simulateFix projects cycle-time reduction", () => {
  const metrics = computeFlowMetrics(events);
  const ranked = rankBottlenecks(metrics);
  const result = simulateFix(metrics, ranked, ranked[0].key, 0.5);
  assert.ok(result.projectedCycleTimeHours < metrics.cycleTimeHours);
  assert.ok(result.projectedImprovementPct > 0);
});
test("simulateFix rejects invalid improvement", () => {
  const metrics = computeFlowMetrics(events); const ranked = rankBottlenecks(metrics);
  assert.throws(() => simulateFix(metrics, ranked, ranked[0].key, 1), /between 0 and 1/);
});
test("simulateFix rejects unknown bottleneck", () => {
  const metrics = computeFlowMetrics(events); const ranked = rankBottlenecks(metrics);
  assert.throws(() => simulateFix(metrics, ranked, "unknown" as never), /Unknown/);
});
test("diagnoseFactory returns top bottleneck", () => {
  const result = diagnoseFactory(events);
  assert.equal(result.bottlenecks[0].key, "prWaitHours");
  assert.ok(result.projectedCycleTimeHours > 0);
});
test("diagnoseFactory honors targets", () => {
  const result = diagnoseFactory(events, { ...DEFAULT_TARGETS, prWaitHours: 100 });
  assert.notEqual(result.bottlenecks[0].key, "prWaitHours");
});
test("deploy frequency is monotonic", () => {
  const more = [...events, { id: "7", type: "deployed" as const, at: "2026-11-03T09:00:00Z", issueId: "A", prId: "P1", author: "ana" }];
  assert.ok(computeFlowMetrics(more, 7).deployFrequencyPerWeek >= computeFlowMetrics(events, 7).deployFrequencyPerWeek);
});
test("zero metrics remain finite", () => {
  const onlyIssue: FactoryEvent[] = [{ id: "1", type: "issue_opened", at: "2026-11-01T09:00:00Z", issueId: "A" }];
  const m = computeFlowMetrics(onlyIssue);
  assert.equal(m.prWaitHours, 0);
  assert.equal(m.cycleTimeHours, 0);
  assert.equal(m.deployFrequencyPerWeek, 0);
});
