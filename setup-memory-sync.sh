#!/usr/bin/env bash
# ============================================================
# clu – Memory Sync Setup
# ============================================================
# Run this on any machine where clu is installed to set up
# the shared memory repo with symlinks.
#
# What it does:
#   1. Clones the clu-memory repo (or inits a new one)
#   2. Merges local memory files into the repo
#   3. Replaces local dirs with symlinks
#   4. Adjusts heartbeat timer offset to avoid sync collisions
#
# Usage:
#   ./setup-memory-sync.sh                    # clone existing repo
#   ./setup-memory-sync.sh --init             # init new repo (first machine)
#   ./setup-memory-sync.sh --repo <url>       # custom repo URL
#   ./setup-memory-sync.sh --timer-offset 15  # minutes offset for heartbeat
#
# Prerequisites:
#   - clu installed at ~/.clu
#   - git configured with SSH or HTTPS access to GitHub
# ============================================================

set -euo pipefail

AGENT_HOME="${CLU_HOME:-$HOME/.clu}"
MEMORY_REPO="$HOME/repos/clu-memory"
REPO_URL="git@github.com:schmitze/clu-memory.git"
INIT_MODE=false
TIMER_OFFSET=15  # minutes after the hour, to avoid collision with other machine

# ── Parse arguments ──────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --init)        INIT_MODE=true; shift ;;
        --repo)        REPO_URL="$2"; shift 2 ;;
        --timer-offset) TIMER_OFFSET="$2"; shift 2 ;;
        -h|--help)     head -22 "$0" | grep "^#" | sed 's/^# \?//'; exit 0 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Preflight checks ────────────────────────────────────────

if [[ ! -d "$AGENT_HOME" ]]; then
    echo "❌ clu not found at $AGENT_HOME. Install clu first."
    exit 1
fi

if [[ -L "$AGENT_HOME/shared/memory" ]]; then
    echo "⚠ shared/memory is already a symlink — memory sync appears to be set up."
    echo "  Target: $(readlink "$AGENT_HOME/shared/memory")"
    read -p "  Re-run setup anyway? (y/n) " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
fi

mkdir -p "$HOME/repos"

# ── Step 1: Get the memory repo ─────────────────────────────

echo ""
echo "═══ Step 1: Memory repo ═══"

if [[ -d "$MEMORY_REPO/.git" ]]; then
    echo "📁 Memory repo already exists at $MEMORY_REPO"
    echo "   Pulling latest..."
    git -C "$MEMORY_REPO" pull --rebase || true
elif [[ "$INIT_MODE" == true ]]; then
    echo "🆕 Initializing new memory repo at $MEMORY_REPO"
    mkdir -p "$MEMORY_REPO"
    git -C "$MEMORY_REPO" init -b main
    cat > "$MEMORY_REPO/.gitignore" << 'GITIGNORE'
# Runtime state (not memory)
security-incidents.jsonl
dashboard-state.json
*.tmp
*.swp
*.swo
*~
.DS_Store
GITIGNORE
    echo "   Set up remote with: git -C $MEMORY_REPO remote add origin <url>"
else
    echo "📥 Cloning $REPO_URL → $MEMORY_REPO"
    git clone "$REPO_URL" "$MEMORY_REPO"
fi

# ── Step 2: Merge local memory into repo ─────────────────────

echo ""
echo "═══ Step 2: Merge local memory ═══"

merge_dir() {
    local src="$1" dst="$2" label="$3"
    if [[ ! -d "$src" || -L "$src" ]]; then
        return
    fi
    mkdir -p "$dst"
    # Copy files that don't exist in repo yet (local-only content)
    local new_count=0
    while IFS= read -r -d '' file; do
        local rel="${file#$src/}"
        if [[ ! -f "$dst/$rel" ]]; then
            # Skip empty templates (entry_count: 0, no real content)
            local ec
            ec=$(awk '/^entry_count:/{v=$2} /^[0-9]+$/ && prev ~ /entry_count/{v=$0} {prev=$0} END{print v+0}' "$file" 2>/dev/null)
            if [[ "$ec" == "0" && "$(basename "$file")" != "journal.md" ]]; then
                continue
            fi
            mkdir -p "$(dirname "$dst/$rel")"
            cp "$file" "$dst/$rel"
            new_count=$((new_count + 1))
        fi
    done < <(find "$src" -type f -print0 2>/dev/null)
    if [[ $new_count -gt 0 ]]; then
        echo "  📝 $label: merged $new_count new file(s) into repo"
    else
        echo "  ✅ $label: no new files to merge"
    fi
}

# Shared memory
merge_dir "$AGENT_HOME/shared/memory" "$MEMORY_REPO/shared/memory" "shared/memory"
merge_dir "$AGENT_HOME/shared/agent" "$MEMORY_REPO/shared/agent" "shared/agent"

# Project memory
for proj in "$AGENT_HOME"/projects/*/; do
    [[ -d "$proj" ]] || continue
    name=$(basename "$proj")
    merge_dir "$proj/memory" "$MEMORY_REPO/projects/$name/memory" "$name/memory"
done

# Commit merged content
if ! git -C "$MEMORY_REPO" diff --quiet 2>/dev/null || \
   [[ -n "$(git -C "$MEMORY_REPO" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    git -C "$MEMORY_REPO" add -A
    git -C "$MEMORY_REPO" commit -m "merge local memory from $(hostname) $(date +%Y-%m-%d)" --quiet
    echo "  📦 Committed merged memory"
fi

# ── Step 3: Replace local dirs with symlinks ─────────────────

echo ""
echo "═══ Step 3: Create symlinks ═══"

symlink_dir() {
    local src="$1" target="$2" label="$3"
    if [[ -L "$src" ]]; then
        echo "  ⏭ $label: already a symlink"
        return
    fi
    if [[ -d "$src" ]]; then
        rm -rf "$src"
    fi
    ln -s "$target" "$src"
    echo "  🔗 $label → $target"
}

# Shared
symlink_dir "$AGENT_HOME/shared/memory" "$MEMORY_REPO/shared/memory" "shared/memory"
symlink_dir "$AGENT_HOME/shared/agent" "$MEMORY_REPO/shared/agent" "shared/agent"

# Projects
for proj in "$AGENT_HOME"/projects/*/; do
    [[ -d "$proj" ]] || continue
    name=$(basename "$proj")
    if [[ -d "$MEMORY_REPO/projects/$name/memory" ]]; then
        symlink_dir "$proj/memory" "$MEMORY_REPO/projects/$name/memory" "$name/memory"
    else
        echo "  ⏭ $name: no memory dir in repo, keeping local"
    fi
done

# ── Step 4: Adjust heartbeat timer ───────────────────────────

echo ""
echo "═══ Step 4: Heartbeat timer offset ═══"

TIMER_FILE="$HOME/.config/systemd/user/clu-heartbeat.timer"
if [[ -f "$TIMER_FILE" ]]; then
    # Adjust OnCalendar to offset by TIMER_OFFSET minutes
    TIMER_HOUR=4
    TIMER_MIN=$(printf "%02d" "$TIMER_OFFSET")
    sed -i "s|OnCalendar=.*|OnCalendar=*-*-* ${TIMER_HOUR}:${TIMER_MIN}:00|" "$TIMER_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "  ⏰ Heartbeat timer set to 04:${TIMER_MIN} (offset ${TIMER_OFFSET}m)"
else
    echo "  ⬜ No heartbeat timer found — set up manually or run clu install"
fi

# ── Step 5: Push if remote is configured ─────────────────────

echo ""
echo "═══ Step 5: Push ═══"

if git -C "$MEMORY_REPO" remote get-url origin &>/dev/null; then
    if git -C "$MEMORY_REPO" push --quiet 2>/dev/null; then
        echo "  ✅ Pushed to remote"
    else
        echo "  ⚠ Push failed — check remote access"
    fi
else
    echo "  ⬜ No remote configured. Add one with:"
    echo "     git -C $MEMORY_REPO remote add origin <url>"
fi

# ── Done ─────────────────────────────────────────────────────

echo ""
echo "✅ Memory sync setup complete!"
echo ""
echo "  Memory repo: $MEMORY_REPO"
echo "  Symlinks: ~/.clu/shared/ and ~/.clu/projects/*/memory/"
echo "  Heartbeat: auto-commits and pushes memory changes nightly"
echo ""
echo "  To pull memory from other machines:"
echo "    git -C $MEMORY_REPO pull"
echo ""
