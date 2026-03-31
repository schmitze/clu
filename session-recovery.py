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


def format_recovery(session_file: Path, entries: list[dict]) -> str:
    """Format entries as a recovery block for CLAUDE.md."""
    lines = []
    mtime = datetime.fromtimestamp(session_file.stat().st_mtime, tz=timezone.utc)

    lines.append("## Session Recovery (auto-injected)")
    lines.append("")
    lines.append(
        f"**The previous session (`{session_file.stem[:8]}`, "
        f"{mtime:%Y-%m-%d %H:%M} UTC) was interrupted — no end-of-session "
        f"protocol ran.** The tail of that conversation follows so you can "
        f"pick up where things left off."
    )
    lines.append("")
    lines.append("### Conversation tail (last ~60 messages)")
    lines.append("")

    for entry in entries:
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
    lines.append(
        "**Action:** Read the above, identify where work was interrupted, "
        "and offer to continue from that point. Do NOT repeat work that was "
        "already completed."
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

    session_file = get_last_session(claude_dir)
    if not session_file:
        sys.exit(0)

    if session_ended_cleanly(session_file, days_dir):
        # Clean exit — no recovery needed
        sys.exit(0)

    entries = extract_tail(session_file, max_messages=args.max_messages)
    if not entries:
        sys.exit(0)

    print(format_recovery(session_file, entries))


if __name__ == "__main__":
    main()
