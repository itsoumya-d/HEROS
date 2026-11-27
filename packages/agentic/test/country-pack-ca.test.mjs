import test from "node:test";
import assert from "node:assert/strict";
import { loadCountryPack, evaluateCountryPolicy } from "../src/packs.js";

test("loadCountryPack loads valid rules from packs/ca/rules.json", () => {
  const rules = loadCountryPack("ca");
  assert.ok(Array.isArray(rules), "rules must be an array");
  assert.ok(rules.length >= 4, "expected at least 4 CA regulatory rules");

  for (const r of rules) {
    assert.ok(r.id, "rule must have an id");
    assert.ok(r.what_it_decides, "rule must describe what it decides");
    assert.ok(r.values, "rule must contain values");
    assert.ok(r.source_url, "rule must cite official source URL");
    assert.ok(r.source_url.startsWith("https://"), "source_url must be HTTPS");
    assert.ok(
      r.source_url.includes(".gc.ca") || r.source_url.includes(".canada.ca") || r.source_url.includes(".cyber.gc.ca") || r.source_url.includes(".priv.gc.ca"),
      `source URL must be official Canadian government or regulator domain: ${r.source_url}`
    );
    assert.ok(r.checked_on, "rule must indicate checked_on date");
  }
});

test("evaluateCountryPolicy enforces CRA GST/HST invoicing threshold (CAD 150)", () => {
  // Over $150 without buyer name -> rejected
  const resOverWithoutBuyer = evaluateCountryPolicy("invoice.create", {
    amount_cad: 250,
    buyer_name: ""
  }, "ca");
  assert.equal(resOverWithoutBuyer.approved, false);
  assert.equal(resOverWithoutBuyer.ruleId, "CA-CRA-GST-001");
  assert.ok(resOverWithoutBuyer.source_url.includes("canada.ca"));

  // Over $150 with buyer name -> approved
  const resOverWithBuyer = evaluateCountryPolicy("invoice.create", {
    amount_cad: 250,
    buyer_name: "Acme Enterprises Ltd"
  }, "ca");
  assert.equal(resOverWithBuyer.approved, true);

  // Under $150 without buyer name -> approved
  const resUnder = evaluateCountryPolicy("invoice.create", {
    amount_cad: 85,
    buyer_name: ""
  }, "ca");
  assert.equal(resUnder.approved, true);
});

test("evaluateCountryPolicy enforces PIPEDA Principle 7 data encryption", () => {
  // PII without encryption -> rejected
  const resUnencrypted = evaluateCountryPolicy("customer.sync", {
    contains_pii: true,
    encrypted: false
  }, "ca");
  assert.equal(resUnencrypted.approved, false);
  assert.equal(resUnencrypted.ruleId, "CA-PIPEDA-007");
  assert.ok(resUnencrypted.source_url.includes("priv.gc.ca"));

  // PII with encryption -> approved
  const resEncrypted = evaluateCountryPolicy("customer.sync", {
    contains_pii: true,
    encrypted: true
  }, "ca");
  assert.equal(resEncrypted.approved, true);
});

test("evaluateCountryPolicy enforces CCCS ITSG-33 privileged access MFA", () => {
  // Privileged action without MFA -> rejected
  const resNoMfa = evaluateCountryPolicy("infra.deploy", {
    privileged: true,
    mfa_verified: false
  }, "ca");
  assert.equal(resNoMfa.approved, false);
  assert.equal(resNoMfa.ruleId, "CA-CCCS-MFA-002");
  assert.ok(resNoMfa.source_url.includes("cyber.gc.ca"));

  // Privileged action with MFA -> approved
  const resWithMfa = evaluateCountryPolicy("infra.deploy", {
    privileged: true,
    mfa_verified: true
  }, "ca");
  assert.equal(resWithMfa.approved, true);
});

test("evaluateCountryPolicy enforces TBS Directive human oversight for high impact", () => {
  // High impact without logged review -> rejected
  const resNoReview = evaluateCountryPolicy("risk.score", {
    high_impact: true,
    human_review_logged: false
  }, "ca");
  assert.equal(resNoReview.approved, false);
  assert.equal(resNoReview.ruleId, "CA-TBS-ADM-001");
  assert.ok(resNoReview.source_url.includes("tbs-sct.canada.ca"));

  // High impact with logged review -> approved
  const resWithReview = evaluateCountryPolicy("risk.score", {
    high_impact: true,
    human_review_logged: true
  }, "ca");
  assert.equal(resWithReview.approved, true);
});
