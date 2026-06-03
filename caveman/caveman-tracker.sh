#!/bin/sh
# caveman UserPromptSubmit hook — node-free reimplementation (POSIX sh + jq).
# Tracks the active level (handles "/caveman <level>", natural-language
# activation, and "stop caveman"/"normal mode") in the flag file, and re-emits
# a short reminder each turn so the model does not drift back to verbose.
# Best-effort: always exit 0.

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAG="$CLAUDE_DIR/.caveman-active"
VALID=" lite full ultra wenyan-lite wenyan wenyan-full wenyan-ultra "

input=$(cat 2>/dev/null)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')

mode=""
if [ -f "$FLAG" ]; then
    mode=$(tr -d '[:space:]' < "$FLAG" 2>/dev/null)
fi

# Deactivate.
case "$prompt" in
    *"stop caveman"*|*"normal mode"*|*"disable caveman"*|*"turn off caveman"*|*"deactivate caveman"*)
        rm -f "$FLAG" 2>/dev/null
        exit 0 ;;
esac

# Explicit /caveman command (also matches /caveman:caveman).
case "$prompt" in
    /caveman*)
        arg=$(printf '%s' "$prompt" | sed -n 's#^/caveman[a-z:-]*[[:space:]][[:space:]]*\([a-z-]*\).*#\1#p')
        if [ "$arg" = "off" ]; then
            rm -f "$FLAG" 2>/dev/null
            exit 0
        fi
        if [ -n "$arg" ]; then
            case "$VALID" in *" $arg "*) mode="$arg" ;; esac
        fi
        [ -z "$mode" ] && mode="${CAVEMAN_DEFAULT_MODE:-full}"
        mkdir -p "$CLAUDE_DIR" 2>/dev/null
        printf '%s\n' "$mode" > "$FLAG" 2>/dev/null ;;
esac

# Natural-language activation.
case "$prompt" in
    *"activate caveman"*|*"enable caveman"*|*"talk like caveman"*|*"caveman mode"*)
        if [ -z "$mode" ]; then
            mode="${CAVEMAN_DEFAULT_MODE:-full}"
            mkdir -p "$CLAUDE_DIR" 2>/dev/null
            printf '%s\n' "$mode" > "$FLAG" 2>/dev/null
        fi ;;
esac

# If active, re-inject the compact reminder.
if [ -n "$mode" ] && [ "$mode" != "off" ]; then
    printf 'CAVEMAN MODE ACTIVE (%s). Drop articles/filler/pleasantries/hedging. Fragments OK. Code/commits/security: write normal.' "$mode"
fi
exit 0
