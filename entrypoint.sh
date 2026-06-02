#!/bin/sh
# Container entrypoint. Runs as unprivileged `claude` user. Idempotent.
#  1. Generate ed25519 SSH host key into ~/.ssh/host-keys if missing (ephemeral).
#  2. Hydrate ~/.ssh/authorized_keys from $AUTHORIZED_KEYS (additive + deduped).
#  3. Export GH_TOKEN / HF_TOKEN to ~/.claude-env for SSH-spawned shells.
#  4. gh auth login if $GH_TOKEN set and not already authenticated.
#  5. Pre-accept the workspace trust dialog for ~/workspaces in ~/.claude.json.
#  6. Spawn detached tmux session if $CLAUDE_AUTOSTART_CLAUDE_COMMAND set.
#  7. exec CMD (sshd -D -e by default).
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

# 6. Optional detached tmux session running claude. Attach via SSH:
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

# 7. Hand off to CMD.
exec "$@"
