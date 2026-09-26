# Changelog

Notable changes to this deployment, newest first. **Migration notes** record one-off
steps an existing pod needs; the code itself always describes the current layout only.

## Unreleased

### Workers stay steerable across restarts and CLI updates (#10, #11)

- `DISABLE_AUTOUPDATER=1` is exported by the entrypoint (process env + `~/.claude-env`).
  The CLI self-update replaces `~/.local/bin/claude` at runtime and kills the sessions
  running off the old binary. Upgrade deliberately: rebuild with
  `--build-arg CLAUDE_CACHE_BUST=<value>`.
- Folder trust is pre-accepted for the manager workspace **and** every registered
  worker dir, in both the shared config and each worker's own.
- New `worker-tools/trust-guard.sh` → `~/workspaces/bin/_trust-guard`, refreshed every
  start. It answers the folder-trust and dangerous-settings dialogs on a worker pane.
  The dangerous-settings disclosure ("This folder pre-approves N tool permissions")
  persists no consent anywhere, so it re-appears on every start and blocks the TUI
  before remote control activates. Keep dangerous allow-patterns such as
  `Bash(rm -rf …)` out of project `.claude/settings.json` so it is never armed.
- Ready polls match the 2.1.283 banner (`/remote-control is active · …`) as well as the
  older wordings.
- Worker registry `~/workspaces/.workers.json` is a **name set**: `{"<name>": {}}`.
  Keys are worker names, values ignored. Everything else — dir, repo, session id, RC
  URL — is derived where needed.
- Workers run on a private `CLAUDE_CONFIG_DIR` (`<dir>/.claudecfg`, prepared by
  `_worker-cfg`), so concurrent workers no longer share one `.claude.json`.
  Consequence: `claude agents --json` is scoped to a config dir and therefore cannot
  see workers — use `list-workers`, which reads each worker's own session records,
  verifies the pid is alive, and flags a tmux session with a dead pane as
  `up-DEADPANE`.
- Worker helpers are versioned in `worker-tools/`. The entrypoint installs only the
  ones that are **missing**, so a fresh pod or a lost PVC gets working helpers while an
  existing pod keeps its own edits.

#### Migration notes

Performed on the live pod on 2026-09-26, before this PR was merged. Needed only for a
pod whose PVC predates the changes above; a fresh PVC needs none of it.

0. Config file into the config dir (was a one-off `cp` in `entrypoint.sh`, now removed).
   `CLAUDE_CONFIG_DIR=~/.claude` means claude reads `~/.claude/.claude.json`; a pod that
   ran the older image has it at `~/.claude.json` and would otherwise come up with fresh
   onboarding:
   ```sh
   cp -a ~/.claude.json ~/.claude/.claude.json
   ```
   Copy, not move — sessions still running on the old layout keep using the old path.
   Repeat the copy immediately before the redeploy if the pod keeps running, so trust
   flags and project entries written in the meantime are not lost.

1. Registry → name set (drops `dir`, `repo`, `session`, `started`, `task`):
   ```sh
   cd ~/workspaces && jq 'map_values({})' .workers.json > .tmp && mv .tmp .workers.json
   ```
   Keep the object shape. A bare JSON array breaks every `jq keys[]` reader.
2. Per worker, move its conversation into the private config dir, then restart it
   there. `claude --resume <id>` only sees ids under its own `CLAUDE_CONFIG_DIR`, so
   skipping this makes a resumed worker start a *fresh* conversation while reporting
   success:
   ```sh
   NAME=<worker>; DIR=~/workspaces/$NAME; CFG=$DIR/.claudecfg
   ENC=$(printf '%s' "$DIR" | sed 's/[^A-Za-z0-9]/-/g')
   SID=$(ls -t ~/.claude/projects/$ENC/*.jsonl | head -1 | xargs basename | sed 's/\.jsonl$//')
   _worker-cfg "$NAME"                      # creates $CFG (creds/skills links, trust seeded)
   mkdir -p "$CFG/projects/$ENC" "$CFG/sessions"
   tmux kill-session -t "$NAME"             # stop it first, so the copy captures final writes
   cp ~/.claude/projects/$ENC/$SID.jsonl "$CFG/projects/$ENC/"
   resume-worker "$NAME"                    # relaunches on $CFG with full history
   ```
   Confirm with `list-workers` (pid + session id) and
   `tr '\0' '\n' < /proc/<pane_pid>/environ | grep CLAUDE_CONFIG_DIR`.
   The shared `~/.claude/projects/<enc>/` copy can stay as a backup; nothing reads it.
3. Clear any tmux session whose pane is dead (`list-workers` shows `up-DEADPANE`)
   before resuming it — `resume-worker` refuses while the session exists:
   ```sh
   tmux kill-session -t <name> && resume-worker <name>
   ```
