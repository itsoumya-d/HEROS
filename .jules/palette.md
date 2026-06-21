## 2024-06-21 - Accessible Links and Focus States
**Learning:** Interactive elements require explicit `:focus-visible` indicators for keyboard users, brand logos should intuitively act as home links, and `#666` muted text on `#0a0a0a` fails WCAG AA contrast ratios.
**Action:** Ensure all clickable components (like logos) use semantic `<a>` or `<button>` tags, globally define `:focus-visible` outlines, and select `--muted` colors meeting at least a 4.5:1 contrast ratio.
