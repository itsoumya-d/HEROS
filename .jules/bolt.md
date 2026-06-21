## 2024-05-15 - Cache Compiled Regular Expressions
**Learning:** Re-compiling RegExp objects for the same schema pattern on every validation is a measurable bottleneck.
**Action:** Use a Map to cache compiled RegExp objects keyed by the pattern string for faster regex tests.
