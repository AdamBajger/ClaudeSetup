#!/usr/bin/env bash
# SessionStart hook (manager-only): remind the manager session to ensure every
# registered Slack monitor cron exists. Reads the registry maintained by the
# enable-slack-channel-monitoring skill (~/workspaces/.slack_monitors.json).
# Worker sessions (cwd != manager) stay completely silent so they never touch
# the manager-owned crons. Best-effort; always exits 0.
MANAGER_CWD="/home/claude/workspaces"
REGISTRY="$MANAGER_CWD/.slack_monitors.json"

in=$(cat 2>/dev/null)
cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
[ "$cwd" != "$MANAGER_CWD" ] && exit 0   # not the manager → say nothing
[ -s "$REGISTRY" ] || exit 0             # no monitors registered → say nothing

lines=$(jq -r '.[]? | "- \(.name) (cron \(.cron)) for \(.channel // "?"): if no CronList job whose prompt starts with \"[scheduled: \(.name)]\", CronCreate(cron=\"\(.cron)\", recurring=true) using the EXACT prompt in \(.prompt_file)."' "$REGISTRY" 2>/dev/null)
[ -z "$lines" ] && exit 0

ctx="MANAGER STARTUP — Slack monitors. Run CronList, then ensure each monitor below has its scheduled job (recreate if missing; this also resets the 7-day cron expiry):
$lines"

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null
exit 0
