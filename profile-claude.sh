# Claude dev environment — sourced by /etc/profile for login shells (incl. SSH).
# Docker's ENV directives don't propagate to sshd-forked sessions, so anything
# the SSH user needs in PATH must be set here too.
export PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/workspaces/bin:$PATH"
export RUSTUP_HOME="/home/claude/.rustup"
export CARGO_HOME="/home/claude/.cargo"
export USE_BUILTIN_RIPGREP=0
# Keep uv's CPython builds + cache on the PVC so they survive pod bounces (issue #6).
export UV_PYTHON_INSTALL_DIR="/home/claude/workspaces/.uv/python"
export UV_CACHE_DIR="/home/claude/workspaces/.uv/cache"
# Keep .claude.json inside the ~/.claude dir mount so atomic saves work (issue #4).
export CLAUDE_CONFIG_DIR="/home/claude/.claude"
