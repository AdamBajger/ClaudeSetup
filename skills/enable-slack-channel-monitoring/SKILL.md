---
name: enable-slack-channel-monitoring
description: >
  Register an autonomous scheduled monitor for a Slack channel, tied to project
  working directory. Renders the per-channel operating instructions + cron prompt
  from templates, records the monitor in a registry, and creates the recurring
  in-session cron job. Assumes the Slack connector (hosted MCP) is already enabled
  on the account. Use when the user says "monitor Slack channel X for project Y",
  "watch #channel", "enable slack monitoring", or invokes /enable-slack-channel-monitoring.
---

Set up a scheduled, self-identifying Slack monitor for ONE channel, bound to ONE
project directory, managed by a manager agent session. The monitor wakes on a cron, spawns an isolated subagent that reads Slack channel via the Slack MCP and replies only when clearly warranted. A SessionHook is installed to remind the manager to recreate the cron if it goes missing (e.g. after 7 days, or if the pod restarts). The monitor's prompt and operating instructions are rendered from templates, which the user can customize for each channel/project.

This skill only **registers** a monitor — it does not run it. 

## Preconditions (check first, stop if unmet)

1. **Slack MCP connected.** The `mcp__claude_ai_Slack__*` tools must exist in this
   session (try ToolSearch for `slack_read_channel`). If absent: tell the user to
   add the Slack connector on claude.ai and **restart the session** — MCP tools
   only load at session start. Do not continue without it.
2. **You are the manager session** (cwd = `/home/claude/workspaces`). The cron and
   registry are manager-owned. If you're a worker, hand this to the manager.
3. `jq` available; the project dir exists under `~/workspaces`.
4. Templates present at this skill's dir
   (`~/.claude/skills/enable-slack-channel-monitoring/`): `SLACK_CRON.md.tmpl`,
   `slack_cron.prompt.tmpl`. If missing, copy from `/usr/local/lib/slack-monitor/`.

## Inputs (gather from the user; ask for any missing)

- `CHANNEL_NAME` — e.g. `#xai-methods-concepts` (display only).
- `CHANNEL_ID`   — Slack channel id, e.g. `C0663SX30QY` (find via
  `mcp__claude_ai_Slack__slack_search_channels` if unknown).
- `PROJECT_DIR`  — absolute path of the related project, e.g.
  `/home/claude/workspaces/zennit-crp`.
- `CRON`         — optional, default `7 6-20 * * *` (≈ hourly 08:07–22:07 Prague).
- `MONITOR_NAME` — optional, default derived from the channel
  (`slack-<slug>-monitor`).

## Step 1 — render files + update the registry

Fill the variables, then run this block (uses bash `${//}` substitution — safe
with slashes/`#`):

```bash
set -euo pipefail
CHANNEL_NAME='#REPLACE'          # e.g. #xai-methods-concepts
CHANNEL_ID='REPLACE'             # e.g. C0663SX30QY
PROJECT_DIR='/home/claude/workspaces/REPLACE'
CRON='7 6-20 * * *'
slug=$(printf '%s' "$CHANNEL_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/^#//; s/[^a-z0-9]\+/-/g; s/^-//; s/-$//')
MONITOR_NAME="slack-${slug}-monitor"

SK="$HOME/.claude/skills/enable-slack-channel-monitoring"
WS="$HOME/workspaces"
PROMPT_FILE="$WS/${MONITOR_NAME}.slack_cron.prompt"
NOTES_FILE="$PROJECT_DIR/research/slack_monitor_notes.md"
TASKS_FILE="$PROJECT_DIR/research/slack_tasks.md"
mkdir -p "$PROJECT_DIR/research" "$WS/bin"

render() { # substitute {{KEY}} placeholders
  local t; t=$(cat "$1")
  t=${t//'{{MONITOR_NAME}}'/$MONITOR_NAME}
  t=${t//'{{CHANNEL_NAME}}'/$CHANNEL_NAME}
  t=${t//'{{CHANNEL_ID}}'/$CHANNEL_ID}
  t=${t//'{{PROJECT_DIR}}'/$PROJECT_DIR}
  t=${t//'{{CRON}}'/$CRON}
  t=${t//'{{NOTES_FILE}}'/$NOTES_FILE}
  t=${t//'{{TASKS_FILE}}'/$TASKS_FILE}
  printf '%s\n' "$t"
}

render "$SK/SLACK_CRON.md.tmpl"      > "$PROJECT_DIR/SLACK_CRON.md"
render "$SK/slack_cron.prompt.tmpl"  > "$PROMPT_FILE"

# Ensure tooling exists (seeded by the deployment; copy if missing).
[ -x "$WS/bin/slack-lock" ] || cp /usr/local/lib/slack-monitor/slack-lock "$WS/bin/slack-lock"
[ -x "$WS/bin/_slack-cron-reminder.sh" ] || cp /usr/local/lib/slack-monitor/slack-cron-reminder.sh "$WS/bin/_slack-cron-reminder.sh"
chmod +x "$WS/bin/slack-lock" "$WS/bin/_slack-cron-reminder.sh"

# Upsert the monitor into the registry the SessionStart reminder reads.
REG="$WS/.slack_monitors.json"
[ -s "$REG" ] || echo '[]' > "$REG"
tmp=$(mktemp)
jq --arg n "$MONITOR_NAME" --arg c "$CRON" --arg p "$PROMPT_FILE" --arg ch "$CHANNEL_NAME" \
   '(map(select(.name != $n))) + [{name:$n, cron:$c, prompt_file:$p, channel:$ch}]' \
   "$REG" > "$tmp" && mv "$tmp" "$REG"

echo "rendered SLACK_CRON.md + $PROMPT_FILE; registered $MONITOR_NAME ($CRON)"
echo "PROMPT_FILE=$PROMPT_FILE"
```

## Step 2 — create the recurring cron

Read the rendered prompt file and create the job (it must be the EXACT text):

- Read `"$PROMPT_FILE"`.
- Call **CronCreate** with `cron=<CRON>`, `recurring=true`, and `prompt=<file contents>`.
- Verify with **CronList** that a job whose prompt starts with
  `[scheduled: <MONITOR_NAME>]` now exists.

## Step 3 — confirm

Report back: monitor name, channel, schedule, the project dir, and that the cron
is registered. Remind the user they can tailor `"$PROJECT_DIR/SLACK_CRON.md"`
(reply triggers, code tree, datasets) to the project.

## Notes

- Multiple channels: run this skill once per channel — each gets its own monitor
  name, prompt file, lock (`slack-lock <action> <MONITOR_NAME>`), and registry entry.
- Across pod restarts: the manager-only `_slack-cron-reminder.sh` SessionStart
  hook re-reads the registry and reminds the manager to recreate any missing cron
  (crons expire after 7 days).
- To stop a monitor: delete its CronList job, remove its registry entry, and
  delete `"$PROMPT_FILE"`.
