## 2026-06-05 - Add Keyboard Focus & Transitions
**Learning:** This app's static HTML lacks explicit `:focus-visible` styling and interaction feedback, making keyboard navigation and button interactions feel unresponsive and hard to follow.
**Action:** Adding a global `*:focus-visible` outline using the app's accent color dramatically improves keyboard accessibility with very little code. Adding smooth CSS `transition` for `a` tag colors and `.btn` classes (along with a `.btn:active` scale transform) significantly improves the tactile feel of the UI.
