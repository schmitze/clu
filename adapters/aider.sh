#!/usr/bin/env bash
# ============================================================
# Adapter: Aider
# ============================================================
# Translates clu context into Aider's configuration.
# Aider uses .aider.conf.yml and supports --read for context
# files, plus a system prompt via --system-prompt-file.
#
# Status: STUB — customize for your aider setup.
# ============================================================

adapter_launch() {
    local staging_dir="/tmp/clu/${AGENT_PROJECT_NAME}"
    mkdir -p "$staging_dir"

    # ── Write system prompt ───────────────────────────────────

    local prompt_file="$staging_dir/system-prompt.md"
    echo "$AGENT_PROMPT" > "$prompt_file"

    # ── Write aider config ────────────────────────────────────

    local aider_model
    aider_model=$(grep -A5 "aider:" "$AGENT_HOME/config.yaml" 2>/dev/null \
        | grep "model:" | head -1 \
        | sed 's/.*model:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')
    aider_model="${aider_model:-claude-sonnet-4-20250514}"

    local extra_flags
    extra_flags=$(grep -A5 "aider:" "$AGENT_HOME/config.yaml" 2>/dev/null \
        | grep "extra_flags:" | head -1 \
        | sed 's/.*extra_flags:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')

    # ── Determine launch directory ────────────────────────────

    local launch_dir="$HOME"
    if [[ -n "$AGENT_REPO_PATH" && "$AGENT_REPO_PATH" != *"no repo"* ]]; then
        if [[ -d "$AGENT_REPO_PATH" ]]; then
            launch_dir="$AGENT_REPO_PATH"
        fi
    fi

    # ── Build read-file list for context ──────────────────────

    local read_flags=""
    for mf in "$AGENT_PROJECT_DIR"/memory/*.md; do
        [[ -f "$mf" ]] || continue
        read_flags+=" --read $mf"
    done
    for mf in "$AGENT_HOME"/shared/memory/*.md; do
        [[ -f "$mf" ]] || continue
        read_flags+=" --read $mf"
    done

    # ── Launch ────────────────────────────────────────────────

    echo "🤖 Launching Aider..."
    echo "   Working directory: $launch_dir"
    echo "   Model: $aider_model"
    echo ""

    local session_start
    session_start=$(date +"%Y-%m-%d %H:%M")

    (
        cd "$launch_dir"
        aider \
            --model "$aider_model" \
            --system-prompt-file "$prompt_file" \
            $read_flags \
            $extra_flags
    )

    # ── Post-session ──────────────────────────────────────────

    local auto_summarize
    auto_summarize=$(grep "auto_summarize:" "$AGENT_HOME/config.yaml" 2>/dev/null \
        | head -1 | sed 's/.*auto_summarize:[[:space:]]*//')

    if [[ "$auto_summarize" == "true" ]]; then
        echo ""
        read -p "📝 Run post-session summarizer? (y/n) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            _adapter_quick_journal "$session_start"
        fi
    fi
}

adapter_summarize() {
    _adapter_quick_journal "$(date +"%Y-%m-%d %H:%M")"
}

_adapter_quick_journal() {
    local session_start="${1:-unknown}"
    local journal_file="$AGENT_PROJECT_DIR/memory/journal.md"

    echo "Quick session summary (what did you work on?):"
    read -r summary

    if [[ -n "$summary" ]]; then
        cat >> "$journal_file" << EOF

## Session – $session_start
**Project:** $AGENT_PROJECT_NAME
**Persona(s):** $AGENT_PERSONA
**Summary:** $summary
**Next steps:** [fill in]

EOF
        echo "✅ Appended to journal.md"
    fi
}
