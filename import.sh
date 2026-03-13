#!/usr/bin/env bash
# ============================================================
# clu – Import Claude Code History & Configuration
# ============================================================
# Scans ~/.claude/ for session transcripts, project memory,
# global settings (plugins, MCP servers), plans, and local
# project settings — then imports them into ~/.clu/.
#
# The repo stays clean. All imported data goes to $CLU_HOME
# (the deployed instance, default ~/.clu/).
#
# Usage:
#   clu import              → scan and interactively import
#   clu import --list       → just list what's available
# ============================================================

set -euo pipefail

AGENT_HOME="${CLU_HOME:-$HOME/.clu}"
CLAUDE_HOME="${HOME}/.claude"
CLAUDE_PROJECTS="${CLAUDE_HOME}/projects"
IMPORTED_DIR="$AGENT_HOME/shared/imported"
MODE="${1:-interactive}"

# ── Portable helpers ─────────────────────────────────────────

_sed_i() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# ── Helpers ──────────────────────────────────────────────────

# Decode Claude's path encoding: -home-mi-repos-foo → /home/mi/repos/foo
# Handles ambiguity (e.g., -home-mi-repos-KoSi-backend could be
# /home/mi/repos/KoSi/backend or /home/mi/repos/KoSi-backend)
# by greedily validating against the filesystem.
_decode_claude_path() {
    local encoded="$1"
    # Remove leading dash
    encoded="${encoded#-}"

    # Split on dashes
    IFS='-' read -ra parts <<< "$encoded"

    local path="/"
    local i=0
    while [[ $i -lt ${#parts[@]} ]]; do
        local segment="${parts[$i]}"
        local candidate="$path$segment"

        # Look ahead: try joining subsequent parts with - to find
        # the longest match that exists on the filesystem
        local best="$candidate"
        local best_j=$i
        local j=$((i + 1))
        while [[ $j -lt ${#parts[@]} ]]; do
            candidate="$candidate-${parts[$j]}"
            if [[ -e "$candidate" ]]; then
                best="$candidate"
                best_j=$j
            fi
            j=$((j + 1))
        done

        # If the simple / version exists, prefer it (unless the - version also exists)
        if [[ -e "$path$segment" && ! -e "$best" ]]; then
            best="$path$segment"
            best_j=$i
        fi

        path="$best/"
        i=$((best_j + 1))
    done

    # Remove trailing slash
    echo "${path%/}"
}

_project_name_from_path() {
    basename "$1"
}

_count_sessions() {
    find "$1" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | wc -l
}

_session_date_range() {
    local dir="$1"
    local oldest newest
    oldest=$(find "$dir" -maxdepth 1 -name "*.jsonl" -type f -printf '%T+\n' 2>/dev/null | sort | head -1 | cut -d'+' -f1)
    newest=$(find "$dir" -maxdepth 1 -name "*.jsonl" -type f -printf '%T+\n' 2>/dev/null | sort | tail -1 | cut -d'+' -f1)
    if [[ -n "$oldest" && -n "$newest" ]]; then
        echo "$oldest → $newest"
    else
        echo "—"
    fi
}

_has_claude_memory() {
    local dir="$1"
    [[ -d "$dir/memory" ]] && [[ -n "$(ls -A "$dir/memory/" 2>/dev/null)" ]]
}

_has_local_settings() {
    [[ -f "$1/.claude/settings.local.json" ]]
}

# Check if a file likely contains secrets
_is_credential_file() {
    local file="$1"
    local name
    name=$(basename "$file" | tr '[:upper:]' '[:lower:]')
    [[ "$name" == *credential* || "$name" == *secret* || "$name" == *token* || "$name" == *key* || "$name" == *auth* ]]
}

# ══════════════════════════════════════════════════════════════
# PHASE 1: Import global Claude settings
# ══════════════════════════════════════════════════════════════

_import_global_settings() {
    echo "📋 Global Claude Code configuration:"
    echo ""

    [[ "$MODE" != "--list" ]] && mkdir -p "$IMPORTED_DIR"

    # ── Global settings.json ──────────────────────────────────
    if [[ -f "$CLAUDE_HOME/settings.json" ]]; then
        echo "  Global settings: $CLAUDE_HOME/settings.json"

        # Extract plugins
        local plugins
        plugins=$(CLU_SETTINGS="$CLAUDE_HOME/settings.json" python3 -c '
import json, os
with open(os.environ["CLU_SETTINGS"]) as f:
    d = json.load(f)
for k, v in d.get("enabledPlugins", {}).items():
    if v: print(f"  - {k}")
' 2>/dev/null || echo "  (could not parse)")
        if [[ -n "$plugins" ]]; then
            echo "  Enabled plugins:"
            echo "$plugins"
        fi

        # Extract MCP servers
        local mcp
        mcp=$(CLU_SETTINGS="$CLAUDE_HOME/settings.json" python3 -c '
import json, os
with open(os.environ["CLU_SETTINGS"]) as f:
    d = json.load(f)
for k in d.get("mcpServers", {}):
    print(f"  - {k}")
' 2>/dev/null || echo "")
        if [[ -n "$mcp" ]]; then
            echo "  MCP servers:"
            echo "$mcp"
        fi

        # Extract model + mode
        local model mode
        model=$(CLU_SETTINGS="$CLAUDE_HOME/settings.json" python3 -c 'import json,os; print(json.load(open(os.environ["CLU_SETTINGS"])).get("model","?"))' 2>/dev/null || echo "?")
        mode=$(CLU_SETTINGS="$CLAUDE_HOME/settings.json" python3 -c 'import json,os; print(json.load(open(os.environ["CLU_SETTINGS"])).get("defaultMode","?"))' 2>/dev/null || echo "?")
        echo "  Model: $model | Mode: $mode"

        if [[ "$MODE" != "--list" ]]; then
            cp "$CLAUDE_HOME/settings.json" "$IMPORTED_DIR/claude-global-settings.json"
            echo "  → Copied to $IMPORTED_DIR/claude-global-settings.json"

            # ── Write plugins to config.yaml ───────────────────
            local plugin_list
            plugin_list=$(CLU_SETTINGS="$CLAUDE_HOME/settings.json" python3 -c '
import json, os
with open(os.environ["CLU_SETTINGS"]) as f:
    d = json.load(f)
for k, v in d.get("enabledPlugins", {}).items():
    if v: print(k)
' 2>/dev/null || true)

            if [[ -n "$plugin_list" ]]; then
                # Build YAML array
                local yaml_plugins="plugins:"
                while IFS= read -r p; do
                    yaml_plugins="$yaml_plugins
  - $p"
                done <<< "$plugin_list"

                # Replace plugins section in config.yaml
                # Matches both `plugins: []` and block-list format
                CLU_CFG="$AGENT_HOME/config.yaml" CLU_PLUGINS="$yaml_plugins" python3 -c '
import re, os
config_path = os.environ["CLU_CFG"]
new_plugins = os.environ["CLU_PLUGINS"]
config = open(config_path).read()
if not config.endswith("\n"):
    config += "\n"
new_config, count = re.subn(
    r"^plugins:\s*\[.*?\]|^plugins:\s*\n(?:  - .*\n)*(?:  - .*)?$",
    new_plugins + "\n",
    config,
    flags=re.MULTILINE
)
if count == 0:
    new_config = config + "\n" + new_plugins + "\n"
open(config_path, "w").write(new_config)
' && echo "  → Plugins saved to config.yaml" || echo "  ⚠ Could not update config.yaml plugins"
            fi

            # ── Write MCP servers to config.yaml ──────────────
            local mcp_yaml
            mcp_yaml=$(CLU_SETTINGS="$CLAUDE_HOME/settings.json" python3 -c '
import json, os
with open(os.environ["CLU_SETTINGS"]) as f:
    d = json.load(f)
servers = d.get("mcpServers", {})
if not servers:
    exit(0)
print("mcp_servers:")
for name, cfg in servers.items():
    print(f"  - name: {name}")
    print(f"    command: {cfg.get(\"command\", \"\")}")
    args = cfg.get("args", [])
    if args:
        args_str = ", ".join(f"\"{a}\"" for a in args)
        print(f"    args: [{args_str}]")
' 2>/dev/null || true)

            if [[ -n "$mcp_yaml" ]]; then
                CLU_CFG="$AGENT_HOME/config.yaml" CLU_MCP="$mcp_yaml" python3 -c '
import re, os
config_path = os.environ["CLU_CFG"]
new_mcp = os.environ["CLU_MCP"]
config = open(config_path).read()
if not config.endswith("\n"):
    config += "\n"
new_config, count = re.subn(
    r"^mcp_servers:\s*\[.*?\]$|^mcp_servers:\s*\n(?:  - .*\n(?:    .*\n)*)*(?:  - .*)?$",
    new_mcp + "\n",
    config,
    flags=re.MULTILINE
)
if count == 0:
    new_config = config + "\n" + new_mcp + "\n"
open(config_path, "w").write(new_config)
' && echo "  → MCP servers saved to config.yaml" || echo "  ⚠ Could not update config.yaml MCP servers"
            fi
        fi
    else
        echo "  No global settings found."
    fi

    echo ""

    # ── Plans ─────────────────────────────────────────────────
    local plan_count
    plan_count=$(find "$CLAUDE_HOME/plans/" -name "*.md" -type f 2>/dev/null | wc -l)
    if [[ "$plan_count" -gt 0 ]]; then
        echo "  Plans: $plan_count saved plan(s)"
        if [[ "$MODE" != "--list" ]]; then
            mkdir -p "$IMPORTED_DIR/plans"
            cp "$CLAUDE_HOME/plans/"*.md "$IMPORTED_DIR/plans/" 2>/dev/null
            echo "  → Copied to $IMPORTED_DIR/plans/"
        fi
    else
        echo "  Plans: none"
    fi

    echo ""

    # ── Global command history ────────────────────────────────
    if [[ -f "$CLAUDE_HOME/history.jsonl" ]]; then
        local history_lines
        history_lines=$(wc -l < "$CLAUDE_HOME/history.jsonl")
        echo "  Command history: $history_lines entries"
        # Don't copy — just reference it. It's large and lives in ~/.claude
        echo "  → Referenced (not copied): $CLAUDE_HOME/history.jsonl"
    fi

    echo ""
}

# ══════════════════════════════════════════════════════════════
# PHASE 2: Scan projects
# ══════════════════════════════════════════════════════════════

echo "🔍 Scanning Claude Code data..."
echo ""

if [[ ! -d "$CLAUDE_HOME" ]]; then
    echo "❌ No Claude Code data found at $CLAUDE_HOME"
    echo "   Have you used Claude Code on this machine?"
    exit 1
fi

# Import global settings (always show, only copy files in interactive mode)
_import_global_settings

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🔍 Scanning for project history..."
echo ""

# Build list of discovered projects
declare -a FOUND_ENCODED=()
declare -a FOUND_DECODED=()
declare -a FOUND_NAMES=()
declare -a FOUND_SESSIONS=()
declare -a FOUND_DATES=()
declare -a FOUND_HAS_MEMORY=()
declare -a FOUND_HAS_SETTINGS=()

if [[ -d "$CLAUDE_PROJECTS" ]]; then
    for project_dir in "$CLAUDE_PROJECTS"/*/; do
        [[ -d "$project_dir" ]] || continue
        encoded=$(basename "$project_dir")
        decoded=$(_decode_claude_path "$encoded")
        name=$(_project_name_from_path "$decoded")
        sessions=$(_count_sessions "$project_dir")
        dates=$(_session_date_range "$project_dir")

        # Skip if no sessions
        [[ "$sessions" -eq 0 ]] && continue

        has_memory="no"
        _has_claude_memory "$project_dir" && has_memory="yes"

        has_settings="no"
        _has_local_settings "$decoded" && has_settings="yes"

        FOUND_ENCODED+=("$encoded")
        FOUND_DECODED+=("$decoded")
        FOUND_NAMES+=("$name")
        FOUND_SESSIONS+=("$sessions")
        FOUND_DATES+=("$dates")
        FOUND_HAS_MEMORY+=("$has_memory")
        FOUND_HAS_SETTINGS+=("$has_settings")
    done
fi

# Also scan for repos with .claude/settings.local.json that have no sessions
for settings_file in "$HOME"/repos/*/.claude/settings.local.json "$HOME"/code/*/.claude/settings.local.json "$HOME"/projects/*/.claude/settings.local.json; do
    [[ -f "$settings_file" ]] || continue
    repo_dir=$(dirname "$(dirname "$settings_file")")
    name=$(basename "$repo_dir")

    already_found=false
    for existing_name in "${FOUND_NAMES[@]+"${FOUND_NAMES[@]}"}"; do
        [[ "$existing_name" == "$name" ]] && already_found=true && break
    done
    $already_found && continue

    FOUND_ENCODED+=("local:$name")
    FOUND_DECODED+=("$repo_dir")
    FOUND_NAMES+=("$name")
    FOUND_SESSIONS+=("0")
    FOUND_DATES+=("—")
    FOUND_HAS_MEMORY+=("no")
    FOUND_HAS_SETTINGS+=("yes")
done

if [[ ${#FOUND_ENCODED[@]} -eq 0 ]]; then
    echo "No Claude Code project sessions found."
    exit 0
fi

# ── Display ──────────────────────────────────────────────────

echo "Found ${#FOUND_ENCODED[@]} project(s) with Claude Code history:"
echo ""
printf "  %-4s %-24s %-8s %-8s %-10s %s\n" "#" "Name" "Sessions" "Memory" "Settings" "Date range"
printf "  %-4s %-24s %-8s %-8s %-10s %s\n" "---" "----" "--------" "------" "--------" "----------"

for i in "${!FOUND_ENCODED[@]}"; do
    printf "  %-4s %-24s %-8s %-8s %-10s %s\n" \
        "$((i+1))" \
        "${FOUND_NAMES[$i]}" \
        "${FOUND_SESSIONS[$i]}" \
        "${FOUND_HAS_MEMORY[$i]}" \
        "${FOUND_HAS_SETTINGS[$i]}" \
        "${FOUND_DATES[$i]}"
done
echo ""

if [[ "$MODE" == "--list" ]]; then
    echo "Run 'clu import' to import selected projects."
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# PHASE 3: Interactive project import
# ══════════════════════════════════════════════════════════════

echo "Enter project numbers to import (comma-separated, or 'all', or 'q' to quit):"
read -r selection

if [[ "$selection" == "q" ]]; then
    echo "Aborted."
    exit 0
fi

declare -a SELECTED=()
if [[ "$selection" == "all" ]]; then
    for i in "${!FOUND_ENCODED[@]}"; do
        SELECTED+=("$i")
    done
else
    IFS=',' read -ra parts <<< "$selection"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | tr -d ' ')
        idx=$((part - 1))
        if [[ $idx -ge 0 && $idx -lt ${#FOUND_ENCODED[@]} ]]; then
            SELECTED+=("$idx")
        else
            echo "⚠ Invalid selection: $part (skipping)"
        fi
    done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "Nothing selected."
    exit 0
fi

# ── Import selected projects ────────────────────────────────

for idx in "${SELECTED[@]}"; do
    encoded="${FOUND_ENCODED[$idx]}"
    decoded="${FOUND_DECODED[$idx]}"
    name="${FOUND_NAMES[$idx]}"
    sessions="${FOUND_SESSIONS[$idx]}"
    has_memory="${FOUND_HAS_MEMORY[$idx]}"
    has_settings="${FOUND_HAS_SETTINGS[$idx]}"

    # source_dir only valid for non-local entries
    source_dir="$CLAUDE_PROJECTS/$encoded"
    [[ "$encoded" == local:* ]] && source_dir=""

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 Importing: $name ($decoded)"
    echo "   Sessions: $sessions | Claude memory: $has_memory | Local settings: $has_settings"

    target="$AGENT_HOME/projects/$name"

    # ── Create clu project if needed ──────────────────────────

    if [[ ! -d "$target" ]]; then
        echo "   Creating clu project: $name"
        cp -r "$AGENT_HOME/templates/new-project" "$target"
        mkdir -p "$target/memory/days"

        today=$(date +%Y-%m-%d)

        find "$target" -type f \( -name "*.yaml" -o -name "*.md" \) | while read -r f; do
            _sed_i "s/{{PROJECT_NAME}}/$name/g" "$f"
            _sed_i "s/{{DATE}}/$today/g" "$f"
        done

        if [[ -d "$decoded" ]]; then
            _sed_i "s|repo_path: null|repo_path: $decoded|" "$target/project.yaml"
            echo "   Repo path: $decoded"
        fi
    else
        echo "   clu project already exists, merging history."
    fi

    # ── Import Claude project memory ──────────────────────────

    if [[ "$has_memory" == "yes" && -n "$source_dir" ]]; then
        echo "   Importing Claude memory files..."
        mkdir -p "$target/memory/imported"

        for mf in "$source_dir"/memory/*; do
            [[ -f "$mf" ]] || continue
            local_name=$(basename "$mf")

            # Warn about credential files but still import
            if _is_credential_file "$mf"; then
                echo "   ⚠ WARNING: '$local_name' may contain secrets!"
                echo "     Review and consider removing sensitive data after import."
            fi

            cp "$mf" "$target/memory/imported/$local_name"
            echo "   → $local_name"
        done
    fi

    # ── Import local .claude/settings.local.json ──────────────

    if [[ "$has_settings" == "yes" ]]; then
        echo "   Importing local Claude settings..."
        local_settings="$decoded/.claude/settings.local.json"
        imported_settings="$target/imported-claude-settings.json"
        cp "$local_settings" "$imported_settings"

        constraints_file="$target/constraints.md"
        if ! grep -q "Claude Code Permissions" "$constraints_file" 2>/dev/null; then
            cat >> "$constraints_file" << SETTINGS

## Imported Claude Code Permissions

The following permissions were configured in the original Claude Code project
(\`$decoded/.claude/settings.local.json\`):

\`\`\`json
$(cat "$local_settings")
\`\`\`

> Imported on $(date +%Y-%m-%d). Review and adjust as needed.
SETTINGS
            echo "   → Appended permissions to constraints.md"
        else
            echo "   → constraints.md already has Claude settings (skipping)"
        fi
    fi

    # ── Create session transcript index ───────────────────────

    if [[ "$sessions" -eq 0 ]]; then
        echo "   No session transcripts to index."
        echo "   ✅ Done"
        continue
    fi

    echo "   Indexing $sessions session transcripts..."
    index_file="$target/memory/imported-sessions.md"
    cat > "$index_file" << HEADER
---
last_verified: $(date +%Y-%m-%d)
scope: project
type: imported
abstract: "Imported ${sessions} Claude Code session transcripts from ${decoded}"
entry_count: ${sessions}
---

# Imported Claude Code Sessions

Source: \`$source_dir\`
Original path: \`$decoded\`
Import date: $(date +%Y-%m-%d)

## Session Transcripts

These are the original Claude Code session transcripts (JSONL format).
The agent can read them on-demand for full context from previous sessions.

HEADER

    for jsonl in $(find "$source_dir" -maxdepth 1 -name "*.jsonl" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}'); do
        local_date=$(date -r "$jsonl" +"%Y-%m-%d %H:%M" 2>/dev/null || stat -c '%y' "$jsonl" 2>/dev/null | cut -d'.' -f1)
        local_size=$(du -h "$jsonl" 2>/dev/null | cut -f1)
        echo "- **${local_date}** — \`$jsonl\` (${local_size})" >> "$index_file"
    done

    echo "   → Session index: $index_file"
    echo "   ✅ Done"
done

# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Import complete!"
echo ""
echo "Imported data locations:"
echo "  Global settings:  $IMPORTED_DIR/claude-global-settings.json"
echo "  Plans:            $IMPORTED_DIR/plans/"
echo "  Project data:     $AGENT_HOME/projects/<name>/"
echo ""
echo "Session transcripts remain in ~/.claude/ (referenced by path)."
echo "All other imported data is in ~/.clu/ and part of backups."
echo ""
echo "⚠ Security reminder:"
echo "  Review imported files for credentials/secrets before pushing to git!"
echo "  Check: grep -r 'token\|key\|password\|secret' $AGENT_HOME/projects/*/memory/imported/"
echo ""
echo "Next steps:"
echo "  1. Review imported projects: clu list"
echo "  2. Launch a project: clu <name>"
echo "  3. Tell the agent: 'Read imported memory and summarize key decisions'"
echo "  4. Run 'clu bootstrap' to configure your profile, personality & install plugins"
echo ""
