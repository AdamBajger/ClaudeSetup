#!/usr/bin/env bash
# SessionStart hook, manager-only: remind manager to re-create every registered
# Slack monitor cron (registry kept by enable-slack-channel-monitoring skill).
# Worker sessions (cwd != manager) stay silent — crons are manager-owned.
# Hook → never break session: warn on stderr, always exit 0.
MANAGER_CWD="/home/claude/workspaces"
REGISTRY="$MANAGER_CWD/.slack_monitors.json"

warn() { echo "slack-cron-reminder: $*" >&2; exit 0; }

in=$(cat)
cwd=$(printf '%s' "$in" | jq -r '.cwd // empty') || warn "bad hook input JSON"
[ -z "$cwd" ] && cwd="$PWD"
[ "$cwd" != "$MANAGER_CWD" ] && exit 0
[ -s "$REGISTRY" ] || exit 0

lines=$(jq -r '.[]? | "- \(.name) (cron \(.cron)) for \(.channel // "?"): if no CronList job whose prompt starts with \"[scheduled: \(.name)]\", CronCreate(cron=\"\(.cron)\", recurring=true) using the EXACT prompt in \(.prompt_file)."' "$REGISTRY") \
  || warn "cannot parse $REGISTRY"
[ -z "$lines" ] && exit 0

ctx="MANAGER STARTUP — Slack monitors. Run CronList, then ensure each monitor below has its scheduled job (recreate if missing; this also resets the 7-day cron expiry):
$lines"

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
