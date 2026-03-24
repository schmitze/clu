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
├── heartbeat.sh         # cron-triggered maintenance
├── adapters/            # provider abstraction layer
│   ├── claude-code.sh   # Claude Code adapter
│   ├── aider.sh         # Aider adapter
│   └── cursor.sh        # Cursor adapter
├── personas/            # agent character definitions
│   ├── architect.md
│   ├── implementer.md
│   ├── reviewer.md
│   ├── researcher.md
│   ├── writer.md
│   ├── default.md
│   └── _router.md       # dynamic persona switching logic
├── projects/
│   └── my-project/
│       ├── project.yaml
│       ├── constraints.md
│       └── memory/
│           ├── decisions.md
│           ├── architecture.md
│           ├── journal.md
│           ├── context.md
│           ├── findings.md     # for research projects
│           ├── hypotheses.md   # for research projects
│           └── days/           # daily session logs (YYYY-MM-DD.md)
├── shared/
│   ├── core-prompt.md   # system prompt template
│   ├── constraints.md   # global rules
│   ├── imported/        # global Claude Code imports (via `clu import`)
│   ├── memory/          # USER memory (about you)
│   │   ├── preferences.md
│   │   ├── patterns.md
│   │   └── learnings.md
│   └── agent/           # AGENT memory (how to work)
│       ├── skills.md
│       ├── workflows.md
│       └── meta.md
└── templates/
    └── new-project/     # scaffolding for new projects
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

The agent proactively detects decision-worthy moments and proposes writing them to the appropriate memory file. You confirm before anything is saved. At session end, the agent auto-classifies outputs across all three memory scopes and writes today's daily log.

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

## Backup & Portability

The entire `~/.clu` directory is self-contained. Push it to a private git repo:

```bash
cd ~/.clu
git init
git add -A
git commit -m "initial clu setup"
git remote add origin <your-repo>
git push -u origin main
```

To deploy on a new machine: clone + run `install.sh`.

## Documentation

For a comprehensive guide in German covering architecture, memory system, personas, adapters, maintenance, and system transfer, see [`docs/CLU-DOCUMENTATION.md`](docs/CLU-DOCUMENTATION.md).

## License

MIT
