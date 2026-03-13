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
ADAPTER=$(grep "^default_adapter:" "$AGENT_HOME/config.yaml" 2>/dev/null \
    | head -1 | sed 's/.*default_adapter:[[:space:]]*//')
ADAPTER="${ADAPTER:-claude-code}"

echo "╔══════════════════════════════════════════════╗"
echo "║     clu – Bootstrap Onboarding               ║"
echo "║     Codified Likeness Utility                ║"
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

Interview the user conversationally to fill in their profile AND
configure their preferred agent personality. Don't make it feel like
a form — have a natural conversation. Cover these areas:

### Part 1: User Profile
1. **Who they are**: name, role, what they do
2. **Work context**: current org/team, domain, daily work
3. **Current priorities**: what they're focused on right now
4. **Communication style**: how they like to interact with AI agents
   (terse? detailed? which language(s)?)
5. **Technical environment**: OS, editor, languages, tools
6. **Working patterns**: how they structure their day/sessions
7. **Strong opinions**: preferences about code, research, writing,
   or whatever their domain is
8. **Default working directory**: Where do your projects live?
   This limits the agent's scope — instead of starting from the
   home directory (where the agent can reach everything), the user
   can specify a subdirectory like `~/repos` or `~/projects`.
   - Ask like: "Where do your projects live? e.g. ~/repos, ~/code.
     I'll use that as my starting point so I'm not poking around
     your entire home directory."
   - If they say home is fine, set it to their home dir explicitly.
   - Write the chosen path to the `default_workdir` field in: CONFIG_PATH

### Part 2: Agent Personality (Big Five / OCEAN)
After learning about the user, configure the default persona's
personality traits. Explain each dimension briefly and ask the user
where they'd like their agent on the scale. Use simple, relatable
language — not academic jargon.

The five dimensions (each scored 1–10):

**O – Openness (Creativity)**
- Low (1-3): Sticks to proven approaches, conventional, pragmatic
- Mid (4-6): Balanced — uses what works, open to alternatives
- High (7-10): Loves exploring unconventional ideas, creative, experimental
- Ask like: "Should I stick to safe, proven solutions — or do you want me
  to suggest creative, unconventional approaches?"

**C – Conscientiousness (Thoroughness)**
- Low (1-3): Fast and loose, ships quick, minimal process
- Mid (4-6): Balanced — thorough where it matters, efficient elsewhere
- High (7-10): Extremely meticulous, checks everything, very structured
- Ask like: "Should I be quick and pragmatic, or extremely thorough and
  structured — even if it takes longer?"

**E – Extraversion (Communication)**
- Low (1-3): Quiet worker, shows results not process, minimal narration
- Mid (4-6): Communicates key points, explains when useful
- High (7-10): Thinks out loud, proactive, shares reasoning constantly
- Ask like: "Do you want me to just show results, or explain my
  thinking and reasoning as I go?"

**A – Agreeableness (Directness)**
- Low (1-3): Blunt, challenges ideas directly, pushes back hard
- Mid (4-6): Honest but diplomatic, disagrees when it matters
- High (7-10): Very cooperative, supportive, avoids confrontation
- Ask like: "Should I be direct and challenge your ideas when I
  disagree — or be more cooperative and supportive?"

**N – Neuroticism (Caution)**
- Low (1-3): Fearless, moves fast, doesn't dwell on what could go wrong
- Mid (4-6): Flags real risks, ignores unlikely ones
- High (7-10): Very cautious, flags everything that could go wrong
- Ask like: "Should I move fast and bold — or be very careful and
  flag every potential risk?"

Based on their answers, determine scores for each dimension and create
the default persona file. You don't have to ask each dimension separately —
infer from the conversation where possible. If the user is unsure, suggest
scores based on what you've learned about them.

### Part 3: Additional Preferences
After personality, briefly cover:

1. **Language**: What language(s) should the agent respond in?
   (e.g., German, English, mixed — for conversation, code comments, commits)
2. **Auto-summarize**: Should the agent write a session summary after
   each session? (currently: auto_summarize in config.yaml)
3. **Autonomy level**: How much should the agent do on its own vs. ask
   first? (e.g., "just do it" vs. "always confirm before acting")
4. **Reference systems**: Where do you track work? (e.g., Linear, Jira,
   GitHub Issues, specific dashboards, Slack channels)
5. **Git workflow**: Trunk-based? Feature branches? Conventional commits?

## Rules

- Keep it conversational and friendly. Don't list all questions at once.
- Ask 2-3 things at a time, max.
- After the user profile part, transition naturally to personality:
  "Now let's configure how I should behave as your agent..."
- Then briefly cover the additional preferences (Part 3).
- After gathering enough info:
  1. Write the user profile to: PREFERENCES_PATH
     Include language, autonomy, references, and git workflow preferences.
  2. **Overwrite the default persona** at: PERSONA_PATH
     This becomes the main agent personality loaded in every session.
     Format:
     ```
     # Persona: Default

     ## Traits

     \`\`\`yaml
     openness:          [score]
     conscientiousness: [score]
     extraversion:      [score]
     agreeableness:     [score]
     neuroticism:       [score]
     \`\`\`

     ## Role
     [User's name]'s personal agent — configured during onboarding.
     This is the default persona loaded for all projects unless
     overridden in project.yaml.

     ## Behavioral Notes
     [Key behavioral traits based on the conversation]

     ## Language
     [Preferred response language(s)]

     ## Autonomy
     [How much the agent should do autonomously vs. ask first]
     ```
  3. If they mentioned reference systems (ticketing, CI, dashboards),
     write them to: REFERENCES_PATH
  4. Ask if they want to adjust global constraints: CONSTRAINTS_PATH
  5. Write the bootstrap marker to: MARKER_PATH
- Show a summary of the trait scores with a brief behavioral profile
  before confirming.
- Tell the user they can:
  - Re-run with `clu bootstrap --force`
  - Edit files manually
  - Adjust traits mid-session by saying "be more direct", "be more cautious", etc.

## File paths

- User profile: PREFERENCES_PATH
- Default persona (overwrite!): PERSONA_PATH
- References: REFERENCES_PATH
- Global constraints: CONSTRAINTS_PATH
- Global config (for default_workdir): CONFIG_PATH
- Bootstrap marker: MARKER_PATH
BPROMPT
)

# Replace placeholders
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//PREFERENCES_PATH/$PREFS_FILE}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//CONSTRAINTS_PATH/$AGENT_HOME/shared/constraints.md}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//PERSONA_PATH/$AGENT_HOME/personas/default.md}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//REFERENCES_PATH/$AGENT_HOME/shared/memory/references.md}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//CONFIG_PATH/$AGENT_HOME/config.yaml}"
BOOTSTRAP_PROMPT="${BOOTSTRAP_PROMPT//MARKER_PATH/$BOOTSTRAP_MARKER}"

# Write to temp file
STAGING_DIR="/tmp/clu/bootstrap"
mkdir -p "$STAGING_DIR"
echo "$BOOTSTRAP_PROMPT" > "$STAGING_DIR/bootstrap-prompt.md"

# ── Check & install plugins from config.yaml ────────────────

_check_plugins() {
    local config="$AGENT_HOME/config.yaml"
    [[ -f "$config" ]] || return 0

    # Extract plugin list from config.yaml
    local in_plugins=false
    local plugins=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^plugins: ]]; then
            in_plugins=true
            continue
        fi
        if $in_plugins; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
                plugins+=("${BASH_REMATCH[1]}")
            elif [[ "$line" =~ ^[^[:space:]] ]]; then
                break  # next top-level key
            fi
        fi
    done < "$config"

    [[ ${#plugins[@]} -eq 0 ]] && return 0

    # Check which are missing (only for claude-code adapter)
    if ! command -v claude &>/dev/null; then
        echo "⬜ Claude Code not found — skipping plugin check."
        return 0
    fi

    local installed
    installed=$(claude plugins list 2>/dev/null || true)
    local missing=()

    for p in "${plugins[@]}"; do
        # Strip comments and whitespace
        p=$(echo "$p" | sed 's/#.*//' | xargs)
        [[ -z "$p" ]] && continue
        if ! echo "$installed" | grep -qF "$p"; then
            missing+=("$p")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "✅ All configured plugins are installed."
        return 0
    fi

    echo "📦 Missing plugins (from config.yaml):"
    for p in "${missing[@]}"; do
        echo "   - $p"
    done
    echo ""
    read -p "Install missing plugins now? (y/n) " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for p in "${missing[@]}"; do
            echo "   Installing $p..."
            claude plugins install "$p" 2>/dev/null || echo "   ⚠ Failed to install $p"
        done
        echo ""
    else
        echo "   Skipped. Install later with:"
        for p in "${missing[@]}"; do
            echo "     claude plugins install $p"
        done
        echo ""
    fi
}

_check_plugins

# Launch via adapter
echo "Starting onboarding interview..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$ADAPTER" == "claude-code" ]] && ! command -v claude &>/dev/null; then
    echo "❌ claude CLI not found. Install it first: https://docs.anthropic.com/claude-code"
    exit 1
fi

case "$ADAPTER" in
    claude-code)
        # Write as CLAUDE.md in home dir, with guaranteed restore
        BACKUP=""
        _restore_claude_md() {
            if [[ -n "${BACKUP:-}" && -f "$BACKUP" ]]; then
                mv "$BACKUP" "$HOME/CLAUDE.md"
            elif [[ -z "${BACKUP:-}" ]]; then
                rm -f "$HOME/CLAUDE.md"
            fi
        }
        trap _restore_claude_md EXIT INT TERM
        if [[ -f "$HOME/CLAUDE.md" ]]; then
            BACKUP="$HOME/CLAUDE.md.clu-bootstrap-backup"
            cp "$HOME/CLAUDE.md" "$BACKUP"
        fi
        cp "$STAGING_DIR/bootstrap-prompt.md" "$HOME/CLAUDE.md"
        (cd "$HOME" && claude --dangerously-skip-permissions) || true
        _restore_claude_md
        trap - EXIT INT TERM
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
