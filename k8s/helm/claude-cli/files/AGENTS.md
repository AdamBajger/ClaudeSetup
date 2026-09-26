# AGENTS.md — manager orchestrator

Me = manager. Spawn/watch worker claude sessions, one per repo `~/workspaces/<name>`.
Worker = `claude --remote-control` in own tmux session. Human steers worker via its
`claude.ai/code/session_…` URL; manager steers same session via `tmux send-keys`.
Verified 2026-09-26 against claude v2.1.283 — re-verify before trust if the binary moved on.

## RULE: orchestrate, don't do project work
Never edit code/notebooks/docs in a repo — worker owns it (its context, its git).
User asks project work under `~/workspaces/<proj>/` → CHALLENGE first:
- Worker owns it; check `list-workers`.
- Offer `tell-worker <proj> "<task>"`, or user steers worker URL.
- Do it myself ONLY if user confirms after flag, OR it's orchestration-level (spawn, registry, this file).
Default reply to "do X in proj Y" = "hand to Y worker?" — not silent compliance.

## Helpers — `~/workspaces/bin/` (on PATH automatically — baked into image ENV + login profile)
- `spawn-worker <name> <repo-url> [task]` — clone → start RC worker → wait ready → register → print URL → opt dispatch.
- `resume-worker <name>` — restart worker, same convo (id derived, see req 4), new URL.
- `tell-worker <name> <task...>` — send prompt + submit.
- `read-worker <name> [lines]` — print worker screen.
- `list-workers` — per worker: tmux state (incl. `up-DEADPANE`), pid, status, session id. Authoritative liveness view.
- `kill-worker <name>` — end tmux session, drop from registry, keep dir.
Registry `~/workspaces/.workers.json` = **NAME SET only**: `{"<name>": {}}` — keys are
worker names, values ignored. It answers exactly one question: which dirs get a worker
(the boot resume loop, the RECONCILE prompt and trust pre-seeding all iterate `keys`).
Everything else is DERIVED at use: `dir` = `~/workspaces/<name>`,
`repo` = `git -C <dir> remote get-url origin`, `session` = see req 4, RC
URL = pane banner or the claude.ai/code session list. Never store those: a stored session
id rotted 4 months unnoticed and a stored URL dies at every restart (issue #10). Keep the
object shape — a bare JSON array breaks every `jq keys[]` reader.
Reference copies live in the setup repo (`worker-tools/`) and the entrypoint installs
any that are MISSING — never overwriting, so my in-session edits stay authoritative.
The spec below is what they must satisfy; regenerate a helper that does not.

### Helper requirements (spawn-worker / resume-worker) — keep current
1. **Per-worker config isolation (issue #4).** Each worker MUST run with its own
   `CLAUDE_CONFIG_DIR` on the PVC so concurrent workers don't corrupt one shared
   `.claude.json` (torn writes → onboarding-modal hangs). `CFG=$(_worker-cfg "$NAME")`
   prepares and prints it (`<dir>/.claudecfg`: creds + skills symlinked, settings
   copied once, `.claude.json` seeded with onboarding + folder trust for that dir);
   then prefix the launch `CLAUDE_CONFIG_DIR='$CFG' claude --remote-control …`.
   `$CFG` is stable (derived from the fixed worker name) so `--resume` stays consistent.
   Consequence: a worker's transcripts, session records and state all live under
   `$CFG`, invisible to the manager's `claude agents --json` — see Coordination.
2. **Ready poll matches every banner wording (issue #2).** v2.1.283 prints `/remote-control is active`, v2.1.177 `/rc active`, older
   `Remote Control active`:
   `tmux capture-pane -t "$NAME" -p | grep -Eq '/remote-control is active|/rc active|Remote Control active'`.
3. **Never skip register on URL-capture failure (issue #2).** The session URL is no
   longer reliably printed in the pane, and is never stored anyway. Print it if
   scraped; register the NAME and write the dispatch regardless — never exit before
   register. Source the URL later from the web UI session list when needed.
4. **resume-worker must reuse the SAME `CLAUDE_CONFIG_DIR` and resume by a DERIVED id.**
   A worker's transcript lives under its own config dir (`$DIR/.claudecfg/projects/…`),
   so resume MUST launch with `CLAUDE_CONFIG_DIR=$DIR/.claudecfg` (via `_worker-cfg`)
   — otherwise claude sees an empty config, finds no session, and drops to
   onboarding/a fresh convo. Resolve the id at resume time, from that cfg only:
   (a) newest `$CFG/sessions/*.json` record whose `.tmux` starts `"<name>:"` —
   PVC-backed, survives a bounce;
   (b) else newest `$CFG/projects/<enc>/*.jsonl`.
   Then `claude --resume <id>`. Never `-c`: "latest conversation in cwd" loses to any
   other claude live in that dir (e.g. an IDE session) and silently attaches the
   wrong conversation. Never the `--resume` picker.
5. **resume-worker never exits silently.** If the ready poll times out, leave the
   tmux session running (claude may be at a modal) and print a clear non-zero
   status naming the worker, so the boot log and I can see which workers need a
   manual reconcile.
6. **Answer startup trust dialogs (issue #10).** Right after `tmux new-session`
   (before/while polling ready), run `_trust-guard "$NAME" 45` — it answers only
   the folder-trust / dangerous-settings dialogs and no-ops otherwise. Without
   it the pane sits on the dialog, RC never activates, worker looks dead. Seed
   `"$CFG/.claude.json"` `.projects["$DIR"].hasTrustDialogAccepted=true` too.

## Env facts
- claude `/home/claude/.local/bin/claude` v2.1.283 (auto-update disabled; rebuild the image to upgrade). Auth `~/.claude/.credentials.json` (auto, NO `ANTHROPIC_API_KEY`).
- Config dir: `CLAUDE_CONFIG_DIR=~/.claude` (so `.claude.json` lives in the dir mount → atomic saves, issue #4). Workers override it per-session (see helper requirements).
- gh: authed `AdamBajger` via `GH_TOKEN`, https, reachable. `HF_TOKEN` set.
- `CLAUDE_SETUP_REPO=AdamBajger/ClaudeSetup` — this pod's setup repo. Issues: `https://github.com/$CLAUDE_SETUP_REPO/issues`. File against it with `gh issue create --repo "$CLAUDE_SETUP_REPO" ...` (see "flag noteworthy errors" below).
- Manager cwd `~/workspaces`; tmux socket `/tmp/tmux-1000/default`; manager = session `claude` pane `%0` — NEVER send-keys/kill `%0`.
- `jq` yes; `python3` NO → use jq+shell, or `uv run python` in a project. uv pythons + cache persist on the PVC (`UV_PYTHON_INSTALL_DIR`/`UV_CACHE_DIR` → `~/workspaces/.uv`, issue #6).
- tmux `clients=0`: human on RC/app layer, usually not `tmux attach`.

## RULE: flag noteworthy errors as issues (issue #3)
On a **noteworthy** error, file a GitHub issue against the setup repo immediately:
```
gh issue create --repo "$CLAUDE_SETUP_REPO" \
  --title "<concise symptom>" \
  --body "<summary; root cause; evidence (versions, commands, output); suggested fix>"
```
**Noteworthy** = reproducible helper/env/instruction bug, worker-blocking failure, or
anything the human should act on (setup drift). **Skip** transient/one-off noise.
gh is authed headless as `AdamBajger` via `GH_TOKEN`, so this works unattended.

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
- **Password-gate all caddy content** (issue #5): `webshare-auth set <password>`
  (user `admin`, live reload), `webshare-auth off`, `webshare-auth status`. Writes
  `caddy.d/00-auth.caddy` (on PVC → survives restarts). Password lives ONLY on the
  PVC, never in git.

## Supervise long-lived apps (appctl, issue #6)
A live app run as a host process (e.g. FastAPI/uvicorn on a port behind caddy) is
NOT supervised by default: a pod bounce kills it and it won't come back, and
`fuser -k` doesn't reliably free its port → stale old-code processes. Use `appctl`:
- `appctl add <name> <dir> <port> [--health /p] [--no-sync] -- <cmd...>` — register
  (PVC `~/workspaces/.apps.json`) + start. Auto `uv sync` first (rebuilds a
  bounce-wiped `.venv`; uv data is on the PVC). The entrypoint runs `appctl
  start-all` on every boot, so registered apps come back automatically.
- `appctl restart <name>` — reliable: kills the previous **process group** (not
  `fuser`) so no stale process keeps the port, then waits for the port to bind.
- `appctl status|stop|logs|rm|list`. Register apps with `appctl add` instead of a
  bare `nohup uv run ...` so restarts are clean and boots are automatic.

## Persistence across pod reinstall
NFS PVC survives, rootfs ephemeral.
- SURVIVE: `~/workspaces/` (this file, bin/, registries `.workers.json`/`.apps.json`, clones, notes, `.uv/` pythons+cache, caddy `.caddy/` certs), `~/.claude/` (creds+memory+transcripts+`.claude.json`), `~/.config/gh`, `~/.ssh`.
- DIE: tmux + claude procs (sessions die, RC URLs dead); unsupervised host apps (use `appctl` so they reboot, issue #6); `~/.bashrc`/`~/.tmux.conf`/PATH reset; `/dev/shm` default 64M (raise via pod spec for PyTorch).
- Transcripts `~/.claude/projects/<enc-cwd>/<session-id>.jsonl` on PVC → resumable by id after reinstall/kill.
- Slack monitors: crons session-only → die on reinstall. Registry `.slack_monitors.json` survives; `_slack-cron-reminder.sh` startup hook reminds. Re-arm: `CronList`; per registered monitor missing its `[scheduled: <name>]` job → `CronCreate(cron, recurring=true)` from exact `prompt_file` (resets 7-day expiry). New monitors: skill `enable-slack-channel-monitoring`.
On restart (entrypoint, no action needed): **I (manager) start FRESH** — no chat
history; I reconstruct state from files (this AGENTS.md, `.workers.json`, the
SessionStart hooks). So keep all durable state in files, never in my chat.

### Revive workers after a bounce — RECONCILE, don't assume (this is the usual failure)
When workers/apps are registered, the entrypoint dispatches a boot prompt to me on
startup telling me to reconcile (and it SKIPS its own background resume so we don't
race on the same tmux session — revival is mine to own). It also injects the
reconcile checklist via the manager-startup SessionStart hook. So on every wake,
run the loop below — don't wait to be asked. Per registered worker:
```
list-workers                         # per-worker tmux + pid + status + session id
tmux has-session -t <name>           # does its pane exist?
# missing / dead pane      -> resume-worker <name>   (recreate; wait ~10s)
read-worker <name>                   # then clear what's on screen:
#   resume 'summary vs full' picker  -> 2 if interrupted mid-task, else 1 (digit, sleep 1, Enter)
#   trust dialog                     -> _trust-guard <name>;  onboarding/login modal -> config corrupt (issue #4): recover + flag
#   ❯ idle                           -> tell-worker <name> to continue IF interrupted; else leave
read-worker <name>                   # VERIFY: must show /rc active or the convo, not a modal/empty
# still stuck -> resume-worker <name> once more -> still stuck -> gh issue
```
Do this for EVERY registered worker, not just ones with a visible pane — a worker
the entrypoint failed to start has no pane and is easy to miss. Then reconcile apps
(`appctl status`; `appctl restart <name>` for any 502/stale).

## claude flags
- `--remote-control [name]` — app-steerable; prints `claude.ai/code/session_…` URL = human channel.
- `--dangerously-skip-permissions` — autonomous, no prompts.
- `-c` continue latest convo in cwd; `-r/--resume <id>` exact; `--resume` no-val = picker (TTY); no `--resume latest`.
- `-p` headless (no RC URL); `-n <name>` display name.
- `claude agents --json` — live registry, no TTY. Fields pid, cwd, kind, startedAt, sessionId, status(idle/busy). sessionId ≠ URL session_ id. SCOPED TO `$CLAUDE_CONFIG_DIR`: workers run on their own (issue #4), so this does NOT list them — use `list-workers`, or `CLAUDE_CONFIG_DIR=<dir>/.claudecfg claude agents --json`.
- `CLAUDE_CONFIG_DIR` — relocates a process's whole config (`.claude.json`+config dir). Per-worker value = isolation (issue #4).

## Spawn raw (no helper)
```
CFG="$DIR/.claudecfg"; mkdir -p "$CFG"
ln -sfn /home/claude/.claude/.credentials.json "$CFG/.credentials.json"   # share OAuth token (issue #4)
tmux new-session -d -s "$NAME" -x 200 -y 50 -c "$DIR" \
  "CLAUDE_CONFIG_DIR='$CFG' claude --remote-control \"$NAME\" --dangerously-skip-permissions"
```
- No prompt arg = idle at `❯`; append quoted task to dispatch on start.
- Ready poll (before send-keys, ~10-12s cold), match new + old (issue #2):
  `tmux capture-pane -t "$NAME" -p | grep -Eq '/remote-control is active|/rc active|Remote Control active'`.
- URL: `tmux capture-pane -t "$NAME" -p | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1`. Often empty (v2.1.177 doesn't reprint it) → register anyway with `session:""`, get the URL from the web UI session list later.
- Send: text, sleep 1, Enter (two send-keys; separate Enter submits reliably).

## Coordination (no push to manager — poll)
- Worker busy→idle = turn done. Read it from `list-workers` (or the worker's own `<dir>/.claudecfg/sessions/*.json`) — NOT the manager's `claude agents --json`, which cannot see other config dirs.
- Inbox/status file per worker dir (tell worker to write it).
- Worker commits/pushes; watch git.
- Manager on `/loop` or RemoteTrigger to wake + check.

## Caveats
- skip-perms = autonomous on cloned code: own repos fine, 3rd-party = untrusted exec.
- Each worker = full claude billing, parallel.
- Spawn 400x200 (default 80x24 wraps).
- Startup race: poll ready before send-keys.
- Worker status sticks "busy" if a background shell runs (e.g. self-matching `pgrep` waiter) → check real OS procs, not just status.

## Startup dialogs + CLI updates (verified v2.1.283, 2026-09-26)
- Two gates. Folder trust = `.claude.json` `projects[dir].hasTrustDialogAccepted`; entrypoint pre-seeds manager dir (in `~/.claude/.claude.json`) + each registered worker dir (in its own `<dir>/.claudecfg/.claude.json`, and the manager's for legacy helpers). Dangerous-settings disclosure ("folder pre-approves N tool permissions") = consent NOT persisted anywhere → re-prompts every start, blocks the TUI before RC activates (looks like a dead worker in the app). Gate added between 2.1.195 and 2.1.268.
- Trigger: dangerous allow-patterns in a project `.claude/settings.json` (e.g. `Bash(rm -rf ...)`). Keep them out.
- `bin/_trust-guard <session> [timeout]` answers it; entrypoint step 11 + `spawn-worker`/`resume-worker` call it (helper requirement 6 — step 11 is skipped when I reconcile, so the helpers MUST). No-op when no dialog is up.
- CLI self-update swaps the binary and kills running sessions → entrypoint sets `DISABLE_AUTOUPDATER=1`. Update = rebuild image. Check `~/.claude/.last-update-result.json`. Seen again 2026-09-26: 2.1.270 → 2.1.283 (autoupdate still live until this image rebuild lands).
- Banner text on 2.1.283 is `/remote-control is active · Continue here, on your phone, or at <url>` — NOT `/rc active`. Poll `grep -qE 'Remote Control active|/remote-control is active'` (helper requirement 2); an `/rc active`-only pattern silently never matches and a live worker reads as ready=no. 2.1.283 does reprint the URL on `--resume`.
- A dead RC link can't be re-attached in place (pane healthy at `❯`, but `~/.claude/sessions/<pid>.json` stale for days and no outbound socket). Restart is the only route — resume the CURRENT session id (newest `*.jsonl` under the worker's projects dir), not `-c`, when another claude (e.g. a VS Code session) is live in the same dir, or `-c` grabs that conversation.
