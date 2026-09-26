FROM debian:bookworm-slim

LABEL maintainer="Adam Bajger"
LABEL description="Pre-built Claude Code dev environment with rootless SSH access. Spin up, ssh in, claude."
LABEL version="0.7.1"

# Layers: stable/slow first, often-edited config last → tweaks skip curl installs.

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
# No apt Python: uv manages interpreters. Debian (glibc) not Alpine → manylinux
# wheels (PyTorch) work. gnupg: verify gh apt key. cs_CZ.UTF-8 locale built here
# (Babel/pint in workers; rootless pod can't locale-gen at runtime).
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash curl ca-certificates less vim ripgrep jq tmux tini \
        git \
        openssh-server openssh-client \
        build-essential pkg-config \
        gnupg locales && \
    # gh not in bookworm main → upstream apt repo
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    sed -i 's/^# *cs_CZ.UTF-8 UTF-8/cs_CZ.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen && \
    rm -rf /var/lib/apt/lists/*

# caddy: static web server for ~/workspaces/.public. Pinned.
ARG CADDY_VERSION=2.8.4
RUN curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin caddy && \
    chmod 0755 /usr/local/bin/caddy && \
    /usr/local/bin/caddy version

# ---------------------------------------------------------------------------
# 2. Non-root user
# ---------------------------------------------------------------------------
# `usermod -p '*'`: clear useradd's locked `!` — sshd rejects locked accounts
# even for pubkey auth.
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} claude && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash claude && \
    usermod -p '*' claude && \
    mkdir -p /home/claude/.ssh/host-keys /home/claude/workspaces /home/claude/.config/gh && \
    chown -R claude:claude /home/claude && \
    chmod 700 /home/claude/.ssh /home/claude/.ssh/host-keys

# ---------------------------------------------------------------------------
# 3. User-level toolchains (installed as claude → owned by runtime user)
# ---------------------------------------------------------------------------
USER claude
ENV HOME=/home/claude \
    PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/workspaces/bin:${PATH}" \
    USE_BUILTIN_RIPGREP=0 \
    RUSTUP_HOME=/home/claude/.rustup \
    CARGO_HOME=/home/claude/.cargo \
    # uv interpreters + cache on PVC → project .venv symlinks survive pod bounce
    UV_PYTHON_INSTALL_DIR=/home/claude/workspaces/.uv/python \
    UV_CACHE_DIR=/home/claude/workspaces/.uv/cache \
    # .claude.json inside ~/.claude dir mount → atomic rename works. Workers override.
    CLAUDE_CONFIG_DIR=/home/claude/.claude
WORKDIR /home/claude

RUN curl -Ls https://astral.sh/uv/install.sh | sh

# Autoupdate disabled at runtime → update = rebuild with
# --build-arg CLAUDE_CACHE_BUST=<new value> (refetches claude only).
ARG CLAUDE_CACHE_BUST=0
RUN curl -fsSL https://claude.ai/install.sh | bash

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal -c clippy -c rustfmt

# ---------------------------------------------------------------------------
# 4. Config files + helpers (edited often → bottom)
# ---------------------------------------------------------------------------
USER root

# pubkey-only, claude only, port 2222 (rootless sshd)
COPY --chown=root:root sshd_config /etc/ssh/sshd_config
COPY --chown=root:root motd /etc/motd
# Docker ENV not inherited by sshd sessions → re-export in login profile
COPY --chown=root:root profile-claude.sh /etc/profile.d/claude.sh

COPY --chown=claude:claude bashrc /home/claude/.bashrc
COPY --chown=claude:claude gitconfig /home/claude/.gitconfig
COPY --chown=claude:claude tmux.conf /home/claude/.tmux.conf

# Seeded by entrypoint to ~/.claude/skills/<name> each start.
COPY --chown=root:root skills/ /usr/local/share/claude-skills/
# Manager instructions; injected by manager-startup hook (never copied to PVC).
COPY --chown=root:root k8s/helm/claude-cli/files/MANAGER.md /usr/local/share/claude/MANAGER.md
# Node-free caveman hooks; ruleset from skills/caveman/.
COPY --chown=root:root caveman/ /usr/local/lib/caveman/

COPY --chown=root:root caddy/Caddyfile.default /usr/local/share/caddy/Caddyfile.default
COPY --chown=root:root caddy/webshare /usr/local/bin/webshare
COPY --chown=root:root caddy/webshare-auth /usr/local/bin/webshare-auth

# Installed by entrypoint into ~/workspaces/bin/.
COPY --chown=root:root slack-monitor/ /usr/local/lib/slack-monitor/
# Worker tools → ~/workspaces/bin/: trust-guard refreshed each start; worker
# helpers seeded only if missing (manager owns + edits them).
COPY --chown=root:root worker-tools/ /usr/local/lib/worker-tools/

# YouTrack articles REST helper (issues go via MCP).
COPY --chown=root:root youtrack/youtrack-kb /usr/local/bin/youtrack-kb
COPY --chown=root:root apps/appctl /usr/local/bin/appctl
COPY --chown=root:root manager-startup.sh /usr/local/lib/claude-hooks/manager-startup.sh

COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0644 /etc/profile.d/claude.sh && \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/webshare /usr/local/bin/webshare-auth /usr/local/bin/youtrack-kb /usr/local/bin/appctl \
        /usr/local/lib/caveman/caveman-activate.sh /usr/local/lib/caveman/caveman-tracker.sh \
        /usr/local/lib/slack-monitor/slack-lock /usr/local/lib/slack-monitor/slack-cron-reminder.sh \
        /usr/local/lib/worker-tools/* \
        /usr/local/lib/claude-hooks/manager-startup.sh

# ---------------------------------------------------------------------------
# 5. Runtime
# ---------------------------------------------------------------------------
USER claude
EXPOSE 2222 80 443

# tini PID 1: reaps zombies from SSH session forks.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
