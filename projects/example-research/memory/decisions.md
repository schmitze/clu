---
last_verified: 2026-03-13
abstract: "One decision: bash over Python for launcher."
scope: project
type: decisions
---

# Decisions

### DEC-001 – Use bash for launcher, not Python
- **Date:** 2026-03-13
- **Status:** accepted
- **Context:** Needed a language for the launcher script
- **Decision:** Bash — zero dependencies, runs everywhere
- **Alternatives considered:** Python (more readable but adds dependency), Go (compiled binary but overkill)
- **Consequences:** Slightly harder to maintain complex logic; may revisit if the launcher grows significantly
