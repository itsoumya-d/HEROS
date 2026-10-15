## 2024-05-24 - Interactive Element A11y and Contrast

**Learning:** When reviewing this application's custom static CSS, the `--muted` text variable (`#666`) against the dark background (`#0a0a0a`) had insufficient contrast for WCAG standards, and interactive elements (like the navigation logo, links, and buttons) completely lacked `:focus-visible` indicators, rendering keyboard navigation invisible to users.

**Action:** Update the `--muted` variable to `#999` for compliant contrast on dark backgrounds. Add a global `a:focus-visible, .btn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }` rule, and ensure application logos that function as home buttons are properly wrapped in anchor tags with `color: inherit; text-decoration: none;` to inherit the focus styling without breaking the existing visual design.
