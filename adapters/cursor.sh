#!/usr/bin/env bash
# ============================================================
# Adapter: Cursor
# ============================================================
# Translates clu context into Cursor's .cursorrules
# file and launches Cursor (or just prepares the rules file
# for manual launch).
#
# Status: STUB — customize for your Cursor setup.
# ============================================================

adapter_launch() {
    local launch_dir="$HOME"
    if [[ -n "$AGENT_REPO_PATH" && "$AGENT_REPO_PATH" != *"no repo"* && -d "$AGENT_REPO_PATH" ]]; then
        launch_dir="$AGENT_REPO_PATH"
    fi

    local rules_file="$launch_dir/.cursorrules"

    # Back up existing
    if [[ -f "$rules_file" ]]; then
        cp "$rules_file" "${rules_file}.clu-backup"
        echo "📋 Backed up existing .cursorrules"
    fi

    # Write assembled prompt as .cursorrules
    echo "$AGENT_PROMPT" > "$rules_file"

    # Append memory file references (Cursor can't read external
    # files natively, so we inline the memory content)
    echo "" >> "$rules_file"
    echo "---" >> "$rules_file"
    echo "## Inlined Memory (snapshot at launch time)" >> "$rules_file"
    echo "" >> "$rules_file"

    for mf in "$AGENT_PROJECT_DIR"/memory/*.md "$AGENT_HOME"/shared/memory/*.md; do
        [[ -f "$mf" ]] || continue
        echo "### $(basename "$mf")" >> "$rules_file"
        cat "$mf" >> "$rules_file"
        echo "" >> "$rules_file"
    done

    echo "✅ Wrote .cursorrules ($(wc -l < "$rules_file") lines)"
    echo "   Location: $rules_file"
    echo ""
    echo "Open Cursor in: $launch_dir"
    echo ""

    # Try to open Cursor if available
    if command -v cursor &>/dev/null; then
        read -p "Launch Cursor? (y/n) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cursor "$launch_dir"
        fi
    else
        echo "💡 Cursor CLI not found. Open the folder manually."
    fi
}

adapter_summarize() {
    echo "⚠ Cursor adapter doesn't support automated summarization."
    echo "  Use: clu summarize <project> with a different adapter."
}
