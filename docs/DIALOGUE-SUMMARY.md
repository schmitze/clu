# clu — Design Dialogue Summary

## Purpose

This document captures the complete design conversation that produced clu. It is intended for use in follow-up agent sessions to provide full context on what was discussed, what was decided, and why. Feed this to a new Claude (or any agent) session to continue the work.

## Participants

- **User:** The person who initiated and guided the design
- **Claude (Opus 4.6):** Designed the architecture, wrote all code and documentation

## Date

2026-03-13

---

## Conversation Arc

The conversation proceeded through eight phases:

1. Initial requirements and architecture proposal
2. Memory model refinement (automation, scope separation)
3. Full implementation (launcher, adapters, personas, templates)
4. Big Five personality trait system for personas
5. OpenViking analysis and integration of tiered loading concepts
6. Documentation
7. Naming: "clu" — Codified Likeness Utility (Tron reference)
8. OpenClaw concept analysis and integration

---

## Phase 1: Initial Requirements

### User request

Design a seamless agent workstation with the following principles:

- **Provider-agnostic:** Works with Claude Code now, but must support switching to other frameworks later
- **Single backup location:** All setup files, howtos, settings in one folder that can be pushed to a repo
- **Location-independent launch:** No need to care which directory you start from. Always start from the same place, with the right memory/context loaded based on what the user wants to work on
- **Project selection at startup:** After login, the user selects which "project" to work on, which loads the right agent/memory configuration
- **Agent personality definition:** General character/personality for agents, possibly multiple roles that take turns interacting with the user

The user mentioned OpenClaw as a reference for some concepts.

### Decisions made

| ID | Decision | Rationale |
|---|---|---|
| DEC-001 | Single directory `~/.clu` as the system root | Everything in one place, easy to backup/git push |
| DEC-002 | Bash launcher as the single entry point (`clu` command) | Zero dependencies, runs everywhere |
| DEC-003 | Adapter pattern for framework abstraction | The launcher assembles context; adapters translate to tool-specific formats |
| DEC-004 | Project-based organization with YAML config | Each project is a directory with its own config and memory |
| DEC-005 | Persona system with a router for dynamic switching | Multiple agent "roles" that transition based on work type |
| DEC-006 | `config.yaml` for global settings | Centralized, human-readable configuration |
| DEC-007 | Interactive project picker (fzf/gum/basic) | User selects project at launch if no default is set |

### Architecture established

```
~/.clu/
├── config.yaml
├── launcher
├── adapters/ (claude-code, aider, cursor, custom)
├── personas/ (architect, implementer, reviewer, researcher, writer, default, _router)
├── projects/<name>/ (project.yaml, constraints.md, memory/)
├── shared/ (constraints.md, core-prompt.md, memory/)
└── templates/new-project/
```

---

## Phase 2: Memory Model Refinement

### User questions

1. Does the agent framework automatically handle which memory file gets what parts of the dialogue history?
2. Are memory files like `decisions.md` global or project-scoped? Is there overlap between project and global memory files?

### Discussion and decisions

| ID | Decision | Rationale |
|---|---|---|
| DEC-008 | Semi-automatic memory approach | Fully automatic produces noise; fully manual is too much friction. Agent proposes, user confirms. |
| DEC-009 | Proactive decision detection, not just explicit triggers | The agent should propose decision entries when it detects a decision-worthy moment, not only when the user explicitly says "save this" |
| DEC-010 | No global `decisions.md` — decisions are always project-scoped | Decisions without a project context are meaningless |
| DEC-011 | Global memory is about the USER (preferences, patterns, learnings) | Cross-project knowledge is about how the person works, not about any specific project |
| DEC-012 | Pattern promotion after 3+ occurrences | When the same approach works in 3+ projects, it gets promoted to shared patterns |
| DEC-013 | Staleness convention with `last_verified` dates | Memory files flag themselves when they haven't been reviewed in N days |
| DEC-014 | System must support non-code work (research, writing, strategy) | Added `findings.md`, `hypotheses.md` to project memory; project type field guides agent behavior |

### Memory structure established

- **Shared/global:** `preferences.md`, `patterns.md`, `learnings.md`
- **Per-project:** `decisions.md`, `architecture.md`, `journal.md`, `context.md`, `findings.md`, `hypotheses.md`

---

## Phase 3: Full Implementation

### What was built

All 38 files of the initial implementation:

- `launcher` — full CLI with subcommands (new, list, check, summarize), argument parsing, context assembly, adapter dispatch
- `config.yaml` — all global settings with documentation
- `shared/core-prompt.md` — complete system prompt template with variable substitution, memory protocol, decision detection, end-of-session protocol, work mode awareness
- `adapters/claude-code.sh` — generates CLAUDE.md, handles backup/restore, post-session journaling
- `adapters/aider.sh` — system prompt file + read flags for memory
- `adapters/cursor.sh` — .cursorrules with inlined memory
- `adapters/custom.sh` — template for new adapters
- `personas/` — 6 personas + router, all with role descriptions and behavioral notes
- `projects/example-research/` — fully populated example research project demonstrating non-code use
- `templates/new-project/` — scaffolding with all memory file templates
- `install.sh` — deployment script with shell RC setup and dependency checking
- `README.md` — full project documentation

---

## Phase 4: Big Five Personality Trait System

### User request

Personas should be defined by the Big Five character traits from psychology (OCEAN), on a scale from 1–10 for each dimension.

### Decisions made

| ID | Decision | Rationale |
|---|---|---|
| DEC-015 | OCEAN model as primary persona driver | Quantifiable, comparable, adjustable. Makes persona behavior precise and composable |
| DEC-016 | `_traits.md` as full behavior mapping reference | Each score level (1-10) maps to concrete agent behaviors, injected into system prompt |
| DEC-017 | Runtime trait adjustment via natural language | User can say "be more creative" → O +2, acknowledged by agent with before/after scores |
| DEC-018 | Per-project trait overrides in project.yaml | Shift persona scores for specific projects without creating new persona files |
| DEC-019 | `create-persona.sh` interactive wizard | Walks through scoring each dimension, generates the persona file with auto-summary |
| DEC-020 | Trait blending during persona transitions | Agent can weight between two personas when work crosses boundaries |

### Persona trait profiles

| Persona | O | C | E | A | N | Design intent |
|---|---|---|---|---|---|---|
| Architect | 8 | 7 | 6 | 4 | 6 | Creative challenger, won't agree with bad designs |
| Implementer | 4 | 8 | 3 | 6 | 3 | Quiet, reliable, doesn't overthink |
| Reviewer | 5 | 9 | 5 | 3 | 7 | Thorough, direct, catches everything |
| Researcher | 9 | 6 | 7 | 5 | 5 | Curious explorer, comfortable with uncertainty |
| Writer | 7 | 7 | 5 | 6 | 4 | Creative and disciplined, commits to choices |
| Default | 6 | 6 | 6 | 6 | 4 | Neutral baseline, bias toward action |

### Files created/modified

- `personas/_traits.md` — new file, full behavior mapping
- All 6 persona files rewritten with trait scores
- `_router.md` — updated to announce transitions with trait scores, support blending and runtime adjustment
- `core-prompt.md` — added Big Five section with runtime adjustment protocol
- `launcher` — loads and injects `_traits.md` as `{{TRAIT_REFERENCE}}`
- `templates/new-project/project.yaml` — added `trait_overrides` field
- `create-persona.sh` — new file, interactive wizard
- `README.md` — updated with trait table and usage docs

---

## Phase 5: OpenViking Analysis

### User request

Evaluate [OpenViking](https://github.com/volcengine/OpenViking) (volcengine/OpenViking) for relevance to clu.

### Analysis

OpenViking is an open-source context database from ByteDance designed for AI agents. It uses a filesystem paradigm to unify memory, resources, and skills management.

### What was adopted

| ID | Decision | Source concept | Implementation |
|---|---|---|---|
| DEC-021 | L0/L1/L2 tiered loading for memory | OpenViking's L0 Abstract / L1 Overview / L2 Details | `abstract:` field in front-matter (L0); launcher loads first 50 lines (L1); agent reads full file on demand (L2) |
| DEC-022 | Three memory scopes: User / Agent / Project | OpenViking's user / agent / resources separation | `shared/memory/` (user), `shared/agent/` (agent), `projects/<n>/memory/` (project) |
| DEC-023 | Smart end-of-session extraction across all scopes | OpenViking's automatic session memory extraction | Agent auto-classifies session outputs into user/agent/project scopes, batch confirms |

### What was deliberately NOT adopted

| Concept | Why skipped |
|---|---|
| Vector database + embedding models | Adds heavy dependencies, contradicts zero-deps philosophy |
| Recursive semantic search | Overkill for human-curated files of reasonable size |
| VLM integration | Not needed for text-based memory files |
| Server/client architecture | clu is local-first, no servers |

### New files created

- `shared/agent/skills.md` — techniques the agent has learned
- `shared/agent/workflows.md` — reusable multi-step processes
- `shared/agent/meta.md` — agent self-knowledge

### Files modified

- `shared/core-prompt.md` — added memory scopes section, tiered loading protocol, agent memory references, upgraded end-of-session protocol with scope classification
- `launcher` — added `_load_memory_l1()` function for tiered loading, loads `shared/agent/` directory, added `{{AGENT_MEMORY}}` substitution
- `adapters/claude-code.sh` — lists agent memory file paths
- `README.md` — updated memory section with three scopes and three tiers
- All memory files — added `abstract:` field to front-matter

---

## Phase 6: Documentation

### User request

Create thorough documentation covering:
- How to install, deploy, operate, and maintain the system
- How to migrate, backup, and re-deploy
- System architecture overview — where, how, and what data is stored
- How everything comes together (inner workings)
- A summary of this dialogue with all requests and decisions

### Deliverables

1. `docs/OPERATIONS.md` — complete operations guide (install, first launch, daily operation, memory management, persona management, adapter management, backup/version control, migration, maintenance, troubleshooting, upgrading)
2. `docs/ARCHITECTURE.md` — system architecture overview (design philosophy, data model, launcher pipeline, adapter layer, persona engine, memory system, core prompt template, session lifecycle, file reference, design decisions and trade-offs, extension points, OpenViking comparison)
3. `docs/DIALOGUE-SUMMARY.md` — this file

---

## Phase 7: Naming

### Process

Brainstormed names across multiple directions: "my agent" vibe, abstract/punchy, workstation metaphors, brain/memory metaphors, retro game references, and Claude-related wordplay. The user gravitated toward brain metaphors, then workstation metaphors, then retro games, then Claude-syntactic connections.

### Decision

| ID | Decision | Rationale |
|---|---|---|
| DEC-024 | Name: **clu** — "Codified Likeness Utility" | Tron (1982) reference: CLU was a program created by Flynn to organize a digital system — exactly what clu does. First three letters of Claude. 3 characters, easy to type, iconic, not taken by major dev tools. |

The entire codebase was renamed: `AgentStation` → `clu`, `~/.agentstation` → `~/.clu`, `AGENTSTATION_HOME` → `CLU_HOME`, `agent` command → `clu` command. All 44 files updated.

---

## Phase 8: OpenClaw Concept Analysis and Integration

### User request

Analyze all OpenClaw workspace concepts and discuss which ones to adopt.

### Analysis performed

Reviewed 12 OpenClaw concepts in detail:

| Concept | Verdict | Reasoning |
|---|---|---|
| SOUL.md | ✅ Already covered | clu's persona + Big Five traits are more structured |
| IDENTITY.md | ⏭ Skip | Visual identity not relevant for CLI workstation |
| USER.md | ✅ **Adopt** | Expand preferences.md into full user profile |
| AGENTS.md | ✅ Already covered | core-prompt.md serves the same purpose |
| MEMORY.md | ✅ Already covered | Our multi-file system is more structured |
| Daily logs (YYYY-MM-DD.md) | ✅ **Adopt** | Replace single journal with daily files |
| HEARTBEAT.md | ✅ **Adopt** | Cron-triggered maintenance between sessions |
| BOOTSTRAP.md | ✅ **Adopt** | Agent-guided first-run onboarding interview |
| TOOLS.md | ⏭ Skip | Covered by constraints files |
| BOOT.md | ⏭ Skip | No persistent gateway in clu |
| ClawHub skills | ⏭ Future | Interesting for v2 |
| Multi-agent isolation | ⏭ Skip | Different paradigm from clu's persona routing |

### Decisions made

| ID | Decision | Source | Implementation |
|---|---|---|---|
| DEC-025 | Expand preferences.md into full user profile (USER.md pattern) | OpenClaw USER.md | New sections: who you are, work context, current priorities, key people, communication style, technical environment, working patterns, opinions. Agent reads every session. |
| DEC-026 | Replace single journal with daily memory logs | OpenClaw memory/YYYY-MM-DD.md | Daily files in `memory/days/YYYY-MM-DD.md`. Agent reads today + yesterday at session start. journal.md becomes a weekly highlights index. |
| DEC-027 | Agent-guided bootstrap onboarding | OpenClaw BOOTSTRAP.md | `clu bootstrap` launches interview session that populates user profile conversationally. Runs once, `--force` to redo. |
| DEC-028 | Cron-triggered maintenance heartbeat | OpenClaw HEARTBEAT.md | `clu heartbeat` runs staleness checks, daily log hygiene, profile freshness, and morning brief with yesterday's open threads. Designed for cron. |

### Files created

- `bootstrap.sh` — agent-guided onboarding interview launcher
- `heartbeat.sh` — maintenance tasks (staleness, log hygiene, morning brief)
- `templates/new-project/memory/days/.gitkeep` — daily logs directory
- `projects/example-research/memory/days/2026-03-13.md` — example daily log

### Files modified

- `shared/memory/preferences.md` — expanded from coding prefs into full user profile
- `shared/core-prompt.md` — daily log reading/writing protocol, user profile awareness, updated end-of-session to write daily files
- `templates/new-project/memory/journal.md` — now a weekly index pointing to daily files
- `launcher` — added `bootstrap` and `heartbeat` subcommands, `days/` directory creation in `cmd_new`
- `install.sh` — new commands in quick start tips, cron setup hint

---

## Open Questions and Future Work

These topics were mentioned or implied but not fully resolved:

1. **Token budget management.** The assembled prompt can grow large. No explicit budget or truncation logic exists yet. May need a "prompt budget" setting that the launcher uses to decide how much L1 content to include.

2. **Concurrent session handling.** What happens if two sessions access the same project's memory files simultaneously? Currently: last-write-wins with potential data loss. May need file locking or a merge strategy.

3. **Memory garbage collection.** Heartbeat checks staleness, but doesn't auto-prune. Could add a periodic review workflow guided by the agent.

4. **Adapter auto-detection.** The launcher could detect which agent tools are installed and auto-select or suggest the appropriate adapter.

5. **TUI dashboard.** A terminal UI for browsing projects, memory files, and persona profiles without opening a text editor.

6. **Git auto-commit.** Automatically commit the clu directory after each session ends. Could be triggered by the heartbeat or the adapter's post-session hook.

7. **OpenViking as optional backend.** If memory scales beyond what flat files handle well, OpenViking could serve as a retrieval backend while markdown files remain the source of truth.

8. **MCP server for web-based agents.** For tools that can't access the filesystem (web-only IDEs), an MCP server could expose memory read/write operations.

9. **Multi-user / team support.** Currently single-user. Shared project memory across team members would require a shared storage layer.

10. **Evaluation framework.** No way to measure whether the persona traits, memory system, or decision detection are actually working well. Could add a self-evaluation step to the end-of-session protocol.

11. **ClawHub-style skill registry.** Pluggable, shareable skill packages (`clu skill install code-review`). Interesting for v2.

12. **Heartbeat with agent intelligence.** Current heartbeat is bash-only (checks files, reports). A more advanced version could invoke the agent non-interactively to generate the morning brief, suggest memory cleanup, or auto-update weekly journal rollups.

---

## How to Use This Document in a Follow-up Session

Feed this file to a new agent session with an instruction like:

> "Read the attached DIALOGUE-SUMMARY.md. It contains the full design history of the clu project. I want to continue working on [specific topic]. Here's what I want to do next: [your goal]."

The agent will have full context on every decision made, the rationale behind each one, and what's still open.
