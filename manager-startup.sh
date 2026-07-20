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

## On this startup — RECONCILE workers (registered: ${names})
The entrypoint TRIED to resume each worker, but resumes fail/stall silently
(stale helper, resume picker, onboarding/trust/login modal, or the session never
started). Do NOT assume any worker is up. YOU own recovery — drive EACH
registered worker to a healthy state, re-resuming the ones the entrypoint missed:

1. CHECK LIVE: is there a running claude for it?
   \`claude agents --json\` (match by cwd \`~/workspaces/<name>\`) AND
   \`tmux has-session -t <name> 2>/dev/null\`.
   - No tmux session, OR session exists but no claude running in it (dead pane)
     → \`resume-worker <name>\` to (re)create it. Wait ~10s for cold start.
2. UNBLOCK: \`read-worker <name>\` and clear whatever is on screen:
   - 'Resume from summary vs full' picker → interrupted mid-task → \`2\` (full);
     clean/idle/finished → \`1\`. Send digit, sleep 1, then Enter (two send-keys).
   - Trust dialog → accept. Onboarding/login modal → that's a corrupted-config
     symptom (issue #4): flag an issue AND recover its config, don't just click.
   - \`❯\` idle → interrupted mid-task? \`tell-worker <name>\` to continue; else leave.
3. VERIFY (do not skip): after a few seconds \`read-worker <name>\` again — it must
   show \`/rc active\` (or its live conversation), NOT a modal or empty pane. Still
   stuck → \`resume-worker <name>\` once more; if still stuck, flag an issue.

Then APPS: \`appctl status\`. start-all runs at boot, but confirm each is up (curl
its route — not 502); \`appctl restart <name>\` for any stale one.
Never start NEW work on a worker; only revive/continue what was already running."
fi

[ -z "$ctx" ] && exit 0
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null
exit 0
