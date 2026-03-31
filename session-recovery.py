#!/usr/bin/env python3
"""
session-recovery.py — Detect interrupted sessions and generate recovery context.

Checks whether the last Claude Code session ended cleanly (daily log exists)
or was interrupted. On interruption, extracts the tail of the conversation
to provide continuity context for the next session.

Usage:
    session-recovery.py <project-path> --project-dir <clu-project-dir>
    session-recovery.py /home/mi/repos/fedora --project-dir /home/mi/.clu/projects/fedora

Output: Markdown block for CLAUDE.md injection, or nothing if session ended cleanly.
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def project_path_to_claude_dir(project_path: str) -> Path:
    """Convert a project path to the Claude Code session directory."""
    normalized = os.path.normpath(os.path.expanduser(project_path))
    encoded = normalized.replace("/", "-")
    return Path.home() / ".claude" / "projects" / encoded


def get_last_session(claude_dir: Path) -> Path | None:
    """Get the most recent session JSONL file."""
    if not claude_dir.is_dir():
        return None
    files = sorted(claude_dir.glob("*.jsonl"), key=lambda f: f.stat().st_mtime)
    return files[-1] if files else None


def get_interrupted_sessions(claude_dir: Path, days_dir: Path) -> list[Path]:
    """Get all session files that ended without a daily log (interrupted)."""
    if not claude_dir.is_dir():
        return []
    files = sorted(claude_dir.glob("*.jsonl"), key=lambda f: f.stat().st_mtime)
    interrupted = []
    for f in files:
        if not session_ended_cleanly(f, days_dir):
            interrupted.append(f)
    return interrupted


def session_ended_cleanly(session_file: Path, days_dir: Path) -> bool:
    """Check if a daily log exists for the session's date."""
    mtime = datetime.fromtimestamp(session_file.stat().st_mtime, tz=timezone.utc)
    date_str = mtime.strftime("%Y-%m-%d")
    daily_log = days_dir / f"{date_str}.md"
    if not daily_log.exists():
        return False

    # Daily log exists — but was it written AFTER the session ended?
    # If the session is newer than the daily log, session continued after log.
    log_mtime = daily_log.stat().st_mtime
    return log_mtime >= session_file.stat().st_mtime


def extract_tail(session_file: Path, max_messages: int = 60) -> list[dict]:
    """Extract the last N meaningful messages from a session."""
    all_entries = []

    with open(session_file) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg = obj.get("message", {})
            role = msg.get("role", "")
            content = msg.get("content", "")
            msg_type = obj.get("type", "")

            if msg_type in ("file-history-snapshot", "queue-operation", "last-prompt"):
                continue

            if role == "user":
                if isinstance(content, str) and content.strip():
                    all_entries.append({"role": "user", "text": content.strip()})
                elif isinstance(content, list):
                    texts = [
                        b.get("text", "")
                        for b in content
                        if isinstance(b, dict)
                        and b.get("type") == "text"
                        and b.get("text", "").strip()
                    ]
                    if texts:
                        combined = " ".join(texts)
                        # Skip tool_result noise, keep real user messages
                        if len(combined) > 10:
                            all_entries.append({"role": "user", "text": combined})

            elif role == "assistant":
                if isinstance(content, list):
                    for block in content:
                        btype = block.get("type", "")
                        if btype == "text" and block.get("text", "").strip():
                            all_entries.append(
                                {"role": "assistant", "text": block["text"].strip()}
                            )
                        elif btype == "tool_use":
                            name = block.get("name", "?")
                            inp = block.get("input", {})
                            if name == "Bash":
                                detail = inp.get(
                                    "description", inp.get("command", "")[:80]
                                )
                            elif name in ("Read", "Edit", "Write"):
                                detail = inp.get("file_path", "")
                            elif name == "Grep":
                                detail = f'"{inp.get("pattern", "")}"'
                            elif name == "Glob":
                                detail = inp.get("pattern", "")
                            else:
                                detail = json.dumps(inp)[:60]
                            all_entries.append(
                                {"role": "tool", "name": name, "detail": detail[:120]}
                            )
                elif isinstance(content, str) and content.strip():
                    all_entries.append({"role": "assistant", "text": content.strip()})

    return all_entries[-max_messages:]


def format_recovery(
    all_sessions: list[Path], latest_entries: list[dict], days_dir: Path
) -> str:
    """Format recovery block for CLAUDE.md with all interrupted sessions."""
    lines = []
    today = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    daily_log_path = days_dir / f"{today}.md"

    lines.append("## Session Recovery (auto-injected)")
    lines.append("")

    if len(all_sessions) == 1:
        s = all_sessions[0]
        mtime = datetime.fromtimestamp(s.stat().st_mtime, tz=timezone.utc)
        lines.append(
            f"**The previous session (`{s.stem[:8]}`, "
            f"{mtime:%Y-%m-%d %H:%M} UTC) was interrupted — no end-of-session "
            f"protocol ran.**"
        )
    else:
        lines.append(
            f"**{len(all_sessions)} sessions were interrupted** — none ran "
            f"the end-of-session protocol:"
        )
        lines.append("")
        for s in all_sessions:
            mtime = datetime.fromtimestamp(s.stat().st_mtime, tz=timezone.utc)
            size_kb = s.stat().st_size // 1024
            lines.append(f"- `{s.stem[:8]}` — {mtime:%Y-%m-%d %H:%M} UTC ({size_kb} KB)")

    lines.append("")
    lines.append("### Conversation tail (last session, ~60 messages)")
    lines.append("")

    for entry in latest_entries:
        role = entry.get("role", "")
        if role == "user":
            text = entry["text"][:500]
            lines.append(f"**User:** {text}")
        elif role == "assistant":
            text = entry["text"][:500]
            lines.append(f"**Assistant:** {text}")
        elif role == "tool":
            lines.append(f"  `→ {entry['name']}`: {entry['detail']}")

    lines.append("")
    lines.append("### Recovery action (MUST execute before other work)")
    lines.append("")
    lines.append(
        f"1. **Write a daily log** to `{daily_log_path}` summarizing what "
        f"happened across ALL interrupted sessions listed above. Use the "
        f"standard daily log format (frontmatter with date/project/personas_used, "
        f"sections: What happened, Decisions made, Open threads, Next session). "
        f"Read the session JSONL files if the conversation tail above is not "
        f"enough context."
    )
    lines.append(
        "2. **Then** identify where work was interrupted and offer to continue "
        "from that point. Do NOT repeat work already completed."
    )

    return "\n".join(lines)


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Detect interrupted sessions and generate recovery context"
    )
    parser.add_argument("project_path", help="Path to the project repo directory")
    parser.add_argument(
        "--project-dir",
        required=True,
        help="Path to the clu project directory (e.g. ~/.clu/projects/fedora)",
    )
    parser.add_argument(
        "--max-messages",
        type=int,
        default=60,
        help="Max messages to extract from tail (default: 60)",
    )

    args = parser.parse_args()

    claude_dir = project_path_to_claude_dir(args.project_path)
    days_dir = Path(args.project_dir) / "memory" / "days"

    interrupted = get_interrupted_sessions(claude_dir, days_dir)
    if not interrupted:
        sys.exit(0)

    # Extract tail from the most recent interrupted session
    latest = interrupted[-1]
    entries = extract_tail(latest, max_messages=args.max_messages)
    if not entries:
        sys.exit(0)

    print(format_recovery(interrupted, entries, days_dir))


if __name__ == "__main__":
    main()
