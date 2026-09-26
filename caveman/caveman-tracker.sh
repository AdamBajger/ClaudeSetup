#!/bin/sh
# caveman UserPromptSubmit hook (POSIX sh + jq, node-free). Tracks level in flag
# file ("/caveman <level>", natural-language on/off) and re-emits short reminder
# each turn so model doesn't drift verbose. Hook → never break session: warn on
# stderr, always exit 0.

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAG="$CLAUDE_DIR/.caveman-active"
VALID=" lite full ultra wenyan-lite wenyan wenyan-full wenyan-ultra "

warn() { echo "caveman-tracker: $*" >&2; }
save() { { mkdir -p "$CLAUDE_DIR" && printf '%s\n' "$1" > "$FLAG"; } || warn "cannot write $FLAG"; }
clear_flag() { rm -f "$FLAG" || warn "cannot remove $FLAG"; exit 0; }

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""') || { warn "bad hook input JSON"; exit 0; }
prompt=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')

mode=""
if [ -f "$FLAG" ]; then
    mode=$(tr -d '[:space:]' < "$FLAG") || warn "cannot read $FLAG"
fi

case "$prompt" in
    *"stop caveman"*|*"normal mode"*|*"disable caveman"*|*"turn off caveman"*|*"deactivate caveman"*)
        clear_flag ;;
esac

# /caveman [level] (also /caveman:caveman).
case "$prompt" in
    /caveman*)
        arg=$(printf '%s' "$prompt" | sed -n 's#^/caveman[a-z:-]*[[:space:]][[:space:]]*\([a-z-]*\).*#\1#p')
        [ "$arg" = "off" ] && clear_flag
        if [ -n "$arg" ]; then
            case "$VALID" in *" $arg "*) mode="$arg" ;; esac
        fi
        [ -z "$mode" ] && mode="${CAVEMAN_DEFAULT_MODE:-full}"
        save "$mode" ;;
esac

case "$prompt" in
    *"activate caveman"*|*"enable caveman"*|*"talk like caveman"*|*"caveman mode"*)
        if [ -z "$mode" ]; then
            mode="${CAVEMAN_DEFAULT_MODE:-full}"
            save "$mode"
        fi ;;
esac

if [ -n "$mode" ] && [ "$mode" != "off" ]; then
    printf 'CAVEMAN MODE ACTIVE (%s). Drop articles/filler/pleasantries/hedging. Fragments OK. Code/commits/security: write normal.' "$mode"
fi
exit 0
