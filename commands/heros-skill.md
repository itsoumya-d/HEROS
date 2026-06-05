---
description: Propose, promote, or list HEROS evolve skills (gated self-improvement)
argument-hint: "[propose|promote|list] [skill name or description]"
---

Use the `heros-evolve` MCP server to drive the gated self-improvement loop. A
proposed skill is inert until it is **promoted**, and promotion is a
decision-required action that needs human sign-off.

Request: $ARGUMENTS

Routing:
- **propose** → call `evolve_skill_propose` with `name` (`[a-z][a-z0-9_]*`),
  `trigger` (when it should fire), and `steps` (ordered list). The new skill
  lands in `pending` state.
- **promote** → call `evolve_skill_promote` with the skill `name`. The first call
  returns `decision_required: true` plus an `approval_nonce`. Surface the nonce to
  the human; only on their go-ahead call `evolve_skill_promote` again with
  `human_acknowledgment_token` set to that nonce. On success the skill becomes
  `active`. Never self-approve a promotion.
- **list** → call `evolve_skill_list` and show each skill's name, state,
  successes/total, and score.

After any change, mention that the change is recorded in the tamper-evident audit
log (verify with `/heros-audit-verify`).
