#!/bin/sh
# Container entrypoint. Runs as unprivileged `claude` user. Idempotent.
#  1. Generate ed25519 SSH host key into ~/.ssh/host-keys if missing (ephemeral).
#  2. Hydrate ~/.ssh/authorized_keys from $AUTHORIZED_KEYS (additive + deduped).
#  3. Export GH_TOKEN / HF_TOKEN to ~/.claude-env for SSH-spawned shells.
#  4. gh auth login if $GH_TOKEN set and not already authenticated.
#  5. Pre-accept the workspace trust dialog for ~/workspaces in ~/.claude.json.
#  6. Seed agent skills + orchestrator AGENTS.md from the image (single source
#     for docker compose and k8s).
#  7. Wire node-free caveman hooks into ~/.claude/settings.json (disable plugin).
#  8. Configure optional integrations: YouTrack MCP (if host+token) and the Slack
#     channel-monitoring tools + cron-reminder hook.
#  9. Optionally start caddy web server ($CLAUDE_WEB_ENABLED) to share viz.
# 10. Spawn detached tmux session if $CLAUDE_AUTOSTART_CLAUDE_COMMAND set.
# 11. exec CMD (sshd -D -e by default).
set -eu

CLAUDE_HOME=/home/claude
SSH_KEYDIR="$CLAUDE_HOME/.ssh/host-keys"
AUTH_KEYS_FILE="$CLAUDE_HOME/.ssh/authorized_keys"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# 1. SSH host key (ed25519)
mkdir -p "$SSH_KEYDIR"
chmod 700 "$SSH_KEYDIR"
HOST_KEY="$SSH_KEYDIR/ssh_host_ed25519_key"
if [ ! -f "$HOST_KEY" ]; then
    log "generating SSH host key: ed25519"
    ssh-keygen -t ed25519 -f "$HOST_KEY" -N '' -q
fi
chmod 600 "$HOST_KEY"
[ -f "$HOST_KEY.pub" ] && chmod 644 "$HOST_KEY.pub"

# 2. authorized_keys (additive + deduped)
mkdir -p "$CLAUDE_HOME/.ssh"
chmod 700 "$CLAUDE_HOME/.ssh"
touch "$AUTH_KEYS_FILE"

if [ -n "${AUTHORIZED_KEYS:-}" ]; then
    log "merging \$AUTHORIZED_KEYS into authorized_keys"
    printf '%s\n' "$AUTHORIZED_KEYS" >> "$AUTH_KEYS_FILE"
    awk 'NF && !seen[$0]++' "$AUTH_KEYS_FILE" > "$AUTH_KEYS_FILE.tmp"
    mv "$AUTH_KEYS_FILE.tmp" "$AUTH_KEYS_FILE"
fi

chmod 600 "$AUTH_KEYS_FILE"

if [ ! -s "$AUTH_KEYS_FILE" ]; then
    log "WARNING: authorized_keys is empty. Set AUTHORIZED_KEYS in .env."
fi

# 3. Export tokens to SSH login shells (sshd-forked sessions don't inherit PID 1 env).
ENV_FILE="$CLAUDE_HOME/.claude-env"
: > "$ENV_FILE"
chmod 600 "$ENV_FILE"
write_export() {
    name="$1"
    eval "val=\${$name:-}"
    [ -n "$val" ] || return 0
    esc=$(printf '%s' "$val" | sed "s/'/'\\\\''/g")
    printf "export %s='%s'\n" "$name" "$esc" >> "$ENV_FILE"
}
write_export GH_TOKEN
write_export HF_TOKEN

# 4. GitHub CLI auth
if [ -n "${GH_TOKEN:-}" ]; then
    if gh auth status >/dev/null 2>&1; then
        log "gh already authenticated (via mounted state)"
    else
        log "gh: logging in with GH_TOKEN"
        printf '%s\n' "$GH_TOKEN" | gh auth login --with-token || \
            log "WARNING: gh auth login --with-token failed (bad token? offline?)"
    fi
    gh auth setup-git >/dev/null 2>&1 || true
fi

# 5. Pre-accept the workspace trust dialog for the autostart working dir.
#    Trust is a separate boundary from --dangerously-skip-permissions and has
#    no settings/env bypass; the only non-interactive route is the per-project
#    flag in the user-level ~/.claude.json. Idempotent jq merge — auto-vivifies
#    the nesting and runs before claude launches, so the TUI never prompts.
CLAUDE_JSON="$CLAUDE_HOME/.claude.json"
WORKDIR="$CLAUDE_HOME/workspaces"
[ -s "$CLAUDE_JSON" ] || printf '{}\n' > "$CLAUDE_JSON"
# Write in place (cat >) rather than mv: ~/.claude.json is a subPath bind-mount,
# so renaming over it fails with "Device or resource busy".
tmp=$(mktemp)
if jq --arg d "$WORKDIR" \
      '.projects[$d].hasTrustDialogAccepted = true' "$CLAUDE_JSON" > "$tmp"; then
    cat "$tmp" > "$CLAUDE_JSON"
    log "trust dialog pre-accepted for $WORKDIR"
else
    log "WARNING: could not pre-accept trust dialog (jq failed?)"
fi
rm -f "$tmp"

# 6. Seed agent skills + the orchestrator AGENTS.md from the image. Baking these
#    (rather than k8s ConfigMaps) keeps ONE source for both docker compose and
#    k8s. Add a skill = drop a dir under skills/ in the repo.
#    - Skills: overwrite every start (image is source of truth). User-authored
#      skills under other names in ~/.claude/skills are left untouched.
#    - AGENTS.md: seed only if absent (the manager edits it in-session; don't
#      clobber). Pair it with a CLAUDE.md that @-imports it — claude loads
#      CLAUDE.md, not AGENTS.md.
SKILLSRC=/usr/local/share/claude-skills
if [ -d "$SKILLSRC" ]; then
    mkdir -p "$CLAUDE_HOME/.claude/skills"
    for d in "$SKILLSRC"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        rm -rf "$CLAUDE_HOME/.claude/skills/$name"
        cp -r "$d" "$CLAUDE_HOME/.claude/skills/$name"
    done
    log "seeded skills: $(ls "$SKILLSRC" 2>/dev/null | tr '\n' ' ')"
fi
if [ -f /usr/local/share/claude/AGENTS.md ]; then
    mkdir -p "$CLAUDE_HOME/workspaces"
    [ -e "$CLAUDE_HOME/workspaces/AGENTS.md" ] || cp /usr/local/share/claude/AGENTS.md "$CLAUDE_HOME/workspaces/AGENTS.md"
    [ -e "$CLAUDE_HOME/workspaces/CLAUDE.md" ] || printf '@AGENTS.md\n' > "$CLAUDE_HOME/workspaces/CLAUDE.md"
fi

# 7. Node-free caveman. The upstream caveman plugin's hooks shell out to `node`,
#    which is not installed (native claude needs no Node) — so they error on
#    every session start / prompt. Disable the plugin and wire our vendored
#    POSIX-sh hooks (/usr/local/lib/caveman) into settings.json instead. The
#    /caveman skill itself is seeded by the generic loop in step 6.
CAVE=/usr/local/lib/caveman
SETTINGS="$CLAUDE_HOME/.claude/settings.json"
if [ -x "$CAVE/caveman-activate.sh" ]; then
    mkdir -p "$CLAUDE_HOME/.claude"
    [ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    tmp=$(mktemp)
    if jq --arg act "$CAVE/caveman-activate.sh" --arg trk "$CAVE/caveman-tracker.sh" '
        .enabledPlugins["caveman@caveman"] = false
        | .hooks.SessionStart = (.hooks.SessionStart // [])
        | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
        | (if any(.hooks.SessionStart[].hooks[]?; .command == $act) then .
           else .hooks.SessionStart += [{hooks:[{type:"command",command:$act,timeout:5}]}] end)
        | (if any(.hooks.UserPromptSubmit[].hooks[]?; .command == $trk) then .
           else .hooks.UserPromptSubmit += [{hooks:[{type:"command",command:$trk,timeout:5}]}] end)
        ' "$SETTINGS" > "$tmp"; then
        cat "$tmp" > "$SETTINGS"
        log "caveman: node-free hooks wired, node plugin disabled"
    else
        log "WARNING: caveman settings merge failed (jq?)"
    fi
    rm -f "$tmp"
fi

# 8. Optional MCP servers + integrations. Sessions load MCP tools on start, so
#    configuring here (before the autostart claude) is enough — no restart needed.

# 8a. YouTrack MCP — only if both host and token are provided. Re-add idempotently.
if [ -n "${YT_HOST:-}" ] && [ -n "${YT_TOKEN:-}" ]; then
    claude mcp remove -s user youtrack >/dev/null 2>&1 || true
    if claude mcp add -s user -t http youtrack "${YT_HOST%/}/mcp" \
            -H "Authorization: Bearer $YT_TOKEN" >/dev/null 2>&1; then
        log "youtrack MCP configured (${YT_HOST%/})"
    else
        log "WARNING: youtrack mcp add failed"
    fi
fi

# 8b. Slack channel-monitoring tooling (always installed — harmless when unused).
#     The Slack MCP itself is an account-level claude.ai connector (cannot be
#     baked). The enable-slack-channel-monitoring skill is the real toggle; this
#     just installs the generic tools + the manager-only cron-reminder hook,
#     which is registry-driven and stays silent until a monitor is registered.
SLACKLIB=/usr/local/lib/slack-monitor
if [ -d "$SLACKLIB" ]; then
    mkdir -p "$CLAUDE_HOME/workspaces/bin"
    cp "$SLACKLIB/slack-lock" "$CLAUDE_HOME/workspaces/bin/slack-lock" 2>/dev/null || true
    cp "$SLACKLIB/slack-cron-reminder.sh" "$CLAUDE_HOME/workspaces/bin/_slack-cron-reminder.sh" 2>/dev/null || true
    chmod 0755 "$CLAUDE_HOME/workspaces/bin/slack-lock" "$CLAUDE_HOME/workspaces/bin/_slack-cron-reminder.sh" 2>/dev/null || true
    # Install the manager-only cron-reminder as a SessionStart hook (idempotent).
    REMINDER="$CLAUDE_HOME/workspaces/bin/_slack-cron-reminder.sh"
    [ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    tmp=$(mktemp)
    if jq --arg cmd "$REMINDER" '
        .hooks.SessionStart = (.hooks.SessionStart // [])
        | (if any(.hooks.SessionStart[].hooks[]?; .command == $cmd) then .
           else .hooks.SessionStart += [{hooks:[{type:"command",command:$cmd,timeout:5}]}] end)
        ' "$SETTINGS" > "$tmp"; then
        cat "$tmp" > "$SETTINGS"
        log "slack monitor: tools + cron-reminder hook installed"
    else
        log "WARNING: slack cron-reminder hook merge failed (jq?)"
    fi
    rm -f "$tmp"
fi

# 9. Optional web server (caddy) to share HTML from ~/workspaces over the cluster
#    Ingress. Gated on $CLAUDE_WEB_ENABLED. caddy serves ONLY ~/workspaces/.public
#    (symlinks managed by `webshare`) + optional ~/workspaces/caddy.d/*.caddy
#    snippets — never the whole tree. The Caddyfile is managed (overwritten each
#    start); publish via `webshare add <name> <dir>`, not by editing it.
if [ "${CLAUDE_WEB_ENABLED:-false}" = "true" ] && command -v caddy >/dev/null 2>&1; then
    CADDYFILE="$CLAUDE_HOME/workspaces/Caddyfile"
    CADDYLOG="$CLAUDE_HOME/workspaces/.caddy.log"
    mkdir -p "$CLAUDE_HOME/workspaces/.public" "$CLAUDE_HOME/workspaces/caddy.d"
    cp /usr/local/share/caddy/Caddyfile.default "$CADDYFILE" 2>/dev/null || true
    # Plain background daemon (NOT a tmux session — caddy is a server, not an
    # agent). setsid detaches it so it survives `exec "$@"`. Logs to .caddy.log.
    # Reload after editing caddy.d: `caddy reload --config ~/workspaces/Caddyfile`.
    log "starting caddy daemon on :8080 (serving ~/workspaces/.public; logs $CADDYLOG)"
    setsid sh -c "exec caddy run --config '$CADDYFILE' --adapter caddyfile >'$CADDYLOG' 2>&1" </dev/null >/dev/null 2>&1 &
fi

# 10. Optional detached tmux session running claude. Attach via SSH:
#      tmux attach -t "$CLAUDE_AUTOSTART_TMUX_SESSION_NAME"
if [ -n "${CLAUDE_AUTOSTART_CLAUDE_COMMAND:-}" ]; then
    TMUX_SESSION_NAME="${CLAUDE_AUTOSTART_TMUX_SESSION_NAME:-claude}"
    # Wait for outbound connectivity before launching. At pod boot the CNI/DNS/
    # egress can lag a few seconds; claude's remote-control connection does NOT
    # retry if its first attempt fails, so launching too early leaves a live but
    # disconnected session. Poll claude.ai until any HTTP response (DNS+TCP+TLS
    # all working) before starting, up to ~30s.
    n=0
    while [ "$n" -lt 30 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 https://claude.ai 2>/dev/null || true)
        [ "$code" != "000" ] && [ -n "$code" ] && break
        n=$((n + 1))
        sleep 1
    done
    log "network ready after ${n}s (claude.ai HTTP ${code:-none}); starting tmux '$TMUX_SESSION_NAME'"
    tmux new-session -d -s "$TMUX_SESSION_NAME" -c "$CLAUDE_HOME/workspaces" "$CLAUDE_AUTOSTART_CLAUDE_COMMAND" \
        || log "WARNING: tmux session start failed"
fi

# 11. Hand off to CMD.
exec "$@"
