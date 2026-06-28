## 2024-05-18 - Avoid intermediate arrays in hot paths
**Learning:** Using `Object.entries().sort().map()` or `Array.prototype.map()` in high-throughput data processing (like JSON canonicalization/hashing) causes significant overhead due to intermediate array allocations.
**Action:** Use simple `for` loops, pre-allocate arrays where possible, and prefer `Object.keys().sort()` over `Object.entries()` in performance-critical code to reduce garbage collection pressure and improve execution speed by >40%.
