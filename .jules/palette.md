## 2024-05-24 - Missing global focus visible states
**Learning:** The HEROS static landing page lacked a global `:focus-visible` styling, which resulted in invisible focus when navigating using the Tab key. This makes the interface inaccessible to keyboard users and screen readers navigating linearly.
**Action:** Always ensure that global focus states exist (e.g. by checking `index.html` CSS) before concluding there's no low-hanging accessibility fruit. Using `:focus-visible` with `outline-offset` is an effective, non-intrusive fix.
