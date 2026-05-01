#!/usr/bin/env python3
"""
clu-recall — FTS5 index over clu-memory + session JSONLs.

CLI:
    clu-recall search "query" [--project x] [--limit 10] [--type DEC|FND|LRN|turn]
    clu-recall reindex [--full]
    clu-recall stats

Phase 1 MVP: SQLite + FTS5, block-chunking for Markdown, turn-chunking for JSONLs.
Sources:
    ~/repos/clu-memory/**/*.md           (shared + project memory)
    ~/.claude/projects/*/*.jsonl         (Claude Code session transcripts)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

# ─── Configuration ─────────────────────────────────────────────────────

CLU_HOME = Path.home() / ".clu"
DB_PATH = CLU_HOME / "recall.db"

MEMORY_ROOT = Path.home() / "repos" / "clu-memory"
CLAUDE_SESSIONS_ROOT = Path.home() / ".claude" / "projects"

BLOCK_PATTERN = re.compile(r"^### ([A-Z]+-\d+)\b", re.MULTILINE)
FRONTMATTER_PATTERN = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)


# ─── Schema ────────────────────────────────────────────────────────────

SCHEMA = """
CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
    source_path UNINDEXED,
    source_type UNINDEXED,
    project    UNINDEXED,
    scope      UNINDEXED,
    block_type UNINDEXED,
    block_id   UNINDEXED,
    title,
    content,
    last_modified UNINDEXED,
    content_hash  UNINDEXED,
    tokenize='porter unicode61'
);

CREATE TABLE IF NOT EXISTS file_state (
    path TEXT PRIMARY KEY,
    mtime REAL NOT NULL,
    size INTEGER NOT NULL,
    last_indexed REAL NOT NULL
);
"""


def db_connect(create: bool = True) -> sqlite3.Connection:
    if create:
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    con.executescript(SCHEMA)
    return con


# ─── Chunking ──────────────────────────────────────────────────────────

@dataclass
class Chunk:
    source_path: str
    source_type: str        # 'markdown' | 'jsonl'
    project: str            # 'clu', 'fedora', 'shared', etc.
    scope: str              # 'shared' | 'project' | 'agent'
    block_type: str         # 'DEC' | 'FND' | 'LRN' | 'daily-log' | 'turn' | 'note'
    block_id: str           # 'DEC-003', 'turn-42', etc.
    title: str
    content: str
    last_modified: float


def _strip_frontmatter(text: str) -> tuple[str, str]:
    """Return (frontmatter_text, body)."""
    m = FRONTMATTER_PATTERN.match(text)
    if not m:
        return "", text
    return m.group(1), text[m.end():]


def _classify_md_path(path: Path) -> tuple[str, str, str]:
    """
    Return (project, scope, default_block_type) from path within clu-memory.
    Examples:
        clu-memory/shared/memory/learnings.md -> ('shared', 'shared', 'LRN')
        clu-memory/projects/fedora/decisions.md -> ('fedora', 'project', 'DEC')
        clu-memory/projects/clu/days/2026-04-30.md -> ('clu', 'project', 'daily-log')
    """
    try:
        rel = path.relative_to(MEMORY_ROOT)
    except ValueError:
        return ("unknown", "unknown", "note")

    parts = rel.parts
    if len(parts) >= 2 and parts[0] == "shared":
        scope = "shared" if parts[1] == "memory" else "agent"
        project = "shared"
    elif len(parts) >= 2 and parts[0] == "projects":
        project = parts[1]
        scope = "project"
    else:
        return ("unknown", "unknown", "note")

    name = path.name
    if name.startswith("decisions"):
        block_type = "DEC"
    elif name.startswith("findings"):
        block_type = "FND"
    elif name.startswith("learnings"):
        block_type = "LRN"
    elif "days" in parts:
        block_type = "daily-log"
    else:
        block_type = "note"

    return (project, scope, block_type)


def chunk_markdown(path: Path) -> Iterator[Chunk]:
    text = path.read_text(encoding="utf-8", errors="replace")
    project, scope, default_type = _classify_md_path(path)
    mtime = path.stat().st_mtime

    _, body = _strip_frontmatter(text)

    # Find all ### XXX-NNN headers
    headers = list(BLOCK_PATTERN.finditer(body))

    if not headers:
        # No structured blocks → whole file as one chunk
        title = _first_heading(body) or path.name
        yield Chunk(
            source_path=str(path),
            source_type="markdown",
            project=project,
            scope=scope,
            block_type=default_type,
            block_id=path.stem,
            title=title,
            content=body.strip(),
            last_modified=mtime,
        )
        return

    # Split into blocks at each header
    for i, m in enumerate(headers):
        block_id = m.group(1)
        start = m.start()
        end = headers[i + 1].start() if i + 1 < len(headers) else len(body)
        block_text = body[start:end].strip()

        # Title: first line of block (the ### header line, sans ###)
        first_line = block_text.split("\n", 1)[0]
        title = first_line.lstrip("#").strip()

        prefix = block_id.split("-")[0]  # 'DEC', 'FND', 'LRN'
        yield Chunk(
            source_path=str(path),
            source_type="markdown",
            project=project,
            scope=scope,
            block_type=prefix,
            block_id=block_id,
            title=title,
            content=block_text,
            last_modified=mtime,
        )


def _first_heading(body: str) -> str:
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("#"):
            return line.lstrip("#").strip()
    return ""


# ─── JSONL chunking (Claude Code format) ───────────────────────────────

def _extract_text(content) -> str:
    """Extract plain text from a Claude Code message.content (str or list)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if not isinstance(c, dict):
                continue
            t = c.get("type")
            if t == "text":
                parts.append(c.get("text", ""))
            elif t == "tool_use":
                name = c.get("name", "?")
                parts.append(f"[tool: {name}]")
            elif t == "tool_result":
                # Skip tool results — too noisy
                pass
        return "\n".join(p for p in parts if p)
    return ""


def _is_local_command_or_caveat(text: str) -> bool:
    if not text:
        return True
    t = text.lstrip()
    return (
        t.startswith("<local-command")
        or t.startswith("<command-")
        or t.startswith("Caveat:")
    )


def _content_is_tool_result(content) -> bool:
    if isinstance(content, list):
        return any(
            isinstance(c, dict) and c.get("type") == "tool_result"
            for c in content
        )
    return False


def _project_from_session_path(path: Path) -> str:
    """
    Encoded CWD: leading '-', then the absolute path with '/' replaced by '-'.
    ~/.claude/projects/-home-mi-repos-clu/*.jsonl                -> 'clu'
    ~/.claude/projects/-home-mi-repos-KoSi-backend-webxr/*.jsonl -> 'KoSi-backend-webxr'
    ~/.claude/projects/-home-mi-claude-lab/*.jsonl               -> 'claude-lab'
    """
    parent = path.parent.name
    if parent.startswith("-home-mi-repos-"):
        return parent[len("-home-mi-repos-"):] or "repos"
    if parent == "-home-mi-repos":
        return "repos"
    if parent.startswith("-home-mi-"):
        return parent[len("-home-mi-"):] or "_home"
    if parent == "-home-mi":
        return "_home"
    return parent.lstrip("-")


def chunk_jsonl(path: Path) -> Iterator[Chunk]:
    project = _project_from_session_path(path)
    mtime = path.stat().st_mtime
    session_id = path.stem

    current_user_text: str | None = None
    current_assistant_parts: list[str] = []
    turn_index = 0

    def flush() -> Chunk | None:
        nonlocal turn_index
        if current_user_text is None:
            return None
        body = "**User:** " + current_user_text.strip()
        if current_assistant_parts:
            body += "\n\n**Assistant:** " + "\n".join(current_assistant_parts).strip()
        title = current_user_text.strip().split("\n", 1)[0][:120]
        chunk = Chunk(
            source_path=str(path),
            source_type="jsonl",
            project=project,
            scope="project",
            block_type="turn",
            block_id=f"{session_id}#t{turn_index}",
            title=title,
            content=body,
            last_modified=mtime,
        )
        turn_index += 1
        return chunk

    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                obj = json.loads(line)
            except (ValueError, json.JSONDecodeError):
                continue

            t = obj.get("type")
            msg = obj.get("message") or {}
            role = msg.get("role")
            content = msg.get("content")

            if t == "user" and role == "user":
                if _content_is_tool_result(content):
                    continue
                text = _extract_text(content)
                if _is_local_command_or_caveat(text):
                    continue
                # Start a new turn
                flushed = flush()
                if flushed is not None:
                    yield flushed
                current_user_text = text
                current_assistant_parts = []
            elif t == "assistant" and role == "assistant":
                text = _extract_text(content)
                if text:
                    current_assistant_parts.append(text)

        flushed = flush()
        if flushed is not None:
            yield flushed
    except OSError:
        return


# ─── Indexer ───────────────────────────────────────────────────────────

def _hash_str(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8", errors="replace")).hexdigest()[:16]


def _file_changed(con: sqlite3.Connection, path: Path) -> bool:
    """Return True if file is new or has changed since last index."""
    try:
        st = path.stat()
    except OSError:
        return False
    row = con.execute(
        "SELECT mtime, size FROM file_state WHERE path = ?", (str(path),)
    ).fetchone()
    if row is None:
        return True
    return row[0] != st.st_mtime or row[1] != st.st_size


def _record_file_state(con: sqlite3.Connection, path: Path) -> None:
    st = path.stat()
    con.execute(
        "INSERT OR REPLACE INTO file_state(path, mtime, size, last_indexed) "
        "VALUES (?, ?, ?, ?)",
        (str(path), st.st_mtime, st.st_size, time.time()),
    )


def _delete_chunks_for_file(con: sqlite3.Connection, path: Path) -> None:
    con.execute("DELETE FROM documents WHERE source_path = ?", (str(path),))


def _insert_chunk(con: sqlite3.Connection, c: Chunk) -> None:
    h = _hash_str(c.content)
    con.execute(
        "INSERT INTO documents("
        "  source_path, source_type, project, scope, "
        "  block_type, block_id, title, content, "
        "  last_modified, content_hash"
        ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            c.source_path, c.source_type, c.project, c.scope,
            c.block_type, c.block_id, c.title, c.content,
            c.last_modified, h,
        ),
    )


def reindex(full: bool = False) -> dict:
    """Reindex all sources. Returns counts."""
    con = db_connect()
    if full:
        con.execute("DELETE FROM documents")
        con.execute("DELETE FROM file_state")
        con.commit()

    counts = {"md_files": 0, "md_chunks": 0, "jsonl_files": 0, "jsonl_chunks": 0,
              "skipped_unchanged": 0, "deleted_files": 0}

    # Markdown sources
    if MEMORY_ROOT.exists():
        for path in MEMORY_ROOT.rglob("*.md"):
            if not _file_changed(con, path):
                counts["skipped_unchanged"] += 1
                continue
            _delete_chunks_for_file(con, path)
            chunks = list(chunk_markdown(path))
            for c in chunks:
                _insert_chunk(con, c)
            _record_file_state(con, path)
            counts["md_files"] += 1
            counts["md_chunks"] += len(chunks)

    # JSONL sources — top-level only (skip nested subagent transcripts)
    if CLAUDE_SESSIONS_ROOT.exists():
        for path in CLAUDE_SESSIONS_ROOT.glob("*/*.jsonl"):
            if not _file_changed(con, path):
                counts["skipped_unchanged"] += 1
                continue
            _delete_chunks_for_file(con, path)
            chunks = list(chunk_jsonl(path))
            for c in chunks:
                _insert_chunk(con, c)
            _record_file_state(con, path)
            counts["jsonl_files"] += 1
            counts["jsonl_chunks"] += len(chunks)

    # Sweep deleted files
    rows = con.execute("SELECT path FROM file_state").fetchall()
    for (p,) in rows:
        if not Path(p).exists():
            con.execute("DELETE FROM documents WHERE source_path = ?", (p,))
            con.execute("DELETE FROM file_state WHERE path = ?", (p,))
            counts["deleted_files"] += 1

    con.commit()
    con.close()
    return counts


# ─── Search ────────────────────────────────────────────────────────────

def _build_fts_query(raw: str) -> str:
    """
    Quote tokens that contain FTS5-special chars so 'DEC-003' is parsed as a
    phrase, not as 'DEC' minus column '003'. Multiple safe tokens are joined
    with implicit AND (FTS5 default).
    """
    tokens = raw.split()
    out = []
    fts_specials = set('-+*:^"()')
    for t in tokens:
        if any(c in fts_specials for c in t):
            t_escaped = t.replace('"', '""')
            out.append(f'"{t_escaped}"')
        else:
            out.append(t)
    return " ".join(out) if out else raw


def search(
    query: str,
    project: str | None = None,
    block_type: str | None = None,
    limit: int = 10,
) -> list[dict]:
    con = db_connect(create=False)

    fts_query = _build_fts_query(query)
    where = ["documents MATCH ?"]
    params: list = [fts_query]
    if project:
        where.append("project = ?")
        params.append(project)
    if block_type:
        where.append("block_type = ?")
        params.append(block_type)

    sql = (
        "SELECT source_path, project, block_type, block_id, title, "
        "  snippet(documents, 7, '<<', '>>', '...', 32) AS excerpt, "
        "  bm25(documents) AS rank "
        "FROM documents WHERE " + " AND ".join(where) +
        " ORDER BY rank LIMIT ?"
    )
    params.append(limit)

    rows = con.execute(sql, params).fetchall()
    con.close()
    return [
        {
            "source_path": r[0],
            "project": r[1],
            "block_type": r[2],
            "block_id": r[3],
            "title": r[4],
            "excerpt": r[5],
            "rank": r[6],
        }
        for r in rows
    ]


def stats() -> dict:
    con = db_connect(create=False)
    total = con.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
    by_type = dict(con.execute(
        "SELECT block_type, COUNT(*) FROM documents GROUP BY block_type"
    ).fetchall())
    by_project = dict(con.execute(
        "SELECT project, COUNT(*) FROM documents GROUP BY project"
    ).fetchall())
    files = con.execute("SELECT COUNT(*) FROM file_state").fetchone()[0]
    con.close()
    return {
        "total_chunks": total,
        "indexed_files": files,
        "by_type": by_type,
        "by_project": by_project,
        "db_path": str(DB_PATH),
        "db_size_kb": DB_PATH.stat().st_size // 1024 if DB_PATH.exists() else 0,
    }


# ─── CLI ───────────────────────────────────────────────────────────────

def cmd_search(args: argparse.Namespace) -> int:
    results = search(
        args.query, project=args.project,
        block_type=args.type, limit=args.limit,
    )
    if not results:
        print("No matches.", file=sys.stderr)
        return 1
    for i, r in enumerate(results, 1):
        rank = abs(r["rank"])
        print(f"[{i}] {r['project']}/{Path(r['source_path']).name} · "
              f"{r['block_id']} (rank {rank:.2f})")
        print(f"    {r['title']}")
        print(f"    {r['excerpt']}")
        print(f"    → {r['source_path']}")
        print()
    return 0


def cmd_reindex(args: argparse.Namespace) -> int:
    counts = reindex(full=args.full)
    print(f"Reindex {'(full)' if args.full else '(incremental)'}:")
    for k, v in counts.items():
        print(f"  {k}: {v}")
    return 0


def cmd_stats(args: argparse.Namespace) -> int:
    s = stats()
    print(f"DB:           {s['db_path']} ({s['db_size_kb']} KB)")
    print(f"Files indexed: {s['indexed_files']}")
    print(f"Total chunks: {s['total_chunks']}")
    print("By type:")
    for k, v in sorted(s["by_type"].items(), key=lambda x: -x[1]):
        print(f"  {k:12s} {v}")
    print("By project:")
    for k, v in sorted(s["by_project"].items(), key=lambda x: -x[1]):
        print(f"  {k:20s} {v}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="clu-recall",
                                description="FTS5 index over clu memory + sessions")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("search", help="Search the index")
    sp.add_argument("query", help="FTS5 query string (e.g. 'podman uid')")
    sp.add_argument("--project", help="Filter to a single project name")
    sp.add_argument("--type", choices=["DEC", "FND", "LRN", "daily-log", "turn", "note"],
                    help="Filter by block type")
    sp.add_argument("--limit", type=int, default=10, help="Max results (default 10)")
    sp.set_defaults(func=cmd_search)

    rp = sub.add_parser("reindex", help="Reindex sources")
    rp.add_argument("--full", action="store_true",
                    help="Drop everything and rebuild from scratch")
    rp.set_defaults(func=cmd_reindex)

    st = sub.add_parser("stats", help="Show index statistics")
    st.set_defaults(func=cmd_stats)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
