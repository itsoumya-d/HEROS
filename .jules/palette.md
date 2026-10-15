## 2024-05-15 - Improve Focus and Contrast for A11y
 **Learning:** Hardcoded `#666` for muted text fails the 4.5:1 WCAG contrast ratio on a `#0a0a0a` background. Interactive elements missed `:focus-visible` styling, hindering keyboard accessibility. The app logo lacked a semantic anchor wrapper.
 **Action:** Always ensure dark-mode text meets WCAG contrast (e.g., `#888` instead of `#666`), globally apply `:focus-visible` on interactive tags (`a, button, input`), and wrap logos in anchors linking to the root path.
