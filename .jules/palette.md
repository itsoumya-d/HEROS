## 2024-05-18 - Improve keyboard accessibility and contrast
**Learning:** Found that custom buttons and links lack focus-visible outlines, which hurts keyboard navigation. Also, the muted text color (#666) did not meet WCAG AA contrast ratio against the dark background (#0a0a0a).
**Action:** Always ensure `:focus-visible` styles are globally applied to interactive elements like `a` and `.btn`. Check and update contrast ratios for text on dark backgrounds to meet 4.5:1.
