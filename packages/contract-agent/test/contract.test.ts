import test from "node:test";
import assert from "node:assert/strict";
import { actionPlan, extractClauses, extractFacts, retrieveClauses, reviewContract, scoreRisks } from "../src/engine.ts";

const text = `This agreement is between Acme Ltd and Beta Inc. Effective 2026-11-01. The parties agree to the following. Liability shall be capped at USD 25,000. Payment is due within 45 days of invoice. The agreement will automatically renew on 2026-12-01 unless notice is given 30 days before renewal. This agreement is governed by the laws of England. Confidential information must be protected. Either party may terminate for material breach.`;
const now = new Date("2026-11-07T00:00:00Z");

test("extracts liability clause", () => assert.ok(extractClauses(text).some((c) => c.type === "liability")));
test("extracts payment clause", () => assert.ok(extractClauses(text).some((c) => c.type === "payment")));
test("extracts renewal clause", () => assert.ok(extractClauses(text).some((c) => c.type === "renewal")));
test("extracts governing law", () => assert.ok(extractClauses(text).some((c) => c.type === "governing_law")));
test("extracts confidentiality", () => assert.ok(extractClauses(text).some((c) => c.type === "confidentiality")));
test("extracts termination", () => assert.ok(extractClauses(text).some((c) => c.type === "termination")));
test("rejects empty contract", () => assert.throws(() => extractClauses(" "), /required/));
test("extracts parties", () => assert.deepEqual(extractFacts(text, extractClauses(text)).parties, ["Acme Ltd", "Beta Inc"]));
test("extracts payment days", () => assert.equal(extractFacts(text, extractClauses(text)).paymentDays, 45));
test("extracts liability cap", () => assert.equal(extractFacts(text, extractClauses(text)).liabilityCap, 25000));
test("extracts notice days", () => assert.equal(extractFacts(text, extractClauses(text)).noticeDays, 30));
test("extracts governing law", () => assert.equal(extractFacts(text, extractClauses(text)).governingLaw, "England"));
test("flags low liability cap", () => assert.ok(scoreRisks(text, extractFacts(text, extractClauses(text)), extractClauses(text), now).some((r) => r.key === "low_cap")));
test("flags renewal window", () => assert.ok(scoreRisks(text, extractFacts(text, extractClauses(text)), extractClauses(text), now).some((r) => r.key === "renewal_window")));
test("review requires negotiation", () => assert.equal(reviewContract(text, now).action, "negotiate"));
test("review has positive risk score", () => assert.ok(reviewContract(text, now).riskScore > 0));
test("clean contract approves", () => {
  const clean = `This agreement is between A and B. Liability is capped at USD 100,000. Payment within 30 days. Confidentiality applies. Termination for breach. Governed by the laws of England.`;
  assert.equal(reviewContract(clean, now).action, "approve");
});
test("retrieves liability clauses", () => {
  const r = retrieveClauses({ question: "What is the liability cap?", clauses: extractClauses(text) });
  assert.equal(r[0].type, "liability");
});
test("retrieval rejects empty question", () => assert.throws(() => retrieveClauses({ question: "the and", clauses: extractClauses(text) }), /searchable/));
test("action plan includes top risk", () => {
  const review = reviewContract(text, now);
  assert.ok(actionPlan(review).some((x) => /cap|liability/i.test(x)));
});
