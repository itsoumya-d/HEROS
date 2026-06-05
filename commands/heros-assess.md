---
description: Risk-assess an operation with HEROS guardian before running it
argument-hint: "[describe the operation, e.g. 'delete /etc/hosts']"
---

Use the `heros-guardian` MCP server's `guardian_assess` tool to risk-score the
operation the user describes **before** it is executed.

Operation to assess: $ARGUMENTS

Steps:
1. Map the description to a `guardian_assess` call: pick the closest
   `operation_type` (`file_system`, `shell_command`, `network_request`,
   `infrastructure`, `code_execution`, or `data_access`) and build the
   `operation` object (action, target/path, etc.).
2. Call `guardian_assess`. Report the `risk_tier`, `risk_score`, and whether
   `decision_required` is true.
3. If `decision_required` is true, explain that a HIGH/CRITICAL operation needs
   human sign-off: the first call returns an `approval_nonce`; the same operation
   must be re-submitted with `human_acknowledgment_token` set to that nonce
   (single-use, 5-min TTL) to proceed. Do **not** auto-approve — surface the
   nonce and prompt the human.
4. Never run the underlying operation yourself as part of assessing it.
