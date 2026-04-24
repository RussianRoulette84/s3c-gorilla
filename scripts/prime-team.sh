#!/usr/bin/env bash
# scripts/prime-team.sh — push priming prompts into the 4 tmux-team panes.
#
# Usage:
#   1. Run `cld --tt` and wait for all 4 Claude panes to reach their prompt.
#   2. Run `./scripts/prime-team.sh` (can be from inside any pane).
#   3. Each pane receives its role prompt from .claude/PARALLEL_AGENTS.md
#      and auto-submits.
#
# Single source of truth: the blockquoted prompts under **@lead:** /
# **@agent-1:** / ... in .claude/PARALLEL_AGENTS.md. Edit there, re-run.

set -u

SESS="${TMUX_TEAM_SESSION:-team}"
DOC="$(cd "$(dirname "$0")/.." && pwd)/.claude/PARALLEL_AGENTS.md"

if ! tmux has-session -t "$SESS" 2>/dev/null; then
    echo "error: no tmux session named '$SESS' — run 'cld --tt' first" >&2
    exit 1
fi

if [[ ! -f "$DOC" ]]; then
    echo "error: $DOC missing — can't extract prompts" >&2
    exit 1
fi

# Extract the blockquoted paragraph under `**<role>:**` from the doc,
# joined into a single line with spaces.
extract() {
    local role="**$1:**"
    awk -v role="$role" '
        $0 == role      { in_block = 1; next }
        in_block && /^> / {
            sub(/^> /, "")
            if (out == "") out = $0
            else out = out " " $0
            next
        }
        in_block && out != "" && !/^> / { print out; exit }
    ' "$DOC"
}

# Send a prompt to the pane whose title matches $1.
send() {
    local title="$1"
    local text
    text="$(extract "$title")"
    if [[ -z "$text" ]]; then
        echo "warn: no prompt found for $title in PARALLEL_AGENTS.md" >&2
        return 1
    fi
    local pane
    pane=$(tmux list-panes -t "$SESS" -F '#{pane_id} #{pane_title}' \
        | awk -v t="$title" '$2==t {print $1; exit}')
    if [[ -z "$pane" ]]; then
        echo "warn: pane with title '$title' not found" >&2
        return 1
    fi
    tmux send-keys -t "$pane" -l "$text"
    tmux send-keys -t "$pane" Enter
    echo "primed: $title  ($pane)"
}

send '@lead'
send '@agent-1'
send '@agent-2'
send '@agent-3-haiku'

echo
echo "all panes primed. switch to @lead (Ctrl-b + ←) to drive."
