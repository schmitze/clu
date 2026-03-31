#!/usr/bin/env bash
# ============================================================
# clu migration tool
# Creates a portable migration bundle from ~/.clu/
# and provides restore on the target system.
#
# Usage:
#   ./migrate.sh pack              # Create bundle
#   ./migrate.sh restore <file>    # Restore from bundle
#   ./migrate.sh check             # Dry-run: show what would be packed
# ============================================================

set -euo pipefail

CLU_HOME="${CLU_HOME:-$HOME/.clu}"
BUNDLE_DIR="${BUNDLE_DIR:-$HOME/clu-migration}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUNDLE_NAME="clu-migration-${TIMESTAMP}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}→${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# ── Duplicate nested directory detection ─────────────────────
# Some installs create duplicates like adapters/adapters/, personas/personas/
# These are template originals; the outer versions are the active ones.
EXCLUDE_NESTED=(
    "adapters/adapters"
    "personas/personas"
    "templates/templates"
    "docs/docs"
)

# Files to exclude from bundle (sensitive or ephemeral)
EXCLUDE_FILES=(
    ".secrets.env"
    "heartbeat.log"
    "heartbeat-agent.log"
    "security-incidents.jsonl"
    "__pycache__"
    "*.pyc"
    ".DS_Store"
)

build_tar_excludes() {
    local excludes=()
    for nested in "${EXCLUDE_NESTED[@]}"; do
        excludes+=(--exclude="$nested")
    done
    for pattern in "${EXCLUDE_FILES[@]}"; do
        excludes+=(--exclude="$pattern")
    done
    echo "${excludes[@]}"
}

# ── PACK ─────────────────────────────────────────────────────
cmd_pack() {
    if [[ ! -d "$CLU_HOME" ]]; then
        error "CLU_HOME not found at $CLU_HOME"
        exit 1
    fi

    info "Packing clu from $CLU_HOME"

    # Create bundle directory
    mkdir -p "$BUNDLE_DIR/$BUNDLE_NAME"

    # 1) Create the tarball (excluding sensitive/ephemeral files)
    local excludes
    excludes=$(build_tar_excludes)

    tar czf "$BUNDLE_DIR/$BUNDLE_NAME/clu-data.tar.gz" \
        $excludes \
        -C "$(dirname "$CLU_HOME")" \
        "$(basename "$CLU_HOME")"

    ok "Data packed"

    # 2) Extract repo_path mappings for adjustment on target
    info "Extracting repo paths from project configs..."
    local paths_file="$BUNDLE_DIR/$BUNDLE_NAME/repo-paths.txt"
    echo "# Repo paths found in project.yaml files." > "$paths_file"
    echo "# Edit these BEFORE running restore if paths differ on target." >> "$paths_file"
    echo "# Format: project_name=repo_path" >> "$paths_file"
    echo "" >> "$paths_file"

    for pfile in "$CLU_HOME"/projects/*/project.yaml; do
        [[ -f "$pfile" ]] || continue
        local pname
        pname=$(basename "$(dirname "$pfile")")
        local repo_path
        repo_path=$(grep -E '^repo_path:' "$pfile" | sed 's/repo_path:\s*//' | tr -d '"' | tr -d "'" || true)
        if [[ -n "$repo_path" && "$repo_path" != "null" ]]; then
            echo "${pname}=${repo_path}" >> "$paths_file"
        fi
    done
    ok "Repo paths extracted → repo-paths.txt"

    # 3) Record source system info
    local sysinfo="$BUNDLE_DIR/$BUNDLE_NAME/source-info.txt"
    {
        echo "hostname=$(hostname)"
        echo "user=$USER"
        echo "home=$HOME"
        echo "date=$(date -Iseconds)"
        echo "clu_home=$CLU_HOME"
        echo "os=$(uname -s)"
        echo "arch=$(uname -m)"
    } > "$sysinfo"
    ok "Source info recorded"

    # 4) Create secrets template
    local secrets_tmpl="$BUNDLE_DIR/$BUNDLE_NAME/secrets.env.template"
    if [[ -f "$CLU_HOME/.secrets.env" ]]; then
        # Extract variable names without values
        grep -E '^[A-Z_]+=' "$CLU_HOME/.secrets.env" \
            | sed 's/=.*/=# FILL IN/' \
            > "$secrets_tmpl" 2>/dev/null || true
        ok "Secrets template created (values stripped)"
    else
        echo "# No secrets found on source system" > "$secrets_tmpl"
    fi

    # 5) Copy restore script into bundle
    cp "$0" "$BUNDLE_DIR/$BUNDLE_NAME/migrate.sh"
    chmod +x "$BUNDLE_DIR/$BUNDLE_NAME/migrate.sh"

    # 6) Record clu plugin list for reinstall
    local plugins_file="$BUNDLE_DIR/$BUNDLE_NAME/plugins.txt"
    if [[ -f "$CLU_HOME/config.yaml" ]]; then
        sed -n '/^plugins:/,/^[a-z_]*:/{ /^plugins:/d; /^[a-z_]*:/d; p; }' \
            "$CLU_HOME/config.yaml" \
            | grep -E '^\s+-\s' \
            | sed 's/^\s*-\s*//' \
            > "$plugins_file" 2>/dev/null || true
        ok "clu plugin list extracted → plugins.txt"
    fi

    # 6b) Extract full Claude Code plugin ecosystem for reinstall
    local claude_dir="$HOME/.claude"
    local claude_plugins_dir="$BUNDLE_DIR/$BUNDLE_NAME/claude-plugins"
    mkdir -p "$claude_plugins_dir"

    # 6b-i) Marketplaces (repos to re-add)
    if [[ -f "$claude_dir/plugins/known_marketplaces.json" ]]; then
        cp "$claude_dir/plugins/known_marketplaces.json" "$claude_plugins_dir/"
        ok "Marketplace registry copied"
    fi

    # 6b-ii) Installed plugins (what to reinstall)
    if [[ -f "$claude_dir/plugins/installed_plugins.json" ]]; then
        cp "$claude_dir/plugins/installed_plugins.json" "$claude_plugins_dir/"
        ok "Installed plugins registry copied"
    fi

    # 6b-iii) Settings (enabled/disabled state + extra marketplaces)
    if [[ -f "$claude_dir/settings.json" ]]; then
        python3 -c "
import json, sys
with open('$claude_dir/settings.json') as f:
    s = json.load(f)
out = {}
for k in ('enabledPlugins', 'extraKnownMarketplaces'):
    if k in s:
        out[k] = s[k]
json.dump(out, sys.stdout, indent=2)
" > "$claude_plugins_dir/plugin-settings.json" 2>/dev/null || true
        ok "Plugin settings extracted"
    fi

    # 6b-iv) Generate human-readable reinstall script
    local reinstall_script="$claude_plugins_dir/reinstall.sh"
    cat > "$reinstall_script" << 'REINSTALL_HEADER'
#!/usr/bin/env bash
# Auto-generated: reinstall all Claude Code plugins on target system
# Run after Claude Code CLI is installed.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${CYAN}→${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Install Claude Code first."
    exit 1
fi

echo "Reinstalling Claude Code plugins..."
echo ""
REINSTALL_HEADER

    # Parse marketplaces and plugins to generate install commands
    python3 -c "
import json, sys, os

claude_dir = '$claude_dir'
script_lines = []

# 1) Add custom marketplaces
settings_file = os.path.join(claude_dir, 'settings.json')
if os.path.isfile(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)
    extras = settings.get('extraKnownMarketplaces', {})
    for name, config in extras.items():
        repo = config.get('source', {}).get('repo', '')
        if repo:
            script_lines.append(f'info \"Adding custom marketplace: {name} ({repo})\"')
            script_lines.append(f'claude plugins marketplace add {repo} || warn \"marketplace {name} may already exist\"')
            script_lines.append('')

# 2) Install plugins
plugins_file = os.path.join(claude_dir, 'plugins', 'installed_plugins.json')
if os.path.isfile(plugins_file):
    with open(plugins_file) as f:
        pdata = json.load(f)

    enabled = {}
    if os.path.isfile(settings_file):
        with open(settings_file) as f:
            enabled = json.load(f).get('enabledPlugins', {})

    for plugin_key, entries in pdata.get('plugins', {}).items():
        # plugin_key format: 'name@marketplace'
        parts = plugin_key.split('@', 1)
        plugin_name = parts[0]
        marketplace = parts[1] if len(parts) > 1 else 'unknown'
        is_enabled = enabled.get(plugin_key, True)
        status = 'enabled' if is_enabled else 'disabled'

        script_lines.append(f'info \"Installing {plugin_name} from {marketplace} [{status}]\"')
        script_lines.append(f'claude plugins install {plugin_key} || warn \"failed: {plugin_key}\"')
        if not is_enabled:
            script_lines.append(f'# Plugin was disabled on source system — disable after install if needed')
        script_lines.append(f'ok \"{plugin_name}\"')
        script_lines.append('')

script_lines.append('echo \"\"')
script_lines.append('ok \"All plugins reinstalled.\"')
script_lines.append('echo \"Check with: claude plugins list\"')

print('\n'.join(script_lines))
" >> "$reinstall_script" 2>/dev/null || true

    chmod +x "$reinstall_script"
    ok "Plugin reinstall script generated → claude-plugins/reinstall.sh"

    # 7) Create final archive
    tar czf "$BUNDLE_DIR/${BUNDLE_NAME}.tar.gz" \
        -C "$BUNDLE_DIR" \
        "$BUNDLE_NAME"

    # Clean up intermediate directory
    rm -rf "$BUNDLE_DIR/$BUNDLE_NAME"

    echo ""
    ok "Migration bundle created:"
    echo "   $BUNDLE_DIR/${BUNDLE_NAME}.tar.gz"
    echo ""
    local size
    size=$(du -sh "$BUNDLE_DIR/${BUNDLE_NAME}.tar.gz" | cut -f1)
    info "Size: $size"
    echo ""
    echo "Transfer to target system, then run:"
    echo "   tar xzf ${BUNDLE_NAME}.tar.gz"
    echo "   cd ${BUNDLE_NAME}"
    echo "   # Edit repo-paths.txt if repo locations differ"
    echo "   # Fill in secrets.env.template → .secrets.env"
    echo "   ./migrate.sh restore"
}

# ── RESTORE ──────────────────────────────────────────────────
cmd_restore() {
    local bundle_dir="${1:-.}"

    # Find data tarball
    local data_tar="$bundle_dir/clu-data.tar.gz"
    if [[ ! -f "$data_tar" ]]; then
        error "clu-data.tar.gz not found in $bundle_dir"
        echo "Run this from inside the unpacked bundle directory."
        exit 1
    fi

    local target="${CLU_HOME}"

    if [[ -d "$target" ]]; then
        warn "Target $target already exists!"
        echo -n "   Overwrite? (y/n): "
        read -r confirm
        if [[ "$confirm" != "y" ]]; then
            echo "Aborted."
            exit 0
        fi
        # Backup existing
        local backup="$target.backup-$(date +%Y%m%d-%H%M%S)"
        mv "$target" "$backup"
        ok "Existing clu backed up to $backup"
    fi

    # 1) Extract data
    info "Extracting clu data to $target..."
    tar xzf "$data_tar" -C "$(dirname "$target")"

    # Rename if extracted dir name doesn't match target
    local extracted_name
    extracted_name=$(tar tzf "$data_tar" | head -1 | cut -d/ -f1)
    local extracted_path="$(dirname "$target")/$extracted_name"
    if [[ "$extracted_path" != "$target" && -d "$extracted_path" ]]; then
        mv "$extracted_path" "$target"
    fi
    ok "Data extracted"

    # 2) Fix repo paths
    local paths_file="$bundle_dir/repo-paths.txt"
    if [[ -f "$paths_file" ]]; then
        info "Checking repo paths..."
        local has_missing=false
        while IFS='=' read -r pname repo_path; do
            [[ "$pname" =~ ^#.*$ || -z "$pname" ]] && continue
            repo_path=$(echo "$repo_path" | xargs)  # trim whitespace
            if [[ ! -d "$repo_path" ]]; then
                warn "  $pname → $repo_path (NOT FOUND)"
                has_missing=true
            else
                ok "  $pname → $repo_path"
            fi
        done < "$paths_file"

        if $has_missing; then
            echo ""
            warn "Some repo paths don't exist on this system."
            echo "   Edit the project.yaml files in $target/projects/*/project.yaml"
            echo "   to fix repo_path values."
        fi
    fi

    # 3) Restore secrets
    local secrets_tmpl="$bundle_dir/secrets.env.template"
    if [[ -f "$secrets_tmpl" ]]; then
        if [[ ! -f "$target/.secrets.env" ]]; then
            cp "$secrets_tmpl" "$target/.secrets.env"
            warn "Secrets template copied to $target/.secrets.env — fill in values!"
        fi
    fi

    # 4) Fix permissions
    chmod +x "$target/launcher" \
             "$target/bootstrap.sh" \
             "$target/heartbeat.sh" \
             "$target/import.sh" \
             "$target/create-persona.sh" 2>/dev/null || true
    ok "Permissions set"

    # 5) Regenerate integrity hashes
    info "Regenerating integrity hashes..."
    if [[ -x "$target/heartbeat.sh" ]]; then
        (
            cd "$target"
            sha256sum launcher bootstrap.sh heartbeat.sh \
                      shared/core-prompt.md shared/constraints.md \
                      config.yaml 2>/dev/null > .integrity-hashes || true
        )
        ok "Integrity hashes regenerated"
    fi

    # 6) Shell integration
    local shell_rc=""
    if [[ -f "$HOME/.zshrc" ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_rc="$HOME/.bashrc"
    fi

    if [[ -n "$shell_rc" ]]; then
        if ! grep -q 'CLU_HOME' "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# clu – agent workstation" >> "$shell_rc"
            echo "export CLU_HOME=\"$target\"" >> "$shell_rc"
            echo "alias clu='$target/launcher'" >> "$shell_rc"
            ok "Shell alias added to $shell_rc"
            warn "Run: source $shell_rc"
        else
            ok "Shell integration already present in $shell_rc"
        fi
    else
        warn "No .zshrc or .bashrc found. Add manually:"
        echo "   export CLU_HOME=\"$target\""
        echo "   alias clu='$target/launcher'"
    fi

    # 7) Plugin reminder (clu plugins from config.yaml)
    local plugins_file="$bundle_dir/plugins.txt"
    if [[ -f "$plugins_file" && -s "$plugins_file" ]]; then
        echo ""
        info "clu plugins to install (from config.yaml):"
        while IFS= read -r plugin; do
            [[ -z "$plugin" ]] && continue
            echo "   claude plugins install $plugin"
        done < "$plugins_file"
    fi

    # 7b) Claude Code plugin ecosystem reinstall
    local claude_plugins_dir="$bundle_dir/claude-plugins"
    if [[ -d "$claude_plugins_dir" ]]; then
        echo ""
        if [[ -x "$claude_plugins_dir/reinstall.sh" ]]; then
            info "Claude Code plugins — run reinstall.sh or copy-paste:"
            echo "   ┌──────────────────────────────────────────────"
            # Extract just the claude commands from the script
            grep -E '^\s*(claude plugins )' "$claude_plugins_dir/reinstall.sh" \
                | sed 's/^\s*/   │ /' 2>/dev/null || true
            echo "   └──────────────────────────────────────────────"
            echo ""
            echo "   Or run: ./claude-plugins/reinstall.sh"
        fi
    fi

    # 8) Clean up duplicate nested directories (install bug)
    for nested in adapters/adapters personas/personas templates/templates docs/docs; do
        if [[ -d "$target/$nested" ]]; then
            rm -rf "$target/$nested"
            ok "Removed duplicate: $nested/"
        fi
    done

    echo ""
    ok "Restore complete!"
    echo ""
    echo "Next steps:"
    echo "  1. source $shell_rc"
    echo "  2. Fill in $target/.secrets.env"
    echo "  3. Fix any missing repo paths (see warnings above)"
    echo "  4. Install Claude Code plugins (see commands above or run ./claude-plugins/reinstall.sh)"
    echo "  5. clu list          # verify projects"
    echo "  6. clu heartbeat     # run maintenance check"
}

# ── CHECK (dry run) ──────────────────────────────────────────
cmd_check() {
    if [[ ! -d "$CLU_HOME" ]]; then
        error "CLU_HOME not found at $CLU_HOME"
        exit 1
    fi

    echo "clu migration check"
    echo "==================="
    echo ""

    # Count files
    local total
    total=$(find "$CLU_HOME" -type f -not -path '*/__pycache__/*' | wc -l)
    info "Total files: $total"

    # Excluded files
    echo ""
    info "Will be EXCLUDED (sensitive/ephemeral):"
    for pattern in "${EXCLUDE_FILES[@]}"; do
        local matches
        matches=$(find "$CLU_HOME" -name "$pattern" -type f 2>/dev/null | wc -l)
        [[ $matches -gt 0 ]] && echo "   $pattern ($matches files)"
    done

    # Duplicate nested dirs
    echo ""
    info "Duplicate nested dirs (will be excluded):"
    for nested in "${EXCLUDE_NESTED[@]}"; do
        if [[ -d "$CLU_HOME/$nested" ]]; then
            local count
            count=$(find "$CLU_HOME/$nested" -type f | wc -l)
            echo "   $nested/ ($count files)"
        fi
    done

    # Projects
    echo ""
    info "Projects:"
    for pdir in "$CLU_HOME"/projects/*/; do
        [[ -d "$pdir" ]] || continue
        local pname
        pname=$(basename "$pdir")
        [[ "$pname" == "_workspace" ]] && continue
        local repo_path="(no repo)"
        if [[ -f "$pdir/project.yaml" ]]; then
            repo_path=$(grep -E '^repo_path:' "$pdir/project.yaml" \
                | sed 's/repo_path:\s*//' | tr -d '"' | tr -d "'" || true)
            [[ -z "$repo_path" || "$repo_path" == "null" ]] && repo_path="(no repo)"
        fi
        local memory_count
        memory_count=$(find "$pdir/memory" -type f 2>/dev/null | wc -l)
        echo "   $pname → $repo_path ($memory_count memory files)"
    done

    # Memory files with content
    echo ""
    info "Shared memory:"
    for mfile in "$CLU_HOME"/shared/memory/*.md "$CLU_HOME"/shared/agent/*.md; do
        [[ -f "$mfile" ]] || continue
        local lines
        lines=$(wc -l < "$mfile")
        local name
        name=$(basename "$mfile")
        local scope
        scope=$(basename "$(dirname "$mfile")")
        echo "   $scope/$name ($lines lines)"
    done

    # Estimate size
    echo ""
    local size
    size=$(du -sh "$CLU_HOME" --exclude='__pycache__' --exclude='.secrets.env' \
           --exclude='heartbeat.log' --exclude='heartbeat-agent.log' 2>/dev/null | cut -f1)
    info "Estimated bundle size: ~$size (compressed will be smaller)"

    # Claude Code plugins
    echo ""
    info "Claude Code plugins (~/.claude/):"
    local claude_dir="$HOME/.claude"
    if [[ -f "$claude_dir/plugins/installed_plugins.json" ]]; then
        python3 -c "
import json, os
with open('$claude_dir/plugins/installed_plugins.json') as f:
    pdata = json.load(f)
settings_file = os.path.join('$claude_dir', 'settings.json')
enabled = {}
if os.path.isfile(settings_file):
    with open(settings_file) as f:
        enabled = json.load(f).get('enabledPlugins', {})
for key in pdata.get('plugins', {}):
    parts = key.split('@', 1)
    name, marketplace = parts[0], parts[1] if len(parts) > 1 else '?'
    status = 'on' if enabled.get(key, True) else 'OFF'
    print(f'   {name:25s} from {marketplace:30s} [{status}]')
" 2>/dev/null || echo "   (could not parse)"
    else
        echo "   (none found)"
    fi
    if [[ -f "$claude_dir/plugins/known_marketplaces.json" ]]; then
        local mp_count
        mp_count=$(python3 -c "
import json
with open('$claude_dir/plugins/known_marketplaces.json') as f:
    print(len(json.load(f)))" 2>/dev/null || echo "?")
        info "Marketplaces registered: $mp_count"
    fi

    # Secrets check
    echo ""
    if [[ -f "$CLU_HOME/.secrets.env" ]]; then
        local secret_vars
        secret_vars=$(grep -cE '^[A-Z_]+=' "$CLU_HOME/.secrets.env" 2>/dev/null || echo 0)
        warn "Secrets file has $secret_vars variables (will NOT be included, template only)"
    fi
}

# ── Main ─────────────────────────────────────────────────────
case "${1:-help}" in
    pack)
        cmd_pack
        ;;
    restore)
        cmd_restore "${2:-.}"
        ;;
    check)
        cmd_check
        ;;
    help|--help|-h)
        echo "clu migration tool"
        echo ""
        echo "Usage:"
        echo "  $0 pack              Create migration bundle"
        echo "  $0 restore [dir]     Restore from bundle (run from unpacked dir)"
        echo "  $0 check             Dry-run: show what would be packed"
        echo ""
        echo "Environment:"
        echo "  CLU_HOME             clu directory (default: ~/.clu)"
        echo "  BUNDLE_DIR           Where to write bundle (default: ~/clu-migration)"
        ;;
    *)
        error "Unknown command: $1"
        echo "Run '$0 help' for usage."
        exit 1
        ;;
esac
