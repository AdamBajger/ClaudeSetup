---
name: enable-slack-channel-monitoring
description: >
  Register an autonomous scheduled monitor for ONE Slack channel, tied to a project
  dir. Renders per-channel operating instructions + cron prompt from templates, records
  it in a registry, creates the recurring in-session cron. Assumes the Slack connector
  (hosted MCP) is already enabled on the account. Use when the user says "monitor Slack
  channel X for project Y", "watch #channel", "enable slack monitoring", or invokes
  /enable-slack-channel-monitoring.
---

Set up a scheduled, self-identifying Slack monitor for ONE channel, bound to ONE project
dir, managed by a manager session. Monitor wakes on cron, spawns an isolated subagent
that reads the channel via Slack MCP and replies only when warranted. A SessionHook
reminds the manager to recreate the cron if missing (7-day expiry, or pod restart).
Prompt + instructions render from templates, user-customizable per channel/project.

This skill only **registers** a monitor — does not run it.

## Preconditions (check first, stop if unmet)

1. **Slack MCP connected** — `mcp__claude_ai_Slack__*` tools exist this session (ToolSearch
   `slack_read_channel`). Absent → tell user to add the Slack connector on claude.ai and
   **restart the session** (MCP loads at session start). Don't continue without it.
2. **You are the manager session** (cwd = `/home/claude/workspaces`); cron + registry are
   manager-owned. Worker → hand to the manager.
3. `jq` available; project dir exists under `~/workspaces`.
4. Templates present at `~/.claude/skills/enable-slack-channel-monitoring/`:
   `SLACK_CRON.md.tmpl`, `slack_cron.prompt.tmpl`. Missing → copy from
   `/usr/local/lib/slack-monitor/`.

## Inputs (gather from user; ask for any missing)

- `CHANNEL_NAME` — e.g. `#xai-methods-concepts` (display only).
- `CHANNEL_ID`   — Slack channel id, e.g. `C0663SX30QY` (find via
  `mcp__claude_ai_Slack__slack_search_channels`).
- `PROJECT_DIR`  — abs path of the project, e.g. `/home/claude/workspaces/zennit-crp`.
- `WORKER_NAME`  — optional, worker session the monitor nudges for code work; default
  `$(basename "$PROJECT_DIR")` (spawn-worker convention).
- `CRON`         — optional, default `7 6-20 * * *` (≈ hourly 08:07–22:07 Prague).
- `MONITOR_NAME` — optional, default from channel (`slack-<slug>-monitor`).

## Step 1 — render files + update registry

Fill the variables, run this block (bash `${//}` substitution — safe with slashes/`#`):

```bash
set -euo pipefail
CHANNEL_NAME='#REPLACE'          # e.g. #xai-methods-concepts
CHANNEL_ID='REPLACE'             # e.g. C0663SX30QY
PROJECT_DIR='/home/claude/workspaces/REPLACE'
WORKER_NAME="$(basename "$PROJECT_DIR")"   # worker the monitor nudges; override if it differs
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
  t=${t//'{{WORKER_NAME}}'/$WORKER_NAME}
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

Read the rendered prompt file, create the job (must be the EXACT text):

- Read `"$PROMPT_FILE"`.
- **CronCreate** with `cron=<CRON>`, `recurring=true`, `prompt=<file contents>`.
- Verify with **CronList**: a job whose prompt starts with `[scheduled: <MONITOR_NAME>]`
  exists.

## Step 3 — confirm

Report: monitor name, channel, schedule, project dir, cron registered. Remind the user
they can tailor `"$PROJECT_DIR/SLACK_CRON.md"` (reply triggers, code tree, datasets).

## Notes

- Multiple channels: run once per channel — each gets its own monitor name, prompt file,
  lock (`slack-lock <action> <MONITOR_NAME>`), registry entry.
- Across pod restarts: the manager-only `_slack-cron-reminder.sh` SessionStart hook
  re-reads the registry, reminds the manager to recreate any missing cron (7-day expiry).
- Stop a monitor: delete its CronList job, remove its registry entry, delete `"$PROMPT_FILE"`.
