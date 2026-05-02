#!/usr/bin/env bash
# ============================================================
# clu – Installer
# ============================================================
# Installs clu to ~/.clu and sets up the
# `clu` command in your shell.
#
# Usage:
#   curl -sL <url>/install.sh | bash
#   — or —
#   git clone <repo> && cd clu && ./install.sh
# ============================================================

set -euo pipefail

INSTALL_DIR="${CLU_HOME:-$HOME/.clu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════╗"
echo "║      clu – Codified Likeness Utility        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Check if already installed ────────────────────────────────

if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/config.yaml" ]]; then
    echo "⚠ clu already exists at $INSTALL_DIR"
    read -p "  Overwrite config files? Existing projects will be preserved. (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    UPGRADE=true
else
    UPGRADE=false
fi

# ── Copy files ────────────────────────────────────────────────

echo "📦 Installing to $INSTALL_DIR ..."

_copy_framework_files() {
    local src="$1" dst="$2"
    cp "$src/launcher" "$dst/launcher"
    cp "$src/bootstrap.sh" "$dst/bootstrap.sh"
    cp "$src/heartbeat.sh" "$dst/heartbeat.sh"
    cp "$src/create-persona.sh" "$dst/create-persona.sh"
    cp "$src/dashboard.py" "$dst/dashboard.py"
    cp -rT "$src/adapters" "$dst/adapters"
    cp -rT "$src/personas" "$dst/personas"
    cp -rT "$src/templates" "$dst/templates"
    cp -rT "$src/docs" "$dst/docs"
    if [[ -d "$src/tools" ]]; then
        cp -rT "$src/tools" "$dst/tools"
    fi
    cp "$src/session-recovery.py" "$dst/session-recovery.py"
    cp "$src/session-digest.py" "$dst/session-digest.py"
    cp "$src/migrate.sh" "$dst/migrate.sh"
    cp "$src/clu-dashboard.service" "$dst/clu-dashboard.service"
    cp "$src/clu-heartbeat.service" "$dst/clu-heartbeat.service"
    cp "$src/clu-heartbeat.timer" "$dst/clu-heartbeat.timer"
    cp "$src/.gitignore" "$dst/.gitignore"
    mkdir -p "$dst/shared"
    cp "$src/shared/core-prompt.md" "$dst/shared/core-prompt.md"
    cp "$src/shared/constraints.md" "$dst/shared/constraints.md"
}

if [[ "$UPGRADE" == "true" ]]; then
    # Preserve projects/, shared/memory/, and config.yaml on upgrade
    echo "  ℹ Preserving config.yaml, projects/, shared/memory/"
    _copy_framework_files "$SCRIPT_DIR" "$INSTALL_DIR"
else
    mkdir -p "$INSTALL_DIR"
    _copy_framework_files "$SCRIPT_DIR" "$INSTALL_DIR"
    # Only copy config.yaml and memory scaffolds on fresh install
    cp "$SCRIPT_DIR/config.yaml" "$INSTALL_DIR/config.yaml"
    cp -r "$SCRIPT_DIR/shared/memory/" "$INSTALL_DIR/shared/memory/"
    cp -r "$SCRIPT_DIR/projects/" "$INSTALL_DIR/projects/"
fi

chmod +x "$INSTALL_DIR/launcher" "$INSTALL_DIR/bootstrap.sh" "$INSTALL_DIR/heartbeat.sh" "$INSTALL_DIR/session-recovery.py" "$INSTALL_DIR/session-digest.py" "$INSTALL_DIR/migrate.sh"

# ── Create the `clu` symlink/alias ─────────────────────────

echo "🔗 Setting up 'clu' command..."

# Determine shell
SHELL_NAME=$(basename "$SHELL")
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.bashrc" ;;
esac

ALIAS_LINE="alias clu='$INSTALL_DIR/launcher'"
EXPORT_LINE="export CLU_HOME='$INSTALL_DIR'"

# Check if already in RC file
add_to_rc() {
    local line="$1"
    local file="$2"
    if ! grep -qF "$line" "$file" 2>/dev/null; then
        echo "" >> "$file"
        echo "# clu" >> "$file"
        echo "$line" >> "$file"
        echo "  Added to $file: $line"
    else
        echo "  Already in $file: $line"
    fi
}

if [[ "$SHELL_NAME" == "fish" ]]; then
    ALIAS_LINE="alias clu '$INSTALL_DIR/launcher'"
    EXPORT_LINE="set -gx CLU_HOME '$INSTALL_DIR'"
fi

add_to_rc "$EXPORT_LINE" "$RC_FILE"
add_to_rc "$ALIAS_LINE" "$RC_FILE"

# ── Verify dependencies ──────────────────────────────────────

echo ""
echo "🔍 Checking optional dependencies..."

check_dep() {
    local cmd="$1" purpose="$2" required="$3"
    if command -v "$cmd" &>/dev/null; then
        echo "  ✅ $cmd ($(command -v "$cmd"))"
    elif [[ "$required" == "true" ]]; then
        echo "  ❌ $cmd — REQUIRED: $purpose"
    else
        echo "  ⬜ $cmd — optional: $purpose"
    fi
}

check_dep "claude" "Claude Code CLI (default adapter)" "false"
check_dep "aider" "Aider CLI (alternative adapter)" "false"
check_dep "fzf" "Fuzzy project picker" "false"
check_dep "gum" "Pretty project picker (Charm)" "false"

# ── Heartbeat systemd timer ──────────────────────────────────

echo ""
echo "🫀 Daily heartbeat"
echo "   The heartbeat runs maintenance between sessions:"
echo "   memory staleness checks, daily log hygiene, memory"
echo "   compaction, and a morning brief with open threads."
echo "   Uses systemd timer with Persistent=true (catches up"
echo "   if the machine was off at the scheduled time)."
echo ""

SETUP_HEARTBEAT=false
if command -v systemctl &>/dev/null; then
    read -p "   Set up daily heartbeat at 4am? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "$HOME/.config/systemd/user"
        cp "$INSTALL_DIR/clu-heartbeat.service" "$HOME/.config/systemd/user/clu-heartbeat.service"
        cp "$INSTALL_DIR/clu-heartbeat.timer" "$HOME/.config/systemd/user/clu-heartbeat.timer"
        systemctl --user daemon-reload
        systemctl --user enable --now clu-heartbeat.timer
        echo "   ✅ Heartbeat scheduled daily at 4am (persistent)."
        echo "   Manage with:"
        echo "     systemctl --user status clu-heartbeat.timer"
        echo "     systemctl --user list-timers"
        echo "     journalctl --user -u clu-heartbeat -f"
        SETUP_HEARTBEAT=true

        # Remove old cron entry if present
        if crontab -l 2>/dev/null | grep -qF "heartbeat.sh"; then
            crontab -l 2>/dev/null | grep -v "heartbeat.sh" | crontab -
            echo "   🔄 Removed old cron-based heartbeat entry."
        fi
    else
        echo "   Skipped. Set up later with:"
        echo "     cp $INSTALL_DIR/clu-heartbeat.{service,timer} ~/.config/systemd/user/"
        echo "     systemctl --user daemon-reload && systemctl --user enable --now clu-heartbeat.timer"
    fi
else
    echo "   ⬜ systemd not available. Use cron instead:"
    echo "   0 4 * * * $INSTALL_DIR/heartbeat.sh >> $INSTALL_DIR/heartbeat.log 2>&1"
fi

# ── Dashboard systemd service ────────────────────────────────

echo ""
echo "📊 Dashboard service"
echo "   The dashboard provides a local web UI for monitoring"
echo "   projects, security audits, and heartbeat status."
echo ""

SETUP_DASHBOARD=false
if command -v systemctl &>/dev/null && [[ -d "$HOME/.config/systemd/user" || true ]]; then
    read -p "   Set up dashboard as a persistent service? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "$HOME/.config/systemd/user"
        cp "$INSTALL_DIR/clu-dashboard.service" "$HOME/.config/systemd/user/clu-dashboard.service"
        systemctl --user daemon-reload
        systemctl --user enable clu-dashboard.service
        systemctl --user start clu-dashboard.service
        echo "   ✅ Dashboard running at http://localhost:3141"
        echo "   Manage with:"
        echo "     systemctl --user status clu-dashboard"
        echo "     systemctl --user restart clu-dashboard"
        echo "     journalctl --user -u clu-dashboard -f"
        SETUP_DASHBOARD=true
    else
        echo "   Skipped. Start manually with: clu dashboard"
    fi
else
    echo "   ⬜ systemd not available. Start manually with: clu dashboard"
fi

# ── Done ──────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║              ✅ Installed!                   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Quick start:"
echo ""
echo "  1. Reload your shell:"
echo "     source $RC_FILE"
echo ""
echo "  2. Create your first project:"
echo "     clu new my-project"
echo ""
echo "  3. Edit the project config:"
echo "     \$EDITOR $INSTALL_DIR/projects/my-project/project.yaml"
echo ""
echo "  4. Run the onboarding interview:"
echo "     clu bootstrap"
echo ""
echo "  5. (or customize manually):"
echo "     \$EDITOR $INSTALL_DIR/shared/memory/preferences.md"
echo ""
echo "  6. Launch:"
echo "     clu my-project"
echo ""
echo "Pro tips:"
echo "  • 'clu list' to see all projects"
echo "  • 'clu' with no args for interactive picker"
echo "  • 'clu bootstrap' for agent-guided profile setup"
echo "  • 'clu heartbeat' for manual maintenance check"
echo "  • 'clu --persona researcher my-project' to override persona"
echo "  • 'clu check my-project' to check memory staleness"
echo "  • Push $INSTALL_DIR to a git repo for backup/portability"
echo ""
