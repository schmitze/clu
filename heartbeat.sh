#!/usr/bin/env bash
# ============================================================
# clu – Heartbeat (Maintenance Between Sessions)
# ============================================================
# Runs automated maintenance tasks without starting a full
# agent session. Designed to be called by cron or manually.
#
# Usage:
#   clu heartbeat              → run all maintenance tasks
#   clu heartbeat <project>    → run for a specific project
#
# Cron setup (daily at 8am):
#   0 8 * * * $HOME/.clu/heartbeat.sh >> $HOME/.clu/heartbeat.log 2>&1
#
# What it does:
#   1. Memory staleness check across all projects
#   2. Daily log hygiene (flag empty days, suggest weekly rollup)
#   3. User profile freshness check
#   4. Optional: generate "morning brief" for active projects
# ============================================================

set -euo pipefail

# ── Portable helpers (Linux + macOS) ─────────────────────────

# Portable date string to epoch (GNU: date -d, macOS: date -j -f)
_date_to_epoch() {
    local datestr="$1"
    date -d "$datestr" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%d" "$datestr" +%s 2>/dev/null \
        || echo "0"
}

# Portable relative date (GNU: date -d, macOS: date -v)
_date_relative() {
    local offset="$1" fmt="$2"
    date -d "$offset" +"$fmt" 2>/dev/null \
        || date -v"$offset" +"$fmt" 2>/dev/null \
        || echo "unknown"
}

AGENT_HOME="${CLU_HOME:-$HOME/.clu}"
CONFIG_FILE="$AGENT_HOME/config.yaml"
TARGET_PROJECT="${1:-}"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M")
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(_date_relative "-1d" "%Y-%m-%d")

# ── Logging ───────────────────────────────────────────────────

log() {
    echo "[$TIMESTAMP] $1"
}

log "🫀 clu heartbeat starting"

# ── Load config ───────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "❌ Config not found. Is clu installed?"
    exit 1
fi

STALENESS_DAYS=$(grep "memory_staleness_days:" "$CONFIG_FILE" 2>/dev/null \
    | head -1 | sed 's/.*memory_staleness_days:[[:space:]]*//')
STALENESS_DAYS="${STALENESS_DAYS:-30}"

# ── Task 1: Memory staleness across all projects ─────────────

log "📋 Checking memory staleness (threshold: ${STALENESS_DAYS}d)..."

stale_count=0
today_epoch=$(date +%s)

check_staleness() {
    local file="$1"
    local verified
    verified=$(grep "last_verified:" "$file" 2>/dev/null | head -1 | sed 's/.*last_verified:[[:space:]]*//')
    if [[ -n "$verified" ]]; then
        local v_epoch
        v_epoch=$(_date_to_epoch "$verified")
        local age_days=$(( (today_epoch - v_epoch) / 86400 ))
        if [[ $age_days -ge $STALENESS_DAYS ]]; then
            log "  ⚠ STALE (${age_days}d): $file"
            stale_count=$((stale_count + 1))
        fi
    fi
}

# Shared memory
for mf in "$AGENT_HOME"/shared/memory/*.md "$AGENT_HOME"/shared/agent/*.md; do
    [[ -f "$mf" ]] || continue
    check_staleness "$mf"
done

# Project memory
if [[ -n "$TARGET_PROJECT" ]]; then
    project_dirs=("$AGENT_HOME/projects/$TARGET_PROJECT")
else
    project_dirs=("$AGENT_HOME"/projects/*/)
fi

for project_dir in "${project_dirs[@]}"; do
    [[ -d "$project_dir" ]] || continue
    for mf in "$project_dir"/memory/*.md; do
        [[ -f "$mf" ]] || continue
        check_staleness "$mf"
    done
done

if [[ $stale_count -eq 0 ]]; then
    log "  ✅ All memory files are fresh."
else
    log "  ⚠ $stale_count stale file(s) found."
fi

# ── Task 2: Daily log hygiene ─────────────────────────────────

log "📅 Checking daily log hygiene..."

for project_dir in "${project_dirs[@]}"; do
    [[ -d "$project_dir" ]] || continue
    local_name=$(basename "$project_dir")
    days_dir="$project_dir/memory/days"

    if [[ ! -d "$days_dir" ]]; then
        mkdir -p "$days_dir"
        log "  📁 Created days/ directory for $local_name"
        continue
    fi

    # Count daily logs this week
    week_count=0
    for i in $(seq 0 6); do
        day=$(_date_relative "-${i}d" "%Y-%m-%d")
        [[ "$day" == "unknown" ]] && continue
        if [[ -f "$days_dir/$day.md" ]]; then
            week_count=$((week_count + 1))
        fi
    done
    log "  $local_name: $week_count session(s) this week"

    # Check if weekly rollup is due (it's Monday or 7+ daily logs without rollup)
    day_of_week=$(date +%u)  # 1=Monday
    if [[ "$day_of_week" == "1" ]]; then
        log "  💡 It's Monday — consider running a weekly journal rollup for $local_name"
    fi
done

# ── Task 3: User profile freshness ───────────────────────────

log "👤 Checking user profile..."

prefs_file="$AGENT_HOME/shared/memory/preferences.md"
if [[ -f "$prefs_file" ]]; then
    # Check if profile is still mostly template (uncommented sections)
    filled_lines=$(grep -v "^#\|^$\|^--\|^<" "$prefs_file" 2>/dev/null | grep -v "^<!--" | wc -l)
    if [[ $filled_lines -lt 10 ]]; then
        log "  ⚠ User profile looks sparse ($filled_lines lines of content)."
        log "    Run 'clu bootstrap' to fill it via interview, or edit manually."
    else
        log "  ✅ User profile has content ($filled_lines lines)."
    fi
else
    log "  ❌ User profile not found!"
fi

# ── Task 4: Morning brief (optional) ─────────────────────────

log "🌅 Generating morning brief..."

for project_dir in "${project_dirs[@]}"; do
    [[ -d "$project_dir" ]] || continue
    local_name=$(basename "$project_dir")
    days_dir="$project_dir/memory/days"

    # Show yesterday's open threads if a log exists
    if [[ -f "$days_dir/$YESTERDAY.md" ]]; then
        open_threads=$(sed -n '/^## Open threads/,/^## /p' "$days_dir/$YESTERDAY.md" 2>/dev/null | head -10 | grep -v "^##")
        if [[ -n "$open_threads" ]]; then
            log "  📌 $local_name — open from yesterday:"
            echo "$open_threads" | while read -r line; do
                [[ -n "$line" ]] && log "     $line"
            done
        fi
    fi

    # Show next session notes
    if [[ -f "$days_dir/$YESTERDAY.md" ]]; then
        next=$(sed -n '/^## Next session/,/^## \|^$/p' "$days_dir/$YESTERDAY.md" 2>/dev/null | head -5 | grep -v "^##")
        if [[ -n "$next" ]]; then
            log "  ➡️  $local_name — pick up:"
            echo "$next" | while read -r line; do
                [[ -n "$line" ]] && log "     $line"
            done
        fi
    fi
done

# ── Done ──────────────────────────────────────────────────────

log "🫀 Heartbeat complete."
echo ""
