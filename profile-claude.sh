# Claude dev environment — sourced by /etc/profile for login shells (incl. SSH).
# Docker's ENV directives don't propagate to sshd-forked sessions, so anything
# the SSH user needs in PATH must be set here too.
export PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:$PATH"
export RUSTUP_HOME="/home/claude/.rustup"
export CARGO_HOME="/home/claude/.cargo"
export USE_BUILTIN_RIPGREP=0
