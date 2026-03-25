# Trait Learning System — Design Spec

> Personas lernen aus Interaktionen und passen ihre OCEAN-Scores an.

**Date:** 2026-03-25
**Status:** Approved
**Scope:** Rein prompt-basiert — keine Launcher- oder Heartbeat-Änderungen

---

## 1. Überblick

clu Personas haben OCEAN-Trait-Scores (1–10), die konkretes Verhalten steuern.
Bisher sind diese Scores statisch. Dieses Feature ergänzt ein Lernsystem:

1. **Explizite Signale** — User korrigiert Verhalten ("sei direkter" → A: -1)
2. **Implizite Signale** — Agent erkennt Muster am Session-Ende durch Reflexion
3. **Aggregation** — Bei genug Evidenz schlägt der Agent eine Anpassung vor
4. **Direkte Änderung** — Persona-Dateien werden angepasst (kein Delta-Layer)

## 2. Signal-Erkennung

### Explizite Signale

Sofort erkannt und geloggt wenn der User Verhalten korrigiert:

| User sagt | Trait | Richtung |
|-----------|-------|----------|
| "sei direkter" / "weniger diplomatisch" | A | -1 |
| "weniger vorsichtig" / "mach einfach" | N | -1 |
| "rede weniger" / "kürzer bitte" | E | -1 |
| "sei kreativer" / "denk weiter" | O | +1 |
| "gründlicher bitte" / "prüf nochmal" | C | +1 |
| (und Umkehrungen) | | |

Wird nach Bestätigung sofort als Signal in `meta.md` geschrieben.

### Implizite Signale

Erkannt bei End-of-Session Reflexion durch Rückblick auf Interaktionsmuster:

| Beobachtung | Mögliches Signal |
|-------------|-----------------|
| User kürzt Agent ab, überspringt Erklärungen | E zu hoch |
| User lehnt kreative Vorschläge wiederholt ab | O zu hoch |
| User muss Fehler korrigieren die Agent übersah | C oder N zu niedrig |
| User überspringt Rückfragen, will schneller vorankommen | N zu hoch |
| User fragt nach Details die Agent hätte liefern sollen | C zu niedrig |
| User bestätigt ungewöhnlichen Ansatz ohne Widerspruch | O bestätigt (kein Signal) |

Implizite Signale sind Vermutungen — sie brauchen **3 übereinstimmende Signale**
bevor sie eine Anpassung auslösen.

## 3. Storage-Format

Neue Sektion `## Trait Signals` in `shared/agent/meta.md`.
Ersetzt die bisherige (leere) Sektion `## Trait Corrections`.

```markdown
## Trait Signals

### SIG-001 – "sei direkter"
- **Date:** 2026-03-24
- **Persona:** implementer
- **Trait:** A
- **Direction:** -1
- **Type:** explicit
- **Context:** User wollte weniger Rückfragen bei Routine-Tasks
- **Status:** pending

### SIG-002 – User kürzt Erklärungen ab
- **Date:** 2026-03-24
- **Persona:** implementer
- **Trait:** E
- **Direction:** -1
- **Type:** implicit
- **Context:** 3x "ja ja, mach einfach" bei Narration
- **Status:** pending
```

Nach erfolgter Anpassung wechselt Status:

```markdown
- **Status:** applied → implementer.md A: 6→5 (2026-03-26)
```

## 4. End-of-Session Reflexion

Neuer Schritt im End-of-Session Protocol, nach Auto-Classify und vor Daily Log:

1. Agent blickt auf gesamte Session zurück
2. Sucht nach impliziten Signalen (Muster aus Abschnitt 2)
3. Prüft ob explizite Signale aufgetreten sind
4. Fasst zusammen und schlägt ggf. Signale zum Loggen vor

**Output-Format:**

```
🎭 Trait-Reflexion (implementer)
┌─────────────────────────────────────
│ 1 explizites Signal: "sei direkter" → A: -1
│
│ 1 implizite Beobachtung:
│ Du hast mehrfach kreative Vorschläge abgelehnt und
│ pragmatischere Lösung gewählt. → O: -1
│
│ Signale loggen? (y/n/review)
└─────────────────────────────────────
```

**Randfälle:**
- Wenn Trait schon am Rand ist (≤2 oder ≥9): erkennen, kein sinnloses Signal vorschlagen
- Wenn keine Signale erkannt: Reflexion still überspringen (kein Output)

## 5. Aggregation und Anpassungsvorschlag

Passiert **am Session-Start** (nicht am Ende — da werden nur Signale geloggt).

### Logik

1. Agent liest `meta.md` → `## Trait Signals` mit Status `pending`
2. Gruppiert nach Persona + Trait + Direction
3. Prüft Schwellenwert:
   - **Explizit:** 1 Signal reicht → sofort vorschlagen
   - **Implizit:** 3+ Signale in dieselbe Richtung → vorschlagen
   - **Gemischt:** 1 explizit + 1 implizit reicht auch
4. Vorschlag mit Evidenz

### Output-Format

```
🎭 Trait-Anpassung vorgeschlagen → personas/implementer.md
┌─────────────────────────────────────
│ A: 6 → 5
│
│ Evidenz (4 Signale seit 2026-03-20):
│  • SIG-001 explicit: "sei direkter"
│  • SIG-003 implicit: Erklärungen übersprungen
│  • SIG-005 implicit: Rückfragen abgelehnt
│  • SIG-008 implicit: "mach einfach"
│
│ Max ±1 pro Zyklus. Nächste Anpassung frühestens
│ nach 3 weiteren Sessions.
└─────────────────────────────────────
Anpassen? (y/n)
```

### Bei Bestätigung

1. Persona-Datei direkt ändern (Score + Kommentar aktualisieren)
2. Alle beteiligten Signale → Status `applied`
3. **Cooldown: 3 Sessions** bevor derselbe Trait derselben Persona erneut angepasst wird

### Constraints

- **Max ±1** pro Trait pro Anpassungszyklus
- **Cooldown: 3 Sessions** nach einer Anpassung für denselben Trait
- **Boden/Decke: 1–10** — Traits können nicht unter 1 oder über 10 gehen

## 6. Betroffene Komponenten

| Komponente | Änderung |
|---|---|
| `shared/core-prompt.md` | End-of-Session Protocol um Trait-Reflexion erweitern. Session-Start um Signal-Aggregation erweitern. Bestehende "Self-tuning"-Zeile ersetzen. |
| `shared/agent/meta.md` | `## Trait Corrections` → `## Trait Signals` mit SIG-Format |
| `personas/*.md` | Werden direkt geändert wenn Anpassung bestätigt wird |
| `config.yaml` | Neuer Schalter `trait_learning: true` |

### Was sich NICHT ändert

- **Launcher** — kein neuer Code, alles prompt-basiert
- **Heartbeat** — keine Aggregation, der Agent macht das selbst
- **`trait_overrides` in `project.yaml`** — bleibt ungenutzt
- **Persona-Datei-Struktur** — gleiches Format, nur Scores ändern sich

## 7. Zusammenfassung

Das gesamte Feature ist **rein prompt-basiert**. Der Agent bekommt
Instruktionen in `core-prompt.md` zum:

1. Erkennen expliziter Korrekturen → sofort loggen
2. End-of-Session Reflexion → implizite Signale erkennen und loggen
3. Session-Start Aggregation → bei Schwellenwert Anpassung vorschlagen
4. Bei Bestätigung → Persona-Datei direkt ändern, Signale als applied markieren

Keine neue Infrastruktur nötig. Die einzige Daten-Struktur ist das
Signal-Format in `meta.md`.
