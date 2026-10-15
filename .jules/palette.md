## 2024-05-18 - Keyboard Navigation Polish
**Learning:** The HEROS static landing page lacks custom focus states, relying on default browser outlines which may have poor contrast against the `#0a0a0a` background.
**Action:** Always define explicit `:focus-visible` states using theme variables (e.g., `--accent`) to ensure keyboard navigability is clearly visible and matches the design system.
