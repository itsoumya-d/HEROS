/**
 * Incident blast-radius diagnostics and AI engineering delivery flywheel analytics.
 * Answers what failed, who/what was affected, why it failed, and how to tighten agent/CI safeguards.
 */

const CAUSE_RULES = [
  {
    match: /(approval|forbidden|unauthorized|permission|eacces|auth|scope)/i,
    category: "permission_boundary",
    guardrail: "Tighten least-privilege tool allowlists and pre-flight capability checks before agent execution."
  },
  {
    match: /(schema|validation|invalid_input|typeerror|contract|required property)/i,
    category: "schema_contract",
    guardrail: "Enforce strict JSON-schema input/output contracts and fail-closed parser assertions in CI."
  },
  {
    match: /(timeout|etimedout|rate_limit|429|oom|saturation|pool exhausted)/i,
    category: "capacity_timeout",
    guardrail: "Bound concurrency, add circuit breakers, and enforce bounded backoff timeouts per downstream call."
  },
  {
    match: /(econnrefused|enotfound|502|503|upstream|dependency)/i,
    category: "dependency_outage",
    guardrail: "Isolate external calls behind idempotent outbox retries and synthetic health probes."
  }
];

/**
 * Attribute a failed span/trace to what failed, whom it affected, and root cause + recommended safeguard.
 */
export function diagnoseIncidentSpan(span) {
  if (!span || typeof span !== "object") {
    throw new TypeError("span must be a non-null object");
  }
  const service = span.service || "unknown-service";
  const operation = span.operation || "unknown-operation";
  const errorCode = span.errorCode || "UNKNOWN_ERROR";
  const message = String(span.message || "");
  const affectedTenants = Array.isArray(span.affectedTenants)
    ? [...new Set(span.affectedTenants.filter(Boolean))].sort()
    : [];
  const affectedUsersCount = Number.isFinite(span.affectedUsersCount) ? Math.max(0, span.affectedUsersCount) : 0;

  const matched = CAUSE_RULES.find((r) => r.match.test(`${errorCode} ${message}`));
  const rootCauseCategory = matched ? matched.category : "runtime_defect";
  const recommendedGuardrail = matched
    ? matched.guardrail
    : "Add a deterministic regression test and structured failure telemetry field for this code path.";

  const blastRadius =
    affectedTenants.length >= 3 || affectedUsersCount >= 100
      ? "high"
      : affectedTenants.length >= 1 || affectedUsersCount >= 10
        ? "medium"
        : "low";

  return {
    whatFailed: {
      service,
      operation,
      errorCode,
      message: message.slice(0, 200)
    },
    whoAffected: {
      tenants: affectedTenants,
      usersCount: affectedUsersCount,
      blastRadius
    },
    why: {
      rootCauseCategory,
      recommendedGuardrail
    }
  };
}

function percentile(sortedValues, p) {
  if (sortedValues.length === 0) return 0;
  const idx = Math.min(sortedValues.length - 1, Math.floor((sortedValues.length - 1) * p));
  return sortedValues[idx];
}

/**
 * Compute delivery/diagnosis timing percentiles and rank repeatable flywheel safeguards across incidents.
 */
export function computeDeliveryFlywheel(runs = [], spans = []) {
  const leadTimes = runs.map((r) => r.leadTimeSeconds).filter((n) => Number.isFinite(n) && n >= 0).sort((a, b) => a - b);
  const diagTimes = runs.map((r) => r.diagnoseTimeSeconds).filter((n) => Number.isFinite(n) && n >= 0).sort((a, b) => a - b);
  const failedRuns = runs.filter((r) => r.failed === true).length;

  const grouped = new Map();
  for (const span of spans) {
    const diag = diagnoseIncidentSpan(span);
    const key = `${diag.why.rootCauseCategory}::${diag.whatFailed.service}`;
    const existing = grouped.get(key) || {
      category: diag.why.rootCauseCategory,
      service: diag.whatFailed.service,
      occurrences: 0,
      maxBlastRadius: "low",
      guardrail: diag.why.recommendedGuardrail
    };
    existing.occurrences += 1;
    const rank = { low: 0, medium: 1, high: 2 };
    if (rank[diag.whoAffected.blastRadius] > rank[existing.maxBlastRadius]) {
      existing.maxBlastRadius = diag.whoAffected.blastRadius;
    }
    grouped.set(key, existing);
  }

  const flywheelActions = [...grouped.values()].sort((a, b) => b.occurrences - a.occurrences || a.service.localeCompare(b.service));
  return {
    totalRuns: runs.length,
    changeFailureRate: runs.length > 0 ? Number((failedRuns / runs.length).toFixed(4)) : 0,
    leadTimeP50Seconds: percentile(leadTimes, 0.5),
    leadTimeP95Seconds: percentile(leadTimes, 0.95),
    diagnoseTimeP50Seconds: percentile(diagTimes, 0.5),
    diagnoseTimeP95Seconds: percentile(diagTimes, 0.95),
    flywheelActions
  };
}
