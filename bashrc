alias ll='ls -la'
alias gs='git status'

export HISTFILE="${HOME}/.bash_history"
export HISTSIZE=10000
export HISTFILESIZE=20000
shopt -s histappend
PROMPT_COMMAND='history -a'

# GH_TOKEN, HF_TOKEN, DISABLE_AUTOUPDATER — rewritten by entrypoint each start (mode 600).
[ -r "$HOME/.claude-env" ] && . "$HOME/.claude-env"
