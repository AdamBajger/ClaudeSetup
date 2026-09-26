#!/bin/sh
# _trust-guard <tmux-session> [timeout-sec]
#
# Answer claude startup trust dialogs on worker pane so auto-resumed worker
# reaches prompt (and Remote Control) unattended. Two gates:
#   1. folder trust — persisted (hasTrustDialogAccepted in worker's .claude.json)
#   2. dangerous-settings disclosure ("pre-approves N tool permissions") — NOT
#      persisted, re-shown every start; blocks TUI before RC activates.
# Only picks "Yes, I trust this folder"; other pickers ("Resume from summary")
# left for orchestrator. Idempotent. Exit 0 unless session missing / tmux fails.
set -u

NAME="${1:?usage: _trust-guard <tmux-session> [timeout-sec]}"
TIMEOUT="${2:-60}"

die() { echo "[trust-guard] $NAME: $*" >&2; exit 1; }
keys() { tmux send-keys -t "$NAME" "$1" || die "send-keys $1 failed"; }

# Wording differs per gate/version → broad match.
is_trust_dialog() {
    printf '%s' "$1" | grep -qE 'Yes, I trust this folder|pre-approves [0-9]+ tool permissions|Is this a project you created or one you trust'
}

n=0
acted=no
while [ "$n" -lt "$TIMEOUT" ]; do
    scr=$(tmux capture-pane -t "$NAME" -p) || die "capture-pane failed (session gone?)"
    if is_trust_dialog "$scr"; then
        # Default = "No, exit" → walk Down to trust option, then Enter as
        # separate send-keys (chained keys submit unreliably).
        if printf '%s' "$scr" | grep -qE '^[[:space:]]*❯[[:space:]]*Yes, I trust'; then
            keys Enter
            acted=yes
        else
            keys Down
        fi
        sleep 1
        n=$((n + 1))
        continue
    fi
    [ "$acted" = yes ] && break
    # Dialog may still be rendering (cold start ~10-12s). Stop once clearly past
    # startup (RC banner / status line / input box) so healthy pane costs ~1s.
    if printf '%s' "$scr" | grep -qE 'Remote Control active|/remote-control is active|bypass permissions on|for shortcuts|⏵⏵'; then break; fi
    sleep 1
    n=$((n + 1))
done

printf '[trust-guard] %s: answered=%s after %ss\n' "$NAME" "$acted" "$n" >&2
exit 0
