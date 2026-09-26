# claude-cli-cloud-run

Batteries-included [Claude Code](https://code.claude.com/docs) environment. Same image, same behaviour in Docker and Kubernetes (Helm). Starts authenticated Claude Code in detached remote-control session: orchestrates multi-agent work, publishes to web, talks to Slack + YouTrack. Built for unattended cloud: survives restarts, resumes workers, rebuilds state from files not chat. Drive from Claude app, phone, or SSH.

## What's in the box

- **Claude Code (native build)** + `uv`, Rust, `gh`, `jq`, `tmux`, `caddy`, `openssh`. No Node.
- **Autostarting orchestrator** — long-lived `claude --remote-control` session, coordinates **workers** (one per repo).
- **Survives restarts** — workers resume conversations; orchestrator starts fresh, re-derives state from worker registry, `AGENTS.md`, SessionStart hooks.
- **Web publishing** — `caddy` serves chosen dirs; k8s Ingress + cert-manager → `https://<you>.<zone>/...` via `webshare add`.
- **Integrations** — node-free *caveman* token-compression mode, *Slack channel-monitoring* skill, *YouTrack* issues (MCP) + knowledge base (REST helper).
- **Rootless + GPU-ready** — unprivileged user; GPU via Helm values.
- **Persistent** — repos, Claude state, gh auth, SSH keys on volume.

---

## Quick start for an LLM agent

Hand repo to Claude Code agent. Prompts:

- **Deploy locally:**
  > "Read `README.md` and `docker-compose.yml`. Build and run this locally with Docker Compose. Put my SSH public key in `AUTHORIZED_KEYS` and the contents of my `~/.claude/.credentials.json` into `CLAUDE_CREDENTIALS_JSON` in `.env`, then `docker compose up -d --build` and confirm the orchestrator session is live."
- **Deploy to Kubernetes:**
  > "Deploy the Helm chart in `k8s/helm/claude-cli` to namespace `<ns>`. Copy `values.example.yaml` to `values.yaml`, fill `auth.authorizedKeys` with my key and `auth.credentialsJson` from my local `~/.claude/.credentials.json`, set `youtrack.host` if I use YouTrack, then `helm upgrade --install`."
- **Understand it:**
  > "Explain the orchestrator/worker model in this repo and what happens to each on a pod restart."
- **Use a feature:**
  > "From a worker project, publish its `public/` folder on the web." / "Set up a Slack monitor for channel `#foo` tied to project `~/workspaces/bar`."

---

## Quickstart (manual)

### Local — Docker Compose

```bash
cp .env.example .env          # fill AUTHORIZED_KEYS, CLAUDE_CREDENTIALS_JSON, tokens
docker compose up -d --build
ssh -p 2222 claude@localhost  # web server on http://localhost:8080
```

### Kubernetes — Helm

```bash
cp k8s/helm/claude-cli/values.example.yaml k8s/helm/claude-cli/values.yaml
# edit values.yaml: auth.authorizedKeys, auth.credentialsJson, youtrack.host, web.host, gpu, ...
helm upgrade --install claude k8s/helm/claude-cli -n <ns> -f k8s/helm/claude-cli/values.yaml
```

Service is `ClusterIP` by default. SSH: `kubectl -n <ns> port-forward svc/claude-claude-cli-ssh 2222:2222`, or `kubectl exec`. Web: chart Ingress (see [Web publishing](#web-publishing)).

> Image = single source of truth. Helm chart authoritative for behaviour; `docker-compose.yml` mirrors it (env, volumes, shm, ports); shared `entrypoint.sh` does per-start setup in both.

---

## Authentication — log in locally first

Container uses your **Claude account OAuth credentials** (Max/Pro). Headless container can't do interactive login:

1. Log in with `claude` on own machine.
2. Copy `~/.claude/.credentials.json` contents into deployment:
   - **Docker:** `CLAUDE_CREDENTIALS_JSON=...` in `.env`
   - **Helm:** `auth.credentialsJson: |- ...` in `values.yaml` (or pre-made Secret via `auth.existingSecret`)
3. First start: entrypoint writes it to `~/.claude/.credentials.json` on volume; CLI then owns + refreshes token in place. Re-seeded only when your value changes (hash-tracked), so in-container rotation kept.

```bash
cat ~/.claude/.credentials.json
```

Token stale (e.g. refresh token rotated by login elsewhere) → update `CLAUDE_CREDENTIALS_JSON` / `auth.credentialsJson`, restart. Force re-seed: delete `~/.claude/.credentials.json` on volume, restart.

---

## Secrets & configuration

| | Docker | Kubernetes |
|---|---|---|
| Where you fill secrets | `.env` (gitignored) | `values.yaml` (gitignored) → rendered into a Secret, **or** `auth.existingSecret` (SOPS / sealed-secrets / ESO) |
| SSH key | `AUTHORIZED_KEYS` | `auth.authorizedKeys` |
| Claude creds | `CLAUDE_CREDENTIALS_JSON` | `auth.credentialsJson` |
| GitHub / HF / YouTrack | `GH_TOKEN` / `HF_TOKEN` / `YT_TOKEN` | `auth.ghToken` / `auth.hfToken` / `auth.ytToken` |

- `.env`, `k8s/helm/claude-cli/values.yaml`, `container_mounts/` gitignored — real secrets there; commit only `values.example.yaml` / `.env.example`.
- YouTrack token stored redacted by `claude mcp add` in `~/.claude.json`, sent as Bearer header.
- Slack uses **account-level claude.ai connector** (enabled on your Claude account), no token in repo.

---

## Orchestrator / worker model

One **orchestrator** (manager) coordinates many **workers** (one per repo).

- **Orchestrator** — autostarted tmux session `claude` running `claude --remote-control "<name>"`. **Fresh on every restart** (no `--continue`); no durable chat state, rebuilds from files. Coordinates only, never edits project code. Instructions: `k8s/helm/claude-cli/files/AGENTS.md`.
- **Workers** — one per repo under `~/workspaces/<name>`, own tmux session + remote-control URL + private config dir `<dir>/.claudecfg`. Stateful → resumed by session id on restart.
- **Helpers** (`~/workspaces/bin`, on `PATH`; source `worker-tools/`, seeded if missing): `spawn-worker`, `resume-worker`, `tell-worker`, `read-worker`, `list-workers`, `kill-worker`. Registry `~/workspaces/.workers.json` = worker name set.

### Restarts & hooks

- Entrypoint resumes every registered worker session on restart (token-free).
- **Manager-only `SessionStart` hook** (`manager-startup.sh`, guarded so workers never see it) injects `AGENTS.md` into orchestrator + tells it to tend resumed workers: read each pane, answer "resume from summary?" picker (*as-is* if interrupted, *summary* if clean), continue only interrupted work.
- Hook, not workspace `CLAUDE.md`: `CLAUDE.md` loads from every parent dir → would leak orchestrator role into workers. Hook scoped to manager's exact cwd.

### Communication

- **Human ↔ agent:** each session's `claude.ai/code/session_…` remote-control URL (web/phone), listed in your Claude sessions.
- **Manager ↔ worker:** `tell-worker <name> "<msg>"` (keystrokes to worker's tmux pane); `read-worker <name>` reads its screen.
- **Worker → manager (durable):** workers append to notes/task files in project; orchestrator polls. Nothing important lives only in chat.

---

## Skills

Baked in, seeded into `~/.claude/skills/` on start:

- **caveman** — ultra-compressed output mode, cuts tokens, keeps technical accuracy. Node-free. On by default; toggle `/caveman lite|full|ultra|off`.
- **enable-slack-channel-monitoring** — registers scheduled monitor for one Slack channel tied to one project dir: renders per-channel `SLACK_CRON.md` + cron prompt, records in registry, creates recurring in-session cron that spawns Slack-reading subagent each tick. **Needs Slack connector enabled on Claude account.**
- **youtrack** — issues/projects via official **YouTrack MCP** (auto-configured when `youtrack.host` + token set); knowledge-base articles via REST with bundled `youtrack-kb` helper (MCP has no article tools).

---

## Web publishing

One shared `caddy` publishes selected dirs — never whole workspace.

- Static HTML folder:
  ```bash
  webshare add myviz ~/workspaces/myproject/public   #  ->  https://<host>/myviz/
  webshare list        # show published locations
  webshare rm myviz    # unpublish
  ```
  `webshare` symlinks dir under `~/workspaces/.public/` — the **only** thing caddy serves. Put only public-safe files in published dir.
- Live app on port (e.g. Streamlit `:8501`): snippet in `~/workspaces/caddy.d/<name>.caddy`:
  ```
  handle_path /myapp/* { reverse_proxy localhost:8501 }
  ```
  then `caddy reload --config ~/workspaces/Caddyfile`. Apps with absolute asset paths may need own hostname via `web.extraHosts` instead of subpath.
- **Docker:** `caddy` on `:8080` (published to `localhost:8080`).
- **Kubernetes:** `web.enabled: true` + `web.host: <name>.<zone>` → chart creates Service + Ingress, cert-manager issues TLS; reachable at `https://<web.host>/...` over IPv4 + IPv6.

---

## Other details

- **PATH** — `~/workspaces/bin` on `PATH` automatically (image env + login profile).
- **Persistence** — PVC (k8s) / `container_mounts/` (compose): `~/workspaces`, `~/.claude` (+`.claude.json`), `~/.config/gh`, `~/.ssh`. Rest (rootfs, tmux/claude processes, `~/.bashrc`) ephemeral, rebuilt on start.
- **`/dev/shm`** — 16 GiB default (`shmSize` / `shm_size`) for PyTorch-style workloads; counts against memory limit.
- **GPU (k8s)** — uncomment `gpu:` in values (`A100|A40|H100|Tesla P100|mig-*`); chart sets resource limits + node selector.
- **MCP tools load at session start** — entrypoint configures them before launching orchestrator. New MCP config → new session (or fresh SSH session) needed.

---

## File reference

| File | Purpose |
|------|---------|
| [`claude.Dockerfile`](claude.Dockerfile) | Image (Claude Code + tools + skills + hooks). |
| [`entrypoint.sh`](entrypoint.sh) | Per-start setup, shared by Docker and k8s. |
| [`docker-compose.yml`](docker-compose.yml) / [`.env.example`](.env.example) | Local deployment + config. |
| [`k8s/helm/claude-cli/`](k8s/helm/claude-cli/) | Helm chart (authoritative); `values.example.yaml` documents every option. |
| [`k8s/helm/claude-cli/files/AGENTS.md`](k8s/helm/claude-cli/files/AGENTS.md) | Orchestrator operating instructions. |
| `skills/`, `caddy/`, `slack-monitor/`, `youtrack/`, `caveman/`, `manager-startup.sh` | Baked-in skills, web server config, integrations. |

Config files carry inline comments for every option.
