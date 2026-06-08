#!/usr/bin/env bash
# SessionStart hook (manager-only): on orchestrator startup, instruct it to tend
# the worker sessions the entrypoint auto-resumed — read each worker's pane and
# decide what to send (resolve a resume picker, or continue interrupted work),
# rather than the entrypoint blindly sending keys. Worker sessions (cwd != the
# manager cwd) stay completely silent. Best-effort; always exits 0.
MANAGER_CWD="/home/claude/workspaces"
REG="$MANAGER_CWD/.workers.json"

in=$(cat 2>/dev/null)
cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
[ "$cwd" != "$MANAGER_CWD" ] && exit 0     # not the orchestrator → say nothing
[ -s "$REG" ] || exit 0                    # no workers registered → say nothing

names=$(jq -r 'keys[]' "$REG" 2>/dev/null | tr '\n' ' ')
[ -n "$names" ] || exit 0

ctx="MANAGER STARTUP — tend the auto-resumed workers: ${names}. The entrypoint already started each worker's tmux session (resuming its saved conversation); they may still be loading, and remote-control is active even while a dialog is up. For EACH worker, decide interactively from its pane — do NOT blindly send keys:
1. Read the pane: \`read-worker <name>\` (or \`tmux capture-pane -t <name> -p\`).
2. If it shows the 'Resume from summary' picker → choose summary: \`tmux send-keys -t <name> 1\` then (after ~1s) \`tmux send-keys -t <name> Enter\`.
3. Then judge the pane: only if the worker was interrupted mid-task, \`tell-worker <name> \"continue where you left off\"\`. If it is idle, finished, or already awaiting a human at its own menu/question → LEAVE IT ALONE.
Never start new work on a worker. Give slow workers a few seconds and re-read before acting."

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null
exit 0
