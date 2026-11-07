export type SignalInput = {
  id: string;
  name: string;
  demandSignal: number;
  willingnessToPay: number;
  buildSpeed: number;
  grossMargin: number;
  strategicFit: number;
  competition: number;
  buildCostUsd: number;
};

export type UnitEconomicsInput = {
  arpuUsd: number;
  cogsUsd: number;
  cacUsd: number;
  monthlyChurn: number;
};

export type ValidationInput = {
  paidPreorders: number;
  verifiedRevenueUsd: number;
  humanVerificationComplete: boolean;
};

export type Opportunity = {
  id: string;
  name: string;
  score: number;
  buildCostUsd: number;
};

export type UnitEconomics = {
  contributionMarginUsd: number;
  grossMarginRate: number;
  paybackMonths: number | null;
  ltvUsd: number | null;
  ltvCacRatio: number | null;
};

export type GateDecision = {
  opportunity: Opportunity;
  economics: UnitEconomics;
  qualified: boolean;
  reasons: string[];
  allocatedUsd: number;
};

export type FleetCycle = {
  decisions: GateDecision[];
  allocatedUsd: number;
  remainingBudgetUsd: number;
  audit: AuditEvent[];
};

export type AuditEvent = {
  at: string;
  action: string;
  subject: string;
  detail: string;
};

export type Outcome = {
  opportunityId: string;
  realisedPaybackMonths: number;
  realisedLtvCac: number;
};

export type Weights = {
  demandSignal: number;
  willingnessToPay: number;
  buildSpeed: number;
  grossMargin: number;
  strategicFit: number;
  competition: number;
};
