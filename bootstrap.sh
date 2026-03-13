#!/usr/bin/env bash
# ============================================================
# clu – Bootstrap Onboarding
# ============================================================
# Agent-guided first-run interview. The agent asks you about
# yourself and your working style, then populates:
#   - shared/memory/preferences.md (your user profile)
#   - shared/constraints.md (your global rules)
#   - initial persona customization
#
# Usage:
#   clu bootstrap              → run the onboarding
#   clu bootstrap --force      → re-run even if already done
# ============================================================

set -euo pipefail

AGENT_HOME="${CLU_HOME:-$HOME/.clu}"
PREFS_FILE="$AGENT_HOME/shared/memory/preferences.md"
BOOTSTRAP_MARKER="$AGENT_HOME/.bootstrapped"

# Check if already bootstrapped
if [[ -f "$BOOTSTRAP_MARKER" && "${1:-}" != "--force" ]]; then
    echo "✅ Already bootstrapped. Run 'clu bootstrap --force' to redo."
    exit 0
fi

# Detect adapter
source "$AGENT_HOME/config.yaml" 2>/dev/null || true
ADAPTER=$(grep "^default_adapter:" "$AGENT_HOME/config.yaml" 2>/dev/null \
    | head -1 | sed 's/.*default_adapter:[[:space:]]*//')
ADAPTER="${ADAPTER:-claude-code}"

echo "╔══════════════════════════════════════════════╗"
echo "║     clu – Bootstrap Onboarding               ║"
echo "║     Codified Likeness Utility                 ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "This will start an agent session that interviews you"
echo "and populates your user profile and preferences."
echo ""

# Build a special bootstrap prompt
BOOTSTRAP_PROMPT=$(cat << 'BPROMPT'
# clu Bootstrap – Onboarding Interview

You are running a one-time onboarding interview for clu, a personal
agent workstation. Your job is to learn about the user and populate
their profile.

## Your task

Interview the user conversationally to fill in their profile. Don't
make it feel like a form — have a natural conversation. Cover these
areas in whatever order feels natural:

1. **Who they are**: name, role, what they do
2. **Work context**: current org/team, domain, daily work
3. **Current priorities**: what they're focused on right now
4. **Communication style**: how they like to interact with AI agents
   (terse? detailed? which language(s)?)
5. **Technical environment**: OS, editor, languages, tools
6. **Working patterns**: how they structure their day/sessions
7. **Strong opinions**: preferences about code, research, writing,
   or whatever their domain is

## Rules

- Keep it conversational and friendly. Don't list all questions at once.
- Ask 2-3 things at a time, max.
- After gathering enough info, generate the complete preferences.md
  file and write it to: PREFERENCES_PATH
- Also ask if they want to adjust the default global constraints
  and update: CONSTRAINTS_PATH
- When done, write a one-line marker to: MARKER_PATH
- Tell the user they can always re-run with `clu bootstrap --force`
  or edit the files manually.

## File paths

- User profile: PREFERENCES_PATH
- Global constraints: CONSTRAINTS_PATH
- Bootstrap marker: MARKER_PATH
BPROMPT
)

# Replace placeholders
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//PREFERENCES_PATH/$PREFS_FILE}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//CONSTRAINTS_PATH/$AGENT_HOME/shared/constraints.md}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//MARKER_PATH/$BOOTSTRAP_MARKER}"

# Write to temp file
STAGING_DIR="/tmp/clu/bootstrap"
mkdir -p "$STAGING_DIR"
echo "$BOOTSTRAP_PROMPT" > "$STAGING_DIR/bootstrap-prompt.md"

# Launch via adapter
echo "Starting onboarding interview..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

case "$ADAPTER" in
    claude-code)
        # Write as CLAUDE.md in home dir
        BACKUP=""
        if [[ -f "$HOME/CLAUDE.md" ]]; then
            BACKUP="$HOME/CLAUDE.md.clu-bootstrap-backup"
            cp "$HOME/CLAUDE.md" "$BACKUP"
        fi
        cp "$STAGING_DIR/bootstrap-prompt.md" "$HOME/CLAUDE.md"
        (cd "$HOME" && claude)
        # Restore
        if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
            mv "$BACKUP" "$HOME/CLAUDE.md"
        else
            rm -f "$HOME/CLAUDE.md"
        fi
        ;;
    aider)
        (cd "$HOME" && aider --system-prompt-file "$STAGING_DIR/bootstrap-prompt.md")
        ;;
    *)
        echo "Adapter '$ADAPTER' doesn't support interactive bootstrap."
        echo "Run the onboarding manually by editing:"
        echo "  $PREFS_FILE"
        exit 1
        ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -f "$BOOTSTRAP_MARKER" ]]; then
    echo ""
    echo "✅ Bootstrap complete! Your profile is saved."
    echo "   Edit anytime: $PREFS_FILE"
    echo ""
else
    echo ""
    echo "⚠ Bootstrap may not have completed."
    echo "  You can fill in your profile manually:"
    echo "  \$EDITOR $PREFS_FILE"
    echo ""
    echo "  Or re-run: clu bootstrap"
fi
