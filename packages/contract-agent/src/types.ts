export type ClauseType = "liability" | "termination" | "renewal" | "payment" | "confidentiality" | "governing_law" | "other";
export type Clause = { id: string; type: ClauseType; text: string; start: number; end: number };
export type ContractFacts = { parties: string[]; effectiveDate: string | null; renewalDate: string | null; noticeDays: number | null; paymentDays: number | null; liabilityCap: number | null; governingLaw: string | null };
export type RiskItem = { key: string; severity: number; clauseId: string | null; finding: string; recommendation: string };
export type Review = { facts: ContractFacts; clauses: Clause[]; risks: RiskItem[]; riskScore: number; action: "approve" | "review" | "negotiate" };
export type AgentQuery = { question: string; clauses: Clause[]; topK?: number };
