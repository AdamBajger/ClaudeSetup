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
- Fixed: manager boot prompt contained single quotes, which broke the tmux autostart
  command; `spawn-worker` exited before registering when no URL was in the pane;
  `resume-worker` exited instead of starting fresh when a worker had no transcripts.
- Worker tmux window is 400x200.
- Repo-wide cleanup: history comments dropped, dead guards removed, silent `|| true` /
  `2>/dev/null` replaced by loud failure or a logged warning. `appctl` health probe no
  longer reports a dead app as up.
- Manager instructions renamed `AGENTS.md` → `MANAGER.md` and no longer copied to the
  PVC; the manager-startup hook injects them straight from the image. Claude 2.1.283
  auto-loads `AGENTS.md` from every ancestor dir, so `~/workspaces/AGENTS.md` leaked the
  orchestrator role into every worker (and reached the manager twice). Copy-if-absent
  also meant instruction updates never reached an existing pod. Change instructions via
  the repo, not in-session.

#### Deploying this change

The chart pulls `adambajger/claude-cli-cloud-run:latest`, so a `helm upgrade` alone
changes nothing here — entrypoint, Dockerfile, MANAGER.md and `worker-tools/` all ship
inside the image. Order:

1. Rebuild and push the image from the PR head (merge after the boot is verified). The
   cache-bust arg also bakes a current CLI, which matters now that the auto-updater is
   disabled: the image version is the version the pod keeps until the next rebuild.
   ```sh
   docker build -f claude.Dockerfile -t adambajger/claude-cli-cloud-run:<version> \
     -t adambajger/claude-cli-cloud-run:latest --build-arg CLAUDE_CACHE_BUST=$(date +%s) .
   docker push adambajger/claude-cli-cloud-run:<version>
   docker push adambajger/claude-cli-cloud-run:latest
   ```
2. Run migration steps 0 and 5 below on the live pod, as late as possible before the restart.
3. `helm upgrade --install claude k8s/helm/claude-cli -n <ns> -f k8s/helm/claude-cli/values.yaml`,
   then `kubectl -n <ns> rollout restart deploy/claude-claude-cli` — with an unchanged
   `latest` tag and manifest, helm alone does not restart the pod.
4. Migration step 4 below (helper refresh).
5. Merge this PR.

Expected on boot: trust pre-accepted for `~/workspaces` and every registered worker dir
(shared + private configs), missing helpers seeded, the RECONCILE prompt dispatched to
the manager, and the entrypoint's own background resume skipped so the two don't race.

Verify after boot:
```sh
list-workers                              # expect: up, a live pid, the prior session id
read-worker <name>                        # if a pane sits on a modal instead
kubectl logs <pod> | grep -E 'trust|helpers|reconcile|resuming'
```
With a worker registered, revival is the manager's job and the entrypoint skips its own
resume loop, so `~/workspaces/.workers-resume.log` is NOT written on such a boot — look
for the `worker revival delegated to the manager's boot reconcile` log line instead. The
log only appears when nothing is registered for the manager to reconcile.
Boot path verified on the live pod with 0.7.0 (2026-09-26): boot prompt → reconcile →
`resume-worker` → remote control active, no trust dialog.

#### Migration notes

Needed only for a pod whose PVC predates the changes above; a fresh PVC needs none of
it. **Steps 1–3 were already performed on the live pod on 2026-09-26** (registry
reduced to `{"zennit-crp": {}}`; zennit-crp moved into `.claudecfg` and restarted
there on session `979a7c86…` with history intact; the dead-pane `aigopath-contract-spec`
session purged and dropped from the registry). Step 0 was performed too, but is the one
step to repeat immediately before the restart.

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
4. Refresh the pod's helper copies (the entrypoint never overwrites existing ones, and
   the copies installed on 2026-09-26 carry the spawn/resume bugs fixed above). After
   boot, have the manager run:
   ```sh
   for h in _worker-cfg spawn-worker resume-worker list-workers; do
     cp /usr/local/lib/worker-tools/$h ~/workspaces/bin/$h
   done
   ```
5. Move the old seeded `~/workspaces/AGENTS.md` (and any `~/workspaces/CLAUDE.md`) aside
   before the restart, otherwise workers keep auto-loading it:
   ```sh
   mv ~/workspaces/AGENTS.md ~/workspaces/AGENTS.md.bak
   ```
   Its in-session edits were folded into `MANAGER.md`; the backup is only for reference.
