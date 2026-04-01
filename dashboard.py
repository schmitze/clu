#!/usr/bin/env python3
"""clu Dashboard — Local web UI for agent workstation monitoring.

Serves a single-page dashboard on localhost showing:
- Security audit results
- Heartbeat status
- Project overview
- Pending actions with interactive buttons

Usage:
    clu dashboard              → start on port 3141
    clu dashboard 8080         → start on custom port
    python3 dashboard.py       → direct launch
"""

import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from collections import deque
from datetime import datetime
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────

AGENT_HOME = Path(os.environ.get("CLU_HOME", Path.home() / ".clu"))
DEFAULT_PORT = 3141

SECURITY_REPORT = AGENT_HOME / "shared" / "agent" / "security-report.md"
SECURITY_INCIDENTS = AGENT_HOME / "security-incidents.jsonl"
HEARTBEAT_LOG = AGENT_HOME / "heartbeat.log"
AGENT_LOG = AGENT_HOME / "heartbeat-agent.log"
CONFIG_FILE = AGENT_HOME / "config.yaml"
META_FILE = AGENT_HOME / "shared" / "agent" / "meta.md"
PROJECTS_DIR = AGENT_HOME / "projects"
LAUNCHER = AGENT_HOME / "launcher"
HEARTBEAT_SH = AGENT_HOME / "heartbeat.sh"

# ── Parsers ────────────────────────────────────────────────────


def parse_frontmatter(text):
    """Extract YAML front-matter from markdown text."""
    if not text.startswith("---"):
        return {}, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}, text
    fm = {}
    for line in parts[1].strip().splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            v = v.strip().strip('"').strip("'")
            fm[k.strip()] = v
    return fm, parts[2]


def parse_simple_yaml(path):
    """Parse a simple YAML file (flat key: value, one level nesting)."""
    result = {}
    if not path.exists():
        return result
    current_section = None
    for line in path.read_text(errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        if line[0] != " " and ":" in line:
            k, v = line.split(":", 1)
            v = v.strip()
            if v == "" or v == "null":
                current_section = k.strip()
                result[current_section] = {}
            else:
                current_section = None
                result[k.strip()] = v
        elif current_section and line.startswith("  ") and ":" in line:
            if isinstance(result.get(current_section), list):
                # Section already parsed as list, skip key:value lines
                continue
            k, v = line.strip().split(":", 1)
            result.setdefault(current_section, {})[k.strip()] = v.strip()
        elif current_section and line.strip().startswith("- "):
            val = line.strip()[2:].strip()
            if isinstance(result.get(current_section), dict) and not result[current_section]:
                result[current_section] = []
            if isinstance(result.get(current_section), list):
                result[current_section].append(val)
    # Clean up quoted empty strings
    for k, v in result.items():
        if isinstance(v, str):
            v = v.strip('"').strip("'")
            result[k] = v if v else ""
    return result


def parse_security_report():
    """Parse security-report.md into structured data."""
    if not SECURITY_REPORT.exists():
        return {"exists": False, "status": "no-report", "sections": {}}
    text = SECURITY_REPORT.read_text(errors="replace")
    fm, body = parse_frontmatter(text)
    sections = {}
    current = None
    for line in body.splitlines():
        if line.startswith("## "):
            current = line[3:].strip()
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    # Join section lines
    sections = {k: "\n".join(v).strip() for k, v in sections.items()}
    return {"exists": True, **fm, "sections": sections}


def parse_heartbeat_log():
    """Parse last heartbeat run from log file."""
    if not HEARTBEAT_LOG.exists():
        return {"exists": False, "last_run": None, "entries": []}
    lines = list(deque(
        HEARTBEAT_LOG.open(errors="replace"), maxlen=200
    ))
    entries = []
    last_run = None
    stale = []
    security_issues = []
    for line in lines:
        line = line.rstrip()
        if not line:
            continue
        # Extract timestamp
        m = re.match(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\]", line)
        if m:
            last_run = m.group(1)
        if "STALE" in line:
            stale.append(line)
        if any(k in line for k in ["INJECTION", "TAMPERED", "CREDENTIAL", "WORLD-WRITABLE", "STAGING"]):
            security_issues.append(line)
        entries.append(line)
    # Only keep last run's entries
    last_entries = []
    for line in reversed(entries):
        last_entries.insert(0, line)
        if "heartbeat starting" in line:
            break
    return {
        "exists": True,
        "last_run": last_run,
        "entries": last_entries,
        "stale_files": stale,
        "security_issues": security_issues,
    }


def scan_projects():
    """Scan all projects and return metadata."""
    projects = []
    if not PROJECTS_DIR.exists():
        return projects
    for pdir in sorted(PROJECTS_DIR.iterdir()):
        if not pdir.is_dir():
            continue
        pyaml = pdir / "project.yaml"
        if not pyaml.exists():
            continue
        meta = parse_simple_yaml(pyaml)
        # Count memory files and check staleness
        mem_dir = pdir / "memory"
        mem_files = []
        stale_count = 0
        if mem_dir.exists():
            for mf in mem_dir.glob("*.md"):
                fm, _ = parse_frontmatter(mf.read_text(errors="replace"))
                age = None
                if "last_verified" in fm:
                    try:
                        vdate = datetime.strptime(fm["last_verified"], "%Y-%m-%d")
                        age = (datetime.now() - vdate).days
                        if age >= 30:
                            stale_count += 1
                    except ValueError:
                        pass
                mem_files.append({
                    "name": mf.name,
                    "abstract": fm.get("abstract", ""),
                    "age_days": age,
                })
        # Last activity
        days_dir = mem_dir / "days"
        last_activity = None
        if days_dir.exists():
            day_files = sorted(days_dir.glob("*.md"), reverse=True)
            if day_files:
                last_activity = day_files[0].stem
        projects.append({
            "name": pdir.name,
            "type": meta.get("type", "unknown"),
            "description": meta.get("description", ""),
            "persona": meta.get("persona", "default"),
            "repo_path": meta.get("repo_path", ""),
            "memory_count": len(mem_files),
            "stale_count": stale_count,
            "last_activity": last_activity,
            "memory_files": mem_files,
        })
    return projects


def parse_security_incidents():
    """Parse the persistent security incident log (JSONL)."""
    if not SECURITY_INCIDENTS.exists():
        return []
    incidents = []
    for line in SECURITY_INCIDENTS.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            incidents.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    # Most recent first
    incidents.reverse()
    return incidents


def infer_recommendation_action(text):
    """Map recommendation text to an actionable fix."""
    # Strip markdown bold markers and numbering for matching
    clean = re.sub(r'\*\*', '', text)
    tl = clean.lower()

    # Skill removal: "removing offer-k-dense-web skill" or "`offer-k-dense-web` skill"
    m = re.search(r'remov\w*\s+`?([\w-]+)`?\s+skill', tl)
    if not m:
        m = re.search(r'`([\w-]+)`\s+skill', tl)
    if m:
        return "remove-skill", m.group(1)

    # Plugin install with explicit command: `claude plugins install X`
    cmd = re.search(r'`(claude\s+plugins\s+install\s+\S+)`', text)
    if cmd:
        return "plugin-install", cmd.group(1)

    # Generic plugin update
    if 'plugin' in tl and any(w in tl for w in ('update', 'upgrade', 'outdated')):
        return "plugin-update", None

    # Executable shell command in backticks (rm, clean, delete operations)
    cmd = re.search(r'`(rm\s+[^`]+)`', text)
    if cmd:
        return "shell-clean", cmd.group(1)

    # Bootstrap
    if 'bootstrap' in tl:
        return "bootstrap", None

    # Constraint review — show the file
    if 'constraint' in tl:
        return "show-constraints", None

    # Allowlist / suppress false positive
    if any(w in tl for w in ('allowlist', 'suppress', 'false positive', 'whitelist')):
        return "heartbeat", None

    # Stale / staleness
    if 'stale' in tl or 'staleness' in tl:
        return "heartbeat", None

    # Integrity hashes / hash comparison
    if 'hash' in tl or 'integrity' in tl:
        return "refresh-hashes", None

    # Fallback: any backtick command starting with clu/claude
    cmd = re.search(r'`((?:clu|claude)\s+[^`]+)`', text)
    if cmd:
        return "safe-cmd", cmd.group(1)

    # Default: re-run heartbeat to re-evaluate
    return "heartbeat", None


def extract_recommendations():
    """Extract actionable recommendations from all sources."""
    recs = []
    # From security report — extract regardless of status
    report = parse_security_report()
    rec_text = report.get("sections", {}).get("Recommendations", "")
    if rec_text:
        is_table = any(l.strip().startswith("|") for l in rec_text.splitlines()[:3])
        for line in rec_text.splitlines():
            line = line.strip()
            if is_table:
                if not line.startswith("|"):
                    continue
                cells = [c.strip() for c in line.split("|") if c.strip()]
                if not cells or all(re.match(r"^[\-:]+$", c) for c in cells):
                    continue
                first = cells[0].strip("* ")
                if first.lower() in ("priority", "action", "status", "item"):
                    continue
                prio = cells[0].strip("* ").upper()
                cleaned = cells[1].strip() if len(cells) >= 2 else ""
                if not cleaned:
                    continue
                if "CRITICAL" in prio or "HIGH" in prio:
                    severity = "high"
                elif "LOW" in prio or "INFO" in prio:
                    severity = "low"
                else:
                    severity = "medium"
            else:
                line = re.sub(r'^\d+\.\s*', '', line)  # strip "1. "
                line = line.lstrip("- ")
                cleaned = line
                severity = "high"
            if cleaned:
                action, param = infer_recommendation_action(cleaned)
                recs.append({
                    "id": f"sec-{len(recs)}",
                    "category": "security",
                    "description": cleaned,
                    "severity": severity,
                    "action": action,
                    "action_param": param,
                })
    # Stale files
    hb = parse_heartbeat_log()
    for sf in hb.get("stale_files", []):
        recs.append({
            "id": f"stale-{len(recs)}",
            "category": "maintenance",
            "description": sf.strip(),
            "severity": "medium",
            "action": "heartbeat",
        })
    return recs


def get_config():
    """Read config.yaml as dict."""
    return parse_simple_yaml(CONFIG_FILE)


def get_meta():
    """Read meta.md front-matter and content."""
    if not META_FILE.exists():
        return {"exists": False}
    text = META_FILE.read_text(errors="replace")
    fm, body = parse_frontmatter(text)
    return {"exists": True, **fm, "body": body[:2000]}


# ── Action System ──────────────────────────────────────────────

def validate_project_name(name):
    """Validate project name to prevent path traversal."""
    if not re.match(r"^[a-zA-Z0-9_-]+$", name):
        raise ValueError(f"Invalid project name: {name}")
    if not (PROJECTS_DIR / name).exists():
        raise ValueError(f"Project not found: {name}")
    return name


def _execute_remove_skill(skill_name):
    """Find and remove a skill from installed plugins."""
    if not skill_name or not re.match(r'^[a-zA-Z0-9_-]+$', skill_name):
        return {"status": "error", "output": f"Invalid skill name: {skill_name}", "exit_code": 1}
    plugins_dir = Path.home() / ".claude" / "plugins"
    if not plugins_dir.exists():
        return {"status": "error", "output": "Plugins directory not found", "exit_code": 1}
    # Search for skill directories and files matching the name
    found = []
    for p in plugins_dir.rglob("*"):
        if p.is_dir() and p.name == skill_name:
            found.append(p)
        elif p.is_file() and p.stem == skill_name and p.suffix == '.md':
            found.append(p)
    if not found:
        return {"status": "error", "output": f"Skill '{skill_name}' not found under {plugins_dir}", "exit_code": 1}
    removed = []
    for target in found:
        try:
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
            removed.append(str(target))
        except Exception as e:
            return {"status": "error", "output": f"Failed to remove {target}: {e}", "exit_code": 1}
    return {"status": "ok", "output": "Removed:\n" + "\n".join(removed), "exit_code": 0}


def _execute_plugin_install(cmd_str):
    """Run a validated claude plugins install command."""
    if not cmd_str:
        return {"status": "error", "output": "No command provided", "exit_code": 1}
    parts = cmd_str.split()
    if len(parts) < 4 or parts[0] != 'claude' or parts[1] != 'plugins' or parts[2] != 'install':
        return {"status": "error", "output": f"Invalid plugin command: {cmd_str}", "exit_code": 1}
    # Validate plugin spec (no shell metacharacters)
    plugin_spec = parts[3]
    if not re.match(r'^[a-zA-Z0-9@_./-]+$', plugin_spec):
        return {"status": "error", "output": f"Invalid plugin spec: {plugin_spec}", "exit_code": 1}
    try:
        result = subprocess.run(
            parts, capture_output=True, text=True, timeout=300,
            env={**os.environ, "CLU_HOME": str(AGENT_HOME)},
        )
        return {
            "status": "ok" if result.returncode == 0 else "error",
            "output": result.stdout + result.stderr,
            "exit_code": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"status": "error", "output": "Plugin install timed out (300s)", "exit_code": -1}
    except Exception as e:
        return {"status": "error", "output": str(e), "exit_code": -1}


def _execute_safe_cmd(cmd_str):
    """Run a whitelisted clu/claude command."""
    if not cmd_str:
        return {"status": "error", "output": "No command provided", "exit_code": 1}
    parts = cmd_str.split()
    if not parts or parts[0] not in ('clu', 'claude'):
        return {"status": "error", "output": f"Only clu/claude commands allowed: {cmd_str}", "exit_code": 1}
    # Block dangerous subcommands
    dangerous = {'rm', 'delete', 'purge', 'reset', 'exec', 'eval'}
    if any(p in dangerous for p in parts):
        return {"status": "error", "output": f"Blocked dangerous subcommand in: {cmd_str}", "exit_code": 1}
    try:
        result = subprocess.run(
            parts, capture_output=True, text=True, timeout=300,
            env={**os.environ, "CLU_HOME": str(AGENT_HOME)},
        )
        return {
            "status": "ok" if result.returncode == 0 else "error",
            "output": result.stdout + result.stderr,
            "exit_code": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"status": "error", "output": "Command timed out (300s)", "exit_code": -1}
    except Exception as e:
        return {"status": "error", "output": str(e), "exit_code": -1}


def _execute_shell_clean(cmd_str):
    """Run a whitelisted rm command for cleanup tasks."""
    if not cmd_str:
        return {"status": "error", "output": "No command provided", "exit_code": 1}
    # Only allow rm commands targeting safe paths
    expanded = os.path.expanduser(cmd_str.split()[-1]) if cmd_str.split() else ""
    safe_prefixes = [
        str(Path.home() / ".claude"),
        str(Path.home() / ".clu"),
        "/tmp/clu",
    ]
    if not any(expanded.startswith(p) for p in safe_prefixes):
        return {"status": "error", "output": f"Path not in safe prefix: {expanded}", "exit_code": 1}
    try:
        result = subprocess.run(
            ["bash", "-c", cmd_str], capture_output=True, text=True, timeout=30,
        )
        return {
            "status": "ok" if result.returncode == 0 else "error",
            "output": result.stdout + result.stderr or "Done.",
            "exit_code": result.returncode,
        }
    except Exception as e:
        return {"status": "error", "output": str(e), "exit_code": -1}


def execute_action(action, param=None):
    """Execute a whitelisted action and return result."""
    # Parameterized actions with custom handlers
    if action == "remove-skill":
        return _execute_remove_skill(param)
    if action == "plugin-install":
        return _execute_plugin_install(param)
    if action == "safe-cmd":
        return _execute_safe_cmd(param)
    if action == "shell-clean":
        return _execute_shell_clean(param)

    actions = {
        "heartbeat": lambda: [str(HEARTBEAT_SH)],
        "check": lambda: [str(LAUNCHER), "check", validate_project_name(param)],
        "refresh-hashes": lambda: ["rm", "-f", str(AGENT_HOME / ".integrity-hashes")],
        "plugin-update": lambda: ["claude", "plugins", "marketplace", "update"],
        "plugin-list": lambda: ["claude", "plugins", "list"],
        "bootstrap": lambda: [str(LAUNCHER), "bootstrap"],
        "show-constraints": lambda: ["cat", str(AGENT_HOME / "constraints.md")],
    }
    if action not in actions:
        return {"status": "error", "output": f"Unknown action: {action}", "exit_code": 1}
    try:
        cmd = actions[action]()
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300,
            env={**os.environ, "CLU_HOME": str(AGENT_HOME)},
        )
        return {
            "status": "ok" if result.returncode == 0 else "error",
            "output": result.stdout + result.stderr,
            "exit_code": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"status": "error", "output": "Action timed out (300s)", "exit_code": -1}
    except Exception as e:
        return {"status": "error", "output": str(e), "exit_code": -1}


# ── HTML Dashboard ─────────────────────────────────────────────

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>clu Dashboard</title>
<style>
:root {
    --bg: #0d1117;
    --surface: #161b22;
    --surface2: #21262d;
    --border: #30363d;
    --text: #c9d1d9;
    --text-dim: #8b949e;
    --accent: #58a6ff;
    --green: #3fb950;
    --amber: #d29922;
    --red: #f85149;
    --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    --mono: 'SF Mono', 'Cascadia Code', 'Fira Code', monospace;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: var(--font); background: var(--bg); color: var(--text); line-height: 1.6; }
.header {
    display: flex; justify-content: space-between; align-items: center;
    padding: 16px 24px; background: var(--surface); border-bottom: 1px solid var(--border);
}
.header h1 { font-size: 18px; font-weight: 600; }
.header h1 span { color: var(--accent); }
.header-actions { display: flex; gap: 8px; align-items: center; }
.header-actions .last-refresh { color: var(--text-dim); font-size: 12px; margin-right: 8px; }
button {
    background: var(--surface2); color: var(--text); border: 1px solid var(--border);
    padding: 6px 14px; border-radius: 6px; cursor: pointer; font-size: 13px;
    transition: background 0.15s;
}
button:hover { background: var(--border); }
button.primary { background: #1f6feb; border-color: #388bfd; }
button.primary:hover { background: #388bfd; }
button.danger { background: #da3633; border-color: #f85149; }
button:disabled { opacity: 0.5; cursor: not-allowed; }
.tabs {
    display: flex; gap: 0; border-bottom: 1px solid var(--border);
    padding: 0 24px; background: var(--surface);
}
.tab {
    padding: 10px 18px; cursor: pointer; color: var(--text-dim);
    border-bottom: 2px solid transparent; font-size: 14px; transition: all 0.15s;
}
.tab:hover { color: var(--text); }
.tab.active { color: var(--accent); border-bottom-color: var(--accent); }
.tab .badge {
    display: inline-block; background: var(--red); color: white; font-size: 11px;
    padding: 1px 6px; border-radius: 10px; margin-left: 6px;
}
.content { padding: 24px; max-width: 1200px; margin: 0 auto; }
.panel { display: none; }
.panel.active { display: block; }
.card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 16px; margin-bottom: 16px;
}
.card h3 { font-size: 14px; font-weight: 600; margin-bottom: 8px; }
.card-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }
.status-badge {
    display: inline-block; padding: 3px 10px; border-radius: 12px;
    font-size: 12px; font-weight: 600; text-transform: uppercase;
}
.status-clean { background: rgba(63,185,80,0.15); color: var(--green); }
.status-issues { background: rgba(210,153,34,0.15); color: var(--amber); }
.status-critical { background: rgba(248,81,73,0.15); color: var(--red); }
.status-unknown { background: rgba(139,148,158,0.15); color: var(--text-dim); }
table { width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0; }
th { text-align: left; padding: 8px; color: var(--text-dim); border-bottom: 1px solid var(--border); font-weight: 500; }
td { padding: 8px; border-bottom: 1px solid var(--border); }
tr:hover td { background: var(--surface2); }
pre {
    background: var(--surface2); border: 1px solid var(--border); border-radius: 6px;
    padding: 12px; font-family: var(--mono); font-size: 12px; overflow-x: auto;
    max-height: 400px; overflow-y: auto; white-space: pre-wrap;
}
.log-line { font-family: var(--mono); font-size: 12px; padding: 2px 0; }
.log-ok { color: var(--green); }
.log-warn { color: var(--amber); }
.log-error { color: var(--red); }
.rec-list { list-style: none; }
.rec-item {
    display: flex; align-items: flex-start; gap: 10px; padding: 10px;
    border-bottom: 1px solid var(--border);
}
.rec-text { flex: 1; }
.rec-action-btn { flex-shrink: 0; padding: 3px 10px; font-size: 12px; }
.rec-severity { font-size: 11px; font-weight: 600; text-transform: uppercase; padding: 2px 8px; border-radius: 4px; flex-shrink: 0; }
.sev-high { background: rgba(248,81,73,0.15); color: var(--red); }
.sev-medium { background: rgba(210,153,34,0.15); color: var(--amber); }
.sev-low { background: rgba(139,148,158,0.15); color: var(--text-dim); }
.action-bar { display: flex; gap: 8px; padding: 8px 0; align-items: center; flex-wrap: wrap; }
.spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid var(--border); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.output-area { margin-top: 16px; }
.empty { color: var(--text-dim); font-style: italic; padding: 24px; text-align: center; }
.project-meta { color: var(--text-dim); font-size: 12px; margin-top: 4px; }
.project-meta span { margin-right: 12px; }
.staleness-ok { color: var(--green); }
.staleness-warn { color: var(--amber); }
.staleness-bad { color: var(--red); }
select {
    background: var(--surface2); color: var(--text); border: 1px solid var(--border);
    padding: 6px 10px; border-radius: 6px; font-size: 13px; cursor: pointer;
    appearance: none; -webkit-appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath fill='%238b949e' d='M6 8L1 3h10z'/%3E%3C/svg%3E");
    background-repeat: no-repeat; background-position: right 8px center;
    padding-right: 26px;
}
select:hover { background-color: var(--border); }
select:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.section-md h1, .section-md h2 { font-size: 15px; font-weight: 600; margin: 12px 0 6px; }
.section-md ul { padding-left: 20px; margin: 4px 0; }
.section-md p { margin: 4px 0; }
.section-md code, code {
    background: var(--surface2); border: 1px solid var(--border); border-radius: 4px;
    padding: 1px 5px; font-family: var(--mono); font-size: 0.9em;
}
.section-md table { width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0; }
.section-md th { text-align: left; padding: 8px; color: var(--text-dim); border-bottom: 1px solid var(--border); font-weight: 500; }
.section-md td { padding: 8px; border-bottom: 1px solid var(--border); }
@media (prefers-reduced-motion: reduce) {
    * { transition-duration: 0.01ms !important; animation-duration: 0.01ms !important; }
}
</style>
</head>
<body>

<div class="header">
    <h1><span>clu</span> Dashboard</h1>
    <div class="header-actions">
        <span class="last-refresh" id="lastRefresh">loading...</span>
        <select id="autoRefresh" title="Auto-refresh interval" aria-label="Auto-refresh interval">
            <option value="0">Auto: off</option>
            <option value="30">Auto: 30s</option>
            <option value="60" selected>Auto: 60s</option>
            <option value="300">Auto: 5m</option>
        </select>
        <button onclick="refreshAll()">Refresh</button>
    </div>
</div>

<div class="tabs" id="tabs">
    <div class="tab active" data-panel="security">Security</div>
    <div class="tab" data-panel="heartbeat">Heartbeat</div>
    <div class="tab" data-panel="projects">Projects</div>
    <div class="tab" data-panel="incidents">Incidents</div>
    <div class="tab" data-panel="actions">Actions</div>
</div>

<div class="content">
    <!-- Security Panel -->
    <div class="panel active" id="panel-security">
        <div class="card" id="security-summary"></div>
        <div class="card" id="security-details"></div>
    </div>

    <!-- Heartbeat Panel -->
    <div class="panel" id="panel-heartbeat">
        <div class="card">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
                <h3>Heartbeat Status</h3>
                <button onclick="runAction('heartbeat')">Run Heartbeat Now</button>
            </div>
            <div id="heartbeat-status"></div>
        </div>
        <div class="card">
            <h3>Log Output</h3>
            <pre id="heartbeat-log"></pre>
        </div>
    </div>

    <!-- Projects Panel -->
    <div class="panel" id="panel-projects">
        <div class="card-grid" id="project-grid"></div>
    </div>

    <!-- Incidents Panel -->
    <div class="panel" id="panel-incidents">
        <div class="card">
            <h3>Security Incident History</h3>
            <p style="color:var(--text-dim); font-size:13px; margin-bottom:12px">
                Persistent log of all security events detected by heartbeat audits.
            </p>
            <div id="incident-list"></div>
        </div>
    </div>

    <!-- Actions Panel -->
    <div class="panel" id="panel-actions">
        <div class="card">
            <h3>Pending Recommendations</h3>
            <ul class="rec-list" id="rec-list"></ul>
        </div>
        <div class="card">
            <h3>Quick Actions</h3>
            <div class="action-bar">
                <button onclick="runAction('heartbeat')" title="Run the full heartbeat maintenance cycle: memory staleness check, security audit, daily log hygiene.">Run Heartbeat</button>
                <button onclick="runAction('refresh-hashes')" title="Delete cached SHA-256 hashes of core files. Next heartbeat will recompute them — use after intentional file changes to silence tamper warnings.">Reset Integrity Hashes</button>
                <button onclick="runAction('plugin-update')" title="Fetch latest plugin versions from all configured marketplaces. Does not auto-install — only refreshes the available version index.">Update Plugin Index</button>
                <button onclick="runAction('plugin-list')" title="Show all currently installed Claude Code plugins with version and source.">List Plugins</button>
            </div>
        </div>
        <div class="card output-area" id="action-output" style="display:none">
            <div style="display:flex; justify-content:space-between; align-items:center;">
                <h3>Action Output</h3>
                <button onclick="document.getElementById('action-output').style.display='none'">Clear</button>
            </div>
            <pre id="action-output-text"></pre>
        </div>
    </div>
</div>

<script>
// ── State ────────────────────────────────────────────
let refreshTimer = null;
let data = {};

// ── Tab switching ────────────────────────────────────
document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        tab.classList.add('active');
        document.getElementById('panel-' + tab.dataset.panel).classList.add('active');
    });
});

// ── Auto-refresh ─────────────────────────────────────
document.getElementById('autoRefresh').addEventListener('change', e => {
    if (refreshTimer) clearInterval(refreshTimer);
    const secs = parseInt(e.target.value);
    if (secs > 0) refreshTimer = setInterval(refreshAll, secs * 1000);
});

// ── API Helpers ──────────────────────────────────────
async function api(endpoint) {
    const r = await fetch('/api/' + endpoint);
    return r.json();
}

async function postAction(action, param) {
    const r = await fetch('/api/action', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({action, param})
    });
    return r.json();
}

function runRecAction(btn) {
    const action = btn.dataset.action;
    const param = btn.dataset.param || null;
    runAction(action, param);
}

function recButtonLabel(action) {
    const labels = {
        'remove-skill': 'Remove',
        'plugin-install': 'Install',
        'plugin-update': 'Update',
        'show-constraints': 'View',
        'heartbeat': 'Run',
        'refresh-hashes': 'Reset',
        'bootstrap': 'Run',
        'safe-cmd': 'Run',
        'shell-clean': 'Clean',
    };
    return labels[action] || 'Fix';
}

// ── Render Functions ─────────────────────────────────

function statusBadge(status) {
    const cls = {
        'clean': 'status-clean',
        'no-report': 'status-unknown',
        'issues-found': 'status-issues',
        'action-taken': 'status-critical',
    }[status] || 'status-unknown';
    return `<span class="status-badge ${cls}">${status || 'unknown'}</span>`;
}

function renderSecurity(d) {
    const sum = document.getElementById('security-summary');
    const det = document.getElementById('security-details');

    if (!d.exists) {
        sum.innerHTML = '<h3>Security Report</h3><p class="empty">No security report yet. Run the heartbeat to generate one.</p>';
        det.style.display = 'none';
        return;
    }

    sum.innerHTML = `
        <h3>Security Report ${statusBadge(d.status)}</h3>
        <p style="margin-top:8px">${d.date ? 'Last audit: ' + d.date : ''}</p>
        <div class="section-md" style="margin-top:12px">${simpleMarkdown(d.sections?.Summary || 'No summary available.')}</div>
    `;

    let detHtml = '';
    for (const [title, content] of Object.entries(d.sections || {})) {
        if (title === 'Summary') continue;
        detHtml += `<h3 style="margin-top:16px">${title}</h3><div class="section-md">${simpleMarkdown(content)}</div>`;
    }
    det.innerHTML = detHtml || '<p class="empty">No details available.</p>';
    det.style.display = detHtml ? 'block' : 'none';

    // Update tab badge
    const secTab = document.querySelector('[data-panel="security"]');
    if (d.status === 'issues-found' || d.status === 'action-taken') {
        secTab.innerHTML = 'Security <span class="badge">!</span>';
    } else {
        secTab.textContent = 'Security';
    }
}

function renderHeartbeat(d) {
    const status = document.getElementById('heartbeat-status');
    const log = document.getElementById('heartbeat-log');

    if (!d.exists) {
        status.innerHTML = '<p class="empty">No heartbeat log yet. Run the heartbeat first.</p>';
        log.textContent = '';
        return;
    }

    const issues = d.security_issues?.length || 0;
    const stale = d.stale_files?.length || 0;

    status.innerHTML = `
        <table>
            <tr><td>Last run</td><td><strong>${d.last_run || 'unknown'}</strong></td></tr>
            <tr><td>Stale files</td><td>${stale === 0 ? '<span class="staleness-ok">none</span>' : `<span class="staleness-warn">${stale}</span>`}</td></tr>
            <tr><td>Security issues</td><td>${issues === 0 ? '<span class="staleness-ok">none</span>' : `<span class="staleness-bad">${issues}</span>`}</td></tr>
        </table>
    `;

    log.innerHTML = d.entries.map(line => {
        let cls = '';
        if (line.includes('✅')) cls = 'log-ok';
        else if (line.includes('⚠') || line.includes('STALE')) cls = 'log-warn';
        else if (line.includes('🚨') || line.includes('❌')) cls = 'log-error';
        return `<div class="log-line ${cls}">${escapeHtml(line)}</div>`;
    }).join('');
}

function renderProjects(projects) {
    const grid = document.getElementById('project-grid');
    if (!projects.length) {
        grid.innerHTML = '<p class="empty">No projects found.</p>';
        return;
    }
    grid.innerHTML = projects.map(p => {
        const staleCls = p.stale_count > 0 ? 'staleness-warn' : 'staleness-ok';
        return `<div class="card">
            <h3>${escapeHtml(p.name)}</h3>
            <p style="font-size:13px; color:var(--text-dim); margin-bottom:8px">${escapeHtml(p.description || 'No description')}</p>
            <div class="project-meta">
                <span>Type: ${escapeHtml(p.type)}</span>
                <span>Persona: ${escapeHtml(p.persona)}</span>
                <span>Memory: ${p.memory_count} file(s)</span>
                <span class="${staleCls}">Stale: ${p.stale_count}</span>
                ${p.last_activity ? `<span>Last: ${p.last_activity}</span>` : ''}
            </div>
            ${p.repo_path ? `<div class="project-meta"><span>Repo: ${escapeHtml(p.repo_path)}</span></div>` : ''}
        </div>`;
    }).join('');
}

function renderRecommendations(recs) {
    const list = document.getElementById('rec-list');
    const actTab = document.querySelector('[data-panel="actions"]');
    if (!recs.length) {
        list.innerHTML = '<li class="empty">No pending recommendations.</li>';
        actTab.textContent = 'Actions';
        return;
    }
    actTab.innerHTML = `Actions <span class="badge">${recs.length}</span>`;
    list.innerHTML = recs.map(r => `
        <li class="rec-item" title="${escapeHtml(r.description)}">
            <span class="rec-severity sev-${r.severity}">${r.severity}</span>
            <span class="rec-text">${escapeHtml(r.description)}</span>
            ${r.action ? `<button class="rec-action-btn" data-action="${escapeHtml(r.action)}" data-param="${escapeHtml(r.action_param || '')}" onclick="runRecAction(this)" title="Run: ${escapeHtml(r.action)}">${recButtonLabel(r.action)}</button>` : ''}
        </li>
    `).join('');
}

function renderIncidents(incidents) {
    const el = document.getElementById('incident-list');
    const incTab = document.querySelector('[data-panel="incidents"]');

    if (!incidents || !incidents.length) {
        el.innerHTML = '<p class="empty">No security incidents recorded.</p>';
        incTab.textContent = 'Incidents';
        return;
    }

    incTab.innerHTML = `Incidents <span class="badge">${incidents.length}</span>`;

    el.innerHTML = `<table>
        <tr><th>Time</th><th>Severity</th><th>Source</th><th>Detail</th></tr>
        ${incidents.map(i => {
            const sevCls = i.severity === 'critical' ? 'status-critical' : i.severity === 'high' ? 'status-issues' : 'status-unknown';
            return `<tr>
                <td style="white-space:nowrap">${escapeHtml(i.timestamp || '?')}</td>
                <td><span class="status-badge ${sevCls}">${escapeHtml(i.severity || '?')}</span></td>
                <td>${escapeHtml(i.source || '?')}</td>
                <td>${escapeHtml(i.detail || '')}</td>
            </tr>`;
        }).join('')}
    </table>`;
}

// ── Helpers ──────────────────────────────────────────

function escapeHtml(s) {
    if (!s) return '';
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function simpleMarkdown(text) {
    if (!text) return '';
    const lines = text.split('\n');
    let html = '';
    let inTable = false;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        // Table row detection
        if (line.trim().startsWith('|') && line.trim().endsWith('|')) {
            const cells = line.split('|').slice(1, -1).map(c => escapeHtml(c.trim()));
            // Skip separator rows (|---|---|)
            if (cells.every(c => /^[-:]+$/.test(c))) continue;
            if (!inTable) { html += '<table>'; inTable = true; }
            const isHeader = i + 1 < lines.length && lines[i+1].trim().startsWith('|') &&
                lines[i+1].split('|').slice(1,-1).every(c => /^[\s-:]+$/.test(c));
            const tag = isHeader ? 'th' : 'td';
            html += '<tr>' + cells.map(c => `<${tag}>${inlineMarkdown(c)}</${tag}>`).join('') + '</tr>';
            continue;
        }
        if (inTable) { html += '</table>'; inTable = false; }
        // Block elements
        const escaped = escapeHtml(line);
        if (line.startsWith('### ')) html += `<h3>${inlineMarkdown(escapeHtml(line.slice(4)))}</h3>`;
        else if (line.startsWith('## ')) html += `<h2>${inlineMarkdown(escapeHtml(line.slice(3)))}</h2>`;
        else if (line.startsWith('# ')) html += `<h1>${inlineMarkdown(escapeHtml(line.slice(2)))}</h1>`;
        else if (line.startsWith('- ')) html += `<li>${inlineMarkdown(escapeHtml(line.slice(2)))}</li>`;
        else html += inlineMarkdown(escaped) + '<br>';
    }
    if (inTable) html += '</table>';
    return html;
}

function inlineMarkdown(s) {
    return s
        .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
        .replace(/`(.+?)`/g, '<code>$1</code>');
}

// ── Actions ──────────────────────────────────────────

async function runAction(action, param) {
    const output = document.getElementById('action-output');
    const text = document.getElementById('action-output-text');
    output.style.display = 'block';
    text.innerHTML = '<span class="spinner"></span> Running...';

    // Switch to actions tab
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
    document.querySelector('[data-panel="actions"]').classList.add('active');
    document.getElementById('panel-actions').classList.add('active');

    const result = await postAction(action, param);
    text.innerHTML = `<div class="log-line ${result.status === 'ok' ? 'log-ok' : 'log-error'}">[exit: ${result.exit_code}]</div>\n${escapeHtml(result.output)}`;

    // Refresh data after action
    setTimeout(refreshAll, 1000);
}

// ── Data Loading ─────────────────────────────────────

async function refreshAll() {
    const safe = async (fn) => { try { return await fn(); } catch(e) { console.error(e); return null; } };
    const [security, heartbeat, projects, recs, incidents] = await Promise.all([
        safe(() => api('security')), safe(() => api('heartbeat')), safe(() => api('projects')),
        safe(() => api('recommendations')), safe(() => api('incidents')),
    ]);
    if (security) { data.security = security; renderSecurity(security); }
    if (heartbeat) { data.heartbeat = heartbeat; renderHeartbeat(heartbeat); }
    if (projects) { data.projects = projects; renderProjects(projects); }
    if (recs) { data.recs = recs; renderRecommendations(recs); }
    if (incidents !== null) { data.incidents = incidents; renderIncidents(incidents); }
    document.getElementById('lastRefresh').textContent = 'Updated: ' + new Date().toLocaleTimeString();
}

// ── Init ─────────────────────────────────────────────
refreshAll();
refreshTimer = setInterval(refreshAll, 60000);
</script>

</body>
</html>"""


# ── HTTP Handler ───────────────────────────────────────────────

class DashboardHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        if path == "/" or path == "":
            self._send_html(DASHBOARD_HTML)
        elif path == "/api/security":
            self._send_json(parse_security_report())
        elif path == "/api/heartbeat":
            self._send_json(parse_heartbeat_log())
        elif path == "/api/projects":
            self._send_json(scan_projects())
        elif path == "/api/recommendations":
            self._send_json(extract_recommendations())
        elif path == "/api/incidents":
            self._send_json(parse_security_incidents())
        elif path == "/api/config":
            self._send_json(get_config())
        elif path == "/api/meta":
            self._send_json(get_meta())
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        content_len = int(self.headers.get("Content-Length", 0))
        if content_len > 1_000_000:
            self._send_json({"error": "body too large"}, 413)
            return
        try:
            body = json.loads(self.rfile.read(content_len)) if content_len > 0 else {}
        except (json.JSONDecodeError, ValueError):
            self._send_json({"error": "invalid JSON"}, 400)
            return

        if path == "/api/action":
            action = body.get("action", "")
            param = body.get("param") or body.get("project")
            result = execute_action(action, param)
            self._send_json(result)
        else:
            self._send_json({"error": "not found"}, 404)

    def _send_json(self, data, status=200):
        body = json.dumps(data, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        """Quiet logging — only show errors (non-2xx)."""
        if len(args) > 1 and str(args[1]).startswith("2"):
            return
        super().log_message(format, *args)


# ── Entry Point ────────────────────────────────────────────────

def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print(f"Usage: {sys.argv[0]} [port]")
            sys.exit(1)

    server = http.server.HTTPServer(("127.0.0.1", port), DashboardHandler)
    print(f"clu dashboard running on http://127.0.0.1:{port}")
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
