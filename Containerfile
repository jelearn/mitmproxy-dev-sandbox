# ============================================================
# VS Code + mitmproxy Sandbox
# Base: Debian
#
# Architecture:
#   User separation between coder and mitmproxy.
#   Multi-stage image build.
#   noVNC (pixels only) → Xtigervnc → Openbox → Chromium → code-server
#   All outbound :443 → iptables REDIRECT → mitmproxy (mitm uid)
#                                               ↓
#                                       allowlist.py (Python)
#                                               ↓
#                                    real upstream server (if allowed)
#
# Users:
#   coder — runs code-server, Chromium, Claude Code,
#           and all VS Code processes. Has NO special
#           network privileges. All outbound :443/:80
#           is intercepted by mitmproxy.
#
#   mitm  — runs mitmproxy only. The iptables REDIRECT
#           exemption is granted to this uid exclusively,
#           so it is the only process that can make real
#           outbound HTTPS connections. Cannot sudo.
#           Cannot write to the workspace.
#
# Multi-stage Stages (each has its own cache layer):
#
#   base               — Ubuntu 24.04 + OS packages + users
#   node-runtime       — Node.js 20 LTS (built on top of base)
#   code-server-install— code-server .deb + Claude Code CLI
#   mitmproxy-install  — Python venv + mitmproxy (independent of node)
#   display-stack      — Xtigervnc + Openbox + noVNC + Chromium
#   final              — configs, scripts, entrypoint (changes most often)
#
# Rebuild only the stages you need:
#   podman build --target code-server-install ...  → rebuild code-server only
#   podman build --target mitmproxy-install ...    → rebuild mitmproxy only
#   podman build ...                               → full build (uses cache)
#
# Container naming:
#   The image is named at build time:  podman build -t myname .
#   The container is named at runtime: podman run --name mycontainer
#   Or via compose.yml:         container_name: mitmproxy-dev-sandbox
#   You cannot set a container name inside a Containerfile — it is a
#   runtime concept, not a build-time one.
#
# ARGs are declared in the stage that first uses them.
# ARGs do not persist across stages unless re-declared.
# ============================================================


# ════════════════════════════════════════════════════════════
# STAGE 1 — base
#
# Installs all OS-level packages, creates the three users
# (main is the host user — not created here), and sets up the
#
# Rebuild trigger: OS package list changes, user UID changes.
# ════════════════════════════════════════════════════════════
FROM debian:bookworm-slim AS base

ARG DEBIAN_FRONTEND=noninteractive

# User identity ARGs — override at build time if your host UIDs differ:
#   podman build --build-arg CODER_UID=1100 --build-arg MITM_UID=1101 .
ARG CODER_USER=coder
ARG CODER_UID=1100
ARG MITM_USER=mitm
ARG MITM_UID=1101

# Persist user names as ENV so downstream stages can reference them
# without re-declaring the ARGs (ARGs do not cross stage boundaries).
ENV CODER_USER=${CODER_USER} \
    CODER_UID=${CODER_UID} \
    MITM_USER=${MITM_USER} \
    MITM_UID=${MITM_UID}

RUN apt-get update

# This is the minimal effort to allow all UTF-8 characters
# to be displayed properly, which aren't by default as the
# POSIX locale doesn't support them.
RUN apt-get update && apt-get install -y locales && \
    sed -i 's/# C.UTF-8 UTF-8/C.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# ════════════════════════════════════════════════════════════
# core-utilities
#
# Installs the core utilities needed to for the non-display
# elements of the architecture
#
# ════════════════════════════════════════════════════════════

RUN apt-get install -y --no-install-recommends \
    # Certificates and basic network tools (needed by later stages)
    ca-certificates \
    curl \
    wget \
    # Python runtime (for mitmproxy stage)
    python3 \
    python3-pip \
    python3-venv \
    # Certificate tooling for Chromium NSS database
    libnss3-tools \
    openssl \
    # Network / firewall
    iptables \
    iproute2 \
    dnsutils \
    iputils-ping \
    # Build tools (required by some npm packages)
    git \
    build-essential \
    # Misc
    jq \
    xterm \
    less \
    vim \
    tmux \
    shellcheck

# ════════════════════════════════════════════════════════════
# display-stack
#
# Installs the virtual display, window manager, noVNC bridge,
# and in-container browser. These change very infrequently and
# are expensive to install, so they get their own stage.
#
# ════════════════════════════════════════════════════════════

RUN apt-get install -y --no-install-recommends \
    tigervnc-standalone-server \
    tigervnc-common \
    openbox \
    novnc \
    websockify \
    chromium \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-noto-core \
    dbus-x11

# apt install artifact clean-up
RUN apt-get clean \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# ── Create service users ──────────────────────────────────────
# coder: unprivileged, real home, bash shell (VS Code terminals need it)
RUN useradd \
        --uid "${CODER_UID}" \
        --create-home \
        --home-dir "/home/${CODER_USER}" \
        --shell /bin/bash \
        --comment "VS Code sandbox user — no sudo" \
        "${CODER_USER}" \
    && useradd \
        --uid "${MITM_UID}" \
        --create-home \
        --home-dir "/home/${MITM_USER}" \
        --shell /usr/sbin/nologin \
        --comment "mitmproxy service account — no sudo, no login" \
        "${MITM_USER}" \
    && deluser "${CODER_USER}" sudo 2>/dev/null || true \
    && deluser "${MITM_USER}"  sudo 2>/dev/null || true

# ── Shared CA cert directory ──────────────────────────────────
RUN mkdir -p /opt/mitmproxy-ca \
    && chown "${MITM_USER}:${MITM_USER}" /opt/mitmproxy-ca \
    && chmod 755 /opt/mitmproxy-ca


# TODO: Decide which is better to use npm or curl install for claude code
# ════════════════════════════════════════════════════════════
# STAGE 2 — node-runtime
#
# Installs Node.js 20 LTS via NodeSource on top of base.
# Kept as its own stage so a Node version bump only invalidates
# this layer and everything downstream — not the OS packages.
#
# Rebuild trigger: NODE_MAJOR changes.
# ════════════════════════════════════════════════════════════
#FROM base AS node-runtime
#
#ARG NODE_MAJOR=20
#
#RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
#    && apt-get install -y nodejs
#
## apt install artifact clean-up
#RUN apt-get clean \
#    && apt autoremove -y \
#    && rm -rf /var/lib/apt/lists/*
#
#RUN if [ "${CLAUDE_CODE_VERSION}" = "latest" ]; then \
#        npm install -g @anthropic-ai/claude-code; \
#    else \
#        npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
#    fi

# ════════════════════════════════════════════════════════════
# STAGE 3a — code-server-install
#
# Installs code-server and Claude Code CLI.
# Independent of the mitmproxy stage — changing CODE_SERVER_VERSION
# does not touch the mitmproxy venv, and vice versa.
#
# Rebuild trigger: CODE_SERVER_VERSION or CLAUDE_CODE_VERSION changes.
# ════════════════════════════════════════════════════════════
#FROM node-runtime AS code-server-install
FROM base AS code-server-install

# Version ARGs — override at build time:
#   podman build --build-arg CODE_SERVER_VERSION=4.96.0 .
ARG CODE_SERVER_VERSION=4.95.3
ARG CLAUDE_CODE_VERSION=latest

RUN curl -fsSL \
    "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_amd64.deb" \
    -o /tmp/code-server.deb \
    && dpkg -i /tmp/code-server.deb \
    && rm /tmp/code-server.deb

# TODO: come back to this:
#    && apt-get install -f -y

RUN runuser -u "${CODER_USER}" -- /bin/bash -c "cd ~/ && curl -fsSL https://claude.ai/install.sh | bash"

# apt install artifact clean-up
RUN apt-get clean \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# ════════════════════════════════════════════════════════════
# STAGE 3b — mitmproxy-install
#
# Installs mitmproxy in an isolated Python venv.
#
# Branches from BASE (not node-runtime) because mitmproxy is
# pure Python and has no dependency on Node.js whatsoever.
# This means changing NODE_MAJOR does not invalidate this stage,
# and changing MITMPROXY_VERSION does not touch code-server.
# The two stages are fully independent of each other.
#
# Rebuild trigger: MITMPROXY_VERSION changes.
# ════════════════════════════════════════════════════════════
FROM base AS mitmproxy-install

ARG MITMPROXY_VERSION=10.3.1

RUN python3 -m venv /opt/mitmproxy-venv \
    && /opt/mitmproxy-venv/bin/pip install \
        --no-cache-dir \
        "mitmproxy==${MITMPROXY_VERSION}"

# Lock venv ownership to mitm and remove execute permission for others.
# ENV carries MITM_USER from the base stage.
RUN chown -R "${MITM_USER}:${MITM_USER}" /opt/mitmproxy-venv \
    && chmod -R o-x /opt/mitmproxy-venv/bin

# ════════════════════════════════════════════════════════════
# STAGE 5 — final
#
# The thinnest and most frequently changed stage.
# Copies in scripts and configs, sets up user home directories,
# and defines the entrypoint.
#
# Editing a script or config only re-runs this layer —
# none of the expensive install stages above are touched.
#
# Rebuild trigger: any script, config, or ARG below changes.
# ════════════════════════════════════════════════════════════
FROM code-server-install AS final

ARG DEBIAN_FRONTEND=noninteractive

# ── mitmproxy allowlist ───────────────────────────────────────
# Owned root, world-readable, not writable by service users.
# Mounted read-only at runtime by podman compose so the allowlist
# can be edited on the host and reloaded without a rebuild.
RUN mkdir -p /etc/mitmproxy
COPY config/mitmproxy/allowlist.py /etc/mitmproxy/allowlist.py
RUN chown root:root /etc/mitmproxy/allowlist.py \
    && chmod 644 /etc/mitmproxy/allowlist.py

# ── Runtime scripts ───────────────────────────────────────────
COPY scripts/entrypoint.sh           /scripts/entrypoint.sh
COPY scripts/firewall.sh             /scripts/firewall.sh
COPY scripts/install-extensions.sh  /scripts/install-extensions.sh
COPY scripts/launch-chromium.sh     /scripts/launch-chromium.sh
COPY scripts/start-mitmproxy.sh     /scripts/start-mitmproxy.sh
RUN chmod +x \
        /scripts/entrypoint.sh \
        /scripts/firewall.sh \
        /scripts/install-extensions.sh \
        /scripts/launch-chromium.sh \
        /scripts/start-mitmproxy.sh

# Merge: copy the mitmproxy venv from its independent build stage.
# This is the point where both parallel build paths converge.
COPY --from=mitmproxy-install /opt/mitmproxy-venv /opt/mitmproxy-venv

# ── coder home directories and configs ───────────────────────
RUN mkdir -p \
        /home/${CODER_USER}/workspace \
        /home/${CODER_USER}/.vnc \
        /home/${CODER_USER}/.config/code-server \
        /home/${CODER_USER}/.local/share/code-server/User \
        /home/${CODER_USER}/.local/share/code-server/extensions \
        /home/${CODER_USER}/.pki/nssdb \
        /home/${CODER_USER}/.profile.d \
    && chown -R ${CODER_USER}:${CODER_USER} /home/${CODER_USER}

COPY config/vscode/settings.json \
    /home/${CODER_USER}/.local/share/code-server/User/settings.json

RUN chown ${CODER_USER}:${CODER_USER} \
        /home/${CODER_USER}/.local/share/code-server/User/settings.json

# code-server config (auth none — Chromium is inside the container)
RUN printf 'bind-addr: 127.0.0.1:8080\nauth: none\ncert: false\n' \
        > /home/${CODER_USER}/.config/code-server/config.yaml \
    && chown ${CODER_USER}:${CODER_USER} \
        /home/${CODER_USER}/.config/code-server/config.yaml

# Runtime env placeholder — populated by entrypoint.sh, cleared on stop
RUN printf '# Populated at container start by entrypoint.sh\n' \
        > /home/${CODER_USER}/.profile.d/sandbox-env.sh \
    && chmod 600 /home/${CODER_USER}/.profile.d/sandbox-env.sh \
    && chown ${CODER_USER}:${CODER_USER} \
        /home/${CODER_USER}/.profile.d/sandbox-env.sh

# .bashrc: source env (interactive shells — VS Code terminals etc.)
RUN printf 'source ~/.profile.d/sandbox-env.sh 2>/dev/null || true\n' \
        >> /home/${CODER_USER}/.bashrc \
    && chown ${CODER_USER}:${CODER_USER} /home/${CODER_USER}/.bashrc

RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/${CODER_USER}/.bashrc

# .profile: source env (all login shells, interactive AND non-interactive).
# .bashrc has an interactivity guard so it won't source sandbox-env.sh in
# non-interactive login shells (e.g. `bash -l -c "claude"`). .profile has
# no such guard, so NODE_EXTRA_CA_CERTS reaches the claude binary.
RUN printf 'source ~/.profile.d/sandbox-env.sh 2>/dev/null || true\n' \
        >> /home/${CODER_USER}/.profile \
    && chown ${CODER_USER}:${CODER_USER} /home/${CODER_USER}/.profile

# ── mitm config directory ─────────────────────────────────────
RUN mkdir -p /home/${MITM_USER}/.mitmproxy \
    && chown -R ${MITM_USER}:${MITM_USER} /home/${MITM_USER}/.mitmproxy \
    && chmod 700 /home/${MITM_USER}/.mitmproxy

# ── Port ──────────────────────────────────────────────────────
# Only the noVNC pixel-stream port is exposed to the host.
# code-server (:8080) and mitmproxy (:8081) are internal only.
EXPOSE 6080

# ── Image labels ──────────────────────────────────────────────
# Visible via: podman inspect <image> or podman image ls --format
# Note: container_name is set in compose.yml, not here.
LABEL org.opencontainers.image.title="mitmproxy-dev-sandbox" \
      org.opencontainers.image.description="VS Code sandbox — code-server + Chromium + noVNC + mitmproxy allowlist" \
      org.opencontainers.image.base.name="debian:bookworm-slim" \
      org.opencontainers.image.version="2.0"

ENTRYPOINT ["/scripts/entrypoint.sh"]
