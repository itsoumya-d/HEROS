import type {
  AuditEvent,
  FleetCycle,
  GateDecision,
  Opportunity,
  Outcome,
  SignalInput,
  UnitEconomics,
  UnitEconomicsInput,
  ValidationInput,
  Weights
} from "./types.ts";

export const DEFAULT_WEIGHTS: Weights = {
  demandSignal: 0.30,
  willingnessToPay: 0.25,
  buildSpeed: 0.20,
  grossMargin: 0.15,
  strategicFit: 0.10,
  competition: 0.20
};

const clamp01 = (value: number) => Math.min(1, Math.max(0, value));
const round = (value: number, places = 2) => Number(value.toFixed(places));

export function scoreOpportunity(signal: SignalInput, weights: Weights = DEFAULT_WEIGHTS): Opportunity {
  if (!signal.id || !signal.name) throw new Error("Opportunity id and name are required.");
  if (signal.buildCostUsd < 0) throw new Error("Build cost cannot be negative.");
  const score =
    weights.demandSignal * clamp01(signal.demandSignal) +
    weights.willingnessToPay * clamp01(signal.willingnessToPay) +
    weights.buildSpeed * clamp01(signal.buildSpeed) +
    weights.grossMargin * clamp01(signal.grossMargin) +
    weights.strategicFit * clamp01(signal.strategicFit) -
    weights.competition * clamp01(signal.competition);
  return {
    id: signal.id,
    name: signal.name,
    score: round(clamp01(score), 4),
    buildCostUsd: round(signal.buildCostUsd)
  };
}

export function calculateUnitEconomics(input: UnitEconomicsInput): UnitEconomics {
  if (input.arpuUsd <= 0) throw new Error("ARPU must be positive.");
  if (input.cogsUsd < 0 || input.cacUsd < 0) throw new Error("COGS and CAC cannot be negative.");
  if (input.monthlyChurn < 0 || input.monthlyChurn > 1) throw new Error("Monthly churn must be between 0 and 1.");
  const contribution = input.arpuUsd - input.cogsUsd;
  const grossMarginRate = contribution / input.arpuUsd;
  const paybackMonths = contribution > 0 ? input.cacUsd / contribution : null;
  const ltvUsd = input.monthlyChurn > 0 ? (input.arpuUsd * grossMarginRate) / input.monthlyChurn : null;
  const ltvCacRatio = ltvUsd !== null && input.cacUsd > 0 ? ltvUsd / input.cacUsd : null;
  return {
    contributionMarginUsd: round(contribution),
    grossMarginRate: round(grossMarginRate, 4),
    paybackMonths: paybackMonths === null ? null : round(paybackMonths),
    ltvUsd: ltvUsd === null ? null : round(ltvUsd),
    ltvCacRatio: ltvCacRatio === null ? null : round(ltvCacRatio)
  };
}

export function gateOpportunity(
  opportunity: Opportunity,
  economics: UnitEconomics,
  validation: ValidationInput
): { qualified: boolean; reasons: string[] } {
  const reasons: string[] = [];
  if (validation.paidPreorders <= 0) reasons.push("No paid preorders.");
  if (validation.verifiedRevenueUsd <= 0) reasons.push("No verified revenue.");
  if (!validation.humanVerificationComplete) reasons.push("Human verification incomplete.");
  if (economics.contributionMarginUsd <= 0) reasons.push("Contribution margin is not positive.");
  if (economics.paybackMonths === null || economics.paybackMonths > 6) reasons.push("CAC payback exceeds 6 months.");
  if (economics.ltvCacRatio === null || economics.ltvCacRatio < 3) reasons.push("LTV/CAC is below 3x.");
  if (opportunity.score < 0.35) reasons.push("Opportunity score is below launch threshold.");
  return { qualified: reasons.length === 0, reasons };
}

export function runFleetCycle(
  inputs: Array<{ signal: SignalInput; economics: UnitEconomicsInput; validation: ValidationInput }>,
  budgetUsd: number,
  weights: Weights = DEFAULT_WEIGHTS,
  now = new Date()
): FleetCycle {
  if (budgetUsd < 0) throw new Error("Budget cannot be negative.");
  const ranked = inputs
    .map((entry) => {
      const opportunity = scoreOpportunity(entry.signal, weights);
      const economics = calculateUnitEconomics(entry.economics);
      const gate = gateOpportunity(opportunity, economics, entry.validation);
      return { opportunity, economics, ...gate };
    })
    .sort((a, b) => b.opportunity.score - a.opportunity.score);

  let remaining = budgetUsd;
  const decisions: GateDecision[] = [];
  const audit: AuditEvent[] = [];
  for (const row of ranked) {
    let allocated = 0;
    if (row.qualified && remaining >= row.opportunity.buildCostUsd) {
      allocated = row.opportunity.buildCostUsd;
      remaining -= allocated;
    } else if (row.qualified) {
      row.reasons.push("Insufficient remaining fleet budget.");
    }
    const decision: GateDecision = {
      opportunity: row.opportunity,
      economics: row.economics,
      qualified: row.qualified,
      reasons: row.reasons,
      allocatedUsd: round(allocated)
    };
    decisions.push(decision);
    audit.push({
      at: now.toISOString(),
      action: allocated > 0 ? "fleet.allocate" : row.qualified ? "fleet.defer" : "fleet.kill",
      subject: row.opportunity.id,
      detail: allocated > 0 ? `Allocated USD ${allocated.toFixed(2)}.` : row.reasons.join(" ")
    });
  }
  return {
    decisions,
    allocatedUsd: round(budgetUsd - remaining),
    remainingBudgetUsd: round(remaining),
    audit
  };
}

export function calibrateWeights(weights: Weights, outcomes: Outcome[], learningRate = 0.02): Weights {
  if (outcomes.length === 0) return { ...weights };
  const good = outcomes.filter((outcome) => outcome.realisedPaybackMonths <= 6 && outcome.realisedLtvCac >= 3).length;
  const quality = good / outcomes.length;
  const adjust = (value: number, positive: boolean) => {
    const delta = learningRate * (positive ? quality : 1 - quality);
    return Number(Math.min(0.5, Math.max(0.05, value + delta)).toFixed(4));
  };
  return {
    demandSignal: adjust(weights.demandSignal, true),
    willingnessToPay: adjust(weights.willingnessToPay, quality >= 0.5),
    buildSpeed: adjust(weights.buildSpeed, quality >= 0.5),
    grossMargin: adjust(weights.grossMargin, true),
    strategicFit: adjust(weights.strategicFit, quality >= 0.7),
    competition: Number(Math.min(0.5, Math.max(0.05, weights.competition + (quality >= 0.5 ? -learningRate : learningRate))).toFixed(4))
  };
}
