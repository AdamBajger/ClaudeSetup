# claude-cli-cloud-run

A pre-built, batteries-included [Claude Code](https://code.claude.com/docs) environment you can run locally with Docker or in Kubernetes with Helm — **the same image, behaving the same way in both**. Spin it up, and you get an authenticated Claude Code that starts itself in a detached, remote-controllable session, ready to orchestrate multi-agent work, publish results on the web, and talk to Slack and YouTrack.

It's designed to run unattended in the cloud: it survives restarts, resumes its workers, and rebuilds its state from files rather than chat history — while you drive it from the Claude app, your phone, or over SSH.

## What's in the box

- **Claude Code (native build)** + `uv`, Rust, `gh`, `jq`, `tmux`, `caddy`, `openssh` — baked in, no Node required.
- **Autostarting orchestrator** — a long-lived `claude --remote-control` session that comes up on every start and coordinates **worker agents** (one per repo).
- **Survives restarts** — workers auto-resume their conversations; the orchestrator comes up fresh and re-derives state from the worker registry, `AGENTS.md`, and SessionStart hooks.
- **Web publishing** — `caddy` serves chosen directories; in k8s an Ingress + cert-manager give you `https://<you>.<zone>/...` with one command (`webshare add`).
- **Pluggable integrations** — a node-free *caveman* token-compression mode, a *Slack channel-monitoring* skill, and *YouTrack* issues (MCP) + knowledge-base (REST helper).
- **Rootless + GPU-ready** — runs as an unprivileged user; request a GPU in the Helm values.
- **Persistent** — your repos, Claude state, gh auth, and SSH keys live on a volume and survive recreates.

---

## Quick start for an LLM agent

Hand this repo to a Claude Code agent and let it do the work. Useful prompts:

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

The Service is `ClusterIP` by default — reach SSH with `kubectl -n <ns> port-forward svc/claude-claude-cli-ssh 2222:2222`, or just `kubectl exec`. Expose the web server via the chart's Ingress (see [Web publishing](#web-publishing)).

> The image is the **single source of truth** for both paths. The Helm chart is authoritative for behaviour; `docker-compose.yml` mirrors it (same env, volumes, shm, ports) and the shared `entrypoint.sh` does the per-start setup in both.

---

## Authentication — you must log in locally first

Claude Code in the container authenticates with your **Claude account OAuth credentials** (Max/Pro). A headless container **cannot** complete an interactive login, so:

1. **Authenticate Claude Code on your own machine** (`claude`, log in once).
2. Copy the contents of `~/.claude/.credentials.json` into the deployment:
   - **Docker:** `CLAUDE_CREDENTIALS_JSON=...` in `.env`
   - **Helm:** `auth.credentialsJson: |- ...` in `values.yaml` (or provide a pre-made Secret via `auth.existingSecret`)
3. On first start the entrypoint writes it to `~/.claude/.credentials.json` on the persistent volume; **the CLI then owns and refreshes the token in place**. It's only re-seeded from your value if that value changes (tracked by a hash), so in-container rotation is preserved.

Get the value with:

```bash
cat ~/.claude/.credentials.json
```

If the deployed token ever goes stale (e.g. you logged in elsewhere and the refresh token rotated), update `CLAUDE_CREDENTIALS_JSON` / `auth.credentialsJson` and restart.

---

## Secrets & configuration

| | Docker | Kubernetes |
|---|---|---|
| Where you fill secrets | `.env` (gitignored) | `values.yaml` (gitignored) → rendered into a Secret, **or** `auth.existingSecret` (SOPS / sealed-secrets / ESO) |
| SSH key | `AUTHORIZED_KEYS` | `auth.authorizedKeys` |
| Claude creds | `CLAUDE_CREDENTIALS_JSON` | `auth.credentialsJson` |
| GitHub / HF / YouTrack | `GH_TOKEN` / `HF_TOKEN` / `YT_TOKEN` | `auth.ghToken` / `auth.hfToken` / `auth.ytToken` |

- `.env`, `k8s/helm/claude-cli/values.yaml`, and `container_mounts/` are **gitignored** — keep real secrets there; commit `values.example.yaml` / `.env.example` only.
- The YouTrack token is stored redacted by `claude mcp add` in `~/.claude.json` and sent as a Bearer header.
- The Slack integration uses an **account-level claude.ai connector** (enabled on your Claude account), not a token in this repo.

---

## Orchestrator / worker model

This is a **multi-agent** setup. One **orchestrator** (manager) coordinates many **workers** (one per repo).

- **Orchestrator** — the autostarted tmux session `claude`, running `claude --remote-control "<name>"`. It **starts fresh on every restart** (no `--continue`): it keeps no durable chat state and instead reconstructs everything from files. It coordinates; it does **not** edit project code itself. Its instructions live in `k8s/helm/claude-cli/files/AGENTS.md`.
- **Workers** — one per repo under `~/workspaces/<name>`, each its own tmux session + remote-control URL. Their project work **is** stateful, so they resume (`-c`) on restart.
- **Helpers** (in `~/workspaces/bin`, automatically on `PATH`): `spawn-worker`, `resume-worker`, `tell-worker`, `read-worker`, `list-workers`, `kill-worker`. The registry `~/workspaces/.workers.json` records each worker's dir/repo/session.

### Restarts, hooks & reminders

- On restart the **entrypoint** resumes every registered worker's session (token-free).
- A **manager-only `SessionStart` hook** (`manager-startup.sh`, guarded so workers never see it) injects `AGENTS.md` into the orchestrator and tells it to **tend the resumed workers**: read each pane, answer the "resume from summary?" picker (full *as-is* if work was interrupted, *summary* if clean), and only continue work that was actually interrupted.
- Why a hook instead of a `CLAUDE.md`: Claude loads `CLAUDE.md` from every parent directory, so a `CLAUDE.md` at the workspace root would leak the orchestrator role into every worker. The hook is scoped to the manager's exact working directory.

### Communication

- **Human ↔ agent:** the `claude.ai/code/session_…` remote-control URL of each session (drive from web/phone). Find them in your Claude session list.
- **Manager ↔ worker:** `tell-worker <name> "<msg>"` (sends keystrokes to the worker's tmux pane); `read-worker <name>` to read its screen.
- **Worker → manager (durable):** workers append to notes/task files in their project (the orchestrator polls them) — nothing important should live only in chat.

---

## Skills

Baked into the image and seeded into `~/.claude/skills/` on start:

- **caveman** — ultra-compressed "smart caveman" output mode that cuts tokens while keeping technical accuracy. A node-free reimplementation (the upstream plugin needs Node; this doesn't). On by default; toggle with `/caveman lite|full|ultra|off`.
- **enable-slack-channel-monitoring** — registers an autonomous, scheduled monitor for one Slack channel tied to one project directory: it renders a per-channel `SLACK_CRON.md` + cron prompt, records it in a registry, and creates the recurring in-session cron that spawns a Slack-reading subagent each tick. **Requires the Slack connector to be enabled on your Claude account.** The monitor is scoped to its one channel/project.
- **youtrack** — teaches the agent to use **YouTrack issues/projects via the official MCP** (configured automatically when `youtrack.host` + a token are set) and **knowledge-base articles via REST** using the bundled `youtrack-kb` helper. Articles are done over REST because the YouTrack MCP currently ships **no article tools**; when YouTrack adds them, the `youtrack-kb` helper can be retired in favour of the MCP.

---

## Web publishing

One shared `caddy` server publishes selected directories — never your whole workspace.

- Publish a folder of static HTML:
  ```bash
  webshare add myviz ~/workspaces/myproject/public   #  ->  https://<host>/myviz/
  webshare list        # show published locations
  webshare rm myviz    # unpublish
  ```
  `webshare` symlinks the dir under `~/workspaces/.public/`, which is the **only** thing caddy serves — the rest of `~/workspaces` stays private. Only put public-safe files in a published dir.
- Proxy a live app on a port (e.g. Streamlit on `:8501`): drop a snippet in `~/workspaces/caddy.d/<name>.caddy`:
  ```
  handle_path /myapp/* { reverse_proxy localhost:8501 }
  ```
  then `caddy reload --config ~/workspaces/Caddyfile`. (Apps with absolute asset paths may need their own hostname via `web.extraHosts` instead of a subpath.)
- **Docker:** `caddy` listens on `:8080` (published to `localhost:8080`).
- **Kubernetes:** set `web.enabled: true` + `web.host: <name>.<zone>`; the chart creates a Service + Ingress and cert-manager issues TLS, so it's reachable at `https://<web.host>/...` over IPv4 and IPv6.

---

## Other details worth knowing

- **PATH** — `~/workspaces/bin` is on `PATH` automatically (image env + login profile); no manual `export` needed.
- **Persistence** — on the PVC (k8s) / under `container_mounts/` (compose): `~/workspaces`, `~/.claude` (+`.claude.json`), `~/.config/gh`, `~/.ssh`. Everything else (the rootfs, tmux/claude processes, `~/.bashrc`) is ephemeral and rebuilt on start.
- **`/dev/shm`** — raised to 16 GiB by default (`shmSize` / `shm_size`) for PyTorch-style workloads; it counts against the memory limit.
- **GPU (k8s)** — uncomment `gpu:` in values (`A100|A40|H100|Tesla P100|mig-*`); the chart sets the right resource limits + node selector.
- **MCP tools load at session start** — the entrypoint configures them before launching the orchestrator, so a manual session restart isn't needed; a *new* session (or a fresh SSH session) is.
- **Resetting Claude creds on the volume:** delete `~/.claude/.credentials.json` and restart to re-seed from your configured value.

---

## File reference

| File | Purpose |
|------|---------|
| [`claude.Dockerfile`](claude.Dockerfile) | The image (Claude Code + tools + skills + hooks). |
| [`entrypoint.sh`](entrypoint.sh) | Per-start setup, shared by Docker and k8s. |
| [`docker-compose.yml`](docker-compose.yml) / [`.env.example`](.env.example) | Local deployment + its config. |
| [`k8s/helm/claude-cli/`](k8s/helm/claude-cli/) | Helm chart (authoritative); `values.example.yaml` documents every option. |
| [`k8s/helm/claude-cli/files/AGENTS.md`](k8s/helm/claude-cli/files/AGENTS.md) | Orchestrator operating instructions. |
| `skills/`, `caddy/`, `slack-monitor/`, `youtrack/`, `caveman/`, `manager-startup.sh` | Baked-in skills, web server config, and integrations. |

All config files have inline comments explaining the options.
