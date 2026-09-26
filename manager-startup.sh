#!/usr/bin/env bash
# SessionStart hook, manager only (cwd == ~/workspaces; workers run in subdirs).
# Injects image's MANAGER.md + reconcile-workers reminder. Hook, not a file
# under ~/workspaces: CLAUDE.md/AGENTS.md auto-load from every ancestor dir →
# would leak orchestrator role into workers. Always exit 0.
MANAGER_CWD="/home/claude/workspaces"
REG="$MANAGER_CWD/.workers.json"

cwd=$(jq -r '.cwd // empty')
[ "${cwd:-$PWD}" != "$MANAGER_CWD" ] && exit 0

ctx=$(cat /usr/local/share/claude/MANAGER.md)

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
   show remote control active (or live conversation), NOT modal or empty pane.
   Still stuck → \`resume-worker <name>\` once more; still stuck → flag issue.

Then APPS: runit starts them at boot. \`sv status \$SVDIR/*\`; route down →
read its log, \`sv restart <name>\` (skill publish-web-app).
Never start NEW work on a worker; only revive/continue what was running."
fi

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
