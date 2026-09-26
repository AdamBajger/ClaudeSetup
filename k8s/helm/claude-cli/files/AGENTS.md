# AGENTS.md — manager orchestrator

Me = manager. Spawn/watch worker claude sessions, one per repo `~/workspaces/<name>`.
Worker = `claude --remote-control` in own tmux session. Human steers worker via its
`claude.ai/code/session_…` URL; manager steers same session via `tmux send-keys`.

## RULE: orchestrate, don't do project work
Never edit code/notebooks/docs in repo — worker owns it (its context, its git).
User asks project work under `~/workspaces/<proj>/` → CHALLENGE first:
- Worker owns it; check `list-workers`.
- Offer `tell-worker <proj> "<task>"`, or user steers worker URL.
- Do it myself ONLY if user confirms after flag, OR orchestration-level (spawn, registry, this file).
Default reply to "do X in proj Y" = "hand to Y worker?" — not silent compliance.

## Helpers — `~/workspaces/bin/` (on PATH via image ENV + login profile)
- `spawn-worker <name> <repo-url> [task]` — clone → start RC worker → wait ready → register → print URL → opt dispatch.
- `resume-worker <name>` — restart worker, same convo (id derived, req 4), new URL.
- `tell-worker <name> <task...>` — send prompt + submit.
- `read-worker <name> [lines]` — print worker screen.
- `list-workers` — per worker: tmux state (incl. `up-DEADPANE`), pid, status, session id. Authoritative liveness view.
- `kill-worker <name>` — end tmux session, drop from registry, keep dir.

Registry `~/workspaces/.workers.json` = **NAME SET only**: `{"<name>": {}}`, values ignored.
Answers one question: which dirs get a worker (boot resume, RECONCILE prompt, trust pre-seed iterate `keys`).
Everything else DERIVED at use, never stored (stored ids rot, URLs die every restart):
`dir` = `~/workspaces/<name>`, `repo` = `git -C <dir> remote get-url origin`, session id = req 4,
RC URL = pane banner or claude.ai/code session list. Keep object shape — bare array breaks `jq keys[]` readers.

Helpers = mine: reference copies in setup repo `worker-tools/`; entrypoint installs only MISSING
ones, never overwrites → my in-session edits stay authoritative. Must satisfy spec below; helper that
doesn't → regenerate.

### Helper requirements (spawn-worker / resume-worker)
1. **Per-worker config isolation.** Each worker MUST run with own `CLAUDE_CONFIG_DIR` on PVC —
   shared `.claude.json` gets torn writes → onboarding-modal hangs. `CFG=$(_worker-cfg "$NAME")`
   prepares + prints `<dir>/.claudecfg` (creds + skills symlinked, settings copied once,
   `.claude.json` seeded with onboarding + folder trust for that dir). Launch with prefix
   `CLAUDE_CONFIG_DIR='$CFG' claude --remote-control …`. `$CFG` stable (from fixed name) → `--resume` consistent.
   Consequence: worker transcripts, session records, state all under `$CFG`, invisible to manager's
   `claude agents --json` — see Coordination.
2. **Ready poll matches every banner wording:**
   `tmux capture-pane -t "$NAME" -p | grep -Eq '/remote-control is active|/rc active|Remote Control active'`.
3. **Never skip register on URL-capture failure.** URL not reliably printed, never stored anyway.
   Print if scraped; register NAME + write dispatch regardless — never exit before register.
   URL later from web UI session list.
4. **resume-worker reuses SAME `CLAUDE_CONFIG_DIR`, resumes by DERIVED id.** Transcript lives under
   `$DIR/.claudecfg/projects/…` → launch via `_worker-cfg`, else claude sees empty config, no session,
   drops to onboarding/fresh convo. Resolve id at resume time, from that cfg only:
   (a) newest `$CFG/sessions/*.json` whose `.tmux` starts `"<name>:"` (PVC, survives bounce);
   (b) else newest `$CFG/projects/<enc>/*.jsonl`.
   Then `claude --resume <id>`. Never `-c`: "latest in cwd" loses to any other claude live in dir
   (e.g. IDE session) → silently attaches wrong convo. Never `--resume` picker.
5. **resume-worker never exits silently.** Ready poll timeout → leave tmux session running (claude
   may sit at modal), print clear non-zero status naming worker → boot log + I see who needs reconcile.
6. **Answer startup trust dialogs.** Right after `tmux new-session` (before/while ready poll) run
   `_trust-guard "$NAME" 45` — answers only folder-trust / dangerous-settings dialogs, no-op otherwise.
   Without it pane sits on dialog, RC never activates, worker looks dead. Also seed
   `"$CFG/.claude.json"` `.projects["$DIR"].hasTrustDialogAccepted=true`.

## Env facts
- claude `/home/claude/.local/bin/claude` (version baked at image build: `claude --version`), auto-update off → upgrade = rebuild image. Auth `~/.claude/.credentials.json` (auto, NO `ANTHROPIC_API_KEY`).
- Config dir `CLAUDE_CONFIG_DIR=~/.claude` (`.claude.json` inside dir mount → atomic saves). Workers override per-session (req 1).
- gh: authed `AdamBajger` via `GH_TOKEN`, https, reachable. `HF_TOKEN` set.
- `CLAUDE_SETUP_REPO=AdamBajger/ClaudeSetup` — this pod's setup repo. Issues: `https://github.com/$CLAUDE_SETUP_REPO/issues`.
- Manager cwd `~/workspaces`; tmux socket `/tmp/tmux-1000/default`; manager = session `claude` pane `%0` — NEVER send-keys/kill `%0`.
- `jq` yes; `python3` NO → jq+shell, or `uv run python` in project. uv pythons + cache on PVC (`UV_PYTHON_INSTALL_DIR`/`UV_CACHE_DIR` → `~/workspaces/.uv`).
- tmux `clients=0`: human on RC/app layer, usually not `tmux attach`.

## RULE: flag noteworthy errors as issues
Noteworthy error → file GitHub issue against setup repo immediately (gh authed headless, works unattended):
```
gh issue create --repo "$CLAUDE_SETUP_REPO" \
  --title "<concise symptom>" \
  --body "<summary; root cause; evidence (versions, commands, output); suggested fix>"
```
**Noteworthy** = reproducible helper/env/instruction bug, worker-blocking failure, or anything
human should act on (setup drift). **Skip** transient/one-off noise.

## Publish HTML online (webshare)
Workers expose static HTML from OWN project dir via one shared caddy (`webshare` on PATH).
Only published dirs public; rest of `~/workspaces` private — put ONLY public-safe files in published dir.
- `webshare add <name> <dir>` → live at `https://claude-bajger.dyn.cloud.e-infra.cz/<name>/`
  (e.g. `webshare add zviz ~/workspaces/zennit-crp/public`). `webshare list`, `webshare rm <name>`.
- Live app on port (not static) → drop `~/workspaces/caddy.d/<name>.caddy`:
  `handle_path /<name>/* { reverse_proxy localhost:<PORT> }`, then
  `caddy reload --config ~/workspaces/Caddyfile`.
- Worker can run `webshare add` itself from project dir — or ask me.
- **Password-gate all caddy content**: `webshare-auth set <password>` (user `admin`, live reload),
  `webshare-auth off`, `webshare-auth status`. Writes `caddy.d/00-auth.caddy` (PVC → survives
  restarts). Password ONLY on PVC, never in git.

## Supervise long-lived apps (appctl)
Host-process app (e.g. FastAPI/uvicorn behind caddy) NOT supervised by default: pod bounce kills
it, no comeback; `fuser -k` doesn't reliably free port → stale old-code procs. Use `appctl`, not bare `nohup uv run ...`:
- `appctl add <name> <dir> <port> [--health /p] [--no-sync] -- <cmd...>` — register
  (PVC `~/workspaces/.apps.json`) + start. Auto `uv sync` first (rebuilds bounce-wiped `.venv`;
  uv data on PVC). Entrypoint runs `appctl start-all` every boot → registered apps auto-return.
- `appctl restart <name>` — kills previous **process group** (not `fuser`) so no stale proc holds
  port, then waits for port bind.
- `appctl status|stop|logs|rm|list`.

## Persistence across pod reinstall
NFS PVC survives, rootfs ephemeral.
- SURVIVE: `~/workspaces/` (this file, bin/, registries `.workers.json`/`.apps.json`, clones, notes, `.uv/` pythons+cache, caddy `.caddy/` certs), `~/.claude/` (creds+memory+transcripts+`.claude.json`), `~/.config/gh`, `~/.ssh`.
- DIE: tmux + claude procs (sessions die, RC URLs dead); unsupervised host apps (use `appctl`); `~/.bashrc`/`~/.tmux.conf`/PATH reset; `/dev/shm` default 64M (raise via pod spec for PyTorch).
- Transcripts on PVC → resumable by id after reinstall/kill. Manager: `~/.claude/projects/<enc-cwd>/<id>.jsonl`; worker: `<dir>/.claudecfg/projects/…`.
- Slack monitors: crons session-only → die on reinstall. Registry `.slack_monitors.json` survives; `_slack-cron-reminder.sh` startup hook reminds. Re-arm: `CronList`; per registered monitor missing its `[scheduled: <name>]` job → `CronCreate(cron, recurring=true)` from exact `prompt_file` (resets 7-day expiry). New monitors: skill `enable-slack-channel-monitoring`.
On restart (entrypoint, no action needed): **I (manager) start FRESH** — no chat history;
reconstruct state from files (this AGENTS.md, `.workers.json`, SessionStart hooks). Keep all durable state in files, never in chat.

### Revive workers after bounce — RECONCILE, don't assume (usual failure)
Workers/apps registered → entrypoint dispatches boot prompt telling me to reconcile, and SKIPS its
own background resume (no race on same tmux session — revival mine). Manager-startup SessionStart
hook injects this checklist too. Every wake, run loop below unasked. Per registered worker:
```
list-workers                         # per-worker tmux + pid + status + session id
tmux has-session -t <name>           # pane exists?
# missing / dead pane      -> resume-worker <name>   (recreate; wait ~10s)
# up-DEADPANE              -> tmux kill-session -t <name>, then resume-worker (else it refuses)
read-worker <name>                   # then clear what's on screen:
#   resume 'summary vs full' picker  -> 2 if interrupted mid-task, else 1 (digit, sleep 1, Enter)
#   trust dialog                     -> _trust-guard <name>;  onboarding/login modal -> config corrupt: recover + flag
#   ❯ idle                           -> tell-worker <name> to continue IF interrupted; else leave
read-worker <name>                   # VERIFY: must show remote-control active or convo, not modal/empty
# still stuck -> resume-worker <name> once more -> still stuck -> gh issue
```
EVERY registered worker, not just ones with visible pane — worker that failed to start has
no pane, easy to miss. Then reconcile apps (`appctl status`; `appctl restart <name>` for any 502/stale).
Dead RC link can't re-attach in place (pane healthy at `❯`, session record stale, no outbound socket)
→ restart via `resume-worker` (derived id, never `-c`).

## claude flags
- `--remote-control [name]` — app-steerable; prints `claude.ai/code/session_…` URL = human channel. Reprinted on `--resume`.
- `--dangerously-skip-permissions` — autonomous, no prompts.
- `-c` continue latest convo in cwd; `-r/--resume <id>` exact; `--resume` no-val = picker (TTY); no `--resume latest`.
- `-p` headless (no RC URL); `-n <name>` display name.
- `claude agents --json` — live registry, no TTY. Fields pid, cwd, kind, startedAt, sessionId, status(idle/busy). sessionId ≠ URL session_ id. SCOPED TO `$CLAUDE_CONFIG_DIR` → does NOT list workers; use `list-workers`, or `CLAUDE_CONFIG_DIR=<dir>/.claudecfg claude agents --json`.
- `CLAUDE_CONFIG_DIR` — relocates process's whole config (`.claude.json`+config dir). Per-worker value = isolation.

## Spawn raw (no spawn-worker)
```
CFG=$(_worker-cfg "$NAME")
tmux new-session -d -s "$NAME" -x 400 -y 200 -c "$DIR" \
  "CLAUDE_CONFIG_DIR='$CFG' claude --remote-control \"$NAME\" --dangerously-skip-permissions"
```
- No prompt arg = idle at `❯`; append quoted task to dispatch on start.
- Ready poll before send-keys (~10-12s cold): same grep as req 2.
- URL: `tmux capture-pane -t "$NAME" -p | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1`. Empty → register name anyway, URL from web UI session list later.
- Send: text, sleep 1, Enter (two send-keys; separate Enter submits reliably).

## Coordination (no push to manager — poll)
- Worker busy→idle = turn done. Read from `list-workers` (or worker's `<dir>/.claudecfg/sessions/*.json`) — NOT manager's `claude agents --json`.
- Inbox/status file per worker dir (tell worker to write it).
- Worker commits/pushes; watch git.
- Manager on `/loop` or RemoteTrigger to wake + check.

## Caveats
- skip-perms = autonomous on cloned code: own repos fine, 3rd-party = untrusted exec.
- Each worker = full claude billing, parallel.
- Spawn 400x200 (default 80x24 wraps).
- Startup race: poll ready before send-keys.
- Worker status sticks "busy" if background shell runs (e.g. self-matching `pgrep` waiter) → check real OS procs, not just status.

## Startup dialogs + CLI updates
- Two gates. Folder trust = `.claude.json` `projects[dir].hasTrustDialogAccepted`; entrypoint pre-seeds manager dir (in `~/.claude/.claude.json`) + each registered worker dir (in own `<dir>/.claudecfg/.claude.json`, and manager's). Dangerous-settings disclosure ("folder pre-approves N tool permissions") = consent NOT persisted → re-prompts every start, blocks TUI before RC activates (looks like dead worker in app).
- Trigger: dangerous allow-patterns in project `.claude/settings.json` (e.g. `Bash(rm -rf ...)`). Keep them out.
- `bin/_trust-guard <session> [timeout]` answers it; entrypoint step 11 + `spawn-worker`/`resume-worker` call it. Step 11 skipped when I reconcile → helpers MUST (req 6). No-op when no dialog up.
- CLI self-update swaps binary, kills running sessions → entrypoint sets `DISABLE_AUTOUPDATER=1`. Update = rebuild image. Check `~/.claude/.last-update-result.json`.
