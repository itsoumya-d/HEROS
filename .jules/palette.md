## 2024-05-30 - Missing Focus Styles
**Learning:** Static HTML landing pages often lack explicit `:focus-visible` styles for basic interactive elements (links, buttons), degrading keyboard accessibility because default browser outlines might be insufficient or overridden.
**Action:** Always verify keyboard navigation and add `outline` and `outline-offset` to `:focus-visible` pseudo-classes for interactive elements like `a` and `.btn`.
