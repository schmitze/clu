# clu — Dokumentation

> **clu** (Codified Likeness Utility) ist ein provider-agnostisches Agent-Workstation-Framework.
> Es gibt KI-Agenten persistenten Kontext über Sessions, Projekte und Tools hinweg —
> ohne Datenbank, ohne Runtime-Dependencies, nur Bash + Markdown + YAML.

---

## Inhaltsverzeichnis

1. [Prinzipien](#1-prinzipien)
2. [Architektur](#2-architektur)
3. [Verzeichnisstruktur](#3-verzeichnisstruktur)
4. [Betriebslogik](#4-betriebslogik)
5. [Das Persona-System](#5-das-persona-system)
6. [Das Memory-System](#6-das-memory-system)
7. [Adapter-Schicht](#7-adapter-schicht)
8. [Wichtige Dateien](#8-wichtige-dateien)
9. [Wartung & Monitoring](#9-wartung--monitoring)
10. [Transfer auf ein anderes System](#10-transfer-auf-ein-anderes-system)
11. [Häufige Workflows](#11-häufige-workflows)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prinzipien

### Alles ist Text
Konfiguration, Memory, Personas — alles ist Markdown oder YAML. Kein proprietäres Format,
keine Datenbank. Jede Datei ist mit `$EDITOR` lesbar und editierbar.

### Provider-agnostisch
clu ist nicht an Claude Code gebunden. Über eine Adapter-Schicht (`adapters/`) lässt sich
jedes LLM-Tool anbinden: Claude Code, Aider, Cursor, oder eigene Integrationen.
Der Agent sieht immer denselben assemblierten Prompt — das Tool ist austauschbar.

### Null Dependencies
Reines Bash. Kein Python-Framework, kein Node, kein Package Manager.
Die einzige Voraussetzung ist ein LLM-Tool (z.B. `claude`) und eine Shell.
(`dashboard.py` ist optional und die einzige Ausnahme.)

### Memory über Sessions hinweg
Agenten vergessen zwischen Sessions alles. clu löst das durch strukturierte
Memory-Dateien, die beim Session-Start in den Prompt geladen werden.
Drei Scopes (User / Agent / Projekt) verhindern, dass Kontexte vermischt werden.

### Portabilität
`~/.clu/` ist ein Git-Repo. `git push` + `git clone` + `./install.sh` auf einem
neuen Rechner — fertig. Alle Projekte, Memory, Personas und Settings sind dabei.

### Persona statt Prompt-Engineering
Statt für jede Aufgabe einen eigenen System-Prompt zu schreiben, definiert clu
Personas über das Big-Five-Persönlichkeitsmodell (OCEAN). Die Trait-Scores steuern
konkretes Verhalten: Wie direkt? Wie vorsichtig? Wie kreativ?

---

## 2. Architektur

### Überblick

```
┌──────────────────────────────────────────────────────────┐
│  User                                                     │
│  $ clu my-project                                        │
└────────────┬─────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────┐
│  Launcher (launcher)                                      │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐ │
│  │ Arg Parsing  │→│ Project      │→│ Context Assembly │ │
│  │              │  │ Resolution   │  │ (core-prompt.md) │ │
│  └─────────────┘  └──────────────┘  └────────┬────────┘ │
│                                               │          │
│  ┌─────────────┐  ┌──────────────┐  ┌────────▼────────┐ │
│  │ Post-Session │←│ Adapter      │←│ Budget           │ │
│  │ (switch?)    │  │ Dispatch     │  │ Enforcement      │ │
│  └─────────────┘  └──────────────┘  └─────────────────┘ │
└──────────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────┐
│  Adapter (adapters/claude-code.sh)                        │
│  - Schreibt CLAUDE.md in Projekt-Verzeichnis              │
│  - Startet claude CLI                                     │
│  - Räumt nach Session auf                                 │
└──────────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────┐
│  Agent (Claude, Aider, etc.)                              │
│  - Liest assemblierten Prompt als System Instructions     │
│  - Liest/schreibt Memory-Dateien direkt auf Disk          │
│  - Arbeitet im Projekt-Repo                               │
└──────────────────────────────────────────────────────────┘
```

### Datenfluss

1. **Launcher** liest `config.yaml`, `project.yaml`, Persona-Dateien, Memory-Dateien
2. **Context Assembly** setzt alles in `core-prompt.md` ein (Template mit `{{VAR}}` Platzhaltern)
3. **Budget Enforcement** kürzt bei Überschreitung von `prompt_budget_chars`
4. **Adapter** übersetzt den assemblierten Prompt ins Format des jeweiligen Tools
5. **Agent** arbeitet mit dem Prompt als System Instructions + direktem Dateizugriff auf Memory

---

## 3. Verzeichnisstruktur

```
~/.clu/
├── config.yaml                  # Globale Einstellungen
├── launcher                     # Haupt-Entry-Point (~1000 Zeilen Bash)
├── bootstrap.sh                 # Onboarding-Interview (~350 Zeilen)
├── heartbeat.sh                 # Cron-Wartung (~560 Zeilen)
├── import.sh                    # Claude Code History-Import (~600 Zeilen)
├── dashboard.py                 # Web-Dashboard (~1300 Zeilen, optional)
├── create-persona.sh            # Persona-Wizard
├── install.sh                   # Installer/Upgrader
├── .bootstrapped                # Marker: Onboarding abgeschlossen
├── .integrity-hashes            # SHA-256 Checksums der Core-Dateien
├── .secrets.env                 # Lokale Credentials (nicht committed)
│
├── adapters/                    # Provider-Integrationen
│   ├── claude-code.sh           # Claude Code CLI
│   ├── aider.sh                 # Aider CLI
│   ├── cursor.sh                # Cursor IDE
│   └── custom.sh                # Template für eigene Adapter
│
├── personas/                    # Persona-Definitionen (Big Five)
│   ├── _traits.md               # Trait → Verhalten Referenztabelle
│   ├── _router.md               # Regeln für dynamisches Persona-Switching
│   ├── default.md               # O:7 C:8 E:5 A:3 N:3
│   ├── architect.md             # O:8 C:7 E:6 A:4 N:6
│   ├── implementer.md           # O:4 C:8 E:3 A:6 N:3
│   ├── reviewer.md              # O:5 C:9 E:5 A:3 N:7
│   ├── researcher.md            # O:9 C:6 E:7 A:5 N:5
│   ├── writer.md                # O:7 C:7 E:5 A:6 N:4
│   └── entrepreneur.md          # Produkt/Business
│
├── shared/                      # Projekt-übergreifende Ressourcen
│   ├── core-prompt.md           # System-Prompt-Template mit {{VAR}}
│   ├── constraints.md           # Globale Regeln
│   ├── memory/                  # USER-Scope
│   │   ├── preferences.md       # Nutzerprofil
│   │   ├── patterns.md          # Bewährte Ansätze (3+ Projekte)
│   │   ├── learnings.md         # Lessons Learned
│   │   └── references.md        # Externe Referenzen
│   └── agent/                   # AGENT-Scope
│       ├── skills.md            # Gelernte Techniken
│       ├── workflows.md         # Multi-Step-Prozesse
│       ├── meta.md              # Agent-Selbstkenntnis
│       └── security-report.md   # Audit-Ergebnisse
│
├── projects/                    # Projekt-spezifische Daten
│   ├── _workspace/              # Internes Projekt für Multi-Projekt-Modus
│   └── <projekt-name>/
│       ├── project.yaml         # Projekt-Konfiguration
│       ├── constraints.md       # Projekt-spezifische Regeln
│       └── memory/              # PROJEKT-Scope
│           ├── decisions.md     # DEC-NNN Einträge
│           ├── architecture.md  # Systemdesign
│           ├── context.md       # Projektbeschreibung, Ziele
│           ├── findings.md      # FND-NNN (Forschung)
│           ├── hypotheses.md    # Arbeitshypothesen
│           ├── journal.md       # Wochen-Index
│           └── days/            # Tägliche Session-Logs
│               └── YYYY-MM-DD.md
│
├── templates/                   # Scaffolding für neue Projekte
│   └── new-project/
│       ├── project.yaml
│       ├── constraints.md
│       └── memory/ (+ days/)
│
└── docs/                        # Dokumentation
```

---

## 4. Betriebslogik

### 4.1 Session-Start: Was passiert bei `clu my-project`?

**Phase 1 — Argument Parsing:**
Erkennt `--adapter`, `--persona`, Subcommand, Projektname.

**Phase 2 — Projekt-Resolution:**
- Projekt angegeben → validiert Existenz in `projects/`
- Kein Projekt → prüft `default_project` in `config.yaml`, sonst **Workspace Mode**

**Phase 3 — Context Assembly** (Kernlogik):

```
1.  project.yaml lesen (Typ, Repo-Pfad, Default-Persona)
2.  core-prompt.md Template laden
3.  Persona-Datei laden (Override > Projekt-Default > Fallback)
4.  Router-Regeln laden (wenn dynamic_personas: true)
5.  Trait-Referenztabelle laden (_traits.md)
6.  Globale Constraints laden (shared/constraints.md)
7.  Projekt-Constraints laden (projects/<n>/constraints.md)
8.  User Memory L1 laden (shared/memory/*.md, erste ~50 Zeilen)
9.  Agent Memory L1 laden (shared/agent/*.md, erste ~50 Zeilen)
10. Projekt Memory L1 laden (projects/<n>/memory/*.md, erste ~50 Zeilen)
11. Repo-Pfad auflösen und validieren
12. Behavior Profile aus Trait-Scores generieren
13. Alle {{VAR}} im Template substituieren
14. → $AGENT_PROMPT + Metadaten-Env-Vars
```

**Phase 4 — Budget Enforcement:**
Wenn der assemblierte Prompt `prompt_budget_chars` (default: 39000) überschreitet:

| Tier | Aktion | Einsparung |
|------|--------|------------|
| 1 | Agent Memory → nur Abstracts | ~1000–2000 Zeichen |
| 2 | Projekt-Index → kompakt (Name/Typ/Repo) | ~1000–3000 Zeichen |
| 3 | Shared Memory → nur Abstracts | ~500–1500 Zeichen |
| Fallback | Warnung, aber weiter | — |

**Phase 5 — Adapter Dispatch:**
Sourced `adapters/${ADAPTER}.sh`, ruft `adapter_launch()` mit Env-Vars auf.

**Phase 6 — Post-Session:**
Backup wiederherstellen, optionaler Summary-Prompt, Switch-Target prüfen.

### 4.2 Workspace Mode

Wenn kein Projekt angegeben: clu baut einen Index aller Projekte mit Abstracts,
zeigt verfügbare Personas und ermöglicht Navigation zwischen Projekten.
Der Agent kann per `clu switch <projekt>` wechseln.

### 4.3 Projekt-Switch

```
Agent: Memory gespeichert. Switch vorbereitet.
       Type /exit to complete.

User: /exit

→ Launcher erkennt /tmp/clu/switch-target
→ Relauncht mit neuem Projekt und frischem Kontext
```

### 4.4 End-of-Session Protocol

1. Agent klassifiziert automatisch, was passiert ist
2. Schlägt Memory-Updates vor (Projekt/User/Agent/Daily Log)
3. User bestätigt (`Save all? y/n/review each`)
4. Daily Log wird geschrieben → `memory/days/YYYY-MM-DD.md`
5. L0-Abstracts werden aktualisiert

---

## 5. Das Persona-System

### Big Five (OCEAN) — Fünf Dimensionen

| Trait | Niedrig (1–3) | Hoch (7–10) |
|-------|---------------|-------------|
| **O — Openness** | Konventionell, bewährte Lösungen | Kreativ, explorativ, unkonventionell |
| **C — Conscientiousness** | Schnell & locker, wenig Prozess | Akribisch, strukturiert, dokumentiert |
| **E — Extraversion** | Wortkarg, minimale Narration | Redselig, denkt laut, proaktiv |
| **A — Agreeableness** | Direkt kritisch, widerspricht | Kooperativ, diplomatisch, harmonisch |
| **N — Neuroticism** | Mutig, handelt schnell | Risikoavers, prüft alles doppelt |

### Eingebaute Personas

| Persona | O | C | E | A | N | Fokus |
|---------|---|---|---|---|---|-------|
| Default | 7 | 8 | 5 | 3 | 3 | Generalist — gründlich, direkt, mutig |
| Architect | 8 | 7 | 6 | 4 | 6 | Design & Planung — hinterfragt, strukturiert |
| Implementer | 4 | 8 | 3 | 6 | 3 | Ausführung — leise, zuverlässig, schnell |
| Reviewer | 5 | 9 | 5 | 3 | 7 | Qualität — gründlich, kritisch, vorsichtig |
| Researcher | 9 | 6 | 7 | 5 | 5 | Exploration — neugierig, denkt laut |
| Writer | 7 | 7 | 5 | 6 | 4 | Kommunikation — kreativ, diszipliniert |
| Entrepreneur | — | — | — | — | — | Produkt/Business/MVP |

### Dynamisches Switching

Jedes Projekt hat eine `default_persona` in `project.yaml` — das ist der Startpunkt jeder Session. Dynamisches Switching ist **optional** und nur aktiv wenn `dynamic_personas: true` in `config.yaml` steht. Dann gilt:

- Agent erkennt Aktivitätswechsel innerhalb der Session (Design → Architect, Bug → Implementer, etc.)
- Kündigt an: `[→ Reviewer mode (C:9 A:3 N:7)]`
- Blending möglich: 70% Architect / 30% Reviewer
- User kann jederzeit überschreiben: „sei direkter" → A−2

Wenn `dynamic_personas: false`, bleibt die Projekt-Persona die gesamte Session über aktiv.

### Per-Projekt Trait-Overrides

In `project.yaml`:
```yaml
trait_overrides:
  reviewer:
    agreeableness: +2    # Weniger harsch für dieses Projekt
```

### Eigene Personas erstellen

```bash
~/.clu/create-persona.sh
# Interaktiver Wizard: Name, Trait-Scores (1–10 je Dimension)
# Generiert: personas/meine-persona.md
```

---

## 6. Das Memory-System

### Drei Scopes

| Scope | Pfad | Inhalt | Lebensdauer |
|-------|------|--------|-------------|
| **User** | `shared/memory/` | Wer du bist, deine Muster, Lessons Learned | Projekt-übergreifend |
| **Agent** | `shared/agent/` | Wie clu arbeitet, Skills, Workflows | Projekt-übergreifend |
| **Projekt** | `projects/<n>/memory/` | Entscheidungen, Erkenntnisse, Logs | Pro Projekt |

**Warum User und Agent getrennt?** Beide werden jede Session geladen — die Trennung ist semantisch, nicht technisch. **User** = Wissen über *dich* (Rolle, Präferenzen, Kommunikationsstil). **Agent** = Wissen über *sich selbst* (gelernte Techniken, Trait-Korrekturen, was funktioniert). Der Unterschied wird relevant beim Transfer: Wenn du clu für jemand anderen aufsetzt, nimmst du Agent Memory mit (bewährte Arbeitsweisen), ersetzt aber User Memory (anderer Mensch). Nur **Projekt**-Memory wechselt tatsächlich zwischen Sessions — es wird nur für das aktive Projekt geladen.

### Drei Tiers (Detail-Level)

| Tier | Was | Wann geladen |
|------|-----|-------------|
| **L0 — Abstract** | 1-Satz-Summary im Frontmatter | Immer (alle Dateien) |
| **L1 — Overview** | Erste ~50 Zeilen Inhalt | Session-Start (relevante Dateien) |
| **L2 — Full** | Gesamte Datei | On-Demand (Agent liest bei Bedarf) |

### Memory-Datei Format

Jede Memory-Datei hat YAML-Frontmatter:

```yaml
---
last_verified: 2026-03-24
scope: project
type: decisions
abstract: "Drei Architektur-Entscheidungen zu Auth und API-Design."
entry_count: 3
---
```

### Entry-Formate

**Entscheidungen:**
```markdown
### DEC-001 – Titel
- **Date:** 2026-03-24
- **Status:** Accepted
- **Context:** Warum diese Entscheidung nötig war
- **Decision:** Was entschieden wurde
- **Alternatives:** Was in Betracht gezogen wurde
- **Consequences:** Was sich dadurch ändert
```

**Findings (Forschung):**
```markdown
### FND-001 – Titel
- **Date:** 2026-03-24
- **Source:** Woher die Erkenntnis stammt
- **Finding:** Die eigentliche Erkenntnis
- **Confidence:** High | Medium | Low
- **Implications:** Was das für das Projekt bedeutet
```

### Semi-automatisches Schreiben

Der Agent erkennt Entscheidungen/Findings während der Session und schlägt vor:

```
📝 Proposed memory update → decisions.md
┌─────────────────────────────
│ ### DEC-042 – JWT statt Sessions
│ - **Date:** 2026-03-24
│ - **Decision:** JWT für stateless Scaling
│ ...
└─────────────────────────────
Save this? (y/n/edit)
```

Erst nach User-Bestätigung wird geschrieben.

### Promotion-Regel

Wenn ein Pattern in 3+ Projekten auftaucht → wird nach `shared/memory/patterns.md` promoted.

---

## 7. Adapter-Schicht

### Konzept

Adapter übersetzen den assemblierten Prompt ins Format des jeweiligen Tools.
Jeder Adapter implementiert zwei Funktionen:

```bash
adapter_launch()    # Pflicht: Tool starten mit $AGENT_PROMPT
adapter_summarize() # Optional: Post-Session Zusammenfassung
```

### claude-code.sh (Haupt-Adapter)

1. Staging-Verzeichnis erstellen: `/tmp/clu/${PROJECT}/`
2. Prompt als `CLAUDE.md` ins Projekt-Repo schreiben
3. Bestehende `CLAUDE.md` sichern
4. `claude` CLI starten
5. Nach Session: Original-`CLAUDE.md` wiederherstellen
6. Switch-Target prüfen

### Weitere Adapter

| Adapter | Methode |
|---------|---------|
| `aider.sh` | `--system-prompt-file` Flag |
| `cursor.sh` | `.cursorrules` Datei im Projekt |
| `custom.sh` | Template zum Selbstbauen |

### Eigenen Adapter schreiben

```bash
# adapters/mein-tool.sh
adapter_launch() {
    # $AGENT_PROMPT enthält den assemblierten Prompt
    # $AGENT_REPO_PATH ist das Arbeitsverzeichnis
    mein-tool --system-prompt "$AGENT_PROMPT" --dir "$AGENT_REPO_PATH"
}
```

In `config.yaml`:
```yaml
default_adapter: mein-tool
```

---

## 8. Wichtige Dateien

### Konfiguration

| Datei | Zweck |
|-------|-------|
| `config.yaml` | Globale Settings: Adapter, Plugins, Budget, Pfade |
| `projects/<n>/project.yaml` | Projekt-Settings: Typ, Repo, Persona, Constraints |
| `shared/constraints.md` | Globale Regeln (gelten immer) |
| `projects/<n>/constraints.md` | Projekt-Regeln (zusätzlich zu global) |

### Core-Framework

| Datei | Zeilen | Zweck |
|-------|--------|-------|
| `launcher` | ~1000 | Entry Point, Context Assembly, Budget, Dispatch |
| `shared/core-prompt.md` | ~170 | System-Prompt-Template mit `{{VAR}}` Platzhaltern |
| `personas/_traits.md` | — | Trait → Verhalten Mapping-Tabelle |
| `personas/_router.md` | — | Dynamische Persona-Switching-Regeln |

### Automatisierung

| Datei | Zweck |
|-------|-------|
| `bootstrap.sh` | Agent-geführtes Onboarding |
| `heartbeat.sh` | Cron-Wartung (Staleness, Security, Hygiene) |
| `import.sh` | Claude Code History/Settings importieren |
| `dashboard.py` | Web-Dashboard (Flask, Port 3141) |
| `create-persona.sh` | Interaktiver Persona-Wizard |

### Sicherheit

| Datei | Zweck |
|-------|-------|
| `.integrity-hashes` | SHA-256 Checksums der Core-Dateien |
| `.secrets.env` | Lokale Credentials (nie committed) |
| `security-incidents.jsonl` | Log aller Security-Findings |
| `shared/agent/security-report.md` | Letzter Audit-Bericht |

---

## 9. Wartung & Monitoring

### Heartbeat (heartbeat.sh)

Automatische Wartung zwischen Sessions. Empfohlenes Setup via Cron:

```bash
0 4 * * * ~/.clu/heartbeat.sh >> ~/.clu/heartbeat.log 2>&1
```

**Was der Heartbeat prüft:**

| Check | Was passiert |
|-------|-------------|
| Memory Staleness | Warnt bei `last_verified` > 30 Tage |
| Daily Log Hygiene | Erstellt fehlende Verzeichnisse, schlägt Wochen-Rollup vor |
| User Profile | Warnt wenn `preferences.md` leer oder dünn |
| Morning Brief | Zeigt gestrige Open Threads und Next Session |
| Security Audit (Bash) | Prompt-Injection-Scan, Integrity-Check, Credential-Scan |
| Security Audit (Agent) | Plugin-Versionen, Threat Intelligence, Content-Audit |

### Dashboard

```bash
clu dashboard          # http://localhost:3141
clu dashboard 8080     # Custom Port
```

Zeigt: Projekt-Übersicht, Security-Status, Heartbeat-Ergebnisse, Action-Buttons.

Optional als systemd User Service:
```bash
systemctl --user enable --now clu-dashboard
```

---

## 10. Transfer auf ein anderes System

### Voraussetzungen auf dem Zielsystem

- Bash (4.0+)
- Git
- Ein LLM-Tool: `claude` (Claude Code), `aider`, oder `cursor`
- Optional: `fzf` oder `gum` für Projekt-Picker
- Optional: Python 3 für Dashboard

### Schritt 1: clu als Git-Repo sichern

```bash
cd ~/.clu
git init                 # Falls noch nicht geschehen
git add -A
git commit -m "clu state backup"
git remote add origin git@github.com:user/clu-config.git
git push -u origin main
```

**.gitignore** sorgt dafür, dass sensible Dateien nicht committed werden:
```
.secrets.env
heartbeat*.log
security-incidents.jsonl
__pycache__/
```

### Schritt 2: Auf neuem System klonen und installieren

```bash
git clone git@github.com:user/clu-config.git ~/.clu
cd ~/.clu
chmod +x install.sh launcher heartbeat.sh bootstrap.sh import.sh
./install.sh
```

**Was `install.sh` macht:**
1. Prüft ob `~/.clu` existiert (Upgrade vs. Neuinstallation)
2. Schützt bei Upgrade: `projects/`, `shared/memory/`, `shared/agent/`
3. Fügt Shell-Alias hinzu: `alias clu='~/.clu/launcher'`
4. Exportiert `$CLU_HOME=~/.clu`
5. Prüft Dependencies (claude/aider/cursor)
6. Bietet Cron-Heartbeat-Setup an
7. Bietet systemd-Dashboard-Setup an

### Schritt 3: Shell neu laden und testen

```bash
source ~/.bashrc         # oder ~/.zshrc
clu list                 # Alle Projekte sollten da sein
clu bootstrap            # Nur nötig wenn User-Profil angepasst werden soll
```

### Schritt 4: Repo-Pfade anpassen

Projekt-Repos liegen möglicherweise an anderen Pfaden. In jeder `project.yaml`
den `repo_path` prüfen und anpassen:

```bash
# Schnellcheck: welche Repo-Pfade sind konfiguriert?
grep -r "repo_path" ~/.clu/projects/*/project.yaml
```

### Was wird übertragen?

| Wird übertragen | Wird NICHT übertragen |
|-----------------|----------------------|
| Alle Memory-Dateien | `.secrets.env` (Credentials) |
| Alle Personas | Heartbeat-Logs |
| config.yaml + project.yaml | Security-Incident-Log |
| Constraints | `/tmp/clu/` Staging |
| Adapter-Konfiguration | `.integrity-hashes` (wird neu generiert) |
| Templates | Lokale Cache-Dateien |

### Checkliste nach Transfer

- [ ] `clu list` zeigt alle Projekte
- [ ] `repo_path` in project.yaml-Dateien stimmen
- [ ] LLM-Tool ist installiert und funktioniert (`claude --version`)
- [ ] `.secrets.env` neu anlegen falls nötig
- [ ] `clu heartbeat` läuft fehlerfrei
- [ ] Optional: Cron-Job einrichten
- [ ] Optional: Plugins installieren (`clu update`)

---

## 11. Häufige Workflows

### Neues Projekt anlegen

```bash
clu new mein-projekt
# Erstellt projects/mein-projekt/ aus Template

$EDITOR ~/.clu/projects/mein-projekt/project.yaml
# type, description, repo_path setzen

clu mein-projekt
# Erste Session starten
```

### Session starten

```bash
clu                          # Workspace Mode (alle Projekte)
clu mein-projekt             # Direkt ins Projekt
clu --persona architect X    # Mit bestimmter Persona
clu --adapter aider X        # Mit anderem Tool
```

### Memory manuell prüfen

```bash
clu check mein-projekt       # Zeigt Staleness aller Memory-Dateien
```

### Claude Code History importieren

```bash
clu import --list            # Vorschau: was würde importiert?
clu import                   # Interaktiver Import
```

### Plugins aktualisieren

```bash
clu update                   # Prüft und aktualisiert Plugins
```

---

## 12. Troubleshooting

| Problem | Lösung |
|---------|--------|
| „Persona not found" | `ls ~/.clu/personas/` — fehlt die Datei? |
| Memory erscheint nicht im Prompt | `abstract:` Feld im Frontmatter prüfen — leere Abstracts werden übersprungen |
| Prompt zu groß, Memory gekürzt | `prompt_budget_chars` in `config.yaml` erhöhen |
| Projekt startet nicht | `project.yaml` auf YAML-Syntax prüfen, `repo_path` validieren |
| Heartbeat läuft nicht via Cron | `crontab -l | grep heartbeat`, dann `heartbeat.sh` manuell testen |
| Switch zwischen Projekten klappt nicht | `/exit` statt Ctrl+C verwenden, `/tmp/clu/switch-target` prüfen |
| Adapter nicht gefunden | `config.yaml` → `default_adapter` prüfen, Datei in `adapters/` vorhanden? |
