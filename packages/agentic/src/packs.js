import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Resolve root repository path.
 */
function defaultPacksDir() {
  return path.resolve(__dirname, "../../../packs");
}

/**
 * Load and validate a country pack.
 *
 * @param {string} [country='nz'] - Two-letter ISO country code.
 * @param {string} [customDir=null] - Optional override directory for packs.
 * @returns {Array<object>} Array of validated rule objects.
 */
export function loadCountryPack(country = "nz", customDir = null) {
  if (!country || typeof country !== "string") {
    throw new Error("Country code must be a non-empty string");
  }
  const code = country.toLowerCase().trim();
  const baseDir = customDir || defaultPacksDir();
  const filePath = path.join(baseDir, code, "rules.json");

  if (!fs.existsSync(filePath)) {
    throw new Error(`Unknown country pack: ${country}. Pack rules file not found at ${filePath}`);
  }

  const raw = fs.readFileSync(filePath, "utf-8");
  const rules = JSON.parse(raw);

  if (!Array.isArray(rules) || rules.length === 0) {
    throw new Error(`Country pack ${country} contains no valid rules`);
  }

  for (const r of rules) {
    if (!r.id || !r.what_it_decides || !r.values || !r.source_url || !r.checked_on) {
      throw new Error(`Invalid rule definition in ${country} pack: missing mandatory fields`);
    }
    if (!r.source_url.startsWith("https://")) {
      throw new Error(`Rule ${r.id} source_url must be HTTPS official URL`);
    }
  }

  return rules;
}

/**
 * Evaluate action payload against jurisdiction compliance rules.
 *
 * @param {string} actionName
 * @param {object} payload
 * @param {string} [country='nz']
 * @param {object} [options={}]
 * @returns {{ approved: boolean, reason?: string, ruleId?: string, source_url?: string }}
 */
export function evaluateCountryPolicy(actionName, payload = {}, country = "nz", options = {}) {
  const rules = loadCountryPack(country, options.packsDir);

  if (country.toLowerCase() === "nz") {
    // 1. Check Privacy Act 2020 IPP 5 (Storage & Security)
    const privRule = rules.find((r) => r.id === "NZ-PRIV-005");
    if (privRule && payload.contains_pii && payload.encrypted !== true) {
      return {
        approved: false,
        ruleId: privRule.id,
        reason: "Personal identifiable information (PII) must be encrypted per Privacy Act 2020 IPP 5",
        source_url: privRule.source_url
      };
    }

    // 2. Check IRD GST Act 1985 Section 24 (Tax Invoices > $1,000)
    const gstRule = rules.find((r) => r.id === "NZ-IRD-GST-001");
    if (gstRule && payload.amount_nzd && payload.amount_nzd > gstRule.values.tax_invoice_threshold_nzd) {
      if (gstRule.values.require_buyer_gst_over_threshold && !payload.buyer_gst_number) {
        return {
          approved: false,
          ruleId: gstRule.id,
          reason: `Transactions exceeding NZD ${gstRule.values.tax_invoice_threshold_nzd} require buyer GST number per IRD Section 24`,
          source_url: gstRule.source_url
        };
      }
    }

    // 3. Check NZISM Section 16.1.1 (Privileged access MFA)
    const nzismRule = rules.find((r) => r.id === "NZ-NZISM-1611");
    if (nzismRule && payload.privileged === true && payload.mfa_verified !== true) {
      return {
        approved: false,
        ruleId: nzismRule.id,
        reason: "Privileged infrastructure action requires multi-factor authentication per NZISM Section 16.1.1",
        source_url: nzismRule.source_url
      };
    }

    // 4. Check Algorithm Charter (High impact decisions require human audit trail)
    const ethRule = rules.find((r) => r.id === "NZ-DATA-ETH-001");
    if (ethRule && payload.high_impact === true && payload.human_review_logged !== true) {
      return {
        approved: false,
        ruleId: ethRule.id,
        reason: "High-impact automated decision requires logged human oversight per Algorithm Charter",
        source_url: ethRule.source_url
      };
    }
  }

  if (country.toLowerCase() === "ca") {
    // 1. Check PIPEDA Principle 7 (Safeguarding Personal Information)
    const privRule = rules.find((r) => r.id === "CA-PIPEDA-007");
    if (privRule && payload.contains_pii && payload.encrypted !== true) {
      return {
        approved: false,
        ruleId: privRule.id,
        reason: "Personal identifiable information (PII) must be encrypted per PIPEDA Principle 7",
        source_url: privRule.source_url
      };
    }

    // 2. Check CRA GST/HST Invoicing Rules (Threshold CAD 150)
    const gstRule = rules.find((r) => r.id === "CA-CRA-GST-001");
    if (gstRule && payload.amount_cad && payload.amount_cad > gstRule.values.tax_invoice_threshold_cad) {
      if (gstRule.values.require_buyer_name_over_threshold && !payload.buyer_name) {
        return {
          approved: false,
          ruleId: gstRule.id,
          reason: `Transactions exceeding CAD ${gstRule.values.tax_invoice_threshold_cad} require buyer name and details per CRA invoicing rules`,
          source_url: gstRule.source_url
        };
      }
    }

    // 3. Check CCCS ITSG-33 / Top 10 Security Action #2 (Privileged Access MFA)
    const mfaRule = rules.find((r) => r.id === "CA-CCCS-MFA-002");
    if (mfaRule && payload.privileged === true && payload.mfa_verified !== true) {
      return {
        approved: false,
        ruleId: mfaRule.id,
        reason: "Privileged infrastructure action requires multi-factor authentication per CCCS ITSG-33 Action #2",
        source_url: mfaRule.source_url
      };
    }

    // 4. Check TBS Directive on Automated Decision-Making (Section 6.3 Human Oversight)
    const admRule = rules.find((r) => r.id === "CA-TBS-ADM-001");
    if (admRule && payload.high_impact === true && payload.human_review_logged !== true) {
      return {
        approved: false,
        ruleId: admRule.id,
        reason: "High-impact automated decision requires logged human oversight per TBS Directive on Automated Decision-Making",
        source_url: admRule.source_url
      };
    }
  }

  return { approved: true };
}
