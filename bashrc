# Dev environment defaults for the claude user.
alias ll='ls -la'
alias gs='git status'

# Persist and append Bash history across sessions.
export HISTFILE="${HOME}/.bash_history"
export HISTSIZE=10000
export HISTFILESIZE=20000
shopt -s histappend
PROMPT_COMMAND='history -a'

# Runtime tokens injected by entrypoint (CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN).
# File is mode 600, ephemeral — re-written from k8s Secret on every container
# start, never persisted to the PVC.
[ -r "$HOME/.claude-env" ] && . "$HOME/.claude-env"
