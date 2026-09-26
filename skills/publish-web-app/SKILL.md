---
name: publish-web-app
description: >
  Publish static HTML or a live web app (FastAPI/uvicorn, Streamlit, dashboards) online through
  the pod's shared caddy at https://$CLAUDE_WEB_HOST/<name>/, and keep app servers running under
  runit so they survive crashes and pod restarts. Use when asked to publish, share, host or expose
  HTML, a report, a dashboard or a web app, to run a server that must stay up, or to password-protect
  published content.
---

One shared caddy serves ONLY `~/workspaces/.public/` (symlinks) + snippets in `~/workspaces/caddy.d/`.
Rest of `~/workspaces` private. Everything inside a published dir is public → only public-safe files.
URL base: `https://$CLAUDE_WEB_HOST/` (compose: `http://localhost:8080/`).

## Static files
- `webshare add <name> <dir>` → `/<name>/`. `webshare list`, `webshare rm <name>`.
- Publish a dedicated subdir (e.g. `<proj>/public`), never repo root.

## Live app
Two parts: runit keeps process up; caddy snippet routes to it.

### 1. runit service
`runsvdir` (started by entrypoint) watches `$SVDIR` = `~/workspaces/.sv` (PVC). Service = subdir
with executable `run`. runsvdir picks new dir up within ~5s by itself (no register command), starts
it on every boot, restarts it on crash.
- `run`: `#!/bin/sh`, `exec 2>&1`, `cd` into project, then `exec <server cmd>` (e.g.
  `exec uv run uvicorn app:app --port <PORT>`). Must `exec` → runit signals server directly, no
  stray procs. `uv run` syncs `.venv` itself.
- Logs (optional, rotated): `log/run` = `#!/bin/sh` + `exec svlogd -tt ./main`, plus `mkdir log/main`
  → `$SVDIR/<name>/log/main/current`. Without it, output goes nowhere.
- `chmod +x` both scripts.
- Health: own call. Probe route (curl localhost port or public URL) with timeout fitting app (cold
  `uv sync` can take minutes). Not up → read log, fix `run`.
- Control: `sv status|restart|down|up <name>`; stubborn → `sv force-restart <name>`. `sv` errors
  (`unable to open supervise/ok`) until runsvdir has picked dir up.
- Keep down across boots: `touch $SVDIR/<name>/down`.
- Remove: `sv down <name>`, `mv $SVDIR/<name> $SVDIR/.<name>` (runsvdir skips dot-dirs), `rm -rf` it.

### 2. caddy route
`~/workspaces/caddy.d/<name>.caddy`:
```
handle_path /<name>/* { reverse_proxy localhost:<PORT> }
```
then `caddy reload --config ~/workspaces/Caddyfile`. Live Caddyfile regenerated each start → edit
snippets only. App needing absolute asset paths → own hostname (chart `web.extraHosts`) instead of subpath.

## Password gate (all caddy content)
`webshare-auth set <password>` (user `admin`, live reload), `webshare-auth off`, `webshare-auth status`.
Writes `caddy.d/00-auth.caddy` on PVC. Password never in git.
