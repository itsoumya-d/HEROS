import test from "node:test";
import assert from "node:assert/strict";
import { loadCountryPack, evaluateCountryPolicy } from "../src/packs.js";

test("loadCountryPack loads valid rules from packs/nz/rules.json", () => {
  const rules = loadCountryPack("nz");
  assert.ok(Array.isArray(rules), "rules must be an array");
  assert.ok(rules.length >= 4, "expected at least 4 NZ regulatory rules");

  for (const r of rules) {
    assert.ok(r.id, "rule must have an id");
    assert.ok(r.what_it_decides, "rule must describe what it decides");
    assert.ok(r.values, "rule must contain values");
    assert.ok(r.source_url, "rule must cite official source URL");
    assert.ok(r.source_url.startsWith("https://"), "source_url must be HTTPS");
    assert.ok(
      r.source_url.includes(".govt.nz") || r.source_url.includes(".privacy.org.nz"),
      `source URL must be official government or regulator domain: ${r.source_url}`
    );
    assert.ok(r.checked_on, "rule must indicate checked_on date");
  }
});

test("loadCountryPack rejects unknown country pack without silent fallback", () => {
  assert.throws(
    () => loadCountryPack("xx_unknown"),
    /Unknown country pack/,
    "must throw explicit error for unknown jurisdiction"
  );
});

test("evaluateCountryPolicy enforces NZ IRD GST Section 24 invoice thresholds", () => {
  // Over $1000 without buyer GST -> rejected
  const resOverWithoutGst = evaluateCountryPolicy("invoice.create", {
    amount_nzd: 1500,
    buyer_gst_number: ""
  }, "nz");
  assert.equal(resOverWithoutGst.approved, false);
  assert.equal(resOverWithoutGst.ruleId, "NZ-IRD-GST-001");
  assert.ok(resOverWithoutGst.source_url.includes("ird.govt.nz"));

  // Over $1000 with buyer GST -> approved
  const resOverWithGst = evaluateCountryPolicy("invoice.create", {
    amount_nzd: 1500,
    buyer_gst_number: "123-456-789"
  }, "nz");
  assert.equal(resOverWithGst.approved, true);

  // Under $1000 without buyer GST -> approved
  const resUnder = evaluateCountryPolicy("invoice.create", {
    amount_nzd: 450,
    buyer_gst_number: ""
  }, "nz");
  assert.equal(resUnder.approved, true);
});

test("evaluateCountryPolicy enforces Privacy Act 2020 IPP 5 data security", () => {
  // PII without encryption -> rejected
  const resUnencrypted = evaluateCountryPolicy("customer.sync", {
    contains_pii: true,
    encrypted: false
  }, "nz");
  assert.equal(resUnencrypted.approved, false);
  assert.equal(resUnencrypted.ruleId, "NZ-PRIV-005");
  assert.ok(resUnencrypted.source_url.includes("privacy.org.nz"));

  // PII with encryption -> approved
  const resEncrypted = evaluateCountryPolicy("customer.sync", {
    contains_pii: true,
    encrypted: true
  }, "nz");
  assert.equal(resEncrypted.approved, true);
});

test("evaluateCountryPolicy enforces NZISM Section 16.1.1 privileged access control", () => {
  // Privileged action without MFA -> rejected
  const resNoMfa = evaluateCountryPolicy("infra.deploy", {
    privileged: true,
    mfa_verified: false
  }, "nz");
  assert.equal(resNoMfa.approved, false);
  assert.equal(resNoMfa.ruleId, "NZ-NZISM-1611");
  assert.ok(resNoMfa.source_url.includes("nzism.gcsb.govt.nz"));

  // Privileged action with MFA -> approved
  const resWithMfa = evaluateCountryPolicy("infra.deploy", {
    privileged: true,
    mfa_verified: true
  }, "nz");
  assert.equal(resWithMfa.approved, true);
});
