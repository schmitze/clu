# clu — Operations Guide

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Installation](#2-installation)
3. [First Launch](#3-first-launch)
4. [Daily Operation](#4-daily-operation)
5. [Memory Management](#5-memory-management)
6. [Persona Management](#6-persona-management)
7. [Adapter Management](#7-adapter-management)
8. [Bootstrap Onboarding](#8-bootstrap-onboarding)
9. [Heartbeat (Maintenance Between Sessions)](#9-heartbeat-maintenance-between-sessions)
10. [Backup & Version Control](#10-backup--version-control)
11. [Migration & Re-deployment](#11-migration--re-deployment)
12. [Maintenance & Hygiene](#12-maintenance--hygiene)
13. [Troubleshooting](#13-troubleshooting)
14. [Upgrading](#14-upgrading)

---

## 1. Prerequisites

### Required

- **Bash 4+** (macOS ships Bash 3 — install via `brew install bash`)
- **At least one agent CLI** installed and authenticated:
  - Claude Code: `npm install -g @anthropic-ai/claude-code`
  - Aider: `pip install aider-chat`
  - Or any other CLI-based agent

### Optional but recommended

- **git** — for backup and version control of the config directory

### Compatibility

| OS | Status | Notes |
|---|---|---|
| macOS | Fully supported | Install Bash 4+ via Homebrew |
| Linux (Ubuntu/Debian/Arch) | Fully supported | Bash 4+ is standard |
| WSL2 on Windows | Fully supported | Use Linux instructions |
| Windows (native) | Not supported | Use WSL2 |

---

## 2. Installation

### From a git clone

```bash
git clone <your-repo-url> /tmp/clu-install
cd /tmp/clu-install
chmod +x install.sh
./install.sh
```

### From the tar archive

```bash
tar xzf clu.tar.gz
cd clu
chmod +x install.sh
./install.sh
```

### What the installer does

1. Copies all files to `~/.clu/` (configurable via `$CLU_HOME`), excluding `.git/` on fresh installs
2. Sets executable permissions on `launcher` and helper scripts
3. Adds two lines to your shell RC file (`~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`):
   - `export CLU_HOME='~/.clu'`
   - `alias clu='~/.clu/launcher'`
4. Checks for optional dependencies and reports their status
5. Does NOT touch any existing projects if upgrading
6. Preserves user's `config.yaml` on upgrade

### Post-install verification

```bash
source ~/.zshrc          # or ~/.bashrc
clu --help             # should print usage info
clu list               # should show example-research project
```

### Custom install location

```bash
export CLU_HOME="$HOME/my-custom-path"
./install.sh
```

All paths resolve relative to `$CLU_HOME`.

---

## 3. First Launch

### Step 1: Run the onboarding interview (recommended)

```bash
clu bootstrap
```

This launches an agent-guided interview that conversationally populates your user profile. Much easier than editing markdown by hand. The agent asks about your identity, work context, communication style, and preferences, then writes everything to `shared/memory/preferences.md`.

Alternatively, edit manually:

```bash
$EDITOR ~/.clu/shared/memory/preferences.md
```

This file is your full user profile — identity, work context, current priorities, key people, communication style, technical environment, working patterns, and opinions. Every agent session reads it.

### Step 2: Review global constraints

```bash
$EDITOR ~/.clu/shared/constraints.md
```

These are rules that apply to every project and every session. The defaults are sensible, but you may want to add things like "never commit to main directly" or "always write tests."

### Step 3: Create your first project

```bash
clu new my-project
```

This scaffolds a project directory from the template:

```
~/.clu/projects/my-project/
├── project.yaml         # ← edit this next
├── constraints.md       # ← project-specific rules
└── memory/
    ├── decisions.md
    ├── architecture.md
    ├── journal.md
    ├── context.md
    ├── findings.md
    └── hypotheses.md
```

### Step 4: Configure the project

```bash
$EDITOR ~/.clu/projects/my-project/project.yaml
```

Key fields to set:

```yaml
name: "my-project"
type: software              # software | research | writing | strategy | mixed
description: "Brief description for the project picker"
repo_path: ~/code/my-project   # path to the actual codebase (null if non-code)
default_persona: default        # which persona to start with
```

### Step 5: Launch

```bash
clu my-project
```

The launcher will:
1. Load the project config
2. Assemble the system prompt (persona + traits + constraints + memory)
3. Run a staleness check on memory files
4. Dispatch to the configured adapter (default: claude-code)
5. The adapter injects the prompt and starts the agent session

---

## 4. Daily Operation

### Starting a session

```bash
# Launch a specific project
clu my-project

# Workspace mode — agent sees all projects, can switch between them
clu

# Override the persona for this session
clu --persona reviewer my-project

# Override the adapter for this session
clu --adapter aider my-project
```

### During a session

The agent operates according to the assembled system prompt. Key behaviors:

**Memory detection:** The agent continuously watches for decision-worthy moments and proposes memory updates. When it detects one, you will see:

```
📝 Proposed memory update → decisions.md
┌─────────────────────────────────────
│ ### DEC-005 – Use PostgreSQL over SQLite
│ - Date: 2026-03-13
│ - Status: accepted
│ - Context: Need a database for the API
│ - Decision: PostgreSQL for concurrent access
│ - Alternatives: SQLite (simpler but single-writer)
│ - Consequences: Need to run a DB server in dev
└─────────────────────────────────────
Save this? (y/n/edit)
```

Respond `y` to save, `n` to skip, `edit` to modify.

**Persona switching:** If dynamic personas are enabled, the agent transitions between roles automatically:

```
[→ Architect mode (O:8 C:7 A:4 — creative, structured, direct)]
```

**Trait adjustment:** You can shift behavior mid-session:
- "be more creative" → Openness increases
- "be more direct" → Agreeableness decreases
- "be more cautious" → Neuroticism increases
- "talk less" → Extraversion decreases
- "be more thorough" → Conscientiousness increases

### Ending a session

When you signal you are done, the agent triggers the end-of-session protocol:

1. Scans the conversation for uncommitted memory updates
2. Classifies outputs across all three memory scopes (user/agent/project)
3. Writes today's daily log (`memory/days/YYYY-MM-DD.md`)
4. Updates L0 abstracts for modified files
5. Presents everything for batch confirmation

After the agent exits, the launcher may prompt for a quick manual summary if auto-summarization is enabled.

### The `clu` subcommands

| Command | What it does |
|---|---|
| `clu` | Workspace mode — agent sees all projects, can switch between them and create new ones |
| `clu <project>` | Launch a specific project |
| `clu new <name>` | Create a new project from template |
| `clu list` | List all projects with type and description |
| `clu import` | Import Claude Code session history, global settings (plugins, MCP servers), plans, project memory, and local `.claude/settings.local.json` from repos. Writes to `~/.clu/shared/imported/` and per-project dirs |
| `clu import --list` | Preview what would be imported (read-only) |
| `clu bootstrap` | Agent-guided onboarding interview |
| `clu bootstrap --force` | Re-run onboarding even if already done |
| `clu heartbeat` | Run all maintenance tasks |
| `clu heartbeat <project>` | Run maintenance for a specific project |
| `clu check <project>` | Check memory file staleness |
| `clu summarize <project>` | Run the post-session summarizer manually |
| `clu --adapter <name> <project>` | Launch with a different adapter |
| `clu --persona <name> <project>` | Launch with a specific persona |
| `clu --help` | Print usage information |

---

## 5. Memory Management

### The three scopes

| Scope | Location | Loaded when | Contains |
|---|---|---|---|
| User | `shared/memory/` | Every session | Your preferences, cross-project patterns, lessons learned |
| Agent | `shared/agent/` | Every session | Skills the agent has learned, reusable workflows, meta-knowledge |
| Project | `projects/<n>/memory/` | Active project only | Decisions, architecture, findings, hypotheses, context, journal |

### The three tiers

| Tier | What | Size | Loaded |
|---|---|---|---|
| L0 – Abstract | `abstract:` field in front-matter | ~20-50 tokens | Always, all files |
| L1 – Overview | First ~50 lines of file | ~200-500 tokens | Session start, relevant files |
| L2 – Full | Entire file | Varies | On-demand, when agent needs specifics |

### Memory file anatomy

Every memory file follows this format:

```markdown
---
last_verified: 2026-03-13
scope: project
type: decisions
abstract: "12 architectural decisions, most recent: migrated API to Hono."
entry_count: 12
---

# Decisions

### DEC-001 – Use TypeScript over JavaScript
- **Date:** 2026-01-15
- **Status:** accepted
...
```

### When to manually edit memory

Most memory writes happen through the agent, but some situations warrant manual editing:

- **Bulk cleanup:** When memory files accumulate too many entries and need pruning
- **Scope promotion:** Moving a pattern from project memory to shared patterns
- **Status updates:** Marking a decision as `superseded` after a pivot
- **Abstract refresh:** Rewriting the L0 abstract after significant changes
- **Staleness resolution:** Updating `last_verified` after reviewing a file

### Memory file reference

**Project memory files:**

| File | Purpose | Entry format |
|---|---|---|
| `decisions.md` | Choices with rationale | `DEC-NNN` — status, context, decision, alternatives, consequences |
| `architecture.md` | Current system/structure state | Free-form, updated as system evolves |
| `journal.md` | Weekly highlights index | Week summary, key outcomes, decisions made, open threads |
| `days/YYYY-MM-DD.md` | Daily session logs | What happened, decisions, open threads, next session |
| `context.md` | Domain knowledge, requirements | Free-form — the project "brief" |
| `findings.md` | Research results | `FND-NNN` — source, finding, confidence, implications |
| `hypotheses.md` | Working theories | `HYP-NNN` — hypothesis, evidence for/against, status, how to test |

**User memory files:**

| File | Purpose |
|---|---|
| `preferences.md` | Communication style, coding conventions, tool choices |
| `patterns.md` | Reusable approaches proven across 3+ projects |
| `learnings.md` | Cross-project lessons from mistakes |

**Agent memory files:**

| File | Purpose |
|---|---|
| `skills.md` | Techniques the agent has learned work well |
| `workflows.md` | Validated multi-step processes |
| `meta.md` | Self-knowledge about what works and what doesn't |

---

## 6. Persona Management

### Built-in personas

| Persona | O | C | E | A | N | Best for |
|---|---|---|---|---|---|---|
| Architect | 8 | 7 | 6 | 4 | 6 | System design, trade-off analysis, structure |
| Implementer | 4 | 8 | 3 | 6 | 3 | Coding, building, executing plans |
| Reviewer | 5 | 9 | 5 | 3 | 7 | Code review, quality checks, critiques |
| Researcher | 9 | 6 | 7 | 5 | 5 | Research, exploration, hypothesis formation |
| Writer | 7 | 7 | 5 | 6 | 4 | Prose, documentation, reports |
| Default | 6 | 6 | 6 | 6 | 4 | General work, conversation, planning |

### Creating a custom persona

**Interactive wizard:**

```bash
~/.clu/create-persona.sh
```

Walks you through naming the persona, defining its role, and scoring each OCEAN dimension.

**Manual creation:** Create a file in `~/.clu/personas/<name>.md`:

```markdown
# Persona: Mentor

## Traits

\```yaml
openness:          7
conscientiousness: 6
extraversion:      8
agreeableness:     7
neuroticism:       3
\```

## Role
Patient teacher who explains concepts clearly and guides
learning through questions rather than just giving answers.

## Behavioral Notes
- High E + High A = approachable, talks through reasoning
- High O = draws connections to help understanding
- Low N = encouraging, doesn't focus on what could go wrong
```

Then add it to a project's `available_personas` list in `project.yaml`.

### Per-project trait overrides

In `project.yaml`, you can shift trait scores for specific personas without creating new files:

```yaml
trait_overrides:
  reviewer:
    agreeableness: +2    # softer reviews for this collaborative project
  implementer:
    neuroticism: +2      # more cautious in this safety-critical codebase
```

### Disabling dynamic switching

In `config.yaml`, set `dynamic_personas: false` to lock the agent into the project's `default_persona` for the entire session.

---

## 7. Adapter Management

### How adapters work

An adapter is a bash script in `adapters/` that implements two functions:

- `adapter_launch` — receives `$AGENT_PROMPT` (the fully assembled system prompt) and starts the agent session
- `adapter_summarize` — runs post-session summarization

The launcher sets these environment variables before calling the adapter:

| Variable | Contents |
|---|---|
| `$AGENT_PROMPT` | Full assembled system prompt (personas + traits + constraints + memory) |
| `$AGENT_PROJECT_NAME` | Project name |
| `$AGENT_PROJECT_DIR` | Full path to project dir in clu |
| `$AGENT_PROJECT_TYPE` | `software`, `research`, `writing`, `strategy`, or `mixed` |
| `$AGENT_REPO_PATH` | Path to the project's working directory/repository |
| `$AGENT_PERSONA` | Active persona name |
| `$AGENT_HOME` | Path to clu root |

### Changing the default adapter

In `config.yaml`:

```yaml
default_adapter: aider    # or: claude-code, cursor, custom
```

### Writing a new adapter

1. Copy `adapters/custom.sh` to `adapters/my-tool.sh`
2. Implement `adapter_launch`:
   - Write `$AGENT_PROMPT` to whatever file your tool reads (system prompt, config file, etc.)
   - Launch the tool pointing at `$AGENT_REPO_PATH`
   - Clean up any temporary files when the tool exits
3. Implement `adapter_summarize` (optional — can delegate to the built-in journal prompt)
4. Use it: `clu --adapter my-tool my-project`

### Adapter-specific notes

**Claude Code:** Writes `CLAUDE.md` to the repo directory. Backs up any existing `CLAUDE.md` and restores it after the session ends. Memory file paths are embedded in the prompt so Claude can read/write them directly.

**Aider:** Uses `--system-prompt-file` for the prompt and `--read` flags for each memory file. Memory files are read-only in Aider sessions — updates happen through the post-session summarizer.

**Cursor:** Writes `.cursorrules` with the prompt AND inlined memory (Cursor cannot read external files at runtime). Memory is a snapshot at launch time. Updates require relaunching.

---

## 8. Bootstrap Onboarding

### First-time setup

Instead of manually editing preferences.md, run the onboarding interview:

```bash
clu bootstrap
```

This launches an agent session that interviews you conversationally about your identity, work context, communication style, technical environment, and working patterns. The agent populates `shared/memory/preferences.md` (your user profile) and optionally adjusts `shared/constraints.md` (your global rules).

The interview runs once. A `.bootstrapped` marker file prevents re-runs. To redo:

```bash
clu bootstrap --force
```

### What gets populated

The bootstrap interview fills in the user profile with sections for: who you are (name, role, timezone), your work context, current priorities, key people, communication style, technical environment, working patterns, and strong opinions. This information is read by the agent at the start of every session.

---

## 9. Heartbeat (Maintenance Between Sessions)

### Manual run

```bash
clu heartbeat              # all projects
clu heartbeat my-project   # specific project
```

### What it does

1. **Memory staleness check** — scans all memory files across shared and project memory, flags any with `last_verified` older than the threshold
2. **Daily log hygiene** — counts sessions this week per project, suggests weekly journal rollup on Mondays, creates `memory/days/` directories if missing
3. **User profile freshness** — checks if `preferences.md` has been filled in (flags sparse profiles, suggests running `clu bootstrap`)
4. **Morning brief** — surfaces yesterday's open threads and "next session" notes from daily logs, so you know where to pick up

### Cron setup

For automatic daily maintenance at 8am:

```bash
crontab -e
# Add this line:
0 8 * * * $HOME/.clu/heartbeat.sh >> $HOME/.clu/heartbeat.log 2>&1
```

The heartbeat is non-interactive — it reads files and logs output. It never modifies memory files or starts agent sessions.

---

## 10. Backup & Version Control

### Initial setup

The entire `~/.clu` directory is self-contained and designed to be a git repository:

```bash
cd ~/.clu
git init
git add -A
git commit -m "initial clu setup"
git remote add origin git@github.com:yourname/clu-config.git
git push -u origin main
```

### What to commit

**Always commit:**
- `config.yaml` — global settings
- `launcher` — the entry point
- `install.sh` — deployment script
- `adapters/` — all adapter scripts
- `personas/` — all persona definitions
- `shared/` — global memory, constraints, core prompt, agent memory
- `templates/` — project scaffolding
- `docs/` — documentation

**Commit per preference:**
- `projects/` — project-specific memory and config. Commit if you want portability across machines. Skip if projects contain sensitive data.

### .gitignore considerations

The default `.gitignore` excludes temp files and macOS artifacts. If your memory files contain sensitive information (client names, internal URLs, credentials), add:

```gitignore
projects/*/memory/
shared/memory/
shared/agent/
```

### Routine backup workflow

After any significant session:

```bash
cd ~/.clu
git add -A
git commit -m "session: [project-name] — [brief description]"
git push
```

Or automate it. Add to your shell RC:

```bash
clu-backup() {
    cd "$CLU_HOME" && git add -A && git commit -m "auto-backup $(date +%Y-%m-%d-%H%M)" && git push
}
```

---

## 11. Migration & Re-deployment

### Deploying to a new machine

```bash
# On the new machine:
git clone git@github.com:yourname/clu-config.git /tmp/clu-install
cd /tmp/clu-install
chmod +x install.sh
./install.sh
source ~/.zshrc

# Verify:
clu list
```

The installer detects existing installations and preserves project data during upgrades.

### Moving to a different location

```bash
# 1. Move the directory
mv ~/.clu ~/new-location/.clu

# 2. Update the env variable in your shell RC:
export CLU_HOME="$HOME/new-location/.clu"

# 3. Update the alias:
alias clu="$CLU_HOME/launcher"

# 4. Reload:
source ~/.zshrc
```

### Migrating between machines with different agent tools

The adapter pattern makes this straightforward. On the new machine:

1. Clone your clu repo
2. Run the installer
3. Install whatever agent CLI you want to use
4. Change `default_adapter` in `config.yaml`
5. Launch — all your memory, personas, and project context carry over

### Exporting a single project

```bash
tar czf my-project-export.tar.gz -C ~/.clu/projects my-project
```

To import on another machine:

```bash
tar xzf my-project-export.tar.gz -C ~/.clu/projects/
```

---

## 12. Maintenance & Hygiene

### Memory staleness checks

Run periodically to catch outdated memory:

```bash
clu check my-project
```

Output:

```
🔍 Memory staleness check for: my-project (threshold: 30d)

  decisions.md        ✅  (verified: 2026-03-10)
  architecture.md     ⚠️  STALE (45 days)  (verified: 2026-01-27)
  journal.md          ✅  (verified: 2026-03-13)
  days/               3 logs this week
  preferences.md      ✅  (verified: 2026-03-01)
```

To resolve: open the stale file, verify its contents are still accurate, update `last_verified` in the front-matter.

### Memory pruning

Over time, memory files grow. Periodically review and prune:

- **decisions.md:** Mark superseded decisions with `Status: superseded` and optionally archive old ones to a `decisions-archive.md`
- **daily logs (days/):** These accumulate over months. Periodically archive old daily logs (e.g., `tar czf days-2026-Q1.tar.gz days/2026-01-* days/2026-02-* days/2026-03-*` and remove originals). Keep at least the last 30 days accessible.
- **journal.md:** Update the weekly index when daily logs are archived so the highlights remain accessible
- **findings.md / hypotheses.md:** Close resolved hypotheses, archive validated findings that have been incorporated into decisions

### L0 abstract maintenance

The L0 abstract should always reflect the file's current state. If you manually edit memory files, update the `abstract:` field in the front-matter. Example:

```yaml
abstract: "15 decisions, 3 superseded. Most recent: switched from REST to GraphQL."
```

### Project archiving

For completed or paused projects:

```bash
# Archive
mv ~/.clu/projects/old-project ~/.clu/projects/_archived/old-project

# Or tar it
tar czf ~/.clu/archive/old-project-2026-03.tar.gz \
    -C ~/.clu/projects old-project
rm -rf ~/.clu/projects/old-project
```

The `clu list` command only scans top-level directories in `projects/`, so archived projects won't appear in the picker.

### Config file health check

Verify that your setup is internally consistent:

```bash
# Check all persona files referenced in projects exist
for proj in ~/.clu/projects/*/; do
    echo "=== $(basename "$proj") ==="
    grep "available_personas" "$proj/project.yaml" -A 20 | grep "^  -" | while read -r _ p; do
        if [[ ! -f ~/.clu/personas/$p.md ]]; then
            echo "  ❌ Missing persona: $p"
        else
            echo "  ✅ $p"
        fi
    done
done
```

---

## 13. Troubleshooting

### "Config not found" on launch

The launcher cannot find `config.yaml`. Either `$CLU_HOME` is not set or points to the wrong location.

```bash
echo $CLU_HOME     # should print the path
ls $CLU_HOME/config.yaml   # should exist
```

Fix: re-run `source ~/.zshrc` or re-run `install.sh`.

### Agent doesn't see memory or persona changes

The system prompt is assembled at launch time. Changes to memory files, personas, or constraints only take effect in the NEXT session. To apply changes mid-session, you would need to restart.

Exception: Claude Code reads files referenced in the prompt on-demand, so if the prompt includes file paths (which the Claude Code adapter does), the agent can pick up changes to memory files during a session.

### Existing CLAUDE.md is getting overwritten

The Claude Code adapter backs up any existing `CLAUDE.md` before writing its own, and restores it after the session. If the session crashes or is killed (Ctrl+C), the backup may not be restored. Check for `CLAUDE.md.clu-backup` in your repo and restore manually:

```bash
mv CLAUDE.md.clu-backup CLAUDE.md
```

### Session summary not appearing

The post-session summarizer only runs if `auto_summarize: true` in `config.yaml`. It also requires an interactive terminal — it won't work if the agent was launched in a non-interactive context.

### Memory file has invalid YAML front-matter

If the agent writes malformed front-matter (mismatched quotes, bad indentation), the launcher's L1 loader may fail silently. Check the file manually:

```bash
head -10 ~/.clu/projects/my-project/memory/decisions.md
```

The front-matter must start and end with `---` on their own lines.

### Persona not switching

If `dynamic_personas: false` in `config.yaml`, the router is disabled. Also check that the persona is listed in the project's `available_personas` in `project.yaml`.

---

## 14. Upgrading

### Upgrading the framework files (preserving your data)

When you pull a new version of clu:

```bash
cd /path/to/new-clu
./install.sh
```

The installer in upgrade mode:
- Overwrites: `launcher`, `adapters/`, `personas/`, `templates/`, `shared/core-prompt.md`, `shared/constraints.md`
- Preserves: `config.yaml`, `projects/`, `shared/memory/`, `shared/agent/`, `shared/imported/`

If you have customized personas or constraints, back them up first or maintain your own branch.

### Upgrading memory file format

If a new version changes the memory file format (e.g., adds new front-matter fields), you may need to update existing files. Check the changelog and run a migration if needed. A simple migration example:

```bash
# Add abstract field to all memory files that don't have it
for f in ~/.clu/projects/*/memory/*.md ~/.clu/shared/memory/*.md ~/.clu/shared/agent/*.md; do
    if ! grep -q "^abstract:" "$f" 2>/dev/null; then
        sed -i '/^scope:/a abstract: "TODO: add summary"' "$f"
        echo "Updated: $f"
    fi
done
```
