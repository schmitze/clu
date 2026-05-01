# clu

**Codified Likeness Utility** — a provider-agnostic workstation for AI agent workflows.

One directory. One command. Any framework. Your context survives everything.

> *"CLU, I created you to help me build the perfect system."* — Kevin Flynn, TRON

## The Problem

You use Claude Code (or Aider, or Cursor) and over time you build up context: decisions made, architecture documented, preferences learned. But that context is scattered across tool-specific config files, tied to specific directories, and lost when you switch tools.

## The Solution

clu is a single `~/.clu` directory that contains your entire agent setup: projects, memory, personas, constraints, and adapter scripts that translate everything into whatever tool you're currently using.

```
clu my-saas         # launches Claude Code with full project context
clu --adapter aider my-saas   # same context, different tool
clu                 # workspace mode — agent sees all projects
```

## Architecture

```
~/.clu/
├── config.yaml          # global settings
├── launcher             # the `clu` command
├── bootstrap.sh         # agent-guided onboarding interview
├── heartbeat.sh         # daily maintenance (11 tasks)
├── setup-memory-sync.sh # memory-repo setup
├── session-digest.py    # JSONL → compact digest
├── session-recovery.py  # crashed-session recovery
├── dashboard.py         # optional web dashboard (Flask)
├── adapters/            # provider abstraction layer
│   ├── claude-code.sh
│   ├── aider.sh
│   ├── cursor.sh
│   └── custom.sh
├── personas/            # OCEAN trait profiles
│   ├── _traits.md       # trait → behavior reference
│   ├── _router.md       # dynamic switching rules
│   ├── _trait-learning.md
│   ├── default.md
│   ├── architect.md
│   ├── implementer.md
│   ├── reviewer.md
│   ├── researcher.md
│   ├── writer.md
│   └── entrepreneur.md
├── tools/
│   ├── curator/         # autonomous memory writer (Sonnet 4.6)
│   └── recall/          # FTS5 index over memory + JSONLs
├── projects/
│   └── my-project/
│       ├── project.yaml
│       ├── constraints.md
│       └── memory/      # symlinked to ~/repos/clu-memory/projects/<n>/memory/
│           ├── decisions.md      # DEC-NNN
│           ├── architecture.md
│           ├── findings.md       # FND-NNN
│           ├── journal.md
│           └── days/             # YYYY-MM-DD.md daily logs
├── shared/
│   ├── core-prompt.md   # system prompt template with {{VAR}}
│   ├── constraints.md   # global rules
│   ├── imported/        # global Claude Code imports (via `clu import`)
│   ├── memory/          # USER memory (symlink to clu-memory repo)
│   │   ├── preferences.md
│   │   ├── learnings.md          # LRN-NNN
│   │   ├── patterns.md
│   │   └── references.md
│   └── agent/           # AGENT memory (symlink to clu-memory repo)
│       ├── workflows.md          # WF-NNN
│       ├── skills.md
│       ├── meta.md               # SIG-NNN trait signals
│       └── security-report.md
├── templates/
│   └── new-project/
└── docs/
    ├── CLU-DOCUMENTATION.md      # full manual (German)
    ├── ARCHITECTURE.md           # original architecture doc
    └── OPERATIONS.md             # operations guide

~/repos/clu-memory/      # separate private git repo, holds the actual memory
                         # files behind the symlinks above. Heartbeat task 9
                         # commits and pushes nightly.
```

## Key Concepts

### Memory: Three Scopes, Three Tiers

Inspired by [OpenViking](https://github.com/volcengine/OpenViking) and [OpenClaw](https://github.com/openclaw/openclaw), memory is organized along two dimensions:

**Three scopes** (who owns the knowledge):

| Scope | Location | Contains | Loaded |
|---|---|---|---|
| **User** | `shared/memory/` | Full user profile, patterns, learnings | Every session |
| **Agent** | `shared/agent/` | Skills, workflows, meta-knowledge | Every session |
| **Project** | `projects/<n>/memory/` | Decisions, architecture, findings, daily logs | Active project only |

User and Agent are both loaded every session — the split is semantic, not technical. **User** is knowledge about *you* (portable if someone else uses clu). **Agent** is knowledge about *how clu works* (portable across users). You could set up clu for a colleague: keep Agent memory, replace User memory. Project memory is the only scope that changes between sessions.

**Three tiers** (how much detail to load):

| Tier | What | When loaded |
|---|---|---|
| **L0 – Abstract** | One-sentence summary in front-matter | Always (all files) |
| **L1 – Overview** | First ~50 lines | Session start (relevant files) |
| **L2 – Full** | Entire file content | On-demand |

**Daily session logs** live in `memory/days/YYYY-MM-DD.md` — one file per day. The agent reads today + yesterday at session start. `journal.md` is a weekly highlights index.

There is no global `decisions.md` — decisions are inherently project-scoped. When a pattern appears across 3+ projects, the agent suggests promoting it to `shared/memory/patterns.md`.

### Semi-Automatic Memory

Three writers, all converging on the same memory files:

1. **Live, mid-session** — the agent detects decisions and findings,
   classifies confidence (high ≥0.8 → block as-is, medium 0.5–0.8 →
   block with `⚠️ confidence: medium` marker, low <0.5 → skip), and
   writes directly. You see a one-line notification and can object
   afterwards.
2. **End-of-session protocol** — daily log to `memory/days/YYYY-MM-DD.md`,
   updates L0 abstracts, optional trait-learning reflection.
3. **Nightly curator** — `tools/curator/curator.py` runs in the
   heartbeat, finds sessions without a daily log, sends them to
   Sonnet 4.6 over OpenRouter, and writes daily logs + DEC/FND/LRN
   blocks autonomously. Output in `~/.clu/curator-actions.log`.

A FTS5 index (`tools/recall/recall.py`) over all memory files plus
all Claude Code session JSONLs makes the whole archive searchable
from the command line: `recall.py search "vaultwarden tls"`.

### Persona System — Big Five Traits (OCEAN)

Every persona is defined by five psychological dimensions scored 1–10:

| Trait | Low (1–3) | High (7–10) |
|---|---|---|
| **O** – Openness | Conventional, proven solutions | Exploratory, creative, unconventional |
| **C** – Conscientiousness | Fast and loose, minimal process | Meticulous, thorough, structured |
| **E** – Extraversion | Quiet worker, minimal narration | Thinks out loud, proactive communicator |
| **A** – Agreeableness | Blunt critic, pushes back hard | Cooperative, accommodating, supportive |
| **N** – Neuroticism (Caution) | Fearless, moves fast, ignores edge cases | Risk-averse, flags everything, careful |

Built-in personas and their profiles:

| Persona | O | C | E | A | N | Character |
|---|---|---|---|---|---|---|
| Architect | 8 | 7 | 6 | 4 | 6 | Creative challenger who plans thoroughly |
| Implementer | 4 | 8 | 3 | 6 | 3 | Quiet, reliable, fast executor |
| Reviewer | 5 | 9 | 5 | 3 | 7 | Thorough, direct, catches everything |
| Researcher | 9 | 6 | 7 | 5 | 5 | Curious explorer who thinks out loud |
| Writer | 7 | 7 | 5 | 6 | 4 | Creative and disciplined communicator |
| Default | 6 | 6 | 6 | 6 | 4 | Balanced generalist, bias toward action |

Each project has a `default_persona` in its `project.yaml` — that's the starting point for every session. If `dynamic_personas: true` is set in `config.yaml`, the router (`_router.md`) can switch personas mid-session when your activity changes (e.g. from building to reviewing). Trait scores drive actual behavior — they're not just labels.

**Create custom personas:**
```bash
./create-persona.sh
# Interactive wizard that asks for trait scores and generates the file
```

**Adjust traits mid-session** by telling the agent:
- "be more creative" → O +2
- "be more direct" → A −2
- "be more cautious" → N +2

**Per-project trait overrides** in `project.yaml` let you shift personas for specific projects without creating new persona files.

### Not Just Code

clu works for any intellectual work: software, research, writing, strategy, or mixed projects. The `project.yaml` declares a type that hints the agent toward the right tools and memory structures, but the agent follows your lead.

## Install

```bash
git clone <repo-url> /tmp/clu-install
cd /tmp/clu-install
chmod +x install.sh
./install.sh
```

This copies everything to `~/.clu` (excluding `.git/` on fresh installs), adds the `clu` alias to your shell RC file, and verifies dependencies. Upgrades preserve your `config.yaml`.

## Quick Start

```bash
# Reload shell after install
source ~/.zshrc  # or ~/.bashrc

# Create a project
clu new my-saas

# Edit project config
$EDITOR ~/.clu/projects/my-saas/project.yaml

# Run the onboarding interview (or edit manually)
clu bootstrap
# $EDITOR ~/.clu/shared/memory/preferences.md

# Launch
clu my-saas
```

## Commands

| Command | Description |
|---|---|
| `clu` | Workspace mode — agent sees all projects, can switch between them |
| `clu <project>` | Launch specific project |
| `clu new <name>` | Create new project from template |
| `clu list` | List all projects |
| `clu import` | Import Claude Code session history, settings, plans, and project memory |
| `clu import --list` | Preview what would be imported (read-only) |
| `clu bootstrap` | Agent-guided onboarding interview |
| `clu heartbeat` | Run maintenance checks (or set via cron) |
| `clu check <project>` | Check memory file staleness |
| `clu summarize <project>` | Run post-session summarizer |
| `clu --adapter <name> <project>` | Override adapter |
| `clu --persona <name> <project>` | Override persona |

## Writing a Custom Adapter

Copy `adapters/custom.sh`, rename it, and implement two functions:

- `adapter_launch` — start the agent session using `$AGENT_PROMPT` and other env vars
- `adapter_summarize` — run post-session summarization

See existing adapters for examples.

## Backup, Sync & Memory Repo

Two layers of git:

- `~/.clu/` is the framework code repo (this one).
- `~/repos/clu-memory/` is a separate private repo holding the
  actual memory files. `setup-memory-sync.sh` creates it and
  symlinks `~/.clu/shared/memory`, `~/.clu/shared/agent` and every
  `~/.clu/projects/*/memory` into it. The heartbeat (task 9)
  commits and pushes it every night.

To deploy on a new machine:

```bash
git clone <clu-repo>        ~/repos/clu
git clone <clu-memory-repo> ~/repos/clu-memory
cd ~/repos/clu && ./install.sh
~/.clu/setup-memory-sync.sh
```

## Documentation

The complete manual (German, both user guide and architecture
reference): [`docs/CLU-DOCUMENTATION.md`](docs/CLU-DOCUMENTATION.md).

Other docs:
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — original architecture deep-dive (English)
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — operations guide (English)
- [`docs/DIALOGUE-SUMMARY.md`](docs/DIALOGUE-SUMMARY.md) — design conversation archive

## License

MIT
