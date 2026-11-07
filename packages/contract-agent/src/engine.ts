import type { AgentQuery, Clause, ClauseType, ContractFacts, Review, RiskItem } from "./types.ts";

const round = (n: number, p = 3) => Number(n.toFixed(p));
const words = (s: string) => s.toLowerCase().match(/[a-z0-9]+/g) ?? [];
const STOP = new Set(["the","and","or","of","to","in","a","an","for","with","on","by","is","are","be","this","that","shall","may"]);
const terms = (s: string) => words(s).filter((w) => !STOP.has(w) && w.length > 2);
const daysBetween = (a: string, b: string) => Math.round((new Date(b).getTime() - new Date(a).getTime()) / 864e5);

const PATTERNS: Array<{ type: ClauseType; re: RegExp }> = [
  { type: "liability", re: /(liability|liable|indemnif|indemnity)[^.;]{0,240}/i },
  { type: "termination", re: /(termination|terminate|terminated)[^.;]{0,240}/i },
  { type: "renewal", re: /(renewal|renew|automatically renew|notice period)[^.;]{0,240}/i },
  { type: "payment", re: /(payment|invoice|fees|payable)[^.;]{0,240}/i },
  { type: "confidentiality", re: /(confidential|confidentiality|non-disclosure)[^.;]{0,240}/i },
  { type: "governing_law", re: /(governing law|governed by|jurisdiction)[^.;]{0,240}/i }
];

export function extractClauses(text: string): Clause[] {
  if (!text.trim()) throw new Error("Contract text is required.");
  const out: Clause[] = [];
  let id = 0;
  for (const [idx, sentence] of text.split(/(?<=[.;])\s+/).entries()) {
    for (const p of PATTERNS) {
      const m = sentence.match(p.re);
      if (m) {
        const start = text.indexOf(m[0]);
        out.push({ id: `c${++id}`, type: p.type, text: m[0].trim(), start, end: start + m[0].length });
        break;
      }
      if (idx < 0) break;
    }
  }
  return out;
}

export function extractFacts(text: string, clauses: Clause[]): ContractFacts {
  const partyMatches = [...text.matchAll(/between\s+(.+?)\s+and\s+(.+?)(?:\.|,|\n)/gi)];
  const dateMatches = [...text.matchAll(/\b(20\d{2}-\d{2}-\d{2})\b/g)].map((m) => m[1]);
  const notice = text.match(/notice[^.;]{0,40}?(\d{1,3})\s*days?/i);
  const payment = text.match(/(?:payment|payable|invoice)[^.;]{0,50}?(\d{1,3})\s*days?/i);
  const cap = text.match(/(?:liability[^.;]{0,60}?capped? at|liability cap|aggregate liability)[^.;]{0,60}?(?:USD|GBP|EUR|\$|£|€)\s?([\d,]+)/i);
  const law = text.match(/governed by[^.;]{0,40}?(?:laws? of|law of)\s+([A-Z][A-Za-z ]{2,40})/i);
  const renewal = clauses.find((c) => c.type === "renewal")?.text ?? "";
  const renewalDate = renewal.match(/\b(20\d{2}-\d{2}-\d{2})\b/)?.[1] ?? dateMatches[1] ?? null;
  return {
    parties: partyMatches.length ? [partyMatches[0][1].trim(), partyMatches[0][2].trim()] : [],
    effectiveDate: dateMatches[0] ?? null,
    renewalDate,
    noticeDays: notice ? Number(notice[1]) : null,
    paymentDays: payment ? Number(payment[1]) : null,
    liabilityCap: cap ? Number(cap[1].replace(/,/g, "")) : null,
    governingLaw: law ? law[1].trim() : null
  };
}

export function scoreRisks(text: string, facts: ContractFacts, clauses: Clause[], now = new Date()): RiskItem[] {
  const risks: RiskItem[] = [];
  const has = (type: ClauseType) => clauses.some((c) => c.type === type);
  if (!has("liability")) risks.push({ key: "missing_liability", severity: 0.75, clauseId: null, finding: "No liability clause detected.", recommendation: "Add an aggregate liability cap and carve-outs." });
  if (!has("termination")) risks.push({ key: "missing_termination", severity: 0.65, clauseId: null, finding: "No termination clause detected.", recommendation: "Add termination for convenience and breach." });
  if (!has("confidentiality")) risks.push({ key: "missing_confidentiality", severity: 0.45, clauseId: null, finding: "No confidentiality clause detected.", recommendation: "Add mutual confidentiality and permitted disclosures." });
  if (!has("governing_law")) risks.push({ key: "missing_law", severity: 0.35, clauseId: null, finding: "No governing law detected.", recommendation: "Specify governing law and jurisdiction." });
  const liability = clauses.find((c) => c.type === "liability");
  if (facts.liabilityCap !== null && facts.liabilityCap < 50000) risks.push({ key: "low_cap", severity: 0.8, clauseId: liability?.id ?? null, finding: `Liability cap is ${facts.liabilityCap}.`, recommendation: "Raise the cap to at least 12 months of fees." });
  if (facts.paymentDays !== null && facts.paymentDays > 60) risks.push({ key: "long_payment", severity: 0.5, clauseId: clauses.find((c) => c.type === "payment")?.id ?? null, finding: `Payment term is ${facts.paymentDays} days.`, recommendation: "Negotiate payment within 30-45 days." });
  if (facts.renewalDate) {
    const days = daysBetween(now.toISOString().slice(0,10), facts.renewalDate);
    if (days >= 0 && days <= 30) risks.push({ key: "renewal_window", severity: 0.7, clauseId: clauses.find((c) => c.type === "renewal")?.id ?? null, finding: `Renewal is in ${days} days.`, recommendation: "Confirm renewal intent before the notice deadline." });
  }
  if (/unlimited liability|without limitation/i.test(text)) risks.push({ key: "unlimited_liability", severity: 0.95, clauseId: liability?.id ?? null, finding: "Unlimited liability language found.", recommendation: "Remove unlimited liability or add a negotiated cap." });
  return risks.sort((a, b) => b.severity - a.severity);
}

export function reviewContract(text: string, now = new Date()): Review {
  const clauses = extractClauses(text);
  const facts = extractFacts(text, clauses);
  const risks = scoreRisks(text, facts, clauses, now);
  const riskScore = round(Math.min(1, risks.reduce((s, r) => s + r.severity, 0) / 3), 3);
  return { facts, clauses, risks, riskScore, action: riskScore >= 0.5 ? "negotiate" : riskScore >= 0.25 ? "review" : "approve" };
}

export function retrieveClauses(query: AgentQuery): Array<Clause & { score: number }> {
  const q = new Set(terms(query.question));
  if (q.size === 0) throw new Error("Question must contain searchable terms.");
  const df = new Map<string, number>();
  for (const c of query.clauses) for (const t of new Set(terms(c.text))) df.set(t, (df.get(t) ?? 0) + 1);
  const n = Math.max(1, query.clauses.length);
  return query.clauses.map((c) => {
    const ts = terms(c.text);
    const score = ts.reduce((s, t) => s + (q.has(t) ? Math.log((n + 1) / ((df.get(t) ?? 0) + 1)) + 1 : 0), 0);
    return { ...c, score: round(score, 4) };
  }).filter((c) => c.score > 0).sort((a, b) => b.score - a.score).slice(0, query.topK ?? 3);
}

export function actionPlan(review: Review): string[] {
  const plan: string[] = [];
  if (review.action === "approve") plan.push("Send for signature and archive the executed copy.");
  if (review.action === "review") plan.push("Route to legal review and resolve the top two risks.");
  if (review.action === "negotiate") plan.push("Open a redline with the counterparty before signature.");
  for (const r of review.risks.slice(0, 3)) plan.push(`${r.key}: ${r.recommendation}`);
  return plan;
}
