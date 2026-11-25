import test from "node:test";
import assert from "node:assert/strict";
import { computeDeliveryFlywheel, diagnoseIncidentSpan } from "../src/flywheel-diagnostics.js";

test("diagnoseIncidentSpan answers what failed, who affected, and root cause guardrail", () => {
  const report = diagnoseIncidentSpan({
    service: "assessment-api",
    operation: "generate_feedback",
    errorCode: "APPROVAL_REQUIRED",
    message: "Tool permission boundary denied write operation without approval token",
    affectedTenants: ["school-nz", "school-au", "school-uk"],
    affectedUsersCount: 142
  });

  assert.deepEqual(report.whatFailed, {
    service: "assessment-api",
    operation: "generate_feedback",
    errorCode: "APPROVAL_REQUIRED",
    message: "Tool permission boundary denied write operation without approval token"
  });
  assert.deepEqual(report.whoAffected, {
    tenants: ["school-au", "school-nz", "school-uk"],
    usersCount: 142,
    blastRadius: "high"
  });
  assert.equal(report.why.rootCauseCategory, "permission_boundary");
  assert.match(report.why.recommendedGuardrail, /least-privilege/);
});

test("computeDeliveryFlywheel aggregates DORA lead/MTTR percentiles and prioritizes recurring flywheel gaps", () => {
  const runs = [
    { leadTimeSeconds: 300, diagnoseTimeSeconds: 45, failed: false },
    { leadTimeSeconds: 600, diagnoseTimeSeconds: 90, failed: true },
    { leadTimeSeconds: 1200, diagnoseTimeSeconds: 180, failed: false },
    { leadTimeSeconds: 2400, diagnoseTimeSeconds: 360, failed: true }
  ];
  const spans = [
    { service: "worker-eval", operation: "parse", errorCode: "INVALID_INPUT", message: "schema validation error", affectedTenants: ["t1"], affectedUsersCount: 5 },
    { service: "worker-eval", operation: "parse", errorCode: "INVALID_INPUT", message: "required property missing", affectedTenants: ["t2"], affectedUsersCount: 12 },
    { service: "billing", operation: "sync", errorCode: "ETIMEDOUT", message: "upstream timeout", affectedTenants: ["t1"], affectedUsersCount: 2 }
  ];

  const summary = computeDeliveryFlywheel(runs, spans);
  assert.equal(summary.totalRuns, 4);
  assert.equal(summary.changeFailureRate, 0.5);
  assert.equal(summary.leadTimeP50Seconds, 600);
  assert.equal(summary.diagnoseTimeP95Seconds, 180);
  assert.equal(summary.flywheelActions[0].category, "schema_contract");
  assert.equal(summary.flywheelActions[0].occurrences, 2);
  assert.equal(summary.flywheelActions[0].maxBlastRadius, "medium");
});
