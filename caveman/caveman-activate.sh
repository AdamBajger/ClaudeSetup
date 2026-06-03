#!/bin/sh
# caveman SessionStart hook — node-free reimplementation (POSIX sh).
# Activates caveman mode by emitting the ruleset as session context and
# persisting the active level in a flag file. Best-effort: never fail the
# session, always exit 0.
#
# Mode resolution: persisted flag file > $CAVEMAN_DEFAULT_MODE > 'full'.

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAG="$CLAUDE_DIR/.caveman-active"
SKILL="$DIR/SKILL.md"
VALID=" off lite full ultra wenyan-lite wenyan wenyan-full wenyan-ultra "

mode=""
if [ -f "$FLAG" ]; then
    mode=$(tr -d '[:space:]' < "$FLAG" 2>/dev/null)
fi
[ -z "$mode" ] && mode="${CAVEMAN_DEFAULT_MODE:-}"
[ -z "$mode" ] && mode="full"
case "$VALID" in *" $mode "*) ;; *) mode="full" ;; esac

if [ "$mode" = "off" ]; then
    rm -f "$FLAG" 2>/dev/null
    printf 'OK'
    exit 0
fi

mkdir -p "$CLAUDE_DIR" 2>/dev/null
printf '%s\n' "$mode" > "$FLAG" 2>/dev/null

printf 'CAVEMAN MODE ACTIVE (level: %s).\n\n' "$mode"
# Emit the ruleset body (strip YAML frontmatter: everything up to the 2nd '---').
if [ -f "$SKILL" ]; then
    awk 'c>=2{print} /^---[[:space:]]*$/{c++}' "$SKILL" 2>/dev/null
fi
exit 0
