FROM debian:bookworm-slim

LABEL maintainer="Adam Bajger"
LABEL description="Pre-built Claude Code dev environment with rootless SSH access. Spin up, ssh in, claude."
LABEL version="0.3.1"

# Layer ordering: most-stable steps first, most-frequently-edited last. Editing
# any layer invalidates the cache for all layers below it, so config files
# (which change often) sit at the bottom — past the slow `curl | sh` installs
# of uv, claude, and rustup, which would otherwise re-download on every tweak.

# ---------------------------------------------------------------------------
# 1. System packages (rarely change)
# ---------------------------------------------------------------------------
# Dev tools + SSH server. Python is intentionally NOT installed via apt —
# `uv` manages Python itself (downloads standalone builds on demand via
# `uv python install`).
#
# Debian (glibc) base instead of Alpine (musl) so manylinux pip wheels —
# notably PyTorch — install and run without a glibc shim or source build.
#
# Categories:
#   - bash, curl, ca-certificates, less, vim, ripgrep, jq, tmux, tini:
#       everyday CLI ergonomics + PID 1 zombie reaper
#   - git, gh: VCS + PR work (gh installed below from GitHub's apt repo —
#       not in bookworm main)
#   - openssh-server, openssh-client: remote access (sshd) + outbound git@... support
#   - build-essential, pkg-config: native compile (rust crates + pip packages
#       with C deps); pulls gcc/g++/make/libc-dev
#   - gnupg: needed at build time to verify the GitHub CLI apt repo signing key
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash curl ca-certificates less vim ripgrep jq tmux tini \
        git \
        openssh-server openssh-client \
        build-essential pkg-config \
        gnupg && \
    # GitHub CLI from upstream apt repo (bookworm main has no `gh` package).
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Non-root user (rare; only invalidates if UID/GID args change)
# ---------------------------------------------------------------------------
# UID/GID default to 1000 to match a typical Linux host user so bind-mounted
# files aren't owned by some surprising uid. `usermod -p '*'` clears the
# locked-account `!` placeholder useradd writes to /etc/shadow — sshd refuses
# locked accounts even for pubkey auth (`*` = no password set + not locked).
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} claude && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash claude && \
    usermod -p '*' claude && \
    mkdir -p /home/claude/.ssh/host-keys /home/claude/workspaces /home/claude/.config/gh && \
    chown -R claude:claude /home/claude && \
    chmod 700 /home/claude/.ssh /home/claude/.ssh/host-keys

# ---------------------------------------------------------------------------
# 3. Heavy user-level installs (rarely change; expensive to rebuild)
# ---------------------------------------------------------------------------
# Drop privs and run `curl | sh` installers as claude so toolchains land in
# the user's $HOME and stay owned by the user that will use them at runtime.
USER claude
ENV HOME=/home/claude \
    PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:${PATH}" \
    USE_BUILTIN_RIPGREP=0 \
    RUSTUP_HOME=/home/claude/.rustup \
    CARGO_HOME=/home/claude/.cargo
WORKDIR /home/claude

# uv (Python toolchain) -> $HOME/.local/bin
RUN curl -Ls https://astral.sh/uv/install.sh | sh

# claude CLI -> $HOME/.local/bin (self-updates at runtime)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Rust stable toolchain -> $HOME/.cargo + $HOME/.rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal -c clippy -c rustfmt

# ---------------------------------------------------------------------------
# 4. Config files + entrypoint (edit frequently — kept at the bottom so
#    rebuilds only redo cheap COPYs, not the curl installs above)
# ---------------------------------------------------------------------------
USER root

# sshd config — pubkey-only, claude user only, port 2222 (non-privileged so
# sshd runs rootless), host keys + pidfile under /home/claude/.ssh/.
COPY --chown=root:root sshd_config /etc/ssh/sshd_config

# MOTD shown on SSH login (sshd reads it via PrintMotd).
COPY --chown=root:root motd /etc/motd

# Login-shell PATH + env. Docker's ENV doesn't propagate to sshd-spawned
# shells, so claude/uv/cargo binaries need exporting via /etc/profile.d for
# SSH sessions to find them.
COPY --chown=root:root profile-claude.sh /etc/profile.d/claude.sh

# Per-user dotfiles.
COPY --chown=claude:claude bashrc /home/claude/.bashrc
COPY --chown=claude:claude gitconfig /home/claude/.gitconfig
COPY --chown=claude:claude tmux.conf /home/claude/.tmux.conf

# Entrypoint script.
COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0644 /etc/profile.d/claude.sh && \
    chmod 0755 /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# 5. Runtime metadata
# ---------------------------------------------------------------------------
USER claude
EXPOSE 2222

# tini as PID 1 reaps zombies (each SSH session forks shells whose subprocesses
# get reparented when interactive users exit — without an init these accumulate).
# entrypoint.sh hydrates host keys + authorized_keys + gh auth as claude, then
# exec's CMD. Default CMD is sshd in the foreground; override with bash for a
# shell (no SSH).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
