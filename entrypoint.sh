#!/bin/sh
# Container entrypoint (compose + k8s). Runs as `claude`. Idempotent.
#  0. data bootstrap             6. seed skills, wire hooks
#  1. SSH host key               8. YouTrack MCP, Slack tools, trust-guard
#  2. authorized_keys            9. caddy ($CLAUDE_WEB_ENABLED)
#  3. export tokens to SSH      10. autostart manager in tmux
#  4. gh auth                   11. runsvdir (apps), resume workers
#  5. pre-accept trust dialog   12. exec CMD (sshd -D -e)
set -eu

# Self-update swaps ~/.local/bin/claude symlink → kills running manager+worker
# sessions. Pin binary for pod lifetime; update = rebuild w/ CLAUDE_CACHE_BUST.
DISABLE_AUTOUPDATER=1
export DISABLE_AUTOUPDATER

CLAUDE_HOME=/home/claude
WORKDIR="$CLAUDE_HOME/workspaces"
BIN="$WORKDIR/bin"
SSH_KEYDIR="$CLAUDE_HOME/.ssh/host-keys"
AUTH_KEYS_FILE="$CLAUDE_HOME/.ssh/authorized_keys"
SETTINGS="$CLAUDE_HOME/.claude/settings.json"
ONBOARDED='{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.119"}'

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# reg_count <registry.json> → entry count; 0 if absent/empty/unparseable
reg_count() {
    [ -s "$1" ] || { echo 0; return 0; }
    jq -r 'keys|length' "$1" || { log "WARNING: $1 unparseable, treated as empty"; echo 0; }
}

# settings_merge <label> <jq-filter> [jq args...] — merge into settings.json
# jq def addhook($ev; $cmd): append command hook to event unless present.
ADDHOOK='def addhook($ev; $cmd):
    .hooks[$ev] = (.hooks[$ev] // [])
    | if any(.hooks[$ev][].hooks[]?; .command == $cmd) then .
      else .hooks[$ev] += [{hooks:[{type:"command",command:$cmd,timeout:5}]}] end;'
settings_merge() {
    label="$1"; filter="$2"; shift 2
    tmp=$(mktemp)
    if jq "$@" "$ADDHOOK $filter" "$SETTINGS" > "$tmp"; then
        cat "$tmp" > "$SETTINGS"
        log "$label"
    else
        log "WARNING: settings.json merge failed: $label"
    fi
    rm -f "$tmp"
}

# 0. Data bootstrap
mkdir -p "$CLAUDE_HOME/.claude" "$CLAUDE_HOME/.config/gh" "$WORKDIR" \
         "$WORKDIR/.uv" "$SVDIR" "$BIN"
# .claude.json inside CLAUDE_CONFIG_DIR dir mount → atomic saves work.
CFGDIR="${CLAUDE_CONFIG_DIR:-$CLAUDE_HOME/.claude}"
mkdir -p "$CFGDIR"
CJSON="$CFGDIR/.claude.json"
if [ ! -s "$CJSON" ] || [ "$(cat "$CJSON")" = '{}' ]; then
    printf '%s\n' "$ONBOARDED" > "$CJSON"
fi
[ -e "$CLAUDE_HOME/.bash_history" ] || touch "$CLAUDE_HOME/.bash_history"
# Re-seed creds only when $CLAUDE_CREDENTIALS_JSON changes; CLI rotates them after.
if [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]; then
    CREDS="$CLAUDE_HOME/.claude/.credentials.json"
    HASHF="$CLAUDE_HOME/.claude/.cred-bootstrap-hash"
    newhash=$(printf '%s' "$CLAUDE_CREDENTIALS_JSON" | md5sum | cut -d' ' -f1)
    oldhash=""
    [ -f "$HASHF" ] && oldhash=$(cat "$HASHF")
    if [ ! -e "$CREDS" ] || [ "$newhash" != "$oldhash" ]; then
        printf '%s' "$CLAUDE_CREDENTIALS_JSON" > "$CREDS"
        chmod 600 "$CREDS"
        printf '%s\n' "$newhash" > "$HASHF"
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

# 2. authorized_keys (merge + dedupe)
chmod 700 "$CLAUDE_HOME/.ssh"
touch "$AUTH_KEYS_FILE"
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
    log "merging \$AUTHORIZED_KEYS into authorized_keys"
    printf '%s\n' "$AUTHORIZED_KEYS" >> "$AUTH_KEYS_FILE"
    awk 'NF && !seen[$0]++' "$AUTH_KEYS_FILE" > "$AUTH_KEYS_FILE.tmp"
    mv "$AUTH_KEYS_FILE.tmp" "$AUTH_KEYS_FILE"
fi
chmod 600 "$AUTH_KEYS_FILE"
[ -s "$AUTH_KEYS_FILE" ] || log "WARNING: authorized_keys is empty. Set AUTHORIZED_KEYS in .env."

# 3. Export env to SSH login shells (sshd drops container env; bashrc sources this)
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
write_export DISABLE_AUTOUPDATER

# 4. GitHub CLI auth
if [ -n "${GH_TOKEN:-}" ]; then
    if gh auth status >/dev/null 2>&1; then
        log "gh already authenticated (via mounted state)"
    else
        log "gh: logging in with GH_TOKEN"
        printf '%s\n' "$GH_TOKEN" | gh auth login --with-token || \
            log "WARNING: gh auth login --with-token failed (bad token? offline?)"
    fi
    gh auth setup-git || log "WARNING: gh auth setup-git failed"
fi

# 5. Pre-accept folder-trust dialog. No env bypass (independent of
#    --dangerously-skip-permissions); only per-project flag in .claude.json.
#    Each worker dir = own project → own flag, else pane stuck on dialog, no /rc.
#    Workers use CLAUDE_CONFIG_DIR=<dir>/.claudecfg → seed there; manager copy
#    too, for claude on shared config in worker dir (IDE session, human shell).
#    Dangerous-settings disclosure ("pre-approves N tool permissions") not
#    persisted anywhere → can't pre-seed; _trust-guard answers it per pane.
#    Avoid dangerous allow-patterns (e.g. Bash(rm -rf ...)) in project settings.
# trust_dir <claude.json> <project-dir>
trust_dir() {
    f="$1"; d="$2"
    [ -s "$f" ] || printf '%s\n' "$ONBOARDED" > "$f"
    tmp=$(mktemp)
    if jq --arg d "$d" '.projects[$d].hasTrustDialogAccepted = true' "$f" > "$tmp"; then
        mv "$tmp" "$f"   # atomic rename: .claude.json in dir mount
        log "trust dialog pre-accepted for $d ($f)"
    else
        log "WARNING: could not pre-accept trust dialog for $d in $f"
        rm -f "$tmp"
    fi
}
trust_dir "$CJSON" "$WORKDIR"
WREG="$WORKDIR/.workers.json"
if [ -s "$WREG" ]; then
    # registry = name set; worker dir = ~/workspaces/<name>, no spaces → word-split safe
    wdirs=$(jq -r --arg w "$WORKDIR" 'keys[] | $w + "/" + .' "$WREG") \
        || { log "WARNING: $WREG unparseable, worker dirs not trusted"; wdirs=""; }
    for d in $wdirs; do
        [ -d "$d" ] || continue
        trust_dir "$CJSON" "$d"
        mkdir -p "$d/.claudecfg"
        trust_dir "$d/.claudecfg/.claude.json" "$d"
    done
fi

# 6. Seed skills (overwrite each start; image = source of truth; other-named
#    user skills untouched).
SKILLSRC=/usr/local/share/claude-skills
mkdir -p "$CLAUDE_HOME/.claude/skills"
for d in "$SKILLSRC"/*/; do
    name=$(basename "$d")
    rm -rf "$CLAUDE_HOME/.claude/skills/$name"
    cp -r "$d" "$CLAUDE_HOME/.claude/skills/$name"
done
log "seeded skills: $(ls "$SKILLSRC" | tr '\n' ' ')"

[ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

# 6b. manager-startup SessionStart hook: injects image's MANAGER.md (cwd-guarded
#     → inert in workers). No instructions file under ~/workspaces: claude
#     auto-loads CLAUDE.md/AGENTS.md from every ancestor dir → would leak into workers.
settings_merge "manager-startup hook wired" \
    'addhook("SessionStart"; $cmd)' \
    --arg cmd /usr/local/lib/claude-hooks/manager-startup.sh

# 7. Node-free caveman: upstream plugin hooks need `node` (not installed) →
#    disable plugin, wire POSIX-sh hooks. /caveman skill seeded in step 6.
CAVE=/usr/local/lib/caveman
settings_merge "caveman: node-free hooks wired, node plugin disabled" \
    '.enabledPlugins["caveman@caveman"] = false
     | addhook("SessionStart"; $act) | addhook("UserPromptSubmit"; $trk)' \
    --arg act "$CAVE/caveman-activate.sh" --arg trk "$CAVE/caveman-tracker.sh"

# 8. Integrations. Before autostart claude → MCP tools load without restart.

# 8a. YouTrack MCP (needs host + token). Re-add idempotently.
if [ -n "${YT_HOST:-}" ] && [ -n "${YT_TOKEN:-}" ]; then
    # remove fails when not yet configured → expected
    claude mcp remove -s user youtrack >/dev/null 2>&1 || true
    if claude mcp add -s user -t http youtrack "${YT_HOST%/}/mcp" \
            -H "Authorization: Bearer $YT_TOKEN" >/dev/null; then
        log "youtrack MCP configured (${YT_HOST%/})"
    else
        log "WARNING: youtrack mcp add failed"
    fi
fi

# 8b. Slack monitor tools + cron-reminder hook (silent until monitor registered).
#     Slack MCP = account-level claude.ai connector, can't be baked.
SLACKLIB=/usr/local/lib/slack-monitor
REMINDER="$BIN/_slack-cron-reminder.sh"
if cp "$SLACKLIB/slack-lock" "$BIN/slack-lock" \
   && cp "$SLACKLIB/slack-cron-reminder.sh" "$REMINDER" \
   && chmod 0755 "$BIN/slack-lock" "$REMINDER"; then
    settings_merge "slack monitor: tools + cron-reminder hook installed" \
        'addhook("SessionStart"; $cmd)' --arg cmd "$REMINDER"
else
    log "WARNING: could not install slack monitor tools"
fi

# 8c. _trust-guard (image-owned, refreshed each start): answers folder-trust +
#     dangerous-settings dialogs on worker pane. Used by step 11 + helpers.
WTOOLS=/usr/local/lib/worker-tools
if cp "$WTOOLS/trust-guard.sh" "$BIN/_trust-guard" \
   && chmod 0755 "$BIN/_trust-guard"; then
    log "worker trust-guard installed"
else
    log "WARNING: could not install worker trust-guard"
fi
# 8d. Worker helpers = manager-owned (edits in-session) → seed only missing
#     ones. Fresh pod / lost PVC gets working set; spec in MANAGER.md.
seeded=""
for h in spawn-worker resume-worker tell-worker read-worker list-workers kill-worker _worker-cfg; do
    [ -e "$BIN/$h" ] && continue
    if cp "$WTOOLS/$h" "$BIN/$h" && chmod 0755 "$BIN/$h"; then
        seeded="$seeded $h"
    else
        log "WARNING: could not seed worker helper $h"
    fi
done
[ -z "$seeded" ] || log "worker helpers seeded (were missing):$seeded"

# 9. caddy. Serves ONLY ~/workspaces/.public (`webshare` symlinks) + caddy.d/*.caddy.
#    Caddyfile regenerated each start → route via caddy.d snippets.
#    $CLAUDE_WEB_HOST set (k8s): public vhost, auto Let's Encrypt, :443 + :80
#    redirect (needs NET_BIND_SERVICE + file-cap on binary). Unset: plain :8080.
#    Cert/ACME storage on PVC → renewals survive restarts, no LE rate-limit hits.
if [ "${CLAUDE_WEB_ENABLED:-false}" = "true" ]; then
    CADDYFILE="$WORKDIR/Caddyfile"
    CADDYLOG="$WORKDIR/.caddy.log"
    CADDYDATA="$WORKDIR/.caddy"
    PUBROOT="$WORKDIR/.public"
    mkdir -p "$PUBROOT" "$WORKDIR/caddy.d" "$CADDYDATA"
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
        printf '\timport %s/caddy.d/*.caddy\n' "$WORKDIR"
        printf '}\n'
    } > "$CADDYFILE"
    # setsid → survives `exec "$@"`. Reload: caddy reload --config ~/workspaces/Caddyfile
    log "starting caddy (${CLAUDE_WEB_HOST:-:8080}; storage $CADDYDATA; logs $CADDYLOG)"
    setsid sh -c "exec caddy run --config '$CADDYFILE' --adapter caddyfile >'$CADDYLOG' 2>&1" </dev/null >/dev/null 2>&1 &
fi

# 10. Autostart manager claude in detached tmux.
N_WORKERS=$(reg_count "$WREG")
if [ -n "${CLAUDE_AUTOSTART_CLAUDE_COMMAND:-}" ]; then
    TMUX_SESSION_NAME="${CLAUDE_AUTOSTART_TMUX_SESSION_NAME:-claude}"
    # remote-control connect never retries → wait for egress (any HTTP reply
    # from claude.ai), max ~30s. curl fails while net down → expected.
    n=0
    while [ "$n" -lt 30 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 https://claude.ai || true)
        [ "$code" != "000" ] && [ -n "$code" ] && break
        n=$((n + 1))
        sleep 1
    done
    log "network ready after ${n}s (claude.ai HTTP ${code:-none}); starting tmux '$TMUX_SESSION_NAME'"
    # Manager starts fresh (no --continue); state rebuilt from files. With
    # workers registered, boot prompt makes it reconcile now instead of
    # idling at ❯. Prompt must contain NO single quotes (wrapped below).
    START_CMD="$CLAUDE_AUTOSTART_CLAUDE_COMMAND"
    if [ "$N_WORKERS" != 0 ]; then
        # manager owns revival → step 11 skips resume (no racing resume-worker)
        MANAGER_RECONCILES=1
        BOOT_PROMPT="Pod just (re)started. Before anything else, RECONCILE per MANAGER.md: for EVERY registered worker in .workers.json check live via list-workers (NOT claude agents --json: workers on own CLAUDE_CONFIG_DIR, invisible to manager); resume-worker any missing, stuck or up-DEADPANE (kill lingering tmux session first, else resume refuses); resolve resume/onboarding/trust modals, verify each shows remote control active. Then ls SVDIR and sv status each app. Report one-line status per worker and app. Do not start new work."
        START_CMD="$CLAUDE_AUTOSTART_CLAUDE_COMMAND '$BOOT_PROMPT'"
        log "manager boot prompt: auto-reconcile (workers=$N_WORKERS)"
    fi
    tmux new-session -d -s "$TMUX_SESSION_NAME" -c "$WORKDIR" "$START_CMD" \
        || log "WARNING: tmux session start failed"
fi

# 11a. runit: every service dir in $SVDIR (PVC) starts now + restarts on crash.
log "starting runsvdir on $SVDIR"
setsid runsvdir -P "$SVDIR" </dev/null >/dev/null 2>&1 &

# 11b. Resume workers (token-free, via resume-worker). Pickers left for manager;
#      trust dialogs answered here (they block /rc → worker looks dead).
#      Best-effort: per-worker outcome → resume log; manager reconciles rest.
RESUME_HELPER="$BIN/resume-worker"
RESUME_LOG="$WORKDIR/.workers-resume.log"
if [ "${MANAGER_RECONCILES:-0}" = 1 ]; then
    log "worker revival delegated to the manager's boot reconcile (skipping entrypoint auto-resume to avoid races)"
elif [ "$N_WORKERS" != 0 ]; then
    if [ -x "$RESUME_HELPER" ]; then
        log "resuming workers from registry (background; log ~/workspaces/.workers-resume.log): $(jq -r 'keys|join(" ")' "$WREG")"
        setsid sh -c '
        reg="$1"; rh="$2"; tg="$3"
        printf "==== resume run %s ====\n" "$(date -u)"
        for w in $(jq -r "keys[]" "$reg"); do
            if "$rh" "$w"; then echo "[resume] $w: ok"
            else echo "[resume] $w: FAILED (manager must reconcile)"; fi
            # no-op in ~0s when no dialog on screen
            [ -x "$tg" ] && "$tg" "$w" 45
        done
        ' _ "$WREG" "$RESUME_HELPER" "$BIN/_trust-guard" </dev/null >>"$RESUME_LOG" 2>&1 &
    else
        log "WARNING: $RESUME_HELPER missing/not executable — workers NOT auto-resumed. Manager must recreate the helper (per MANAGER.md) and reconcile: $(jq -r 'keys|join(" ")' "$WREG")"
        printf '%s missing — no auto-resume; manager reconcile required\n' "$RESUME_HELPER" >> "$RESUME_LOG"
    fi
fi

# 12. Hand off to CMD.
exec "$@"
