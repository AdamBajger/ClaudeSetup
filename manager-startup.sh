#!/usr/bin/env bash
# SessionStart hook, manager only (cwd == ~/workspaces; workers run in subdirs).
# Hook not ~/workspaces/CLAUDE.md: CLAUDE.md loads from every ancestor dir →
# would leak orchestrator role into workers.
# Injects AGENTS.md + reconcile-workers reminder. Always exit 0.
MANAGER_CWD="/home/claude/workspaces"
AGENTS="$MANAGER_CWD/AGENTS.md"
REG="$MANAGER_CWD/.workers.json"

cwd=$(jq -r '.cwd // empty')
[ "${cwd:-$PWD}" != "$MANAGER_CWD" ] && exit 0

ctx=""
[ -f "$AGENTS" ] && ctx=$(cat "$AGENTS")

names=""
[ -s "$REG" ] && names=$(jq -r 'keys[]' "$REG" | tr '\n' ' ')
if [ -n "$names" ]; then
    ctx="$ctx

## On this startup — RECONCILE workers (registered: ${names})
Entrypoint resume may have failed/stalled silently (stale helper, resume picker,
onboarding/trust/login modal, session never started) or been skipped. Assume
NO worker up. YOU own recovery — drive EACH registered worker healthy:

1. CHECK LIVE: running claude for it?
   \`list-workers\` (NOT \`claude agents --json\` — workers on own
   CLAUDE_CONFIG_DIR, invisible to manager's) AND
   \`tmux has-session -t <name> 2>/dev/null\`.
   - No tmux session, or session with no claude (dead pane)
     → \`resume-worker <name>\`. Wait ~10s cold start.
2. UNBLOCK: \`read-worker <name>\`, clear what is on screen:
   - 'Resume from summary vs full' picker → interrupted mid-task → \`2\` (full);
     clean/idle/finished → \`1\`. Send digit, sleep 1, then Enter (two send-keys).
   - Trust / 'pre-approves N tool permissions' dialog → \`_trust-guard <name>\`
     (or accept by hand). Onboarding/login modal = corrupted-config symptom:
     flag issue AND recover its config, don't just click through.
   - \`❯\` idle → interrupted mid-task? \`tell-worker <name>\` to continue; else leave.
3. VERIFY (never skip): few seconds later \`read-worker <name>\` again — must
   show \`/rc active\` (or live conversation), NOT modal or empty pane. Still
   stuck → \`resume-worker <name>\` once more; still stuck → flag issue.

Then APPS: \`appctl status\`. start-all runs at boot; confirm each up (curl its
route — not 502); \`appctl restart <name>\` for any stale one.
Never start NEW work on a worker; only revive/continue what was running."
fi

[ -z "$ctx" ] && exit 0
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
