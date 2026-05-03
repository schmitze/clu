# clu — Anleitung & Architektur

> **clu** (Codified Likeness Utility) ist ein provider-agnostisches
> Agent-Workstation-Framework. Es gibt KI-Agenten persistenten Kontext
> über Sessions, Projekte und Tools hinweg — Bash + Markdown + YAML
> als Kern, Python für Tools, SQLite für den Recall-Index.

Letzter Stand der Doku: 2026-05-02 (Refactor: Memory-Layer von 3 auf 2 Scopes, EoS-Ritual entfernt, Curator vor Session-Start). Wenn das deutlich in der Vergangenheit liegt, parallel `git log -- docs/CLU-DOCUMENTATION.md` checken.

---

# Inhaltsverzeichnis

**Teil A — Bedienung & Features**
1. [Was ist clu?](#1-was-ist-clu)
2. [Schnellstart](#2-schnellstart)
3. [Tägliche Bedienung](#3-tägliche-bedienung)
4. [Features im Detail](#4-features-im-detail)
5. [Verzeichnisstruktur](#5-verzeichnisstruktur)

**Teil B — Architektur & Mechanismen**

6. [Architektur-Überblick](#6-architektur-überblick)
7. [Launcher-Pipeline](#7-launcher-pipeline)
8. [Adapter-Schicht](#8-adapter-schicht)
9. [Persona-Engine](#9-persona-engine)
10. [Memory-System](#10-memory-system)
11. [Heartbeat](#11-heartbeat)
12. [Curator](#12-curator)
13. [Recall](#13-recall)
14. [Session-Recovery](#14-session-recovery)
15. [Skripte-Referenz](#15-skripte-referenz)
16. [Datei-Referenz](#16-datei-referenz)
17. [Erweiterungspunkte](#17-erweiterungspunkte)
18. [Troubleshooting](#18-troubleshooting)

---

# Teil A — Bedienung & Features

## 1. Was ist clu?

clu ist eine einzige Verzeichnis-Installation (`~/.clu`), die deinen
gesamten Agent-Setup zusammenhält:

- **Projekte** mit eigener Memory, Constraints, Default-Persona
- **Personas** als Big-Five-Trait-Profile (OCEAN, jeweils 1–10)
- **Memory** über Sessions hinweg, in zwei Scopes (Shared / Projekt)
- **Adapter** zu unterschiedlichen Agent-CLIs (Claude Code, Aider, Cursor, …)
- **Curator** läuft vor jedem Session-Start *und* nächtlich, schreibt Memory autonom aus Session-Transkripten
- **Recall** indexiert das Memory-Repo + alle Session-JSONLs für Volltextsuche
- **Heartbeat** als nächtlicher Wartungs-Job (Security, Compaction, Recall, Curator, wöchentliche Memory-Health-Review)
- **Memory-Sync** spiegelt Memory in ein eigenes privates Git-Repo

Beim Launch ruft clu zuerst den Curator (konsolidiert das letzte Session-Transkript zu einem Daily-Log-Eintrag), dann nimmt's Persona + Constraints + relevantes Memory, baut einen System-Prompt, übergibt ihn dem Adapter, der wiederum den Agent startet. Der Agent liest und schreibt Memory direkt auf Disk — clu hält die Struktur und Lebenszyklen.

### Designprinzipien

- **Provider-agnostisch.** Kein Lock-in auf ein bestimmtes CLI.
- **Alles ist Text.** Markdown, YAML, ein bisschen SQLite.
- **Eine Verzeichnis, ein Backup.** `~/.clu` ist self-contained.
- **Kein End-of-Session-Ritual.** Du tippst `/exit` und gehst. Curator macht den Daily-Log-Eintrag beim nächsten Session-Start (oder spätestens im nächtlichen Heartbeat).
- **Memory ist semi-automatisch.** Agent erkennt Decisions/Findings live mit Confidence-Tagging.
- **Persona statt Prompt-Engineering.** OCEAN-Trait-Scores steuern Verhalten direkt.

---

## 2. Schnellstart

### Installation

```bash
git clone <repo-url> /tmp/clu-install
cd /tmp/clu-install
chmod +x install.sh
./install.sh
```

`install.sh` kopiert den Code nach `~/.clu`, fügt den Shell-Alias
`clu='~/.clu/launcher'` in deine RC-Datei ein, prüft Dependencies,
fragt ob Cron-Heartbeat und systemd-Dashboard eingerichtet werden sollen.

Beim Upgrade bleiben `projects/`, `shared/memory/`,
`config.yaml`, Personas und alles unter `~/.clu/.secrets*` unangetastet.

### Erste Schritte

```bash
source ~/.bashrc                    # oder ~/.zshrc

clu bootstrap                       # Agent-geführtes Onboarding
                                    # → User-Profil, Default-Persona, optional erstes Projekt

clu new mein-projekt                # Neues Projekt aus Template
$EDITOR ~/.clu/projects/mein-projekt/project.yaml
                                    # type, description, repo_path, default_persona setzen

clu mein-projekt                    # Erste Session starten
```

---

## 3. Tägliche Bedienung

### Session-Modi

| Befehl | Modus |
|---|---|
| `clu` | Workspace — Agent sieht alle Projekte, kann zwischen ihnen navigieren |
| `clu <projekt>` | Projekt — Auto-Resume-Check (Haiku, ~10–15s); bei mid-flow → fortsetzen, sonst frische Session mit Memory + Persona |
| `clu --fresh <projekt>` / `clu fresh <projekt>` | Auto-Resume-Check überspringen, immer frische Session (Flag und Subcommand-Alias verhalten sich gleich) |
| `clu resume <projekt>` | Letzten Claude-Thread bedingungslos fortsetzen (`claude --continue`) — kein Memory-Inject, voller Thread |
| `clu --persona <name> <projekt>` | Override Persona |
| `clu --adapter <name> <projekt>` | Override Adapter (`claude-code`, `aider`, `cursor`, …) |

### Subcommands

| Befehl | Was er tut |
|---|---|
| `clu list` | Alle Projekte mit Typ und L0-Abstract |
| `clu new <name>` | Neues Projekt aus `templates/new-project/` |
| `clu summarize <projekt>` | No-op heute (Curator macht Daily Logs); Adapter-Hook bleibt für Custom-Adapter |
| `clu bootstrap` | Onboarding-Interview (User-Profil, Default-Persona) |
| `clu heartbeat` | Wartung manuell starten (sonst per systemd-Timer) |
| `clu dashboard [port]` | Web-Dashboard (Default Port 3141) |

### Mid-Session Projekt-Wechsel

Du kannst innerhalb einer laufenden Session wechseln:

1. Du sagst dem Agent „wechsle zu Projekt X"
2. Agent schreibt `X` in `/tmp/clu/switch-target` und beendet
3. `/exit`
4. Adapter erkennt die Datei, relauncht clu mit dem neuen Projekt

End-of-Session-Protokoll läuft automatisch vor dem Switch — Daily Log
und Memory-Updates für das alte Projekt werden geschrieben.

### Personas im Alltag

- Standard-Persona pro Projekt steht in `project.yaml` → `default_persona`
- Override per Launch: `clu --persona reviewer <projekt>`
- Wenn `dynamic_personas: true` (Default in `config.yaml`):
  - Agent wechselt mid-session selbst, wenn die Aktivität wechselt
    (Architektur-Diskussion → Architect, Bug-Hunting → Implementer)
  - Kündigt das an: `[→ Reviewer mode (C:9 A:3 N:7)]`
- Trait-Adjust per Sprache: „sei direkter" → A−2, „sei mutiger" → N−2,
  „rede weniger" → E−2. Die Anpassung gilt für die laufende Session.

### Memory im Alltag

Du musst nichts manuell schreiben. Drei Mechanismen, alle convergieren:

1. **Live, vom Agent während der Session** (semi-autonom):
   Agent erkennt eine Entscheidung oder ein Finding, klassifiziert die
   Confidence (high/medium/low) und schreibt direkt in die richtige
   Datei. Bei medium kommt ein `⚠️ confidence: medium` Marker. Du siehst
   eine einzeilige Notiz: `📝 Saved → projects/foo/memory/decisions.md · DEC-007 …`.
   Bei low wird gar nichts geschrieben.

2. **Curator vor jedem Session-Start** (im Launcher):
   Bevor das Memory in den neuen Prompt geladen wird, schaut der
   Curator nach orphan Sessions (Transkripte ohne Daily-Log-Eintrag).
   Sonnet 4.6 klassifiziert das Transkript und schreibt für die
   Session einen Subsection-Eintrag in `days/YYYY-MM-DD.md` plus
   ggf. neue DEC/FND/LRN-Blöcke. Latenz: instant wenn nichts pending,
   sonst 10–30s. Limit `--limit 5` pro Lauf.

3. **Curator im nächtlichen Heartbeat** (Sicherheitsnetz):
   Selber Code, andere Frequenz, höheres Limit (`--limit 20`). Falls
   du tagelang nicht in ein Projekt gehst, holt der Heartbeat das nach.

**Kein End-of-Session-Ritual.** Bei `/exit` passiert nichts. Der
Curator beim nächsten Session-Start macht das Daily Log.

Wenn du den Agent korrigieren willst: sag's einfach, er revertiert
oder editiert. Memory-Files sind Markdown — du kannst auch direkt
mit `$EDITOR` ran.

### Lange Sessions / Context-Management

Claude Code lädt bei jedem Turn die komplette JSONL-History — Token-Verbrauch
wächst linear. Bei OpenCode (geplant) wird das automatisch durch Tool-Output-Pruning
und geschützte Zonen abgefedert; in Claude Code ist Disziplin gefragt.

**Empfohlener Workflow:**

| Situation | Aktion |
|---|---|
| Klares Thema fertig | `/exit`. Auto-Resume-Detector entscheidet später |
| Pause innerhalb eines Vorhabens (Stunden bis 1 Tag) | `/exit` + später `clu <projekt>` (Auto-Resume holt verbatim) |
| Themen-Wechsel im selben Projekt am gleichen Tag | `/clear` (gleiche Session, frischer Kontext, CLAUDE.md bleibt) |
| Session ist lang aber thematisch zusammenhängend | `/compact "behalte den aktuellen Plan, drop file contents"` — Fokus-Argument zwingt zur Selektion |
| Du fragst nicht aktiv weiter | `/exit`. Tokens sparen ist der größte Hebel. |

**core-prompt.md weist den Agent an:**

- Bei `/compact` ohne Fokus → strukturiertes Summary nach OpenCode-Schema (Goal / Constraints / Progress / Key Decisions / Next Steps / Critical Context)
- Bei spürbar schwerer Session → Compact mit Fokus-Vorschlag in einer Zeile, nicht eigenmächtig
- Nach `Read` von Files > 500 Zeilen → 3–5 Sätze Digest in eigenen Worten statt Inhalt zu re-quoten

**Was diese Maßnahmen NICHT ersetzen:**

Tool-Output-Pruning auf Frontend-Ebene (das macht OpenCode automatisch im Hintergrund) ist von außen nicht nachrüstbar. Bei langen Multi-Tag-Sessions in Claude Code bleibt nur Disziplin oder Migration.

### Bootstrap (Onboarding-Interview)

```bash
clu bootstrap
```

Startet den `bootstrap.sh`-Wizard, der dich durch:

- User-Profil (`shared/memory/preferences.md`) — Rolle, Sprache, Stil, Prioritäten
- Default-Persona auswählen oder neue anlegen
- Optional: erstes Projekt anlegen
- Setzt `~/.clu/.bootstrapped` als Marker

Du kannst ihn jederzeit erneut aufrufen.

---

## 4. Features im Detail

### 4.1 Persona-System

Personas sind nicht „Charaktere", sondern Big-Five-Profile. Trait-Scores
steuern Verhalten konkret:

| Trait | Niedrig (1–3) | Hoch (7–10) |
|---|---|---|
| **O** — Openness | konventionell, bewährt | explorativ, kreativ |
| **C** — Conscientiousness | schnell, locker | akribisch, gründlich |
| **E** — Extraversion | wortkarg, leise | redselig, denkt laut |
| **A** — Agreeableness | direkt, widerspricht | kooperativ, diplomatisch |
| **N** — Neuroticism | mutig, schnell | risikoavers, vorsichtig |

Eingebaute Personas (in `personas/`):

| Persona | O | C | E | A | N | Fokus |
|---|---|---|---|---|---|---|
| Default | 7 | 8 | 5 | 3 | 3 | Generalist |
| Architect | 8 | 7 | 6 | 4 | 6 | Design, Trade-offs |
| Implementer | 4 | 8 | 3 | 6 | 3 | Bauen, Bugfixen |
| Reviewer | 5 | 9 | 5 | 3 | 7 | Kritisches Review |
| Researcher | 9 | 6 | 7 | 5 | 5 | Exploration |
| Writer | 7 | 7 | 5 | 6 | 4 | Texte, Doku |
| Entrepreneur | — | — | — | — | — | Produkt, Business |

`personas/_traits.md` enthält die ausführliche Mapping-Tabelle (welcher
Trait-Score erzeugt welches Verhalten). Der Agent liest sie bei Bedarf.

`personas/_router.md` steuert das dynamische Switching (wenn aktiv).

#### Custom Persona

```bash
~/.clu/create-persona.sh
# Interaktiver Wizard: Name + 5 Trait-Scores → personas/<name>.md
```

#### Per-Projekt Trait-Override

`project.yaml`:

```yaml
trait_overrides:
  reviewer:
    agreeableness: +2    # Reviewer hier weniger harsch
```

#### Trait-Learning

Wenn `trait_learning: true` in `config.yaml` (Default):

- **Explizite Korrektur** mid-session („sei direkter", „rede weniger")
  → Agent loggt ein Signal in `shared/memory/meta.md` (Format `### SIG-NNN`)
- **Implizite Beobachtung** (User skippt Erklärungen, lehnt kreative Ideen ab, …)
  → in der End-of-Session-Reflexion
- **Aggregation** beim nächsten Session-Start: Bei genug Evidenz
  (1 explizit oder 3+ implizit, gleiche Richtung) wird eine Anpassung
  vorgeschlagen. Max ±1 pro Trait pro Zyklus, 3 Sessions Cooldown.
- Auf Bestätigung wird die Persona-Datei direkt geändert, das Signal
  als `applied` markiert.

### 4.2 Memory-System (Übersicht)

Zwei orthogonale Scopes:

| Scope | Pfad | Was drinsteht | Lebensdauer |
|---|---|---|---|
| **Shared** | `shared/memory/` | Wer du bist, deine Lessons (LRN), externe Refs | projektübergreifend |
| **Projekt** | `projects/<n>/memory/` | Decisions (DEC), Architecture, Findings (FND), Daily Logs | pro Projekt |

Drei Tiers (wieviel Detail beim Session-Start in den Prompt):

| Tier | Inhalt | Wann geladen |
|---|---|---|
| **L0 — Abstract** | 1-Satz-Summary aus `abstract:`-Frontmatter | immer (alle Files) |
| **L1 — Overview** | erste ~20 Zeilen nach Frontmatter | Session-Start (relevante Files) |
| **L2 — Full** | alles | on-demand (Agent öffnet bei Bedarf) |

Mehr in [§10](#10-memory-system).

### 4.3 Memory-Sync (separates Git-Repo)

Memory liegt physisch in `~/repos/clu-memory/` (eigenes privates Repo)
und wird per Symlink in `~/.clu/shared/memory/`
und `~/.clu/projects/*/memory/` eingehängt. Der Heartbeat (Task 9)
committed und pushed jede Nacht automatisch.

Setup auf einer neuen Maschine:

```bash
~/.clu/setup-memory-sync.sh
# klont das Repo, mergt vorhandenes Memory rein, legt Symlinks
```

Vorteile: Memory ist getrennt versionsverwaltbar, kann auf mehreren
Maschinen synchron gehalten werden, geht nicht im clu-Code-Repo unter.

### 4.4 Auto-Memory von Claude Code (separater Layer)

Claude Code hat sein eigenes natives Memory in
`~/.claude/projects/<encoded-path>/memory/`. clu lässt das in Ruhe
und überspringt für Projekte mit aktivem Auto-Memory die L1-Injection
seines eigenen Project Memory (siehe DEC-002). Beide Systeme koexistieren:

- clu-Memory: cross-project Wissen, strukturiert (DEC/FND/LRN)
- Auto-Memory: natives Working Memory von Claude Code (Issues, Setup, Notizen)

`decisions.md` und `architecture.md` werden weiter von clu injected,
weil sie clu-exklusiver strukturierter Inhalt sind.

### 4.5 Curator (autonomes Memory-Schreiben)

`tools/curator/curator.py` läuft an zwei Stellen:

1. **Vor jedem Session-Start** im Launcher (`--limit 5`, timeout 60s) — konsolidiert das letzte Transkript bevor das Memory in den neuen Prompt geladen wird
2. **Im nächtlichen Heartbeat** als Task 11 (`--limit 20`) — Sicherheitsnetz für lange ungenutzte Projekte

Was er tut:

- Findet Sessions ohne zugehörigen Daily-Log-Eintrag (state-tracked in `curator-state.json`)
- Schickt sie an Sonnet 4.6 (über OpenRouter)
- Klassifiziert: schreibe Daily-Log-Sektion + ggf. DEC / FND / LRN
- Confidence-Tagging:
  - `≥0.8` (high) → Block as-is
  - `0.5–0.8` (medium) → Block mit `⚠️ confidence: medium` Marker
  - `<0.5` (low) → skippen, Begründung in `curator-skipped.log`
- Schreibt direkt ins Memory-Repo (kein y/n)
- Daily Logs hängen mehrere Sessions desselben Tages als `## Session HH:MM-HH:MM · <id8>` Subsections in dieselbe Datei

Logs:

- `~/.clu/curator-actions.log` — was geschrieben wurde
- `~/.clu/curator-skipped.log` — was abgelehnt wurde, mit Reason

Mehr in [§12](#12-curator).

### 4.6 Recall (FTS5-Suche)

`tools/recall/recall.py` baut einen SQLite/FTS5-Index über das gesamte
Memory + alle Claude-Code-Session-JSONLs.

- Markdown wird in Blöcke gechunkt (an `### XXX-NNN`-Headern)
- JSONLs werden turn-weise gechunkt (User-Turn + Assistant-Antwort)
- Inkrementell via Content-Hash (nur geänderte Files reindexiert)
- Heartbeat-Task 10 hält den Index aktuell

CLI:

```bash
~/.clu/tools/recall/recall.py search "vaultwarden tls"
~/.clu/tools/recall/recall.py search "DEC*" --type DEC --project clu
~/.clu/tools/recall/recall.py reindex          # incremental
~/.clu/tools/recall/recall.py reindex --full   # rebuild
~/.clu/tools/recall/recall.py stats
```

Index liegt in `~/.clu/recall.db` und ist disposable — jederzeit
neu rebuildbar.

### 4.7 Adapter

| Adapter | Tool | Methode |
|---|---|---|
| `claude-code.sh` | Claude Code CLI | schreibt `CLAUDE.md` ins Repo, startet `claude` |
| `aider.sh` | Aider | `--system-prompt-file` |
| `cursor.sh` | Cursor IDE | `.cursorrules` im Repo |
| `custom.sh` | Vorlage | du implementierst `adapter_launch` und `adapter_summarize` |

Der Adapter ist die einzige Stelle die tool-spezifisch ist. Memory,
Personas, Constraints sind tool-unabhängig.

### 4.8 Dashboard

`dashboard.py` ist ein optionales Flask-Web-Dashboard:

```bash
clu dashboard           # http://localhost:3141
clu dashboard 8080      # custom Port

# Als systemd User Service:
systemctl --user enable --now clu-dashboard
```

Zeigt Projekt-Übersicht, Security-Status, Heartbeat-Ergebnisse,
Action-Buttons (Memory-Compaction, Heartbeat, …).

---

## 5. Verzeichnisstruktur

```
~/.clu/                                # Live-Installation (durch install.sh aus Repo erzeugt)
├── config.yaml                        # globale Settings
├── .secrets.env                       # API-Keys (gitignored)
├── .bootstrapped                      # Marker: Onboarding fertig
├── .integrity-hashes                  # SHA-256 der Core-Dateien
│
├── launcher                           # Hauptbefehl `clu`
├── bootstrap.sh                       # Onboarding-Wizard
├── heartbeat.sh                       # nächtliche Wartung
├── install.sh                         # Installer/Upgrader
├── migrate.sh                         # Migrations-Helper
├── create-persona.sh                  # Persona-Wizard
├── setup-memory-sync.sh               # Memory-Repo-Setup
├── session-digest.py                  # JSONL → kompakter Digest
├── session-recovery.py                # crashed-session Recovery
├── dashboard.py                       # optionales Web-Dashboard
│
├── adapters/                          # tool-spezifische Launches
│   ├── claude-code.sh
│   ├── aider.sh
│   ├── cursor.sh
│   └── custom.sh
│
├── personas/                          # Big-Five-Profile
│   ├── _traits.md                     # Trait → Verhalten Mapping
│   ├── _router.md                     # dynamische Switching-Regeln
│   ├── _trait-learning.md             # Trait-Learning-Protokoll
│   ├── default.md
│   ├── architect.md
│   ├── implementer.md
│   ├── reviewer.md
│   ├── researcher.md
│   ├── writer.md
│   └── entrepreneur.md
│
├── shared/
│   ├── core-prompt.md                 # System-Prompt-Template mit {{VAR}}
│   ├── constraints.md                 # globale Regeln
│   ├── imported/                      # global Claude-Code-Imports (instance-lokal)
│   └── memory/        ─symlink→ clu-memory/shared/memory/
│       ├── preferences.md             # User-Profil
│       ├── learnings.md               # Lessons (LRN-NNN)
│       └── references.md              # externe Refs (Notion, APIs, …)
│
├── projects/
│   ├── _workspace/                    # Workspace-Modus-Projekt
│   └── <name>/
│       ├── project.yaml               # Typ, Repo, Persona, Constraints
│       ├── constraints.md             # Projekt-Regeln (zusätzlich zu shared)
│       └── memory/   ─symlink→ clu-memory/projects/<name>/memory/
│           ├── decisions.md           # DEC-NNN
│           ├── architecture.md
│           ├── findings.md            # FND-NNN
│           └── days/                  # Daily Logs (multi-session per file)
│               └── YYYY-MM-DD.md
│
├── templates/
│   └── new-project/                   # Scaffold für `clu new`
│
├── tools/
│   ├── curator/curator.py             # autonomer Memory-Writer (Sonnet 4.6)
│   └── recall/recall.py               # FTS5-Index
│
├── docs/
│   ├── CLU-DOCUMENTATION.md           # diese Datei
│   ├── ARCHITECTURE.md                # original Architektur-Doc
│   ├── OPERATIONS.md                  # Operations-Guide (englisch)
│   └── DIALOGUE-SUMMARY.md            # Design-Dialog-Archiv
│
├── recall.db                          # FTS5-Index (disposable)
├── curator-state.json                 # processed sessions
├── curator-actions.log                # Curator-Aktionen
├── curator-skipped.log                # abgelehnte Kandidaten
├── memory-review-pending.md           # letzter Memory-Health-Review (Task 12)
├── security-report.md                 # letzter Security-Audit (Task 6)
└── heartbeat-agent.log                # Output Tasks 6/7/12
```

`~/repos/clu-memory/` (eigenes Repo) hält die echten Memory-Dateien;
in `~/.clu/` sind Symlinks. Skripte und Configs bleiben lokal in `~/.clu/`.

---

# Teil B — Architektur & Mechanismen

## 6. Architektur-Überblick

```
              ┌──────────────────────────────────────┐
              │  User                                │
              │  $ clu mein-projekt                  │
              └────────────────┬─────────────────────┘
                               │
                               ▼
              ┌──────────────────────────────────────┐
              │  Launcher (bash)                     │
              │  • parse args                        │
              │  • resolve project + persona         │
              │  • run curator (--limit 5, t/o 60s)  │
              │  • surface pending memory-review     │
              │  • assemble context (core-prompt.md) │
              │  • enforce token budget              │
              │  • dispatch to adapter               │
              └────────────────┬─────────────────────┘
                               │
                               ▼
              ┌──────────────────────────────────────┐
              │  Adapter (z.B. claude-code.sh)       │
              │  • CLAUDE.md ins Repo schreiben      │
              │  • Tool-CLI starten                  │
              │  • bei /exit aufräumen,              │
              │    Switch-Target prüfen              │
              └────────────────┬─────────────────────┘
                               │
                               ▼
              ┌──────────────────────────────────────┐
              │  Agent (Claude Code, Aider, …)       │
              │  • System-Prompt = assembled prompt  │
              │  • Memory-Files direkt auf Disk      │
              │  • Project-Repo ist CWD              │
              └──────────────────────────────────────┘

Asynchron, im Hintergrund:

  Heartbeat (systemd-Timer, 04:00 lokal)
    ├─ Tasks 2–7  Daily-Log-Hygiene, User-Profile, Morning-Brief, Security, Compaction
    ├─ Task 8     Auto-Fix dashboard recommendations
    ├─ Task 9     Memory-Repo committen + pull --rebase + push
    ├─ Task 10    Recall reindex (FTS5)
    ├─ Task 11    Curator run (--limit 20)
    └─ Task 12    Memory health review (wöchentlich, Opus, Vorschläge nach memory-review-pending.md)
```

### Datenfluss beim Launch

1. `launcher` liest `config.yaml`, `project.yaml`, Persona-Datei,
   Constraints, Memory-Files (L1).
2. `core-prompt.md` ist ein Template mit `{{VAR}}`-Platzhaltern.
3. `launcher` substituiert alles und produziert `$AGENT_PROMPT`.
4. Wenn der zusammengesetzte Prompt das Budget überschreitet
   (`prompt_budget_chars`, default 39000), greifen drei Tier-Stufen
   (siehe [§7](#7-launcher-pipeline)).
5. Der Adapter bekommt `$AGENT_PROMPT`, `$AGENT_REPO_PATH`, `$AGENT_HOME`,
   `$AGENT_PROJECT` als Env-Vars und startet das Tool.

---

## 7. Launcher-Pipeline

`launcher` ist Bash, ~1000 Zeilen. Die Hauptfunktionen:

| Funktion | Zweck |
|---|---|
| `cmd_list()` | `clu list` |
| `cmd_new()` | `clu new <name>` — kopiert `templates/new-project/` |
| `cmd_summarize()` | `clu summarize <projekt>` (Adapter-Hook, default no-op) |
| `assemble_workspace_context()` | Workspace-Modus: alle Projekte als Index |
| `assemble_context()` | Project-Modus: Persona + Memory + Constraints |
| `_build_compact_project_index()` | kompakter Projekt-Überblick fürs Budget |
| `_enforce_budget()` | tier-weise Reduktion bei Token-Überschreitung |
| `main()` | Entry-Point, Arg-Parsing, Pre-Session-Curator, Dispatch |

### Pipeline-Phasen

**Phase 1 — Argument Parsing.** Erkennt `--adapter`, `--persona`,
Subcommand, Projektname.

**Phase 2 — Project Resolution.**

- Projekt explizit → Existenz validieren
- Kein Projekt → `default_project` aus `config.yaml`, sonst Workspace

**Phase 3 — Auto-Resume-Check (nur Single-Project + claude-code-Adapter).**
`tools/resume-detector/check.py <repo_path>` ruft Claude Haiku 4.5
über die Subscription (`claude -p --model claude-haiku-4-5`) und fragt:
„war die letzte Session abgeschlossen oder mitten drin?". Liest die
letzten 10 Turns aus dem neuesten JSONL des Projekts. Bias auf
`resume` bei Unklarheit. Bei `resume` → `cd repo_path && exec claude --continue`,
voller Thread, kein Memory-Inject, alles weitere übersprungen. Bei
`fresh` (oder Timeout 25s, oder `--fresh` flag) → normaler Flow weiter.
Latenz ~10–15s wegen claude-CLI-Subprocess-Overhead. Übersprungen im
Workspace-Mode.

**Phase 4 — Pre-Session Curator.** Bevor Memory geladen wird:
`tools/curator/curator.py run --limit 5` (timeout 60s). Findet
orphan Sessions, schreibt Daily-Log-Sektionen + Blocks aus
Transkripten. Memory-Files sind danach aktuell. Wenn pending
`memory-review-pending.md` existiert: Pfad+Alter ausgeben.

**Phase 4 — Context Assembly.**

```
1.  project.yaml laden (type, repo_path, default_persona)
2.  core-prompt.md Template laden
3.  Persona-Datei laden (CLI-Override > project.yaml > Fallback)
4.  Wenn dynamic_personas: _router.md mitladen
5.  _traits.md mitladen (für Verhalten-Lookup)
6.  shared/constraints.md (global)
7.  projects/<n>/constraints.md (projektspezifisch)
8.  shared/memory/*.md → L1-Auszüge
9.  projects/<n>/memory/*.md → L1-Auszüge
10. repo_path validieren
11. Behavior-Profile aus Trait-Scores generieren
12. {{VAR}} im Template substituieren
13. → $AGENT_PROMPT
```

**Phase 5 — Budget Enforcement.** Wenn `$AGENT_PROMPT` das Budget
überschreitet:

| Tier | Aktion | Einsparung |
|---|---|---|
| 1 | Projekt-Index → kompakt (Name/Typ/Repo) | 1–3k Zeichen |
| 2 | Shared Memory → nur Abstracts | 0.5–1.5k |
| Fallback | Warnung loggen, weitermachen | — |

**Phase 6 — Adapter Dispatch.** Sourced `adapters/${ADAPTER}.sh`,
ruft `adapter_launch` mit allen Env-Vars.

**Phase 7 — Post-Session.** Adapter räumt auf (z.B. CLAUDE.md
wiederherstellen), prüft `/tmp/clu/switch-target` für mid-session
Projektwechsel und relauncht ggf. Kein End-of-Session-Ritual mehr —
der nächste Launcher-Run holt das Daily Log über den Curator nach.

---

## 8. Adapter-Schicht

Jeder Adapter implementiert mindestens `adapter_launch`:

```bash
adapter_launch() {
    # Env vars die clu setzt:
    #   $AGENT_PROMPT       — der zusammengesetzte System-Prompt
    #   $AGENT_REPO_PATH    — repo_path aus project.yaml
    #   $AGENT_HOME         — ~/.clu
    #   $AGENT_PROJECT      — Projektname
    #   $AGENT_PERSONA      — aktive Persona
    #   $AGENT_ADAPTER      — Adapter-Name
    
    cd "$AGENT_REPO_PATH"
    mein-tool --system-prompt "$AGENT_PROMPT"
}
```

Optional `adapter_summarize` für Post-Session-Summary.

### claude-code.sh — Schritt für Schritt

1. Staging-Dir anlegen: `/tmp/clu/$AGENT_PROJECT/`
2. Existing `CLAUDE.md` im Repo nach `CLAUDE.md.clu-backup` sichern
3. `$AGENT_PROMPT` als neue `CLAUDE.md` schreiben
4. Wenn die letzte Session unsauber endete: Recovery-Block injizieren
   (mit Conversation-Tail). Sonst: Digest der letzten 3 Sessions
   (`session-digest.py --last 3 --max-chars 800`) anhängen.
5. `claude` CLI in `$AGENT_REPO_PATH` starten
6. Nach `/exit`:
   - Backup wiederherstellen
   - `/tmp/clu/switch-target` prüfen → ggf. relauncht clu
   - `/tmp/clu/$AGENT_PROJECT/` aufräumen

Der Backup-Pfad heißt im Repo `CLAUDE.md.clu-backup` und ist gitignored.

`adapter_summarize` ist heute ein No-op — Daily-Logs schreibt der
Curator. Für Custom-Adapter mit eigener Summarizing-Logik bleibt
der Hook erhalten.

---

## 9. Persona-Engine

### Trait-Resolution beim Launch

```
Override-Reihenfolge (höchste zuerst):

1. CLI-Flag                     clu --persona reviewer
2. trait_overrides              project.yaml: trait_overrides: reviewer: a: +2
3. project.yaml.default_persona
4. config.yaml.default_persona
5. personas/default.md
```

`_traits.md` ist die ausführliche Tabelle „Trait-Score X bedeutet
Verhalten Y". Wird bei Bedarf vom Agent gelesen, nicht standardmäßig
voll injected (zu groß für L1).

### Dynamic Persona Switching

`_router.md` beschreibt die Regeln. Wenn `dynamic_personas: true`:

- Agent erkennt Aktivitätswechsel (Architektur → Implementierung →
  Review …)
- Kündigt Wechsel an: `[→ Reviewer mode (C:9 A:3 N:7)]`
- Blending möglich: `[70% Architect / 30% Reviewer]`
- User-Override jederzeit: „bleib bei Architect", „sei direkter" → A−2

### Trait Learning

Spezifikation in `personas/_trait-learning.md`. Kurzform:

**1. Signal-Erkennung** (live, mid-session):

| User sagt | Mapping |
|---|---|
| „sei direkter" / „weniger diplomatisch" | A: −1 |
| „weniger vorsichtig" / „mach einfach" | N: −1 |
| „rede weniger" / „kürzer" | E: −1 |
| „sei kreativer" / „denk weiter" | O: +1 |
| „gründlicher" / „prüf nochmal" | C: +1 |

→ Schreibt Signal-Block in `shared/memory/meta.md` unter `## Trait Signals`:

```markdown
### SIG-NNN – "User-Wortlaut"
- **Date:** YYYY-MM-DD
- **Persona:** active-persona
- **Trait:** A
- **Direction:** -1
- **Type:** explicit | implicit | mixed
- **Context:** kurze Beschreibung
- **Status:** pending | applied | rejected
```

**2. Aggregation** (Session-Start):

- Alle `pending`-Signale durchgehen
- Gruppieren nach Persona + Trait + Direction
- Schwellen:
  - 1 explizites Signal → Vorschlag
  - 3+ implizite gleicher Richtung → Vorschlag
  - 1 explizit + 1 implizit → Vorschlag
- Cooldown: gleiche Persona+Trait nicht in den letzten 3 Sessions geändert
- Max ±1 pro Trait pro Zyklus

**3. Anwendung**: Bei Confirm wird die Persona-Datei direkt geändert,
das Signal als `applied → [persona].md [Trait]: [old]→[new] ([date])`
markiert.

---

## 10. Memory-System

### Zwei Scopes

| Scope | Pfad | Inhalt | Ladeverhalten |
|---|---|---|---|
| **Shared** | `shared/memory/` | preferences, learnings, references | jede Session |
| **Projekt** | `projects/<n>/memory/` | decisions, architecture, findings, days/ | nur aktives Projekt |

Vorher gab es einen dritten „Agent"-Scope (Workflows, Skills, Meta).
Auflösung 2026-05-02: System-Workflows in die Doku, Lessons als
LRN-Einträge in `shared/memory/learnings.md`, Trait-Signals (falls
genutzt) in `shared/memory/meta.md`. Begründung: einfacher,
weniger Schubladen für Curator und Live-Agent zu wählen.

### Drei Tiers

| Tier | Definition | Wann |
|---|---|---|
| **L0** | `abstract:` im Frontmatter (1 Satz) | immer (alle Files) |
| **L1** | erste ~20 Zeilen nach Frontmatter | Session-Start (relevante Files) |
| **L2** | gesamte Datei | on-demand (Agent öffnet) |

Protokoll: L0 für alle Files → relevante in L1 promoten → L2 nur wenn
nötig. Beim Schreiben muss die L0-`abstract:` aktuell gehalten werden.

### Frontmatter

Jede Memory-Datei hat YAML-Frontmatter:

```yaml
---
last_verified: 2026-05-02
scope: project | shared
type: decisions | findings | learnings | architecture | journal | preferences | …
abstract: "Ein Satz Summary für L0."
entry_count: 14
---
```

Fehlt `abstract:`, wird die Datei beim L0-Loading übersprungen.

### Block-Formate

**Entscheidung:**

```markdown
### DEC-NNN – Titel
- **Date:** YYYY-MM-DD
- **Status:** accepted | proposed | superseded | planned
- **Context:** Warum diese Entscheidung nötig war
- **Decision:** Was entschieden wurde
- **Alternatives considered:** Was abgelehnt wurde, kurz
- **Consequences:** Was sich ändert
```

**Finding (Forschung / Erkenntnis):**

```markdown
### FND-NNN – Titel
- **Date:** YYYY-MM-DD
- **Source:** Wo es herkommt
- **Finding:** Die Erkenntnis
- **Confidence:** high | medium | low
- **Implications:** Konsequenzen
```

**Learning (Lesson Learned):**

```markdown
### LRN-NNN – Titel
- **Date:** YYYY-MM-DD
- **Project origin:** clu | fedora | …
- **Learning:** Was du gelernt hast (gerne lang, mit Befehlen)
- **Category:** technical | process | strategic
```

**Daily Log** (`memory/days/YYYY-MM-DD.md`) — eine Datei pro Tag,
mit einer Subsection pro Session:

```markdown
---
date: YYYY-MM-DD
project: <name>
---

# YYYY-MM-DD

## Session 09:30–12:00 · 8ab13f6e

### What happened
### Decisions made
### Open threads
### Next session

## Session 18:00–19:15 · 49fa0ed4

### What happened
…
```

Der Curator hängt jede neue Session als Subsection an. Idempotent
auf Session-ID — wenn die ID schon im File steht, wird übersprungen.

### Memory-Schreib-Protokoll (live, vom Agent)

Seit 2026-05-02 (Commit `5508543`) autonom mit Confidence-Tagging:

1. **Erkennen**: Decisions, Findings, Architektur-Änderungen, Operational
   Knowledge (Deploy, Build, CI/CD).
2. **Confidence klassifizieren**:
   - `high` ≥ 0.8 — explizite Aussage des Users, klare Quelle
   - `medium` 0.5–0.8 — plausibel, aber nicht bestätigt
   - `low` < 0.5 — spekulativ → skippen
3. **Direkt schreiben** ohne y/n:
   - high → Block as-is
   - medium → Block mit `⚠️ confidence: medium` als erstes Feld nach Date
   - Notification einzeilig: `📝 Saved → projects/foo/memory/decisions.md · DEC-007 …`
4. **User kann objection einlegen** und der Agent revertiert.

### Cross-Project Lessons

Wenn eine Lesson in mehreren Projekten relevant ist → als `LRN-NNN` in
`shared/memory/learnings.md`. Es gibt keine separate `patterns.md`
mehr — Lessons und „bewährte Muster" wurden zu einer Schublade
zusammengelegt.

### Memory-Sync Repo

```
~/repos/clu-memory/
├── .git/
├── shared/
│   └── memory/         # Shared-Scope
└── projects/
    └── <name>/memory/  # Projekt-Scope (Symlinks der einzelnen Projekte)
```

`setup-memory-sync.sh` legt das Repo an, mergt vorhandenes Memory rein
und legt die Symlinks von `~/.clu/` dorthin. Heartbeat-Task 9
committed nightly mit Message `chore(memory): heartbeat sync YYYY-MM-DD`
und pushed.

`config.yaml` → `memory_sync_repo: ~/repos/clu-memory` aktiviert das
Setup. `project.yaml` und `constraints.md` bleiben *außerhalb* des
Memory-Repos (sind Konfiguration, nicht Memory).

---

## 11. Heartbeat

`heartbeat.sh` läuft nächtlich per systemd-Timer (`clu-heartbeat.timer`,
04:00 lokal). 11 aktive Tasks (Task 1 wurde 2026-05-02 entfernt).

| Task | Was passiert | Dauer typ. |
|---|---|---|
| 1 | *(entfernt — war Memory-Staleness, ersetzt durch Task 12)* | — |
| 2 | Daily-Log-Hygiene (fehlende Verzeichnisse) | <1s |
| 3 | User-Profile-Frische (preferences.md zu dünn?) | <1s |
| 4 | Morning Brief (gestrige Open Threads, optional) | <1s |
| 5 | Security-Audit (bash) — Prompt-Injection-Scan, Integrity, Credentials | ~5s |
| 6 | Security-Audit (Agent) — Plugin-Versionen, Threat-Intel, Content | bis 10min (timeout) |
| 7 | Memory-Compaction — wenn Files zu groß, Agent verdichtet | bis 10min (timeout) |
| 8 | Auto-Fix safe dashboard recommendations | <5s |
| 9 | Memory-Repo Sync (commit + pull --rebase + push) | ~3s |
| 10 | Recall Reindex (incremental) | ~10s |
| 11 | Curator Run (--limit 20, autonomes Memory-Schreiben) | bis 5min |
| 12 | Memory Health Review (wöchentlich, Opus, Vorschläge) | bis 15min (timeout) |

Timeouts: Tasks 6, 7 (10 min) und 12 (15 min) haben Hard-Caps,
damit ein hängender Claude-Aufruf nicht den ganzen Heartbeat blockiert.

**Task 12 läuft nur wenn `~/.clu/memory-review-pending.md` älter als
`memory_review_interval_days` (Default 7) ist** — also wöchentlich
solange Mi den Report nicht gelöscht hat. Output: Vorschläge zu stale
facts, Redundanzen, Konflikten, Abstract-Drift, Quality. Beim
Session-Start wird der Report-Pfad + Alter im Launcher-Output
angezeigt.

Logs:

| Datei | Inhalt |
|---|---|
| `~/.clu/heartbeat-agent.log` | Agent-Output von Tasks 6 und 7 |
| `~/.clu/curator-actions.log` | jede Curator-Aktion |
| `~/.clu/curator-skipped.log` | jede Curator-Ablehnung mit Reason |
| Repo: `heartbeat.log` | Standard-Log |

Manuell starten:

```bash
~/.clu/heartbeat.sh           # vollständiger Run
clu heartbeat                 # gleicher Effekt, falls so im Launcher gemappt
```

---

## 12. Curator

`tools/curator/curator.py` (~30k, Python 3, OpenRouter-API).

Wird an zwei Stellen aufgerufen:

- **Pre-Session** im Launcher (`--limit 5`, timeout 60s) — vor jedem `clu <projekt>` oder `clu`-Workspace-Start, konsolidiert das letzte Session-Transkript bevor Memory in den neuen Prompt geladen wird
- **Heartbeat Task 11** (`--limit 20`) — Sicherheitsnetz für Sessions die im Launcher-Pfad nicht erreicht wurden

### State

`~/.clu/curator-state.json` führt Buch über:

- gesehene Session-IDs (verarbeitet ja/nein)
- letzter erfolgreicher Run (Timestamp)
- DEC/FND/LRN-Counter pro Projekt (für sequenzielle NNN-Vergabe)

### Hauptablauf (`curator run`)

```
1. State laden
2. Alle Claude-Code-JSONLs in ~/.claude/projects/*/ scannen
3. Sessions ohne Daily-Log-Eintrag finden (orphan)
   • orphan = (project, date) hat noch keinen Eintrag mit dieser Session-ID
4. Für jede orphan Session (bis --limit):
   a. JSONL parsen → komprimierter Dialogtext
   b. Sonnet 4.6 (über OpenRouter) klassifizieren lassen:
        - Daily-Log-Sektion für diese Session (## Session HH:MM-HH:MM · <id8>)
        - DEC / FND / LRN Kandidaten
        - Confidence pro Block
   c. Filter:
        - confidence < 0.5 → curator-skipped.log, kein Write
        - 0.5–0.8 → ⚠️ confidence: medium Marker
        - ≥0.8 → as-is
   d. Direkt schreiben:
        - Daily-Log-Sektion an days/YYYY-MM-DD.md anhängen
          (file wird mit Frontmatter angelegt falls neu;
           idempotent auf session_id, doppelte Subsections werden übersprungen)
        - DEC → projects/<name>/memory/decisions.md (NNN++)
        - FND → projects/<name>/memory/findings.md (NNN++)
        - LRN → shared/memory/learnings.md (NNN++)
        - bei jedem Append: entry_count + last_verified im Frontmatter aktualisieren
   e. Action loggen → curator-actions.log
5. State updaten (Session als verarbeitet markieren)
```

### Subcommands

| Befehl | Effekt |
|---|---|
| `curator.py run` | Standard-Lauf, schreibt auf Disk |
| `curator.py run --dry-run` | Zeigt was geschrieben würde, kein Write |
| `curator.py run --session <id>` | Nur eine Session |
| `curator.py run --limit N` | Maximale Sessions pro Lauf |
| `curator.py audit` | Letzte Aktionen aus Log anzeigen |
| `curator.py stats` | Statistik (verarbeitet/skipped/pending) |

### Auth

OpenRouter-Key aus `~/.clu/.secrets.env` als `OPENROUTER_API_KEY`.
Modell und Endpunkt sind im Source als Konstante (Sonnet 4.6).

### Output-Beispiel

```
2026-05-01T22:54:35+00:00  DEC DEC-016 → projects/fedora/memory/decisions.md (conf=0.88)
2026-05-01T22:54:35+00:00  LRN LRN-052 → shared/memory/learnings.md (conf=0.92)
2026-05-01T22:54:35+00:00  FND FND-045 → projects/fedora/memory/findings.md (conf=0.82)
```

`curator-skipped.log` hat zusätzlich eine Begründung:

```
2026-05-01T22:54:35+00:00  SKIP DEC (conf=0.42) "no clear decision in transcript"
```

---

## 13. Recall

`tools/recall/recall.py` baut einen FTS5-Index.

### Schema

```sql
CREATE VIRTUAL TABLE blocks USING fts5(
    source,        -- 'md' oder 'jsonl'
    project,       -- Projektname (oder 'shared')
    type,          -- 'DEC', 'FND', 'LRN', 'turn', …
    block_id,      -- 'DEC-007' oder Session-ID + Turn-Index
    title,
    body,
    file_path UNINDEXED,
    line_start UNINDEXED,
    last_seen UNINDEXED
);

CREATE TABLE files (
    path TEXT PRIMARY KEY,
    content_hash TEXT,
    last_indexed REAL
);
```

### Chunking

**Markdown** (`*.md` in `~/repos/clu-memory/`):

- Pro Block: trennt an `### XXX-NNN`-Headern (z.B. `### DEC-001`)
- Frontmatter wird übersprungen
- Block-ID = der NNN-Header

**JSONL** (`~/.claude/projects/*/*.jsonl`):

- Pro Turn: User-Message + folgende Assistant-Response
- Tool-Calls und Outputs werden komprimiert
- Block-ID = `<session-id>#<turn-index>`

### Inkrementelles Reindexieren

- `files`-Tabelle speichert Content-Hash pro Pfad
- Reindex prüft Hash → nur geänderte Files werden neu indexiert
- `--full` ignoriert den Cache und baut neu

### CLI

```bash
recall.py search "query"
recall.py search "vaultwarden tls" --project homelab --type DEC --limit 10
recall.py reindex            # incremental
recall.py reindex --full     # rebuild
recall.py stats              # zeilen/blöcke pro Source und Typ
```

Output von `search` ist eine Liste `(score, project, type, block_id, file_path, snippet)`.

### Heartbeat-Anbindung

Task 10 ruft `recall.py reindex` auf. Bei Erfolg loggt die Anzahl
indexierter md-Files und JSONL-Files. Bei Fehler einfache Warnung,
nicht abortive.

---

## 14. Session-Recovery

`session-recovery.py` (im Repo-Root) hilft, wenn eine Session ohne
sauberes `/exit` endet (Crash, Verbindungsabbruch).

Mechanik:

- Liest `~/.claude/projects/<encoded-path>/<session-id>.jsonl`
- Extrahiert die letzten N Nachrichten als Conversation-Tail
- Generiert eine Recovery-Anweisung in der nächsten CLAUDE.md beim Launch:
  „Identifiziere wo wir unterbrochen wurden und biete an, weiterzumachen."

DEC-004 fixiert: Recovery wird nicht von einem separaten LLM-Call
gemacht. Den Daily-Log-Teil schreibt der Pre-Session-Curator
sowieso (mit Sonnet, aus dem JSONL). Die Recovery-Anweisung lenkt
nur den nächsten Live-Agent zum Wiederaufsatz-Punkt.

`session-digest.py` ist der kleinere Cousin: extrahiert die letzten
3 Sessions als kompakten Digest (`--last 3 --max-chars 800`) und
hängt ihn im claude-code-Adapter an die CLAUDE.md.

```bash
python3 ~/.clu/session-digest.py /home/mi/repos/<projekt> --last 3 --max-chars 800 --format md
python3 ~/.clu/session-recovery.py --session <id> --project <name>
```

---

## 15. Skripte-Referenz

### Entry-Points

| Datei | Sprache | Zweck |
|---|---|---|
| `launcher` | Bash | Hauptbefehl `clu` — Subcommands, Pre-Session-Curator, Context-Assembly, Adapter-Dispatch |
| `bootstrap.sh` | Bash | Onboarding-Wizard (User-Profil, Default-Persona, optional Erstprojekt) |
| `heartbeat.sh` | Bash | Nächtliche Wartung (12 Tasks) |
| `install.sh` | Bash | Installer/Upgrader, kopiert Code nach `~/.clu`, Shell-Alias, Dependency-Check |
| `migrate.sh` | Bash | Migrations-Helper für Schema-Changes |
| `create-persona.sh` | Bash | Interaktiver Persona-Wizard (Name, Trait-Scores) |
| `setup-memory-sync.sh` | Bash | Memory-Repo anlegen + Symlinks |

### Tools

| Datei | Sprache | Zweck |
|---|---|---|
| `tools/curator/curator.py` | Python 3 | Autonomes Memory-Schreiben aus Session-Transkripten (OpenRouter) |
| `tools/recall/recall.py` | Python 3 | FTS5-Index über Memory + JSONLs, CLI-Suche |
| `session-digest.py` | Python 3 | JSONL → kompakter Markdown-Digest |
| `session-recovery.py` | Python 3 | Crashed-Session-Recovery-Setup |
| `dashboard.py` | Python 3 (Flask) | Web-Dashboard auf Port 3141 |

### systemd-Units

| Datei | Zweck |
|---|---|
| `clu-heartbeat.service` | One-Shot-Service der `heartbeat.sh` ausführt |
| `clu-heartbeat.timer` | Tägliche Aktivierung (04:00, persistent=true) |
| `clu-dashboard.service` | Web-Dashboard als User-Service |

---

## 16. Datei-Referenz

### Konfiguration

| Datei | Zweck |
|---|---|
| `config.yaml` | globale Settings: `default_adapter`, `default_project`, `dynamic_personas`, `trait_learning`, `prompt_budget_chars`, `memory_sync_repo`, `memory_review_interval_days` |
| `projects/<n>/project.yaml` | pro Projekt: `type`, `description`, `repo_path`, `default_persona`, `trait_overrides` |
| `shared/constraints.md` | globale Regeln (gelten in jeder Session) |
| `projects/<n>/constraints.md` | projektspezifische Regeln |
| `.secrets.env` | API-Keys (gitignored), z.B. `OPENROUTER_API_KEY` |

### Core-Templates

| Datei | Zweck |
|---|---|
| `shared/core-prompt.md` | System-Prompt-Template mit `{{VAR}}`-Platzhaltern; vom Launcher zusammengebaut |
| `personas/_traits.md` | OCEAN-Trait → Verhalten Mapping (Lookup-Tabelle) |
| `personas/_router.md` | Regeln für dynamisches Persona-Switching |
| `personas/_trait-learning.md` | Trait-Learning-Protokoll im Detail |
| `personas/<name>.md` | konkrete Persona (Trait-Scores + Behavioral Notes) |
| `templates/new-project/` | Scaffold für `clu new` |

### Memory-Files

| Datei | Scope | Inhalt |
|---|---|---|
| `shared/memory/preferences.md` | Shared | wer du bist, Sprache, Stil, Prioritäten |
| `shared/memory/learnings.md` | Shared | LRN-NNN: Lessons Learned, projektübergreifend |
| `shared/memory/references.md` | Shared | Notion, APIs, externe Refs |
| `shared/memory/meta.md` | Shared | optional, `## Trait Signals` (SIG-NNN) — wenn Trait-Learning genutzt |
| `projects/<n>/memory/decisions.md` | Project | DEC-NNN |
| `projects/<n>/memory/architecture.md` | Project | Systemdesign-Beschreibung |
| `projects/<n>/memory/findings.md` | Project | FND-NNN |
| `projects/<n>/memory/days/YYYY-MM-DD.md` | Project | Daily Logs (multi-session per file) |

### Runtime-Artefakte

| Datei | Inhalt | Wer schreibt |
|---|---|---|
| `~/.clu/recall.db` | FTS5-Index | recall.py reindex |
| `~/.clu/curator-state.json` | verarbeitete Sessions, NNN-Counter | curator.py |
| `~/.clu/curator-actions.log` | jede DEC/FND/LRN/Daily-Log Aktion | curator.py |
| `~/.clu/curator-skipped.log` | abgelehnte Kandidaten + Reason | curator.py |
| `~/.clu/security-report.md` | letzter Security-Audit | heartbeat.sh Task 6 |
| `~/.clu/memory-review-pending.md` | Vorschläge vom wöchentlichen Memory-Health-Review | heartbeat.sh Task 12 |
| `~/.clu/heartbeat-agent.log` | Output Tasks 6+7+12 | heartbeat.sh |
| `~/.clu/.bootstrapped` | Marker | bootstrap.sh |
| `~/.clu/.integrity-hashes` | SHA-256 der Core-Files | install.sh, security audit |
| `/tmp/clu/switch-target` | Mid-Session Projekt-Wechsel | Agent / claude-code Adapter |
| `/tmp/clu/<projekt>/` | Adapter-Staging | Adapter |

---

## 17. Erweiterungspunkte

### Eigenen Adapter schreiben

```bash
cp adapters/custom.sh adapters/mein-tool.sh
$EDITOR adapters/mein-tool.sh
```

Implementiere:

```bash
adapter_launch() {
    cd "$AGENT_REPO_PATH"
    mein-tool --system-prompt "$AGENT_PROMPT"
}

adapter_summarize() {
    # optional, wird nur von `clu summarize` aufgerufen
    echo "Post-Session Summary:" 
    echo "$AGENT_PROMPT" | mein-tool-summarize
}
```

In `config.yaml`:

```yaml
default_adapter: mein-tool
```

### Eigene Persona

```bash
~/.clu/create-persona.sh
```

Oder von Hand: `personas/<name>.md` mit Frontmatter:

```yaml
---
o: 7
c: 8
e: 4
a: 5
n: 4
---
```

Plus Beschreibung und Behavioral Notes.

### Eigene Memory-Typen

Wenn dein Projekt einen Typ braucht den's noch nicht gibt: leg eine
`<typ>.md` Datei in `projects/<n>/memory/` an, mit Frontmatter inkl.
`abstract:`. Der Launcher lädt sie automatisch in L1.

Konvention: Block-Header `### XYZ-NNN – Title`, damit der Recall-Index
korrekt chunkt.

---

## 18. Troubleshooting

| Problem | Ursache / Fix |
|---|---|
| „Persona not found" | `ls ~/.clu/personas/` — Datei vorhanden? Korrekte Endung `.md`? |
| Memory taucht nicht im Prompt auf | `abstract:`-Frontmatter prüfen — leerer Abstract → übersprungen |
| Prompt zu groß, Memory wurde gekürzt | `prompt_budget_chars` in `config.yaml` erhöhen, oder Memory verdichten |
| Projekt startet nicht | `project.yaml` validieren (YAML-Syntax), `repo_path` existiert? |
| Heartbeat läuft nicht | `systemctl --user status clu-heartbeat.timer` — aktiv? Logs in `journalctl --user -u clu-heartbeat` |
| Switch zwischen Projekten klappt nicht | `/exit` statt Ctrl+C verwenden. `cat /tmp/clu/switch-target` zeigt das Ziel |
| Adapter nicht gefunden | `config.yaml` → `default_adapter`, Datei in `adapters/` vorhanden + executable? |
| Curator schreibt nichts | `OPENROUTER_API_KEY` in `.secrets.env`? `curator-skipped.log` checken — vielleicht alle low-confidence |
| Curator-Latenz beim Session-Start zu hoch | `~/.clu/curator-state.json` zeigt zuviele orphans? Manuell: `~/.clu/tools/curator/curator.py run --limit 50` einmalig durchlaufen lassen |
| Recall findet nichts | `recall.py stats` — Index leer? `recall.py reindex --full` |
| Memory-Sync committed nicht | `~/repos/clu-memory` ist git-Repo? `cd ~/repos/clu-memory && git status` |
| Memory-Repo lokal/remote divergent | manuell `git pull --rebase`, ggf. Konflikte lösen. Multi-Maschine-Setup: ein Heartbeat pro Maschine, gestaffelte Zeiten (z.B. 04:00 / 04:15) |
| Symlinks zeigen ins Leere | `setup-memory-sync.sh` erneut laufen lassen |
| Git-Push schlägt mit Conflict fehl | Heartbeat macht `pull --rebase` vor `push`; manuell: `cd ~/repos/clu-memory && git pull --rebase && git push` |
| Memory-Review-Report leer / nicht aktuell | Heartbeat Task 12 nur wenn `memory-review-pending.md` älter als `memory_review_interval_days` ist. Manueller Trigger: `rm ~/.clu/memory-review-pending.md && ~/.clu/heartbeat.sh` |

### Debugging-Hilfen

```bash
# Was bekommt der Agent als Prompt?
clu --dry-run mein-projekt    # falls implementiert; sonst:
cat /tmp/clu/mein-projekt/CLAUDE.md  # während laufender Session

# Welches Memory ist aktiv für ein Projekt?
ls ~/.clu/projects/mein-projekt/memory/
ls ~/.clu/shared/memory/

# Welche Personas sind verfügbar?
ls ~/.clu/personas/

# Welche Skripte sind versioniert?
git -C ~/repos/clu ls-files

# Welches Memory wurde wann gesynced?
git -C ~/repos/clu-memory log --oneline -20

# Dashboard für Status-Überblick
clu dashboard
```

---

## Anhang A — Wichtige Decisions (Auszug)

Im clu-Projekt selbst gibt es einige zentrale Entscheidungen, die Arbeit
mit dem System leichter machen wenn man sie kennt. Vollständig in
`projects/clu/memory/decisions.md`.

- **DEC-001** — Session-Digest via Adapter: kompaktes Transkript der
  letzten 2 Sessions wird in CLAUDE.md injected, damit der Agent
  Kontinuität hat ohne volle JSONLs zu laden.
- **DEC-002** — Memory-Aufteilung clu vs. Auto-Memory: clu hält
  cross-project structured Memory (DEC/FND), Claude Code hält natives
  Working Memory pro Projekt. Beide koexistieren, clu skippt L1-Inject
  wo Auto-Memory aktiv ist.
- **DEC-003** — Migration auf OpenCode + Curator/Recall (mehrteilig).
  Phase 1 (Recall) und Phase 2 (Curator) sind live. Phase 3
  (Vector-Search) und Frontend-Wechsel auf OpenCode stehen noch aus.
- **DEC-004** — Session-Recovery via Claude-Anweisung statt eigenem
  LLM-Call. Spart Kosten und nutzt vollen Kontext.

---

## Anhang B — Daily Workflow (Beispiel)

```
04:00   nightly Heartbeat
        → Tasks 2-11 laufen
        → Curator (Task 11) konsolidiert orphan sessions
        → recall.db reindexed
        → Memory-Repo committed + pushed
        → ggf. Task 12 läuft (Sonntag): Memory-Health-Review

09:30   Du startest:  clu mein-projekt
        → Pre-Session-Curator (10–30s wenn pending, instant wenn nicht)
        → ggf. Hinweis auf memory-review-pending.md
        → Launcher injected Persona + Shared+Project Memory (L1)
        → session-digest.py --last 3 --max-chars 800
        → Claude Code startet im Repo

10:30   Beim Arbeiten:
        - Du triffst eine Architektur-Entscheidung
        - Agent sagt: "📝 Saved → projects/.../decisions.md · DEC-019"
        - Du sagst „sei direkter"
        - Agent: "[Adjusted: A 6→4]" + loggt optional SIG-NNN in shared/memory/meta.md

12:00   Du sagst „wechsle zu fedora"
        - Agent schreibt 'fedora' in /tmp/clu/switch-target
        - Du tippst /exit (kein EoS-Ritual)
        - Adapter relauncht clu mit fedora
        - Pre-Session-Curator konsolidiert mein-projekt-Session zu Daily-Log-Eintrag
        - fedora-Memory wird geladen, Claude startet

17:00   /exit
        - Nichts passiert lokal
        - JSONL der Session bleibt unter ~/.claude/projects/

22:00   Du springst nochmal kurz in fedora rein
        - Pre-Session-Curator findet die 12:00–17:00-Session, hängt sie als
          neue Subsection an days/2026-05-02.md an (gleiches File wie davor)
        - Memory wird mit aktuellem Stand geladen

(über Nacht)  Heartbeat läuft, der Curator als Sicherheitsnetz holt nach
              was am Tag vielleicht nicht erfasst wurde.
```
