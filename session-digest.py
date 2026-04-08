#!/usr/bin/env python3
"""
session-digest.py — Extract a readable summary from Claude Code session transcripts.

Reads JSONL session files from ~/.claude/projects/<project>/ and outputs
a compact digest of user messages and assistant text responses.
Tool calls are shown as one-liners, tool results are skipped.

Usage:
    session-digest.py <project-path> [--last N] [--max-chars M] [--format md|plain]

Examples:
    session-digest.py /home/mi/repos/fedora
    session-digest.py /home/mi/repos/fedora --last 2
    session-digest.py /home/mi/repos/fedora --last 1 --max-chars 5000
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def project_path_to_claude_dir(project_path: str) -> Path:
    """Convert a project path to the Claude Code session directory."""
    # Claude Code encodes paths with dashes: /home/mi/repos/fedora -> -home-mi-repos-fedora
    normalized = os.path.normpath(os.path.expanduser(project_path))
    encoded = normalized.replace("/", "-")
    return Path.home() / ".claude" / "projects" / encoded


def get_session_files(claude_dir: Path, last_n: int = 1) -> list[Path]:
    """Get the N most recent session JSONL files, sorted by mtime."""
    if not claude_dir.is_dir():
        print(f"Error: No session directory found at {claude_dir}", file=sys.stderr)
        sys.exit(1)
    files = sorted(claude_dir.glob("*.jsonl"), key=lambda f: f.stat().st_mtime)
    return files[-last_n:] if last_n else files


def parse_session(path: Path) -> list[dict]:
    """Parse a session JSONL into a list of digest entries."""
    entries = []
    session_start = None

    with open(path) as f:
        for line in f:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg = obj.get("message", {})
            role = msg.get("role", "")
            content = msg.get("content", "")
            timestamp = obj.get("timestamp", "")
            msg_type = obj.get("type", "")

            # Skip non-message types
            if msg_type in ("file-history-snapshot", "queue-operation", "last-prompt"):
                continue

            # Track session start time
            if timestamp and not session_start:
                if isinstance(timestamp, str):
                    session_start = timestamp
                elif isinstance(timestamp, (int, float)):
                    session_start = datetime.fromtimestamp(
                        timestamp / 1000, tz=timezone.utc
                    ).isoformat()

            if role == "user":
                if isinstance(content, str) and content.strip():
                    entries.append({"role": "user", "text": content.strip()})
                elif isinstance(content, list):
                    # tool_result blocks — skip, or extract text parts
                    texts = [
                        b.get("text", "")
                        for b in content
                        if b.get("type") == "text" and b.get("text", "").strip()
                    ]
                    if texts:
                        entries.append({"role": "user", "text": " ".join(texts)})

            elif role == "assistant":
                if isinstance(content, list):
                    for block in content:
                        btype = block.get("type", "")
                        if btype == "text" and block.get("text", "").strip():
                            entries.append(
                                {"role": "assistant", "text": block["text"].strip()}
                            )
                        elif btype == "tool_use":
                            name = block.get("name", "?")
                            inp = block.get("input", {})
                            # Compact tool call summary
                            if name == "Bash":
                                detail = inp.get(
                                    "description", inp.get("command", "")[:80]
                                )
                            elif name == "Read":
                                detail = inp.get("file_path", "")
                            elif name == "Edit":
                                detail = inp.get("file_path", "")
                            elif name == "Write":
                                detail = inp.get("file_path", "")
                            elif name == "Grep":
                                detail = f'"{inp.get("pattern", "")}"'
                            elif name == "Glob":
                                detail = inp.get("pattern", "")
                            else:
                                detail = json.dumps(inp)[:60]
                            entries.append(
                                {
                                    "role": "tool",
                                    "name": name,
                                    "detail": detail[:100],
                                }
                            )
                elif isinstance(content, str) and content.strip():
                    entries.append({"role": "assistant", "text": content.strip()})

    return entries, session_start


def format_entry(entry: dict, fmt: str, max_chars: int) -> str:
    """Format a single digest entry."""
    role = entry["role"]

    if role == "user":
        text = entry["text"][:max_chars]
        if fmt == "md":
            return f"**User:** {text}"
        return f"USER: {text}"

    elif role == "assistant":
        text = entry["text"][:max_chars]
        if fmt == "md":
            return f"**Assistant:** {text}"
        return f"ASSISTANT: {text}"

    elif role == "tool":
        name = entry["name"]
        detail = entry["detail"]
        if fmt == "md":
            return f"  `→ {name}`: {detail}"
        return f"  -> {name}: {detail}"

    return ""


def format_digest(
    session_path: Path,
    entries: list[dict],
    session_start: str | None,
    fmt: str,
    max_chars: int,
    max_total: int = 0,
) -> str:
    """Format the full digest for one session, respecting max_total char budget."""
    lines = []
    sid = session_path.stem[:8]
    ts = session_start or "unknown"
    if isinstance(ts, str) and len(ts) > 19:
        ts = ts[:19].replace("T", " ")

    if fmt == "md":
        header = f"### Session `{sid}` — {ts} UTC"
    else:
        header = f"=== Session {sid} — {ts} UTC ==="
    lines.append(header)
    lines.append("")

    total = len(header) + 2
    for entry in entries:
        formatted = format_entry(entry, fmt, max_chars)
        if formatted:
            if max_total and total + len(formatted) + 1 > max_total:
                break
            lines.append(formatted)
            total += len(formatted) + 1

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Extract Claude Code session digests")
    parser.add_argument("project_path", help="Path to the project directory")
    parser.add_argument(
        "--last",
        type=int,
        default=1,
        help="Number of most recent sessions to show (default: 1)",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        default=500,
        help="Max characters per message (default: 500)",
    )
    parser.add_argument(
        "--format",
        choices=["md", "plain"],
        default="plain",
        help="Output format (default: plain)",
    )
    parser.add_argument(
        "--max-total",
        type=int,
        default=4000,
        help="Max total output chars (default: 4000, 0=unlimited)",
    )
    parser.add_argument(
        "--list", action="store_true", help="Just list available sessions"
    )

    args = parser.parse_args()
    claude_dir = project_path_to_claude_dir(args.project_path)

    if args.list:
        files = get_session_files(claude_dir, last_n=0)
        for f in files:
            mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc)
            size = f.stat().st_size
            print(f"  {f.stem[:8]}  {mtime:%Y-%m-%d %H:%M}  {size:>7} bytes")
        return

    files = get_session_files(claude_dir, last_n=args.last)

    total_output = 0
    for i, session_file in enumerate(files):
        entries, session_start = parse_session(session_file)
        if entries:
            digest = format_digest(session_file, entries, session_start, args.format, args.max_chars, args.max_total)
            if args.max_total and total_output + len(digest) > args.max_total and total_output > 0:
                break
            print(digest)
            total_output += len(digest)
            if args.max_total and total_output >= args.max_total:
                break
            if i < len(files) - 1:
                print("\n")


if __name__ == "__main__":
    main()
