---
last_verified: 2026-03-13
abstract: "One finding: no agent framework has structured memory out of the box."
scope: project
type: findings
---

# Findings

### FND-001 – Most agent frameworks lack structured memory
- **Date:** 2026-03-13
- **Source:** Survey of Claude Code, Aider, Cursor, OpenClaw docs
- **Finding:** None of the major frameworks automatically categorize conversation outcomes into structured memory. All use flat file or append-only approaches.
- **Confidence:** high
- **Implications:** A memory management layer must be built on top, not expected from the framework itself.
