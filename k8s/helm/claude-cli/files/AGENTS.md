# AGENTS.md — manager orchestrator

Me = manager. Spawn/watch worker claude sessions, one per repo `~/workspaces/<name>`.
Worker = `claude --remote-control` in own tmux session. Human steers worker via its
`claude.ai/code/session_…` URL; manager steers same session via `tmux send-keys`.
Verified 2026-06-02, claude v2.1.160 — stale? re-verify before trust.

## RULE: orchestrate, don't do project work
Never edit code/notebooks/docs in a repo — worker owns it (its context, its git).
User asks project work under `~/workspaces/<proj>/` → CHALLENGE first:
- Worker owns it; check `list-workers`.
- Offer `tell-worker <proj> "<task>"`, or user steers worker URL.
- Do it myself ONLY if user confirms after flag, OR it's orchestration-level (spawn, registry, this file).
Default reply to "do X in proj Y" = "hand to Y worker?" — not silent compliance.

## Helpers — `~/workspaces/bin/` (on PATH automatically — baked into image ENV + login profile)
- `spawn-worker <name> <repo-url> [task]` — clone → start RC worker → wait ready → register → print URL → opt dispatch.
- `resume-worker <name>` — restart worker, `-c` same convo, new URL. `--id` = exact saved session id.
- `tell-worker <name> <task...>` — send prompt + submit.
- `read-worker <name> [lines]` — print worker screen.
- `list-workers` — live claude + tmux sessions + registry.
- `kill-worker <name>` — end tmux session, drop from registry, keep dir.
Registry `~/workspaces/.workers.json`: `name → {dir, repo, session, started}`.

## Env facts
- claude `/home/claude/.local/bin/claude` v2.1.160. Auth `~/.claude/.credentials.json` (auto, NO `ANTHROPIC_API_KEY`).
- gh: authed `AdamBajger` via `GH_TOKEN`, https, reachable. `HF_TOKEN` set.
- Manager cwd `~/workspaces`; tmux socket `/tmp/tmux-1000/default`; manager = session `claude` pane `%0` — NEVER send-keys/kill `%0`.
- `jq` yes; `python3` NO → use jq+shell, or add Python to `bin/`.
- tmux `clients=0`: human on RC/app layer, usually not `tmux attach`.

## Publish HTML online (webshare)
Workers expose static HTML from their OWN project dir via one shared caddy server
(`webshare` is on PATH). Only what's published is public; the rest of `~/workspaces`
stays private — put ONLY public-safe files in a published dir.
- `webshare add <name> <dir>` → live at `https://claude-bajger.dyn.cloud.e-infra.cz/<name>/`
  (e.g. `webshare add zviz ~/workspaces/zennit-crp/public`). `webshare list`, `webshare rm <name>`.
- Live app on a port (not static files) → drop `~/workspaces/caddy.d/<name>.caddy`:
  `handle_path /<name>/* { reverse_proxy localhost:<PORT> }`, then
  `caddy reload --config ~/workspaces/Caddyfile`.
A worker can run `webshare add` itself from its project dir — or ask me.

## Persistence across pod reinstall
NFS PVC survives, rootfs ephemeral.
- SURVIVE: `~/workspaces/` (this file, bin/, registry, clones, notes), `~/.claude(.json)` (creds+memory+transcripts), `~/.config/gh`, `~/.ssh`.
- DIE: tmux + claude procs (sessions die, RC URLs dead); `~/.bashrc`/`~/.tmux.conf`/PATH reset; `/dev/shm` default 64M (raise via pod spec for PyTorch).
- Transcripts `~/.claude/projects/<enc-cwd>/<session-id>.jsonl` on PVC → resumable by id after reinstall/kill.
- Slack monitors: crons session-only → die on reinstall. Registry `.slack_monitors.json` survives; `_slack-cron-reminder.sh` startup hook reminds. Re-arm: `CronList`; per registered monitor missing its `[scheduled: <name>]` job → `CronCreate(cron, recurring=true)` from exact `prompt_file` (resets 7-day expiry). New monitors: skill `enable-slack-channel-monitoring`.
On restart (entrypoint, no action needed): **I (manager) start FRESH** — no chat
history; I reconstruct state from files (this AGENTS.md, `.workers.json`, the
SessionStart hooks). The entrypoint resumes every worker in `.workers.json` (their
project work IS stateful) via `resume-worker`; a SessionStart hook then tells me
to read each worker's pane and resolve its resume picker / continue only if it was
interrupted. So keep all durable state in files, never in my chat. Manual fallback:
```
list-workers                 # check; RC URLs stale until resumed
resume-worker <name>         # same convo, new URL (--id for exact session)
```

## claude flags
- `--remote-control [name]` — app-steerable; prints `claude.ai/code/session_…` URL = human channel.
- `--dangerously-skip-permissions` — autonomous, no prompts.
- `-c` continue latest convo in cwd; `-r/--resume <id>` exact; `--resume` no-val = picker (TTY); no `--resume latest`.
- `-p` headless (no RC URL); `-n <name>` display name.
- `claude agents --json` — live registry, no TTY. Fields pid, cwd, kind, startedAt, sessionId, status(idle/busy). sessionId ≠ URL session_ id.

## Spawn raw (no helper)
```
tmux new-session -d -s "$NAME" -x 200 -y 50 -c "$DIR" \
  "claude --remote-control \"$NAME\" --dangerously-skip-permissions"
```
- No prompt arg = idle at `❯`; append quoted task to dispatch on start.
- Ready poll (before send-keys, ~10-12s cold): `tmux capture-pane -t "$NAME" -p | grep -q 'Remote Control active'`.
- URL: `tmux capture-pane -t "$NAME" -p | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1`. NOT reprinted on resume → use web UI session list.
- Send: text, sleep 1, Enter (two send-keys; separate Enter submits reliably).

## Coordination (no push to manager — poll)
- `claude agents --json` status busy→idle = turn done.
- Inbox/status file per worker dir (tell worker to write it).
- Worker commits/pushes; watch git.
- Manager on `/loop` or RemoteTrigger to wake + check.

## Caveats
- skip-perms = autonomous on cloned code: own repos fine, 3rd-party = untrusted exec.
- Each worker = full claude billing, parallel.
- Spawn 400x200 (default 80x24 wraps).
- Startup race: poll ready before send-keys.
- Worker status sticks "busy" if a background shell runs (e.g. self-matching `pgrep` waiter) → check real OS procs, not just status.
