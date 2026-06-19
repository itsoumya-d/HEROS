## 2026-06-10 - Focus States and Clickable Logos
**Learning:** Found that the main application logo was unclickable and interactive elements lacked explicit `:focus-visible` styling, hindering keyboard navigation and general discoverability.
**Action:** When working on new frontend interfaces, always ensure the main application logo is wrapped in an anchor tag linking to the root path `/` and explicitly define `:focus-visible` CSS rules for all interactive elements like links and buttons to ensure clear keyboard tab-navigation accessibility.
