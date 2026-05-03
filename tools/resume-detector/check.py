#!/usr/bin/env python3
"""
clu-resume-detector — single-purpose classifier asking the cheapest
Claude model whether the most recent session in a project ended at a
natural close or mid-flow.

Called by the launcher before assembling context for `clu <project>`.
Runs in 2-4 seconds. Output on stdout is exactly one of:

    resume   — last session was mid-task / mid-discussion → caller
               should `claude --continue` instead of starting fresh
    fresh    — last session reached a natural close, or no usable
               session was found → caller starts fresh

Exit code is always 0. Any error path falls back to printing "fresh"
so the caller defaults to the safe option (start a new session).

Usage:
    check.py <repo_path>

The repo_path is the project's working directory; from it we compute
the Claude Code session folder under ~/.claude/projects/.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

MAX_TURNS = 10
MAX_CHARS = 4000
CLAUDE_MODEL = "claude-haiku-4-5"
SUBPROCESS_TIMEOUT = 20  # seconds — Haiku is fast


def _emit(verdict: str) -> None:
    """Print verdict and exit 0. verdict must be 'resume' or 'fresh'."""
    print(verdict)
    sys.exit(0)


def _encoded_project_dir(repo_path: str) -> Path | None:
    """Map an absolute repo path to its ~/.claude/projects/ folder."""
    rp = Path(repo_path).expanduser().resolve()
    if not rp.exists():
        return None
    encoded = "-" + str(rp).strip("/").replace("/", "-")
    cand = Path.home() / ".claude" / "projects" / encoded
    return cand if cand.exists() else None


def _newest_jsonl(folder: Path) -> Path | None:
    """Return the most recently modified .jsonl in folder, or None."""
    files = list(folder.glob("*.jsonl"))
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def _content_text(content) -> str:
    """Flatten a Claude Code message content to plain text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    out.append(block.get("text", ""))
        return "\n".join(out)
    return ""


def _is_tool_result(content) -> bool:
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                return True
    return False


def _is_local_or_caveat(text: str) -> bool:
    """Skip messages injected by the CLI shell (slash commands, caveats)."""
    if not text:
        return True
    head = text.lstrip()[:80]
    return (
        head.startswith("<command-name>")
        or head.startswith("<command-message>")
        or head.startswith("<command-args>")
        or head.startswith("<local-command-")
        or "<local-command-caveat>" in head
    )


def extract_recent_turns(jsonl_path: Path) -> list[dict]:
    """Return up to MAX_TURNS most-recent (user, assistant) pairs."""
    turns: list[dict] = []
    user: str | None = None
    asst: list[str] = []

    def flush() -> None:
        nonlocal user, asst
        if user is not None:
            turns.append({
                "user": user.strip(),
                "assistant": "\n".join(asst).strip(),
            })
        user = None
        asst = []

    try:
        for line in jsonl_path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                obj = json.loads(line)
            except (ValueError, json.JSONDecodeError):
                continue
            t = obj.get("type")
            msg = obj.get("message") or {}
            role = msg.get("role")
            content = msg.get("content")

            if t == "user" and role == "user":
                if _is_tool_result(content):
                    continue
                text = _content_text(content)
                if _is_local_or_caveat(text):
                    continue
                flush()
                user = text
            elif t == "assistant" and role == "assistant":
                text = _content_text(content)
                if text:
                    asst.append(text)
        flush()
    except OSError:
        return []

    if len(turns) > MAX_TURNS:
        turns = turns[-MAX_TURNS:]

    total = 0
    for i in range(len(turns) - 1, -1, -1):
        total += len(turns[i]["user"]) + len(turns[i]["assistant"])
        if total > MAX_CHARS:
            turns = turns[i + 1:]
            break

    return turns


SYSTEM_PROMPT = """You are a single-purpose classifier. You read the
tail of a developer's coding-session transcript and decide whether the
session ended at a natural close or was interrupted mid-flow.

Output rules — these are absolute:
- Output exactly one word, lowercase, no punctuation, no explanation:
  either `resume` or `fresh`.
- Nothing else. No quotes, no markdown, no preamble.

Decide `resume` when:
- The user was mid-debate with the agent (asking follow-up questions,
  weighing options, no clear answer reached)
- A task was started but not finished (debugging an error, mid-implementation,
  pending decision)
- The agent's last message was a question awaiting user input
- The user's last message looks abrupt, mid-sentence, or like an
  interruption rather than a goodbye
- The agent had just outlined a plan and the user had not yet
  approved or declined

Decide `fresh` when:
- A clear conclusion was reached (decision logged, task done, "that's it",
  goodbye, "/exit reicht jetzt")
- The user explicitly closed the session ("ok danke das wars", "passt so",
  "fertig", "perfect, schaut gut aus")
- The agent's last message was a completion announcement and the user
  did not push back
- The transcript is too short or empty to indicate mid-flow

Bias: when genuinely uncertain, output `resume`. False positives are
cheap (the user can ignore the resumed thread); false negatives are
expensive (the user loses context they wanted to keep)."""


def build_user_prompt(turns: list[dict]) -> str:
    parts = ["The session transcript tail (most recent turns last):", ""]
    for i, t in enumerate(turns, 1):
        parts.append(f"--- turn {i} ---")
        parts.append(f"USER: {t['user']}")
        if t["assistant"]:
            parts.append(f"ASSISTANT: {t['assistant']}")
        parts.append("")
    parts.append("Output `resume` or `fresh` only.")
    return "\n".join(parts)


def call_claude(prompt: str) -> str:
    """Run claude -p with Haiku and return the trimmed output."""
    cmd = [
        "claude",
        "--dangerously-skip-permissions",
        "--model", CLAUDE_MODEL,
        "--append-system-prompt", SYSTEM_PROMPT,
        "-p",
    ]
    try:
        result = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=SUBPROCESS_TIMEOUT,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def main() -> None:
    if len(sys.argv) < 2:
        _emit("fresh")
    repo_path = sys.argv[1]

    folder = _encoded_project_dir(repo_path)
    if folder is None:
        _emit("fresh")

    jsonl = _newest_jsonl(folder)
    if jsonl is None:
        _emit("fresh")

    turns = extract_recent_turns(jsonl)
    if not turns:
        _emit("fresh")

    prompt = build_user_prompt(turns)
    raw = call_claude(prompt).lower().strip().strip(".`'\"")
    # Take the last token — Haiku occasionally adds a single line of
    # context before the verdict despite the system prompt.
    verdict = raw.split()[-1] if raw else "fresh"
    if verdict not in ("resume", "fresh"):
        verdict = "resume"  # bias
    _emit(verdict)


if __name__ == "__main__":
    main()
