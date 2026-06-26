#!/bin/sh
# Container entrypoint. Unprivileged `claude` user. Idempotent. Shared by docker
# compose and k8s. Steps:
#  0. Data bootstrap (compose parity w/ k8s init): dirs, .claude.json onboarding,
#     .bash_history, credentials from $CLAUDE_CREDENTIALS_JSON. Idempotent, only
#     re-seeds creds when $CLAUDE_CREDENTIALS_JSON changes (k8s leaves it unset,
#     seeds from Secret file).
#  1. ed25519 SSH host key (ephemeral).        7. Wire node-free caveman hooks.
#  2. authorized_keys from $AUTHORIZED_KEYS.   8. YouTrack MCP + Slack tooling.
#  3. Export GH/HF tokens for SSH shells.      9. caddy web server ($CLAUDE_WEB_ENABLED).
#  4. gh auth login.                          10. Autostart detached tmux claude.
#  5. Pre-accept workspace trust dialog.      11. Auto-resume registered workers.
#  6. Seed skills + orchestrator AGENTS.md.   12. exec CMD (sshd -D -e default).
set -eu

CLAUDE_HOME=/home/claude
SSH_KEYDIR="$CLAUDE_HOME/.ssh/host-keys"
AUTH_KEYS_FILE="$CLAUDE_HOME/.ssh/authorized_keys"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# 0. Data bootstrap
mkdir -p "$CLAUDE_HOME/.claude" "$CLAUDE_HOME/.config/gh" "$CLAUDE_HOME/workspaces"
CJSON="$CLAUDE_HOME/.claude.json"
if [ ! -s "$CJSON" ] || [ "$(cat "$CJSON" 2>/dev/null)" = '{}' ]; then
    printf '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.119"}\n' > "$CJSON"
fi
[ -e "$CLAUDE_HOME/.bash_history" ] || touch "$CLAUDE_HOME/.bash_history"
if [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]; then
    CREDS="$CLAUDE_HOME/.claude/.credentials.json"
    newhash=$(printf '%s' "$CLAUDE_CREDENTIALS_JSON" | md5sum | cut -d' ' -f1)
    oldhash=$(cat "$CLAUDE_HOME/.claude/.cred-bootstrap-hash" 2>/dev/null || true)
    if [ ! -e "$CREDS" ] || [ "$newhash" != "$oldhash" ]; then
        printf '%s' "$CLAUDE_CREDENTIALS_JSON" > "$CREDS"
        chmod 600 "$CREDS"
        printf '%s\n' "$newhash" > "$CLAUDE_HOME/.claude/.cred-bootstrap-hash"
        log "credentials bootstrapped from \$CLAUDE_CREDENTIALS_JSON"
    fi
fi

# 1. SSH host key
mkdir -p "$SSH_KEYDIR"
chmod 700 "$SSH_KEYDIR"
HOST_KEY="$SSH_KEYDIR/ssh_host_ed25519_key"
if [ ! -f "$HOST_KEY" ]; then
    log "generating SSH host key: ed25519"
    ssh-keygen -t ed25519 -f "$HOST_KEY" -N '' -q
fi
chmod 600 "$HOST_KEY"
[ -f "$HOST_KEY.pub" ] && chmod 644 "$HOST_KEY.pub"

# 2. authorized_keys
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

# 3. Export tokens to SSH login shells
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

# 5. Pre-accept the workspace trust dialog. Trust is separate from
#    --dangerously-skip-permissions with no env bypass; only route is the
#    per-project flag in ~/.claude.json. jq merge, runs before claude launches.
CLAUDE_JSON="$CLAUDE_HOME/.claude.json"
WORKDIR="$CLAUDE_HOME/workspaces"
[ -s "$CLAUDE_JSON" ] || printf '{}\n' > "$CLAUDE_JSON"
# Write in place (cat >) not mv: ~/.claude.json is a subPath bind-mount → rename
# fails "Device or resource busy".
tmp=$(mktemp)
if jq --arg d "$WORKDIR" \
      '.projects[$d].hasTrustDialogAccepted = true' "$CLAUDE_JSON" > "$tmp"; then
    cat "$tmp" > "$CLAUDE_JSON"
    log "trust dialog pre-accepted for $WORKDIR"
else
    log "WARNING: could not pre-accept trust dialog (jq failed?)"
fi
rm -f "$tmp"

# 6. Seed skills + orchestrator AGENTS.md from the image (one source for compose
#    and k8s; add a skill = drop a dir under skills/). Skills overwrite every
#    start (image is source of truth); user-authored skills under other names are
#    left untouched. AGENTS.md seeded only if absent (manager edits it in-session).
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
    # AGENTS.md goes into the MANAGER session only (manager-startup hook, cwd-guarded).
    # NO ~/workspaces/CLAUDE.md: claude loads it from every ANCESTOR dir → would leak
    # the orchestrator role into workers. Migrate away the stale managed @AGENTS.md.
    [ "$(cat "$CLAUDE_HOME/workspaces/CLAUDE.md" 2>/dev/null)" = "@AGENTS.md" ] && rm -f "$CLAUDE_HOME/workspaces/CLAUDE.md"
fi

# 6b. Wire the manager-startup SessionStart hook (cwd-guarded → inert in workers,
#     always safe to wire). For the manager: injects AGENTS.md + tend-workers prompt.
TEND=/usr/local/lib/claude-hooks/manager-startup.sh
SETTINGS="$CLAUDE_HOME/.claude/settings.json"
if [ -x "$TEND" ]; then
    mkdir -p "$CLAUDE_HOME/.claude"
    [ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    tmp=$(mktemp)
    if jq --arg cmd "$TEND" '
        .hooks.SessionStart = (.hooks.SessionStart // [])
        | (if any(.hooks.SessionStart[].hooks[]?; .command == $cmd) then .
           else .hooks.SessionStart += [{hooks:[{type:"command",command:$cmd,timeout:5}]}] end)
        ' "$SETTINGS" > "$tmp"; then
        cat "$tmp" > "$SETTINGS"
        log "manager-startup hook wired"
    else
        log "WARNING: manager-startup hook merge failed (jq?)"
    fi
    rm -f "$tmp"
fi

# 7. Node-free caveman. Upstream plugin hooks shell out to `node` (not installed,
#    native claude needs none) → error every session. Disable the plugin, wire our
#    POSIX-sh hooks instead. The /caveman skill is seeded by the step 6 loop.
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

# 8. Optional MCP + integrations. Sessions load MCP tools on start, so configuring
#    here (before the autostart claude) needs no restart.

# 8a. YouTrack MCP — only if both host and token set. Re-add idempotently.
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
#     Slack MCP itself is an account-level claude.ai connector (can't be baked).
#     The enable-slack-channel-monitoring skill is the toggle; this installs the
#     tools + a registry-driven cron-reminder hook that's silent until a monitor
#     is registered.
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

# 9. Optional caddy web server ($CLAUDE_WEB_ENABLED). Serves ONLY
#    ~/workspaces/.public (symlinks via `webshare`) + ~/workspaces/caddy.d/*.caddy
#    snippets — never the whole tree. The Caddyfile is GENERATED here each start
#    (publish via `webshare add <name> <dir>`); edit routing via caddy.d snippets,
#    not the Caddyfile.
#    Two modes, chosen by $CLAUDE_WEB_HOST:
#      - set   (k8s): public vhost, caddy auto-obtains a Let's Encrypt cert and
#                     terminates HTTPS on :443 (+ :80 redirect). Needs the
#                     NET_BIND_SERVICE cap + the file-cap baked on the binary.
#      - unset (compose/local): plain HTTP on :8080 (no public host to certify).
#    Cert + ACME-account storage lives on the PVC ($CADDYDATA) so renewals
#    survive restarts and we don't re-hit Let's Encrypt rate limits.
if [ "${CLAUDE_WEB_ENABLED:-false}" = "true" ] && command -v caddy >/dev/null 2>&1; then
    CADDYFILE="$CLAUDE_HOME/workspaces/Caddyfile"
    CADDYLOG="$CLAUDE_HOME/workspaces/.caddy.log"
    CADDYDATA="$CLAUDE_HOME/workspaces/.caddy"
    PUBROOT="$CLAUDE_HOME/workspaces/.public"
    mkdir -p "$PUBROOT" "$CLAUDE_HOME/workspaces/caddy.d" "$CADDYDATA"
    {
        printf '{\n'
        printf '\tstorage file_system %s\n' "$CADDYDATA"
        [ -n "${CLAUDE_ACME_EMAIL:-}" ] && printf '\temail %s\n' "$CLAUDE_ACME_EMAIL"
        [ -n "${CLAUDE_ACME_CA:-}" ]    && printf '\tacme_ca %s\n' "$CLAUDE_ACME_CA"
        printf '}\n\n'
        if [ -n "${CLAUDE_WEB_HOST:-}" ]; then
            printf '%s {\n' "$CLAUDE_WEB_HOST"
        else
            printf ':8080 {\n'
        fi
        printf '\troot * %s\n' "$PUBROOT"
        printf '\tfile_server browse\n'
        printf '\timport %s/workspaces/caddy.d/*.caddy\n' "$CLAUDE_HOME"
        printf '}\n'
    } > "$CADDYFILE"
    # Background daemon (not tmux — caddy is a server). setsid detaches it so it
    # survives `exec "$@"`. Reload caddy.d: `caddy reload --config ~/workspaces/Caddyfile`.
    log "starting caddy (${CLAUDE_WEB_HOST:-:8080}; storage $CADDYDATA; logs $CADDYLOG)"
    setsid sh -c "exec caddy run --config '$CADDYFILE' --adapter caddyfile >'$CADDYLOG' 2>&1" </dev/null >/dev/null 2>&1 &
fi

# 10. Optional detached tmux session running claude. Attach: tmux attach -t <name>.
if [ -n "${CLAUDE_AUTOSTART_CLAUDE_COMMAND:-}" ]; then
    TMUX_SESSION_NAME="${CLAUDE_AUTOSTART_TMUX_SESSION_NAME:-claude}"
    # Wait for outbound connectivity first: claude's remote-control connect does NOT
    # retry, so launching before CNI/DNS/egress is up leaves a live-but-disconnected
    # session. Poll claude.ai for any HTTP response (DNS+TCP+TLS ok), up to ~30s.
    n=0
    while [ "$n" -lt 30 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 https://claude.ai 2>/dev/null || true)
        [ "$code" != "000" ] && [ -n "$code" ] && break
        n=$((n + 1))
        sleep 1
    done
    log "network ready after ${n}s (claude.ai HTTP ${code:-none}); starting tmux '$TMUX_SESSION_NAME'"
    # Orchestrator starts FRESH each pod (no --continue): holds no chat state, rebuilds
    # from files (AGENTS.md hook, worker registry). No resume picker for the manager.
    tmux new-session -d -s "$TMUX_SESSION_NAME" -c "$CLAUDE_HOME/workspaces" "$CLAUDE_AUTOSTART_CLAUDE_COMMAND" \
        || log "WARNING: tmux session start failed"
fi

# 11. Resume registered worker sessions (token-free, via resume-worker). We do NOT
#     answer their pickers here — the orchestrator reads each pane and decides
REG="$CLAUDE_HOME/workspaces/.workers.json"
RESUME_HELPER="$CLAUDE_HOME/workspaces/bin/resume-worker"
if [ -s "$REG" ] && [ -x "$RESUME_HELPER" ] && command -v jq >/dev/null 2>&1; then
    log "resuming worker sessions from registry (background; orchestrator will tend them)"
    setsid sh -c '
        reg="$1"; rh="$2"
        for w in $(jq -r "keys[]" "$reg" 2>/dev/null); do
            "$rh" "$w" >/dev/null 2>&1 || true
        done
    ' _ "$REG" "$RESUME_HELPER" </dev/null >/dev/null 2>&1 &
fi

# 12. Hand off to CMD.
exec "$@"
