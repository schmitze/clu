# Trait Learning System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Personas lernen aus User-Interaktionen und passen ihre OCEAN-Scores an — rein prompt-basiert.

**Architecture:** Drei neue Prompt-Instruktionen in `core-prompt.md`: (1) explizite Signal-Erkennung, (2) End-of-Session Reflexion, (3) Session-Start Aggregation. Signale werden in `shared/agent/meta.md` gespeichert. Persona-Dateien werden bei bestätigter Anpassung direkt geändert.

**Tech Stack:** Markdown (Prompt-Instruktionen), YAML (config)

**Spec:** `docs/superpowers/specs/2026-03-25-trait-learning-design.md`

---

### Task 1: Add `trait_learning` config switch

**Files:**
- Modify: `config.yaml:43-47`

- [ ] **Step 1: Add trait_learning setting to config.yaml**

Add under the `# ── Persona system` section, after `dynamic_personas: true`:

```yaml
# Enable trait learning — agent logs behavioral signals and
# proposes trait adjustments based on accumulated evidence.
# Requires dynamic_personas: true.
trait_learning: true
```

- [ ] **Step 2: Commit**

```bash
git add config.yaml
git commit -m "feat: add trait_learning config switch"
```

---

### Task 2: Replace Trait Corrections with Trait Signals in meta.md

**Files:**
- Modify: `shared/agent/meta.md`

- [ ] **Step 1: Replace `## Trait Corrections` section**

Replace the existing empty `## Trait Corrections` section with:

```markdown
## Trait Signals

<!-- Signal format:
### SIG-NNN – [short description]
- **Date:** YYYY-MM-DD
- **Persona:** [persona name]
- **Trait:** [O|C|E|A|N]
- **Direction:** [+1|-1]
- **Type:** [explicit|implicit]
- **Context:** [what triggered this signal]
- **Status:** [pending|applied → persona.md Trait: old→new (date)]
-->
```

- [ ] **Step 2: Update frontmatter abstract**

Update `abstract:` to:
```
"Self-knowledge about agent effectiveness — trait signals, patterns, and what works."
```

- [ ] **Step 3: Commit**

```bash
git add shared/agent/meta.md
git commit -m "feat: replace Trait Corrections with Trait Signals format in meta.md"
```

---

### Task 3: Add Trait Learning instructions to core-prompt.md

This is the main task — three new prompt sections that teach the agent how to detect, log, and propose trait adjustments.

**Files:**
- Modify: `shared/core-prompt.md:19-34` (Big Five section — replace Self-tuning line)
- Modify: `shared/core-prompt.md:122-131` (End-of-Session Protocol — add Trait-Reflexion step)

- [ ] **Step 1: Replace the Self-tuning line with Trait Learning block**

Replace line 31 (`**Self-tuning:** Log trait corrections...`) with:

```markdown
**Trait Learning** (when `trait_learning: true` in config):

Explicit signal detection — when the user corrects your behavior mid-session
("be more direct", "less cautious", "talk less"), immediately propose logging
a trait signal:

```
📝 Trait-Signal erkannt → shared/agent/meta.md
┌─────────────────────────────────────
│ ### SIG-NNN – "[user's words]"
│ - **Date:** [today]
│ - **Persona:** [active persona]
│ - **Trait:** [O|C|E|A|N]
│ - **Direction:** [+1|-1]
│ - **Type:** explicit
│ - **Context:** [brief context]
│ - **Status:** pending
└─────────────────────────────────────
Log this signal? (y/n)
```

Map common corrections:
- "sei direkter" / "weniger diplomatisch" → A: -1
- "weniger vorsichtig" / "mach einfach" → N: -1
- "rede weniger" / "kürzer bitte" → E: -1
- "sei kreativer" / "denk weiter" → O: +1
- "gründlicher bitte" / "prüf nochmal" → C: +1

Do not propose signals for traits already at floor (≤1) or ceiling (≥10).
```

- [ ] **Step 2: Add Session-Start Aggregation block**

After the Trait Learning block (before the `---` separator on line 35), add:

```markdown
**Session-Start: Trait Aggregation** — at the start of each session, read
`shared/agent/meta.md` → `## Trait Signals`. If there are `pending` signals:

1. Group by Persona + Trait + Direction
2. Check thresholds:
   - **Explicit:** 1 signal → propose adjustment
   - **Implicit:** 3+ signals same direction → propose adjustment
   - **Mixed:** 1 explicit + 1 implicit → propose adjustment
3. Check cooldown: skip if the same persona+trait was adjusted within the last 3 sessions
4. Propose adjustment (max ±1 per trait per cycle):

```
🎭 Trait-Anpassung vorgeschlagen → personas/[persona].md
┌─────────────────────────────────────
│ [Trait]: [old] → [new]
│
│ Evidenz ([N] Signale seit [date]):
│  • SIG-NNN [type]: [description]
│  • ...
│
│ Max ±1 pro Zyklus. Nächste Anpassung frühestens
│ nach 3 weiteren Sessions.
└─────────────────────────────────────
Anpassen? (y/n)
```

On confirmation:
- Edit the persona file: update the trait score and its comment
- Mark all contributing signals as `applied → [persona].md [Trait]: [old]→[new] ([date])`
- Traits must stay within 1–10
```

- [ ] **Step 3: Add Trait-Reflexion step to End-of-Session Protocol**

In the End-of-Session Protocol (line 122–131), insert a new step between
step 1 (Auto-classify) and step 2 (Write daily log). Renumber subsequent steps.

New step 2:

```markdown
2. **Trait-Reflexion** (when `trait_learning: true`): Review the entire session
   for implicit behavioral signals. Look for patterns:
   - User repeatedly cuts short explanations → E may be too high
   - User rejects creative suggestions, picks pragmatic option → O may be too high
   - User corrects mistakes the agent missed → C or N may be too low
   - User skips agent's clarifying questions → N may be too high
   - User asks for details the agent should have provided → C may be too low

   If signals found, propose logging them:
   ```
   🎭 Trait-Reflexion ([active persona])
   ┌─────────────────────────────────────
   │ [Summarize explicit signals if any]
   │
   │ [Summarize implicit observations if any]
   │
   │ Signale loggen? (y/n/review)
   └─────────────────────────────────────
   ```
   If no signals detected: skip silently (no output).
   Do not propose signals for traits already at floor (≤1) or ceiling (≥10).
```

- [ ] **Step 4: Verify the full core-prompt.md reads correctly**

Read back the modified file end-to-end. Check:
- No duplicate instructions
- Step numbering in End-of-Session is correct (now 1–7 instead of 1–6)
- Trait Learning block and Session-Start Aggregation are between the
  Runtime adjustment line and the `---` separator
- No broken markdown formatting

- [ ] **Step 5: Commit**

```bash
git add shared/core-prompt.md
git commit -m "feat: add trait learning instructions to core prompt

Teaches the agent to detect explicit trait corrections, reflect on
implicit signals at session end, and propose trait adjustments at
session start based on accumulated evidence."
```

---

### Task 4: Update documentation

**Files:**
- Modify: `docs/CLU-DOCUMENTATION.md` (Persona-System section)

- [ ] **Step 1: Add Trait Learning subsection**

After the "Dynamisches Switching" subsection (around line 295), add a new
subsection `### Trait Learning`:

```markdown
### Trait Learning

Wenn `trait_learning: true` in `config.yaml` (Default), lernen Personas
aus den Interaktionen mit dem User:

**Explizite Signale:** Wenn der User Verhalten korrigiert ("sei direkter",
"rede weniger"), wird das sofort als Signal in `shared/agent/meta.md`
geloggt (nach Bestätigung).

**Implizite Signale:** Am Session-Ende reflektiert der Agent über
Interaktionsmuster — z.B. ob der User Erklärungen regelmäßig übersprungen
hat (→ E zu hoch?) oder kreative Vorschläge abgelehnt hat (→ O zu hoch?).

**Aggregation:** Am Session-Start prüft der Agent akkumulierte Signale.
Bei genug Evidenz (1 explizites oder 3+ implizite Signale) schlägt er
eine Trait-Anpassung vor. Max ±1 pro Trait pro Zyklus, Cooldown von
3 Sessions.

**Anpassung:** Bei Bestätigung wird die Persona-Datei direkt geändert.
Signale werden als `applied` markiert.

Signale werden in `shared/agent/meta.md` unter `## Trait Signals`
im Format `### SIG-NNN` gespeichert.
```

- [ ] **Step 2: Commit**

```bash
git add docs/CLU-DOCUMENTATION.md
git commit -m "docs: add trait learning section to CLU documentation"
```

---

### Task 5: Final commit and push

- [ ] **Step 1: Push all commits**

```bash
git push
```

- [ ] **Step 2: Verify file consistency**

Read `shared/core-prompt.md`, `shared/agent/meta.md`, `config.yaml` and
confirm all three reference the same terminology (Trait Signals, SIG-NNN,
trait_learning).
