#!/usr/bin/env bash
# SessionStart hook — ORCHESTRATOR (manager) ONLY. Guarded on cwd == manager
# workspace root, so workers (run in ~/workspaces/<proj> subdirs) never see it.
# Used instead of ~/workspaces/CLAUDE.md because claude loads CLAUDE.md from every
# ANCESTOR dir → a root CLAUDE.md would leak the orchestrator role into workers.
# For the manager: (1) inject AGENTS.md as context; (2) remind it to tend the
# workers the entrypoint auto-resumed. Best-effort; always exits 0.
MANAGER_CWD="/home/claude/workspaces"
AGENTS="$MANAGER_CWD/AGENTS.md"
REG="$MANAGER_CWD/.workers.json"

in=$(cat 2>/dev/null)
cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
[ "$cwd" != "$MANAGER_CWD" ] && exit 0     # not the orchestrator → say nothing

ctx=""
[ -f "$AGENTS" ] && ctx=$(cat "$AGENTS")

# Append a tend-workers reminder iff the registry lists workers.
names=""
[ -s "$REG" ] && names=$(jq -r 'keys[]' "$REG" 2>/dev/null | tr '\n' ' ')
if [ -n "$names" ]; then
    ctx="$ctx

## On this startup — tend the auto-resumed workers: ${names}
Entrypoint resumed each worker's tmux session (worker work IS stateful);
remote-control is live even with a dialog up. For EACH worker, decide from its
pane (\`read-worker <name>\` / \`tmux capture-pane -t <name> -p\`) — do NOT blindly
send keys:
- Workers are ALWAYS continued. On a 'Resume from summary' picker, choose by
  whether work was interrupted mid-task: interrupted → \`2\` (full as-is, keep
  context to finish precisely); clean/idle/finished → \`1\` (summary, lighter).
  Send: \`tmux send-keys -t <name> <1|2>\`, sleep 1, \`tmux send-keys -t <name> Enter\`.
- At the \`❯\` prompt: only if interrupted mid-task, \`tell-worker <name>\` to
  continue where it left off; else leave idle.
Never start new work on a worker. Give slow workers a few seconds, then re-read."
fi

[ -z "$ctx" ] && exit 0
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null
exit 0
