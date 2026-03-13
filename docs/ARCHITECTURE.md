# clu — Architecture & System Overview

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [System Architecture](#2-system-architecture)
3. [Data Model](#3-data-model)
4. [The Launcher Pipeline](#4-the-launcher-pipeline)
5. [The Adapter Layer](#5-the-adapter-layer)
6. [The Persona Engine](#6-the-persona-engine)
7. [The Memory System](#7-the-memory-system)
8. [The Core Prompt Template](#8-the-core-prompt-template)
9. [Session Lifecycle](#9-session-lifecycle)
10. [File Reference](#10-file-reference)
11. [Bootstrap & Heartbeat](#11-bootstrap--heartbeat)
12. [Design Decisions & Trade-offs](#12-design-decisions--trade-offs)
13. [Extension Points](#13-extension-points)
14. [Comparison with OpenViking & OpenClaw](#14-comparison-with-openviking--openclaw)

---

## 1. Design Philosophy

clu is built on five principles:

**Provider-agnostic.** The system does not depend on any specific AI agent framework. Claude Code, Aider, Cursor, Codex, or any future tool can be plugged in via the adapter pattern. Your memory, personas, and project context survive tool switches.

**Zero dependencies.** The entire system is bash scripts and markdown files. No Python runtime, no databases, no servers, no Docker. It runs on any Unix-like system with Bash 4+.

**One directory, one backup.** Everything lives in `~/.clu`. Push it to a git repo and you can redeploy your entire agent workstation on any machine in under a minute.

**Location-independent.** You never need to `cd` to a project directory before launching. The launcher handles project selection and path routing from anywhere.

**Human-readable state.** All configuration, memory, and persona definitions are plain markdown and YAML files. You can read, edit, debug, and understand the entire system state with a text editor.

---

## 2. System Architecture

### High-level flow

```
┌────────────────────────────────────────────────────────────────┐
│  USER                                                          │
│  $ clu my-project                                            │
└─────────────┬──────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────┐
│  LAUNCHER               │
│                         │
│  1. Parse arguments     │
│  2. Resolve project     │
│  3. Load config.yaml    │
│  4. Assemble context    │──────────────────────────────────┐
│  5. Dispatch to adapter │                                  │
└─────────────┬───────────┘                                  │
              │                                              │
              │  $AGENT_PROMPT (fully assembled)              │
              │  $AGENT_PROJECT_DIR                           │
              │  $AGENT_REPO_PATH                             │
              │  $AGENT_PERSONA                               │
              │  ...                                          │
              ▼                                              │
┌─────────────────────────┐    ┌──────────────────────────┐  │
│  ADAPTER                │    │  CONTEXT SOURCES         │  │
│  (claude-code.sh)       │    │                          │  │
│                         │    │  ┌────────────────────┐  │  │
│  Translates prompt into │    │  │ Persona + Traits   │──│──┘
│  tool-specific format   │    │  │ (personas/*.md)    │  │
│  (CLAUDE.md, etc.)      │    │  └────────────────────┘  │
│                         │    │  ┌────────────────────┐  │
│  Launches the agent     │    │  │ Router             │  │
│  tool in the repo dir   │    │  │ (_router.md)       │──│──┘
│                         │    │  └────────────────────┘  │
│  Handles cleanup and    │    │  ┌────────────────────┐  │
│  post-session tasks     │    │  │ Constraints        │  │
└─────────────┬───────────┘    │  │ (shared + project) │──│──┘
              │                │  └────────────────────┘  │
              ▼                │  ┌────────────────────┐  │
┌─────────────────────────┐    │  │ User Memory (L1)   │  │
│  AGENT SESSION          │    │  │ shared/memory/     │──│──┘
│                         │    │  └────────────────────┘  │
│  The AI agent runs with │    │  ┌────────────────────┐  │
│  full context.          │    │  │ Agent Memory (L1)  │  │
│                         │    │  │ shared/agent/      │──│──┘
│  Reads/writes memory    │    │  └────────────────────┘  │
│  files on disk during   │    │  ┌────────────────────┐  │
│  the session.           │    │  │ Project Memory (L1)│  │
│                         │    │  │ projects/x/memory/ │──│──┘
│  Follows the persona    │    │  └────────────────────┘  │
│  trait scores.          │    │  ┌────────────────────┐  │
│                         │    │  │ Trait Reference    │  │
│  Proposes memory writes │    │  │ (_traits.md)       │──│──┘
│  with user confirmation.│    │  └────────────────────┘  │
└─────────────┬───────────┘    └──────────────────────────┘
              │
              ▼
┌─────────────────────────┐
│  POST-SESSION           │
│                         │
│  Adapter cleanup        │
│  (restore CLAUDE.md)    │
│                         │
│  Optional: summarizer   │
│  (journal entry)        │
└─────────────────────────┘
```

### Component boundaries

The system has three clean boundaries:

1. **Launcher ↔ Adapter:** The launcher exports environment variables; the adapter reads them. They share no internal state beyond these variables.

2. **clu ↔ Agent Tool:** The adapter writes configuration files that the agent tool reads natively (e.g., CLAUDE.md). The agent tool does not know clu exists — it just sees its normal config.

3. **Agent ↔ Memory Files:** The core prompt tells the agent where memory files live on disk. The agent reads and writes them as normal files. There is no API layer, no database, no abstraction.

---

## 3. Data Model

### Directory layout

```
~/.clu/                     # $CLU_HOME
│
├── config.yaml                      # Global settings
├── launcher                         # Entry point script
├── install.sh                       # Deployment script
├── create-persona.sh                # Persona creation wizard
├── bootstrap.sh                     # Agent-guided onboarding interview
├── heartbeat.sh                     # Cron-triggered maintenance
│
├── adapters/                        # Provider abstraction
│   ├── claude-code.sh
│   ├── aider.sh
│   ├── cursor.sh
│   └── custom.sh                    # Template for new adapters
│
├── personas/                        # Character definitions
│   ├── _traits.md                   # OCEAN behavior mapping reference
│   ├── _router.md                   # Dynamic switching rules
│   ├── architect.md                 # O:8 C:7 E:6 A:4 N:6
│   ├── implementer.md               # O:4 C:8 E:3 A:6 N:3
│   ├── reviewer.md                  # O:5 C:9 E:5 A:3 N:7
│   ├── researcher.md                # O:9 C:6 E:7 A:5 N:5
│   ├── writer.md                    # O:7 C:7 E:5 A:6 N:4
│   └── default.md                   # O:6 C:6 E:6 A:6 N:4
│
├── shared/                          # Cross-project resources
│   ├── core-prompt.md               # System prompt template with {{variables}}
│   ├── constraints.md               # Global rules
│   ├── imported/                    # Global Claude Code imports (via `clu import`)
│   │   ├── settings.json            # Merged global settings (plugins, MCP servers)
│   │   ├── plans/                   # Imported session plans
│   │   └── ...                      # Session history, etc.
│   ├── memory/                      # USER scope
│   │   ├── preferences.md           # Full user profile (identity + prefs)
│   │   ├── patterns.md
│   │   └── learnings.md
│   └── agent/                       # AGENT scope
│       ├── skills.md
│       ├── workflows.md
│       └── meta.md
│
├── projects/                        # Project-specific data
│   └── <project-name>/
│       ├── project.yaml             # Project config
│       ├── constraints.md           # Project-specific rules
│       └── memory/                  # PROJECT scope
│           ├── decisions.md
│           ├── architecture.md
│           ├── journal.md           # Weekly highlights index
│           ├── context.md
│           ├── findings.md
│           ├── hypotheses.md
│           └── days/                # Daily session logs
│               └── YYYY-MM-DD.md
│
├── templates/                       # Scaffolding
│   └── new-project/
│       ├── project.yaml
│       ├── constraints.md
│       └── memory/
│           └── days/                # Daily log directory
│
└── docs/                            # Documentation
```

### Data flow summary

| Data | Written by | Read by | Format |
|---|---|---|---|
| `config.yaml` | User (manual edit) | Launcher | YAML |
| `project.yaml` | User + `clu new` | Launcher | YAML |
| Persona files | User + `create-persona.sh` | Launcher → Core prompt | Markdown with YAML code block |
| Memory files | Agent (with user confirmation) | Launcher (L1 at start) + Agent (L2 on demand) | Markdown with YAML front-matter |
| Daily logs | Agent (end of session) | Agent (today + yesterday at start) | Markdown (`memory/days/YYYY-MM-DD.md`) |
| User profile | User + bootstrap interview | Agent (every session) | Markdown (`shared/memory/preferences.md`) |
| `core-prompt.md` | clu (template) | Launcher (variable substitution) | Markdown with `{{variables}}` |
| Adapter output (e.g., CLAUDE.md) | Adapter script | Agent tool | Tool-specific format |

### Data lifecycle

```
First install
    → User runs install.sh
    → User runs `clu bootstrap` → agent interviews user
    → preferences.md populated with full user profile

User creates project
    → project.yaml + empty memory files + days/ directory
    → User fills in context.md with project brief

Sessions happen
    → Agent reads today + yesterday's daily log at start
    → Agent proposes memory writes → user confirms
    → Memory files accumulate decisions, findings, etc.
    → Daily log (days/YYYY-MM-DD.md) written at session end
    → L0 abstracts get updated

Between sessions (heartbeat)
    → clu heartbeat runs via cron (optional)
    → Checks memory staleness, log hygiene
    → Generates morning brief from yesterday's open threads

Cross-session learning
    → Agent proposes user profile updates → shared/memory/preferences.md
    → Agent proposes skill entries → shared/agent/
    → Patterns get promoted from project → shared after 3+ occurrences
    → Weekly: journal.md index updated with highlights

Project completes
    → User archives project directory
    → Shared memory (learnings, patterns, user profile) persists
```

---

## 4. The Launcher Pipeline

The launcher (`launcher`) is a bash script that orchestrates every session. Here is the exact sequence of operations:

### Phase 1: Argument parsing

```
Input: command line arguments
Output: $ADAPTER, $PERSONA_OVERRIDE, $COMMAND, $PROJECT
```

Parses `--adapter`, `--persona`, subcommands (`new`, `list`, `check`, `summarize`, `bootstrap`, `heartbeat`), and the project name. Falls back to defaults from `config.yaml`.

Note: `bootstrap` and `heartbeat` dispatch to their own scripts (`bootstrap.sh`, `heartbeat.sh`) and exit before reaching the context assembly phase.

### Phase 2: Project resolution

```
Input: $PROJECT (possibly empty)
Output: resolved project directory path
```

If `$PROJECT` is set, validates it exists in `projects/`. If empty, enters workspace mode: the function `assemble_workspace_context()` builds a multi-project context so the agent sees all projects and can switch between them, create new ones, and work across projects. The interactive picker (fzf/gum/basic select) has been removed.

### Phase 3: Context assembly

This is the core logic. For a specific project, `assemble_context()` does the following in order. For workspace mode (no project specified), `assemble_workspace_context()` builds a multi-project view instead.

1. **Read project config** — parses `project.yaml` for type, repo path, default persona, available personas
2. **Load core prompt template** — reads `shared/core-prompt.md`
3. **Load persona** — reads the persona file (from `--persona` override, project default, or fallback to `default.md`)
4. **Load router** — reads `_router.md` if `dynamic_personas: true`
5. **Load trait reference** — reads `_traits.md` (full OCEAN behavior mapping)
6. **Load global constraints** — reads `shared/constraints.md`
7. **Load project constraints** — reads `projects/<n>/constraints.md`
8. **Load user memory (L1)** — reads first 50 lines of each file in `shared/memory/`
9. **Load agent memory (L1)** — reads first 50 lines of each file in `shared/agent/`
10. **Load project memory (L1)** — reads first 50 lines of each file in `projects/<n>/memory/`
11. **Resolve repo path** — expands `~` and validates the path exists
12. **Substitute variables** — replaces all `{{VARIABLE}}` placeholders in the core prompt template

The result is a single string (`$AGENT_PROMPT`) containing the complete system instruction.

### Phase 4: Adapter dispatch

```
Input: $AGENT_PROMPT + metadata env vars
Output: agent session starts
```

Sources the adapter script and calls `adapter_launch()`. The adapter translates the prompt into tool-specific format and starts the session.

### Phase 5: Post-session

After the adapter returns (agent session ended):
- Adapter performs cleanup (restore backed-up files, etc.)
- If `auto_summarize: true`, prompts user for a journal entry

### Variable substitution reference

| Variable | Replaced with | Source |
|---|---|---|
| `{{PERSONA_BLOCK}}` | Contents of the active persona file | `personas/<n>.md` |
| `{{ROUTER_BLOCK}}` | Persona switching rules | `personas/_router.md` |
| `{{TRAIT_REFERENCE}}` | Full OCEAN behavior mapping | `personas/_traits.md` |
| `{{GLOBAL_CONSTRAINTS}}` | Global rules | `shared/constraints.md` |
| `{{PROJECT_CONSTRAINTS}}` | Project-specific rules | `projects/<n>/constraints.md` |
| `{{SHARED_MEMORY}}` | User memory (L1) | `shared/memory/*.md` |
| `{{AGENT_MEMORY}}` | Agent memory (L1) | `shared/agent/*.md` |
| `{{PROJECT_MEMORY}}` | Project memory (L1) | `projects/<n>/memory/*.md` |
| `{{STALENESS_DAYS}}` | Threshold for memory staleness | `config.yaml` |
| `{{REPO_PATH}}` | Resolved repo path | `project.yaml` |

---

## 5. The Adapter Layer

### Responsibility

An adapter has exactly two jobs:

1. **Translate** the universal `$AGENT_PROMPT` into whatever format the specific agent tool expects
2. **Launch** the tool in the correct working directory

The adapter does NOT:
- Parse memory files
- Resolve personas
- Assemble the system prompt
- Make decisions about what context to include

All of that is done by the launcher before the adapter is invoked.

### Interface contract

Every adapter must implement:

```bash
adapter_launch()       # Start the session
adapter_summarize()    # Post-session summarization (optional)
```

And can read these environment variables:

```bash
$AGENT_PROMPT          # The complete system prompt
$AGENT_PROJECT_NAME    # Project name
$AGENT_PROJECT_DIR     # Path to project dir in clu
$AGENT_PROJECT_TYPE    # software|research|writing|strategy|mixed
$AGENT_REPO_PATH       # Path to the project's working directory
$AGENT_PERSONA         # Active persona name
$AGENT_HOME            # Path to clu root
```

### How each adapter translates the prompt

| Adapter | Prompt delivery | Memory access | Launch mechanism |
|---|---|---|---|
| Claude Code | Writes `CLAUDE.md` to repo dir | File paths in prompt → agent reads directly | `cd $REPO_PATH && claude --dangerously-skip-permissions` |
| Aider | `--system-prompt-file` flag | `--read` flag per memory file | `cd $REPO_PATH && aider` |
| Cursor | Writes `.cursorrules` with inlined memory | Memory snapshot at launch (no live access) | Opens Cursor or prepares file |
| Custom | User-defined | User-defined | User-defined |

---

## 6. The Persona Engine

### How traits drive behavior

Each persona is a markdown file containing a YAML code block with five scores:

```yaml
openness:          8
conscientiousness: 7
extraversion:      6
agreeableness:     4
neuroticism:       6
```

These scores are injected into the system prompt alongside the full behavior mapping table (`_traits.md`). The agent interprets the scores according to the mapping — for example, `agreeableness: 4` means "direct and honest, will disagree openly but without hostility."

The trait scores are the primary behavioral driver. The role description (Architect, Reviewer, etc.) tells the agent what to focus on; the scores tell it how to behave while doing it.

### Dynamic routing

When `dynamic_personas: true`, the router (`_router.md`) is included in the prompt. It instructs the agent to:

1. Detect the work type from user messages
2. Match it to the appropriate persona
3. Announce the transition briefly with trait context
4. Adopt the new persona's trait scores

Transitions are fluid — the agent can blend traits when work crosses persona boundaries (e.g., reviewing architecture uses both Reviewer and Architect traits).

### Runtime adjustment

The user can shift traits mid-session with natural language:
- "be more creative" → O +2
- "be more direct" → A −2

The agent acknowledges: `[Adjusted: A 6→4 — more direct]`

These adjustments persist for the remainder of the session only.

---

## 7. The Memory System

### Architecture

```
┌─────────────────────────────────────────────────┐
│                MEMORY SYSTEM                     │
│                                                  │
│  ┌─────────────┐  ┌──────────┐  ┌────────────┐  │
│  │ USER SCOPE  │  │  AGENT   │  │  PROJECT   │  │
│  │             │  │  SCOPE   │  │  SCOPE     │  │
│  │ preferences │  │  skills  │  │ decisions  │  │
│  │ patterns    │  │ workflows│  │ architecture│ │
│  │ learnings   │  │  meta    │  │ journal    │  │
│  │             │  │          │  │ context    │  │
│  │             │  │          │  │ findings   │  │
│  │             │  │          │  │ hypotheses │  │
│  └──────┬──────┘  └────┬─────┘  └─────┬──────┘  │
│         │              │              │          │
│         ▼              ▼              ▼          │
│  ┌─────────────────────────────────────────────┐ │
│  │         TIERED LOADING SYSTEM               │ │
│  │                                             │ │
│  │  L0 (abstract: field)  ← always loaded     │ │
│  │  L1 (first ~50 lines)  ← loaded at start   │ │
│  │  L2 (full file)         ← loaded on demand  │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

### Tiered loading mechanism

The launcher implements L1 loading via the standalone `_load_memory_l1()` function, which:

1. Iterates over all `.md` files in a given directory
2. For each file, extracts the `abstract:` field from front-matter (L0)
3. Reads the first 50 lines (L1)
4. Includes the full file path so the agent can open L2 on demand

Daily logs (`memory/days/YYYY-MM-DD.md`) use a different loading strategy: the agent reads today's and yesterday's files in full at session start (they are typically short — one session per day). Older daily logs are not loaded but remain searchable on demand.

The agent is instructed via the core prompt to:
- Scan L0 abstracts at session start to assess relevance
- Read today + yesterday's daily logs for recent context
- Read the user profile (`preferences.md`) every session
- Only promote other files to L1/L2 when the user's stated goal requires it
- Update L0 abstracts whenever it modifies a file

### Write protocol

All memory writes follow the semi-automatic protocol:

```
Agent detects memory-worthy moment
    → Agent formats a proposed entry
    → Agent presents it with target file path
    → User confirms (y), rejects (n), or edits
    → Agent writes to the file
    → Agent updates L0 abstract
```

The agent does NOT write memory without user confirmation. This is enforced by the system prompt, not by code.

### Scope separation rationale

| Scope | Persistence | Changes | Examples |
|---|---|---|---|
| User | Permanent, cross-project | Occasionally (profile + preferences evolve) | Full user profile: identity, context, priorities, communication style, tool preferences |
| Agent | Permanent, cross-project | Occasionally (as the agent learns) | "When debugging React, check hooks first" |
| Project | Project lifetime | Frequently (every session) | "We chose PostgreSQL because..." |

The key insight: there is no global `decisions.md`. Decisions are always project-scoped. Cross-project knowledge lives in patterns (User), skills (Agent), or learnings (User).

---

## 8. The Core Prompt Template

The file `shared/core-prompt.md` is the heart of the system. It is a markdown document with `{{VARIABLE}}` placeholders that the launcher fills in at assembly time.

### Structure of the assembled prompt

After variable substitution, the prompt sent to the agent contains these sections in order:

1. **Identity & Operating Mode** — tells the agent it is operating inside clu
2. **Active Persona** — the persona file contents (role + trait scores)
3. **Router** — dynamic switching rules (if enabled)
4. **Big Five Trait System** — OCEAN score meanings + runtime adjustment rules
5. **Trait Reference** — full behavior mapping table
6. **Constraints** — global constraints followed by project constraints
7. **Memory** — scopes explanation, tiered loading explanation, L1 content for all three scopes, file conventions, read/write protocols
8. **End-of-Session Protocol** — auto-classification, summary generation, L0 updates, batch confirmation
9. **Work Mode Awareness** — how to adapt for software/research/writing/strategy
10. **Tool / File Conventions** — repo path, file placement rules

### Prompt size considerations

A typical assembled prompt for a new project with default persona and empty memory files is approximately 4,000–5,000 tokens. This grows as:

- Memory files accumulate entries (mitigated by L1 loading — only first 50 lines)
- Trait reference is included (~1,500 tokens — could be omitted for simpler setups)
- Multiple constraints are active

For context-window-constrained models, you can reduce the prompt by:
- Setting `dynamic_personas: false` (removes router + trait reference)
- Trimming the trait reference to just the active persona's score range
- Reducing L1 from 50 lines to 20 in the launcher

---

## 9. Session Lifecycle

### Complete timeline

```
T0: User runs `clu my-project`
    │
    ├── Launcher: parse args, resolve project
    ├── Launcher: load config.yaml
    ├── Launcher: assemble context (persona + traits + constraints + memory L1)
    ├── Launcher: substitute {{variables}} in core-prompt.md
    ├── Launcher: run staleness check (non-blocking, informational)
    ├── Launcher: export env vars ($AGENT_PROMPT, etc.)
    ├── Launcher: source adapter script
    ├── Adapter: write tool-specific config (CLAUDE.md, etc.)
    ├── Adapter: back up existing config if present
    ├── Adapter: launch agent tool
    │
T1: Agent session active
    │
    ├── Agent: reads user profile (preferences.md)
    ├── Agent: reads today + yesterday daily logs
    ├── Agent: reads L0 abstracts, assesses relevance
    ├── Agent: greets user, surfaces relevant context
    │
    ├── ... work happens ...
    │
    ├── Agent: detects decision-worthy moment
    ├── Agent: proposes memory write → user confirms → writes to file
    ├── Agent: detects persona switch needed → transitions
    ├── User: "be more cautious" → Agent adjusts N +2
    │
    ├── ... more work ...
    │
T2: User signals end of session
    │
    ├── Agent: scans conversation for uncommitted updates
    ├── Agent: auto-classifies into user/agent/project scopes
    ├── Agent: writes today's daily log (days/YYYY-MM-DD.md)
    ├── Agent: proposes updated L0 abstracts
    ├── Agent: presents batch for confirmation
    ├── User: confirms → Agent writes all updates
    │
T3: Agent session ends
    │
    ├── Adapter: restore backed-up config files
    ├── Adapter: cleanup temp files
    ├── Launcher: prompt for manual journal entry (if auto_summarize: true)
    │
T4: Done
```

---

## 10. File Reference

### Configuration files

| File | Format | Editable | Purpose |
|---|---|---|---|
| `config.yaml` | YAML | Manual | Global settings: adapter, staleness, persona switching |
| `project.yaml` | YAML | Manual + `clu new` | Per-project: name, type, repo path, personas, trait overrides |

### Prompt assembly files

| File | Format | Editable | Purpose |
|---|---|---|---|
| `shared/core-prompt.md` | Markdown + `{{vars}}` | Careful | System prompt template — the central instruction set |
| `shared/constraints.md` | Markdown | Yes | Global rules applied to every session |
| `projects/<n>/constraints.md` | Markdown | Yes | Project-specific rules |

### Persona files

| File | Format | Editable | Purpose |
|---|---|---|---|
| `personas/_traits.md` | Markdown | Careful | OCEAN score → behavior mapping reference |
| `personas/_router.md` | Markdown | Careful | Dynamic switching rules |
| `personas/<n>.md` | Markdown + YAML block | Yes | Individual persona definition |

### Memory files

| File | Format | Editable | Purpose |
|---|---|---|---|
| `shared/memory/*.md` | Markdown + front-matter | Agent + manual | User-scope cross-project knowledge |
| `shared/agent/*.md` | Markdown + front-matter | Agent + manual | Agent-scope learned capabilities |
| `projects/<n>/memory/*.md` | Markdown + front-matter | Agent + manual | Project-scope decisions, findings, etc. |
| `projects/<n>/memory/days/*.md` | Markdown + front-matter | Agent (daily) | Daily session logs — one file per day |

### Scripts

| File | Executable | Purpose |
|---|---|---|
| `launcher` | Yes | Main entry point — the `clu` command. Includes `_load_memory_l1()`, `assemble_workspace_context()`, `_decode_claude_path()`, and portable helpers (`_sed_i()`, `_date_to_epoch()`, `_date_relative()`) |
| `install.sh` | Yes | Deploys to `~/.clu`, sets up shell alias. Excludes `.git/` on fresh install, preserves user `config.yaml` on upgrade |
| `create-persona.sh` | Yes | Interactive Big Five persona creation wizard |
| `bootstrap.sh` | Yes | Agent-guided onboarding interview (first-run). Runs Claude with `--dangerously-skip-permissions`. Includes portable macOS helpers |
| `heartbeat.sh` | Yes | Cron-triggered maintenance between sessions. Includes portable macOS helpers (`_sed_i()`, `_date_to_epoch()`, `_date_relative()`) |
| `adapters/*.sh` | Sourced | Adapter implementations. Claude Code adapter runs with `--dangerously-skip-permissions` |

---

## 11. Bootstrap & Heartbeat

### Bootstrap (first-run onboarding)

`clu bootstrap` launches an agent session with a special system prompt that instructs the agent to interview the user and populate their profile. The flow:

```
User runs `clu bootstrap`
    │
    ├── bootstrap.sh builds a special prompt (not core-prompt.md)
    ├── Prompt instructs: "interview the user, populate preferences.md"
    ├── Adapter launches the agent with this prompt
    │
    ├── Agent asks about identity, work context, style, tools
    ├── Agent writes to shared/memory/preferences.md
    ├── Agent optionally adjusts shared/constraints.md
    ├── Agent writes .bootstrapped marker
    │
    └── Session ends, normal adapter cleanup
```

The bootstrap prompt is NOT the core-prompt template — it's a purpose-built instruction set that only runs once. The `.bootstrapped` marker file prevents re-runs; `--force` overrides it.

### Heartbeat (between-session maintenance)

`clu heartbeat` is a non-interactive bash script that runs four maintenance tasks:

```
clu heartbeat
    │
    ├── 1. Memory staleness check
    │      Scans all memory files across shared/ and projects/
    │      Flags any with last_verified > threshold
    │
    ├── 2. Daily log hygiene
    │      Counts sessions per project this week
    │      Suggests weekly journal rollup on Mondays
    │      Creates missing days/ directories
    │
    ├── 3. User profile freshness
    │      Checks if preferences.md has real content
    │      Suggests `clu bootstrap` if sparse
    │
    └── 4. Morning brief
           Reads yesterday's daily logs
           Surfaces open threads and next-session notes
```

The heartbeat never modifies files or starts agent sessions — it's purely diagnostic. Designed for cron: `0 8 * * * ~/.clu/heartbeat.sh`

---

## 12. Design Decisions & Trade-offs

### Why bash, not Python?

**Decision:** Bash for the launcher and adapters.
**Rationale:** Zero dependencies. Runs on every Unix system without installing anything. The launcher is orchestration logic (parse args, read files, string replace, call tool) — bash handles this adequately.
**Trade-off:** Complex string manipulation in bash is fragile. The YAML parser is minimal (regex-based, handles flat keys only). If the system grows significantly more complex, migrating the launcher to Python would be warranted.

### Why markdown files, not a database?

**Decision:** All state in plain markdown files with YAML front-matter.
**Rationale:** Human-readable, git-friendly, editable with any text editor, no server to run, no schema migrations. The agent can read and write them as normal files.
**Trade-off:** No indexing, no querying, no concurrent access protection. Works well for the expected scale (dozens of memory entries per project). Would not scale to thousands of entries — at that point, consider OpenViking or a similar context database as a backend.

### Why tiered loading instead of full RAG?

**Decision:** L0/L1/L2 tiers with the launcher loading L1, agent loading L2 on demand.
**Rationale:** No embedding model dependency, no vector database, no API calls for retrieval. The agent's own judgment (guided by L0 abstracts) decides what to load in full. For human-curated memory files of reasonable size, this is sufficient.
**Trade-off:** If memory files grow very large (hundreds of entries), the agent may miss relevant entries that aren't in the first 50 lines. At that point, either prune aggressively, split files, or add semantic search.

### Why semi-automatic memory, not fully automatic?

**Decision:** Agent proposes, human confirms.
**Rationale:** Fully automatic memory writes produce noise — the agent doesn't reliably distinguish what's worth remembering from what's transient. Semi-automatic keeps memory quality high while reducing the friction of manual logging.
**Trade-off:** Confirmation fatigue. If the agent proposes too many updates, users will start rubber-stamping without reading. Mitigation: the prompt instructs the agent to only propose truly significant updates, and the end-of-session batch confirm reduces interruptions during active work.

### Why Big Five traits, not free-form personas?

**Decision:** Quantify persona behavior on five OCEAN dimensions, scored 1–10.
**Rationale:** Makes personas comparable, adjustable, and composable. "Shift agreeableness down by 2" is more precise than "be more direct." Trait interactions (High O + Low C = creative chaos) emerge naturally. New personas can be created by just picking five numbers.
**Trade-off:** The Big Five is a simplification of human personality. Some behavioral nuances can't be captured in five numbers. Mitigation: the persona file also includes free-form role description and behavioral notes for nuance that doesn't fit the scores.

---

## 13. Extension Points

### Adding a new memory file type

1. Add the file template to `templates/new-project/memory/`
2. Add the type to the front-matter schema in `core-prompt.md`
3. Add filing guidance to the "Write to the correct file" section in `core-prompt.md`
4. Existing projects can create the file manually

### Adding a new persona

1. Run `create-persona.sh` or manually create `personas/<n>.md`
2. Add the persona name to relevant projects' `available_personas` in `project.yaml`

### Adding a new adapter

1. Copy `adapters/custom.sh` to `adapters/<n>.sh`
2. Implement `adapter_launch` and `adapter_summarize`
3. Set `default_adapter: <n>` in `config.yaml` or use `--adapter <n>`

### Integrating external tools

The adapter pattern makes it possible to integrate with external services:
- An adapter could call an API to store/retrieve memory (e.g., OpenViking)
- An adapter could post session summaries to Notion, Obsidian, or a wiki
- An adapter could trigger CI/CD pipelines after code sessions

### Scaling memory with semantic search

If memory files outgrow the L0/L1/L2 approach, OpenViking can serve as a backend:
1. At session start, the adapter writes memory files to OpenViking
2. OpenViking handles embedding, indexing, and hierarchical retrieval
3. The adapter fetches relevant context and injects it into the prompt
4. Memory writes still go to markdown files (source of truth)

This would require a new adapter or a wrapper around an existing one.

---

## 14. Comparison with OpenViking & OpenClaw

clu was influenced by two open-source projects:
- [OpenViking](https://github.com/volcengine/OpenViking) — a context database from ByteDance
- [OpenClaw](https://github.com/openclaw/openclaw) — a personal AI assistant framework

### OpenViking

Here is how clu and OpenViking relate:

| Aspect | clu | OpenViking |
|---|---|---|
| **What it is** | Workstation orchestrator | Context database |
| **Primary job** | Assemble context and launch agents | Store, index, and retrieve context |
| **Dependencies** | Bash only | Python, embedding models, VLM, vector DB |
| **Memory storage** | Markdown files on disk | Virtual filesystem backed by vector DB |
| **Retrieval** | Agent judgment + L0 abstracts | Recursive semantic search |
| **Best for** | Individual developer, human-curated context | Large-scale context with automated retrieval |

### What we adopted from OpenViking

1. **Tiered loading (L0/L1/L2)** — the concept of abstract → overview → full detail, loaded on demand
2. **User / Agent / Resource separation** — splitting context by who owns it (user preferences vs. agent knowledge vs. project data)
3. **Session-end memory extraction** — auto-classifying session outputs into structured memory

### What we deliberately did not adopt from OpenViking

1. Vector database and embedding infrastructure
2. VLM integration for content understanding
3. Recursive directory retrieval with semantic search
4. The server/client architecture

The design allows upgrading to OpenViking as a backend if the scale demands it, without changing the user-facing experience.

### OpenClaw

OpenClaw is a 300k+ star personal AI assistant framework. Its workspace concept influenced clu's later design decisions:

| OpenClaw Concept | clu Equivalent | Status |
|---|---|---|
| SOUL.md (personality) | Persona files + Big Five traits | More structured in clu |
| USER.md (who the user is) | `preferences.md` (expanded user profile) | Adopted — full profile |
| AGENTS.md (operating rules) | `core-prompt.md` + `constraints.md` | Already covered |
| MEMORY.md (persistent memory) | Multi-file structured memory | More organized in clu |
| Daily logs (YYYY-MM-DD.md) | `memory/days/YYYY-MM-DD.md` | Adopted — same pattern |
| BOOTSTRAP.md (first-run) | `bootstrap.sh` | Adopted — agent-guided interview |
| HEARTBEAT.md (periodic autonomy) | `heartbeat.sh` | Adopted — cron maintenance |
| IDENTITY.md (visual identity) | Not adopted | Not relevant for CLI |
| TOOLS.md (tool conventions) | Covered by constraints | Not needed separately |
| BOOT.md (restart checklist) | Not adopted | No persistent gateway |
| ClawHub (skill registry) | Future consideration | Interesting for v2 |
| Multi-agent isolation | Persona routing | Different paradigm |

Key philosophical difference: OpenClaw is an always-on assistant with a persistent gateway, multiple communication channels, and autonomous heartbeat. clu is a session-based workstation — the user invokes it, works, and exits. The heartbeat bridges this gap partially by enabling between-session maintenance, but clu remains fundamentally user-initiated.
