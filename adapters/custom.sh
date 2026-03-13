#!/usr/bin/env bash
# ============================================================
# Adapter: Custom (Template)
# ============================================================
# Copy this file and rename it to create a new adapter.
# Your adapter must implement two functions:
#   adapter_launch    → start the agent session
#   adapter_summarize → run post-session summarization
#
# Available environment variables (set by the launcher):
#   $AGENT_PROMPT        → the fully assembled system prompt
#   $AGENT_PROJECT_NAME  → project name
#   $AGENT_PROJECT_DIR   → path to project dir in clu
#   $AGENT_PROJECT_TYPE  → software|research|writing|strategy|mixed
#   $AGENT_REPO_PATH     → path to the project's repository
#   $AGENT_PERSONA       → active persona name
#   $AGENT_HOME          → path to clu root
# ============================================================

adapter_launch() {
    echo "🤖 Custom adapter launching for: $AGENT_PROJECT_NAME"
    echo ""
    echo "Prompt length: $(echo "$AGENT_PROMPT" | wc -c) chars"
    echo "Project type: $AGENT_PROJECT_TYPE"
    echo "Repo path: $AGENT_REPO_PATH"
    echo ""

    # ── Your launch logic here ────────────────────────────────
    # Example: write prompt to a file and pass it to your tool
    #
    # local prompt_file="/tmp/clu/${AGENT_PROJECT_NAME}/prompt.md"
    # mkdir -p "$(dirname "$prompt_file")"
    # echo "$AGENT_PROMPT" > "$prompt_file"
    #
    # my-agent-tool --system-prompt "$prompt_file" --workdir "$AGENT_REPO_PATH"

    echo "⚠ This is a template adapter. Implement adapter_launch()."
}

adapter_summarize() {
    echo "⚠ This is a template adapter. Implement adapter_summarize()."
}
