## 2024-05-16 - RegExp Recompilation in Hot Paths
**Learning:** In highly recursive schemas or frequently called validation functions, dynamically instantiating `new RegExp(pattern)` for the same schema pattern incurs significant compilation overhead.
**Action:** Always cache and reuse RegExp objects for statically defined schema patterns to avoid repetitive recompilation bottlenecks.
