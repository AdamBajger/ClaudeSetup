# Login-shell env. Docker ENV not inherited by sshd sessions → mirror it here.
export PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/workspaces/bin:$PATH"
export RUSTUP_HOME="/home/claude/.rustup"
export CARGO_HOME="/home/claude/.cargo"
export USE_BUILTIN_RIPGREP=0
# uv interpreters + cache on PVC → survive pod bounce
export UV_PYTHON_INSTALL_DIR="/home/claude/workspaces/.uv/python"
export UV_CACHE_DIR="/home/claude/workspaces/.uv/cache"
# .claude.json inside ~/.claude dir mount → atomic saves
export CLAUDE_CONFIG_DIR="/home/claude/.claude"
# runit service dirs → `sv status <name>`
export SVDIR="/home/claude/workspaces/.sv"
