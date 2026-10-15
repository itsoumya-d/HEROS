## 2024-06-25 - Improved Focus Accessibility and Contrast
**Learning:** Hardcoded `#666` gray fails WCAG text contrast on dark backgrounds (ratio ~3.4:1), while custom CSS resets often strip native browser focus outlines.
**Action:** Use `#a3a3a3` for muted text on dark mode (`#0a0a0a`) and ensure `a:focus-visible` / `.btn:focus-visible` are explicitly restored.
