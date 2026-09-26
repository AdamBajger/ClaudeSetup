#!/bin/sh
# caveman SessionStart hook (POSIX sh, node-free). Emits ruleset as session
# context, persists level in flag file. Hook → never break session: warn on
# stderr, always exit 0.
#
# Mode: flag file > $CAVEMAN_DEFAULT_MODE > 'full'.

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAG="$CLAUDE_DIR/.caveman-active"
SKILL=/usr/local/share/claude-skills/caveman/SKILL.md
VALID=" off lite full ultra wenyan-lite wenyan wenyan-full wenyan-ultra "

warn() { echo "caveman-activate: $*" >&2; }

mode=""
if [ -f "$FLAG" ]; then
    mode=$(tr -d '[:space:]' < "$FLAG") || warn "cannot read $FLAG"
fi
[ -z "$mode" ] && mode="${CAVEMAN_DEFAULT_MODE:-}"
[ -z "$mode" ] && mode="full"
case "$VALID" in *" $mode "*) ;; *) mode="full" ;; esac

if [ "$mode" = "off" ]; then
    rm -f "$FLAG" || warn "cannot remove $FLAG"
    printf 'OK'
    exit 0
fi

{ mkdir -p "$CLAUDE_DIR" && printf '%s\n' "$mode" > "$FLAG"; } || warn "cannot write $FLAG"

printf 'CAVEMAN MODE ACTIVE (level: %s).\n\n' "$mode"
# Ruleset body = everything after 2nd '---' (strip YAML frontmatter).
awk 'c>=2{print} /^---[[:space:]]*$/{c++}' "$SKILL" || warn "cannot read $SKILL"
exit 0
