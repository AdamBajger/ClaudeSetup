#!/bin/sh
# _trust-guard <tmux-session> [timeout-sec]
#
# Answer claude's startup trust dialogs for a worker pane, so an auto-resumed
# worker reaches its prompt (and activates remote control) without a human.
#
# Two distinct gates exist as of claude 2.1.270:
#   1. folder trust      — persisted in ~/.claude.json as
#                          projects[dir].hasTrustDialogAccepted (entrypoint seeds it)
#   2. dangerous-settings disclosure ("This folder pre-approves N tool
#      permissions") — NOT persisted anywhere, so it re-appears on EVERY start
#      whenever the project's .claude/settings.json holds a dangerous pattern.
# Gate 2 blocks the TUI before "Remote Control active" prints, which looks like
# "remote control deactivated" from the app side.
#
# Only ever acts while a trust dialog is on screen, and only selects the
# already-present "Yes, I trust this folder" option. Other pickers (notably
# "Resume from summary") are left untouched — the orchestrator decides those.
# Idempotent, always exits 0.
set -u

NAME="${1:?usage: _trust-guard <tmux-session> [timeout-sec]}"
TIMEOUT="${2:-60}"

pane() { tmux capture-pane -t "$NAME" -p 2>/dev/null; }

# Dialog markers (either gate). Keep broad: the wording differs per gate/version.
is_trust_dialog() {
    printf '%s' "$1" | grep -qE 'Yes, I trust this folder|pre-approves [0-9]+ tool permissions|Is this a project you created or one you trust'
}

n=0
acted=no
while [ "$n" -lt "$TIMEOUT" ]; do
    scr=$(pane) || break
    if is_trust_dialog "$scr"; then
        # Default selection is the refusing option ("No, exit"), so walk down to
        # the trust option, then submit. Enter is a separate send-keys — chained
        # keys submit unreliably.
        if printf '%s' "$scr" | grep -qE '^[[:space:]]*❯[[:space:]]*Yes, I trust'; then
            tmux send-keys -t "$NAME" Enter
            acted=yes
        else
            tmux send-keys -t "$NAME" Down
        fi
        sleep 1
        n=$((n + 1))
        continue
    fi
    [ "$acted" = yes ] && break
    # No dialog yet: it may still be rendering (cold start ~10-12s). Stop as soon
    # as the session is clearly past startup (RC banner, or the TUI status line /
    # input box of an already-restored session), so a healthy pane costs ~1s.
    if printf '%s' "$scr" | grep -qE 'Remote Control active|/remote-control is active|bypass permissions on|for shortcuts|⏵⏵'; then break; fi
    sleep 1
    n=$((n + 1))
done

printf '[trust-guard] %s: answered=%s after %ss\n' "$NAME" "$acted" "$n" >&2
exit 0
