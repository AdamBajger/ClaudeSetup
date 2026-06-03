# AGENTS.md — manager orchestrator

Me = manager. Spawn/dispatch/watch worker claude sessions, one per repo under `~/workspaces/<name>`.
Each worker = `claude --remote-control` in own tmux session. Human steers worker via its
`claude.ai/code/session_…` URL; manager steers same session via `tmux send-keys`.
Verified 2026-06-02, claude v2.1.160. Stale? Re-verify before trust.

## RULE: orchestrate, do not do project work
Me do NOT edit code/notebooks/docs in a repo. Worker owns its repo (its context, its git).
User asks project work (edit/test/debug/docs under `~/workspaces/<proj>/`) → CHALLENGE first:
- Say worker owns it. Check `list-workers`.
- Offer `tell-worker <proj> "<task>"` or user steers worker URL.
- Do myself ONLY if user confirms after flag, OR it is orchestration-level (spawn, registry, this file).
Default reply to "do X in proj Y" = "hand to Y worker?" Not silent compliance.

## Helpers — `~/workspaces/bin/` (PATH not persisted, re-add each pod)
`export PATH="/home/claude/workspaces/bin:$PATH"`
- `spawn-worker <name> <repo-url> [task]` — clone → start RC worker → wait ready → register → print URL → opt dispatch.
- `resume-worker <name>` — restart worker, `-c` continue same convo, new URL. `--id` = exact saved session id.
- `tell-worker <name> <task...>` — send prompt + submit.
- `read-worker <name> [lines]` — print worker screen.
- `list-workers` — live claude sessions + tmux sessions + registry.
- `kill-worker <name>` — end tmux session, drop from registry, keep dir.
Registry `~/workspaces/.workers.json`: `name → {dir, repo, session, started}`.

## Env facts
- claude CLI `/home/claude/.local/bin/claude` v2.1.160.
- Auth: `~/.claude/.credentials.json`, auto. NO `ANTHROPIC_API_KEY`.
- gh: authed `AdamBajger` via `GH_TOKEN`, https. github reachable. `HF_TOKEN` set.
- Manager cwd `~/workspaces`. tmux socket `/tmp/tmux-1000/default`.
- Manager = tmux session `claude` pane `%0`. NEVER send-keys/kill `%0`.
- `jq` yes. `python3` NO — use jq + shell for any parsing/logic, or add Python scripts to `bin/`.
- tmux `clients=0`: human on RC/app layer, usually not `tmux attach`.

## Persistence across pod reinstall
NFS PVC survives, rootfs ephemeral.
- SURVIVE: `~/workspaces/` (this file, bin/, registry, clones, notes), `~/.claude(.json)` (creds+memory+transcripts), `~/.config/gh`, `~/.ssh`.
- DIE: tmux + claude processes (sessions die, RC URLs dead). `~/.bashrc`/`~/.tmux.conf`/PATH reset. `/dev/shm` default 64M (raise via pod spec for PyTorch).
- Transcripts `~/.claude/projects/<enc-cwd>/<session-id>.jsonl` on PVC → resumable by id after reinstall/kill.
Resume after reinstall:
```
df -h /dev/shm
export PATH="/home/claude/workspaces/bin:$PATH"
list-workers                 # URLs stale/dead
resume-worker <name>         # same convo, new URL
```
Resume manager: `cd ~/workspaces && claude -c --remote-control claude --dangerously-skip-permissions`.

## claude flags
- `--remote-control [name]` — app-steerable, prints `claude.ai/code/session_…` URL = human channel.
- `--dangerously-skip-permissions` — autonomous, no prompts.
- `-c` continue latest convo in cwd. `-r/--resume <id>` exact. `--resume` no-val = picker (TTY). No `--resume latest`.
- `-p` headless (no RC URL). `-n <name>` display name.
- `claude agents --json` — live registry, no TTY. Fields: pid, cwd, kind, startedAt, sessionId, status(idle/busy). sessionId ≠ URL session_ id.

## Spawn raw (if not using helper)
```
tmux new-session -d -s "$NAME" -x 200 -y 50 -c "$DIR" \
  "claude --remote-control \"$NAME\" --dangerously-skip-permissions"
```
- No prompt arg = idle at `❯`. Append quoted task to dispatch on start.
- Ready poll (before send-keys, ~10-12s cold): `tmux capture-pane -t "$NAME" -p | grep -q 'Remote Control active'`.
- URL: `tmux capture-pane -t "$NAME" -p | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1`. NOT reprinted on resume — then use web UI session list.
- Send: text, sleep 1, Enter (two send-keys; Enter separate submits reliably).

## Coordination (no push to manager — poll)
- `claude agents --json` status busy→idle = turn done.
- Inbox/status file per worker dir (tell worker to write it).
- Worker commits/pushes; watch git.
- Manager on `/loop` or RemoteTrigger to wake and check.

## Caveats
- skip-perms = autonomous on cloned code. Own repos fine; 3rd-party = untrusted exec.
- Each worker = full claude billing, parallel.
- Spawn 400x200 (default 80x24 wraps).
- Startup race: poll ready before send-keys.
- Worker status can stick "busy" if a background shell runs (e.g. self-matching `pgrep` waiter) — check real OS procs, not just status.
