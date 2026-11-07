import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_WEIGHTS,
  calibrateWeights,
  calculateUnitEconomics,
  gateOpportunity,
  runFleetCycle,
  scoreOpportunity
} from "../src/engine.ts";
import type { SignalInput } from "../src/types.ts";

const signal = (over: Partial<SignalInput> = {}): SignalInput => ({
  id: "opp-1",
  name: "Gutcheck",
  demandSignal: 0.9,
  willingnessToPay: 0.8,
  buildSpeed: 0.8,
  grossMargin: 0.7,
  strategicFit: 0.9,
  competition: 0.2,
  buildCostUsd: 2500,
  ...over
});

test("score follows the published weighted formula", () => {
  const opportunity = scoreOpportunity(signal());
  assert.equal(opportunity.score, 0.785);
});

test("score is clamped to zero", () => {
  const opportunity = scoreOpportunity(signal({ demandSignal: 0, willingnessToPay: 0, buildSpeed: 0, grossMargin: 0, strategicFit: 0, competition: 1 }));
  assert.equal(opportunity.score, 0);
});

test("score rejects missing identity", () => {
  assert.throws(() => scoreOpportunity(signal({ id: "" })), /required/);
});

test("score rejects negative build cost", () => {
  assert.throws(() => scoreOpportunity(signal({ buildCostUsd: -1 })), /negative/);
});

test("unit economics computes contribution and gross margin", () => {
  const economics = calculateUnitEconomics({ arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 });
  assert.equal(economics.contributionMarginUsd, 40);
  assert.equal(economics.grossMarginRate, 0.8163);
});

test("unit economics computes payback", () => {
  const economics = calculateUnitEconomics({ arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 });
  assert.equal(economics.paybackMonths, 3);
});

test("unit economics computes LTV and LTV/CAC", () => {
  const economics = calculateUnitEconomics({ arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 });
  assert.equal(economics.ltvUsd, 800);
  assert.equal(economics.ltvCacRatio, 6.67);
});

test("zero churn has no LTV", () => {
  const economics = calculateUnitEconomics({ arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0 });
  assert.equal(economics.ltvUsd, null);
});

test("zero contribution has no payback", () => {
  const economics = calculateUnitEconomics({ arpuUsd: 10, cogsUsd: 10, cacUsd: 120, monthlyChurn: 0.05 });
  assert.equal(economics.paybackMonths, null);
});

test("unit economics rejects invalid ARPU", () => {
  assert.throws(() => calculateUnitEconomics({ arpuUsd: 0, cogsUsd: 0, cacUsd: 0, monthlyChurn: 0 }), /positive/);
});

test("unit economics rejects invalid churn", () => {
  assert.throws(() => calculateUnitEconomics({ arpuUsd: 10, cogsUsd: 1, cacUsd: 1, monthlyChurn: 1.1 }), /churn/);
});

test("gate passes a validated, profitable opportunity", () => {
  const opportunity = scoreOpportunity(signal());
  const economics = calculateUnitEconomics({ arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 });
  const result = gateOpportunity(opportunity, economics, { paidPreorders: 12, verifiedRevenueUsd: 588, humanVerificationComplete: true });
  assert.equal(result.qualified, true);
  assert.deepEqual(result.reasons, []);
});

test("gate blocks missing preorders", () => {
  const result = gateOpportunity(scoreOpportunity(signal()), calculateUnitEconomics({ arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 }), { paidPreorders: 0, verifiedRevenueUsd: 0, humanVerificationComplete: true });
  assert.equal(result.qualified, false);
  assert.match(result.reasons.join(" "), /preorders/);
});

test("gate blocks slow payback", () => {
  const result = gateOpportunity(scoreOpportunity(signal()), calculateUnitEconomics({ arpuUsd: 20, cogsUsd: 9, cacUsd: 200, monthlyChurn: 0.05 }), { paidPreorders: 3, verifiedRevenueUsd: 60, humanVerificationComplete: true });
  assert.match(result.reasons.join(" "), /payback/);
});

test("gate blocks weak LTV/CAC", () => {
  const result = gateOpportunity(scoreOpportunity(signal()), calculateUnitEconomics({ arpuUsd: 20, cogsUsd: 9, cacUsd: 70, monthlyChurn: 0.5 }), { paidPreorders: 3, verifiedRevenueUsd: 60, humanVerificationComplete: true });
  assert.match(result.reasons.join(" "), /LTV\/CAC/);
});

test("fleet cycle allocates by score", () => {
  const result = runFleetCycle([
    { signal: signal({ id: "a", name: "A", buildCostUsd: 1000 }), economics: { arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 }, validation: { paidPreorders: 10, verifiedRevenueUsd: 490, humanVerificationComplete: true } },
    { signal: signal({ id: "b", name: "B", demandSignal: 0.4, buildCostUsd: 1000 }), economics: { arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 }, validation: { paidPreorders: 10, verifiedRevenueUsd: 490, humanVerificationComplete: true } }
  ], 1500);
  assert.equal(result.decisions[0].allocatedUsd, 1000);
  assert.equal(result.decisions[1].allocatedUsd, 0);
  assert.equal(result.remainingBudgetUsd, 500);
});

test("fleet cycle audits allocation and kill decisions", () => {
  const result = runFleetCycle([
    { signal: signal(), economics: { arpuUsd: 49, cogsUsd: 9, cacUsd: 120, monthlyChurn: 0.05 }, validation: { paidPreorders: 1, verifiedRevenueUsd: 49, humanVerificationComplete: true } },
    { signal: signal({ id: "bad", name: "Bad" }), economics: { arpuUsd: 10, cogsUsd: 10, cacUsd: 120, monthlyChurn: 0.05 }, validation: { paidPreorders: 0, verifiedRevenueUsd: 0, humanVerificationComplete: false } }
  ], 5000);
  assert.equal(result.audit[0].action, "fleet.allocate");
  assert.equal(result.audit[1].action, "fleet.kill");
});

test("fleet cycle rejects negative budget", () => {
  assert.throws(() => runFleetCycle([], -1), /Budget/);
});

test("calibration keeps weights bounded", () => {
  const updated = calibrateWeights(DEFAULT_WEIGHTS, [{ opportunityId: "a", realisedPaybackMonths: 3, realisedLtvCac: 5 }], 0.05);
  assert.ok(updated.demandSignal >= 0.05 && updated.demandSignal <= 0.5);
  assert.ok(updated.competition >= 0.05 && updated.competition <= 0.5);
});

test("empty outcomes do not change weights", () => {
  assert.deepEqual(calibrateWeights(DEFAULT_WEIGHTS, []), DEFAULT_WEIGHTS);
});
