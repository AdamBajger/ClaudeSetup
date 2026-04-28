#!/bin/sh
# Container entrypoint. Runs as the unprivileged `claude` user (no root, no
# privileged container needed). Idempotent — safe to run on every start.
#  1. Generate SSH host keys into ~/.ssh/host-keys if missing. Keys are
#     ephemeral (no bind mount) and regenerate on each container recreate.
#  2. Hydrate ~/.ssh/authorized_keys from $AUTHORIZED_KEYS env var (additive +
#     deduped).
#  3. Export GH_TOKEN / HF_TOKEN to ~/.claude-env so SSH-spawned shells see
#     them (sshd does not inherit PID 1 env).
#  4. If $GH_TOKEN is set AND gh is not already authenticated (mounted gh
#     state persists between starts), run `gh auth login --with-token` and
#     configure git to use gh's credential helper.
#  5. If $CLAUDE_AUTOSTART_CLAUDE_COMMAND is set, spawn detached tmux session
#     named $CLAUDE_AUTOSTART_TMUX_SESSION_NAME running it.
#  6. exec CMD (sshd -D -e in the foreground by default).
set -eu

CLAUDE_HOME=/home/claude
SSH_KEYDIR="$CLAUDE_HOME/.ssh/host-keys"
AUTH_KEYS_FILE="$CLAUDE_HOME/.ssh/authorized_keys"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# 1. SSH host keys
mkdir -p "$SSH_KEYDIR"
chmod 700 "$SSH_KEYDIR"
for t in rsa ed25519; do
    f="$SSH_KEYDIR/ssh_host_${t}_key"
    if [ ! -f "$f" ]; then
        log "generating SSH host key: $t"
        ssh-keygen -t "$t" -f "$f" -N '' -q
    fi
    chmod 600 "$f"
    [ -f "$f.pub" ] && chmod 644 "$f.pub"
done

# 2. authorized_keys
mkdir -p "$CLAUDE_HOME/.ssh"
chmod 700 "$CLAUDE_HOME/.ssh"
touch "$AUTH_KEYS_FILE"

if [ -n "${AUTHORIZED_KEYS:-}" ]; then
    log "merging \$AUTHORIZED_KEYS into authorized_keys"
    printf '%s\n' "$AUTHORIZED_KEYS" >> "$AUTH_KEYS_FILE"
    # Dedupe, preserving order of first occurrence; drop blank lines.
    awk 'NF && !seen[$0]++' "$AUTH_KEYS_FILE" > "$AUTH_KEYS_FILE.tmp"
    mv "$AUTH_KEYS_FILE.tmp" "$AUTH_KEYS_FILE"
fi

chmod 600 "$AUTH_KEYS_FILE"

if [ ! -s "$AUTH_KEYS_FILE" ]; then
    log "WARNING: authorized_keys is empty. Set AUTHORIZED_KEYS in .env."
fi

# 3. Export tokens to SSH login shells. Container env (PID 1) does not
#    propagate to sshd-forked sessions, so write a per-user env file that
#    .bashrc sources. Ephemeral — re-injected from Secret on every restart.
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

# 5. Optional: spawn detached tmux session running claude. Persists across SSH
#    disconnects; killed when pod terminates. Attach later via SSH:
#      tmux attach -t "$CLAUDE_AUTOSTART_TMUX_SESSION_NAME"
if [ -n "${CLAUDE_AUTOSTART_CLAUDE_COMMAND:-}" ]; then
    TMUX_SESSION_NAME="${CLAUDE_AUTOSTART_TMUX_SESSION_NAME:-claude}"
    log "starting tmux session '$TMUX_SESSION_NAME': $CLAUDE_AUTOSTART_CLAUDE_COMMAND"
    tmux new-session -d -s "$TMUX_SESSION_NAME" -c "$CLAUDE_HOME/workspaces" "$CLAUDE_AUTOSTART_CLAUDE_COMMAND" \
        || log "WARNING: tmux session start failed"
fi

# 6. Hand off to CMD.
exec "$@"
