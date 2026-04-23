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
#   coder   — runs code-server, Chromium, Claude Code, opencode,
#             and all VS Code processes. Has NO special
#             network privileges. All outbound :443/:80
#             is intercepted by mitmproxy.
#
#   mitm    — runs mitmproxy only. The iptables REDIRECT
#             exemption is granted to this uid exclusively,
#             so it is the only process that can make real
#             outbound HTTPS connections. Cannot sudo.
#             Cannot write to the workspace.
#
#   display — runs Xtigervnc, Openbox, and noVNC/websockify.
#             Grants coder X11 access via xhost. No network
#             privileges beyond localhost.
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
#   Typically the image is named at build time:  podman build -t myname .
#   Then referenced when starting a container (also named at runtime): podman run --name myname
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

# NOTE: This is the full list of ARGs used in the build, however
# they are repeated again below per lay as needed in order to support
# podman 4.9.3 as a minimum version (current default on Ubuntu).
# TODO: Re-evaluate to support a more modern version 5.x that doesn't
# require the duplication.
#
# User identity ARGs — override at build time if your host UIDs differ:
#   podman build --build-arg CODER_UID=1100 --build-arg MITM_UID=1101 .
#ARG CODER_USER=coder
#ARG CODER_UID=1100
#ARG MITM_USER=mitm
#ARG MITM_UID=1101
#ARG DISPLAY_USER=display
#ARG DISPLAY_UID=1102
#
# Port ARGs — override at build time to remap services:
#   podman build --build-arg MITM_PORT=8082 .
#ARG AGENT_SANDBOX_PORT=6080
#ARG MITM_PORT=8081
#ARG VNC_PORT=5900
#ARG NOVNC_PORT=6080
#ARG CODESERVER_PORT=8080
#
# Persist user names and ports as ENV so downstream stages and all
# runtime scripts can reference them without re-declaring ARGs
# (ARGs do not cross stage boundaries, and scripts read ENV at runtime).
#ENV CODER_USER=${CODER_USER} \
#    CODER_UID=${CODER_UID} \
#    MITM_USER=${MITM_USER} \
#    MITM_UID=${MITM_UID} \
#    DISPLAY_USER=${DISPLAY_USER} \
#    DISPLAY_UID=${DISPLAY_UID} \
#    MITM_PORT=${MITM_PORT} \
#    VNC_PORT=${VNC_PORT} \
#    NOVNC_PORT=${NOVNC_PORT} \
#    CODESERVER_PORT=${CODESERVER_PORT}

FROM debian:bookworm-slim AS base

ARG DEBIAN_FRONTEND=noninteractive

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
    shellcheck \
    npm

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
    dbus-x11 \
    x11-xserver-utils  # provides xhost, used by start-display.sh to grant coder X11 access

# apt install artifact clean-up
RUN apt-get clean \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

FROM base as base-user

# TODO: decide if minimum supported podman version should be 4.9.3 or 5.x.
# User identity ARGs — override at build time if your host UIDs differ:
#   podman build --build-arg CODER_UID=1100 --build-arg MITM_UID=1101 .
ARG CODER_USER=coder
ARG CODER_UID=1100
ARG MITM_USER=mitm
ARG MITM_UID=1101
ARG DISPLAY_USER=display
ARG DISPLAY_UID=1102

# ── Create service users ──────────────────────────────────────
# coder: unprivileged, real home, bash shell (VS Code terminals need it)
# mitm, display: no login
# all: no sudo
RUN useradd \
        --uid "${CODER_UID}" \
        --create-home \
        --home-dir "/home/${CODER_USER}" \
        --shell /bin/bash \
        --comment "VS Code sandbox user" \
        "${CODER_USER}" \
    && useradd \
        --uid "${MITM_UID}" \
        --create-home \
        --home-dir "/home/${MITM_USER}" \
        --shell /usr/sbin/nologin \
        --comment "mitmproxy service account" \
        "${MITM_USER}" \
    && useradd \
        --uid "${DISPLAY_UID}" \
        --create-home \
        --home-dir "/home/${DISPLAY_USER}" \
        --shell /usr/sbin/nologin \
        --comment "display service account — Xtigervnc, Openbox, noVNC" \
        "${DISPLAY_USER}" \
    && deluser "${CODER_USER}"   sudo 2>/dev/null || true \
    && deluser "${MITM_USER}"    sudo 2>/dev/null || true \
    && deluser "${DISPLAY_USER}" sudo 2>/dev/null || true

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
# Installs code-server, Claude Code CLI, and opencode CLI.
# Independent of the mitmproxy stage — changing CODE_SERVER_VERSION
# does not touch the mitmproxy venv, and vice versa.
#
# Rebuild trigger: CODE_SERVER_VERSION or CLAUDE_CODE_VERSION changes.
# ════════════════════════════════════════════════════════════
#FROM node-runtime AS code-server-install
FROM base-user AS code-server-install

# User identity ARGs — override at build time if your host UIDs differ..
ARG CODER_USER=coder

# Version ARGs — override at build time to pin a specific release:
#   podman build --build-arg CODE_SERVER_VERSION=4.96.0 .
# Leave CODE_SERVER_VERSION empty (the default) to always install the latest.
ARG CODE_SERVER_VERSION=4.109.5
ARG CLAUDE_CODE_VERSION=latest

# Use the official install script so the latest release is picked up
# automatically on each build. The ${CODE_SERVER_VERSION:+--version "..."}
# expansion passes --version only when the ARG is non-empty, allowing the
# build to be pinned without changing this file. The install script also
# handles dependency resolution, removing the need for a separate apt-get -f.
RUN curl -fsSL https://code-server.dev/install.sh \
    | sh -s -- ${CODE_SERVER_VERSION:+--version "${CODE_SERVER_VERSION}"}

RUN runuser -u "${CODER_USER}" -- /bin/bash -c "cd ~/ && curl -fsSL https://claude.ai/install.sh | bash"

# Install opencode CLI — an OpenAI-compatible AI coding agent.
# Installs to ~/.local/bin/opencode (picked up by PATH via .bashrc export below).
RUN runuser -u "${CODER_USER}" -- /bin/bash -c "curl -fsSL https://opencode.ai/install | bash"

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
FROM base-user AS mitmproxy-install

ARG MITMPROXY_VERSION=10.3.1

RUN python3 -m venv /opt/mitmproxy-venv \
    && /opt/mitmproxy-venv/bin/pip install \
        --no-cache-dir \
        "mitmproxy==${MITMPROXY_VERSION}"

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

# User identity ARGs — override at build time if your host UIDs differ:
ARG CODER_USER=coder
ARG MITM_USER=mitm
ARG DISPLAY_USER=display

# Port ARGs — override at build time to remap services:
ARG AGENT_SANDBOX_PORT=6080

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
COPY scripts/start-code-server.sh   /scripts/start-code-server.sh
COPY scripts/start-display.sh       /scripts/start-display.sh
COPY scripts/start-mitmproxy.sh     /scripts/start-mitmproxy.sh
RUN chmod +x \
        /scripts/entrypoint.sh \
        /scripts/firewall.sh \
        /scripts/install-extensions.sh \
        /scripts/launch-chromium.sh \
        /scripts/start-code-server.sh \
        /scripts/start-display.sh \
        /scripts/start-mitmproxy.sh

# Merge: copy the mitmproxy venv from its independent build stage.
# This is the point where both parallel build paths converge.
COPY --from=mitmproxy-install /opt/mitmproxy-venv /opt/mitmproxy-venv
# Lock venv ownership to mitm and remove execute permission for others.
# ENV carries MITM_USER from the base stage.
RUN chown -R "${MITM_USER}:${MITM_USER}" /opt/mitmproxy-venv \
    && chmod -R o-x /opt/mitmproxy-venv/bin

# ── Service log and PID directories ──────────────────────────
RUN mkdir -p \
        /home/${MITM_USER}/logs \
        /home/${MITM_USER}/run \
    && chown -R ${MITM_USER}:${MITM_USER} \
        /home/${MITM_USER}/logs \
        /home/${MITM_USER}/run \
    && chmod 750 \
        /home/${MITM_USER}/logs \
        /home/${MITM_USER}/run \
    && mkdir -p \
        /home/${DISPLAY_USER}/logs \
        /home/${DISPLAY_USER}/run \
    && chown -R ${DISPLAY_USER}:${DISPLAY_USER} \
        /home/${DISPLAY_USER}/logs \
        /home/${DISPLAY_USER}/run \
    && chmod 750 \
        /home/${DISPLAY_USER}/logs \
        /home/${DISPLAY_USER}/run

# ── coder home directories and configs ───────────────────────
RUN mkdir -p \
        /home/${CODER_USER}/workspace \
        /home/${CODER_USER}/logs \
        /home/${CODER_USER}/.config/code-server \
        /home/${CODER_USER}/.local/share/code-server/User \
        /home/${CODER_USER}/.local/share/code-server/extensions \
        /home/${CODER_USER}/.pki/nssdb \
        /home/${CODER_USER}/.profile.d \
    && chown -R ${CODER_USER}:${CODER_USER} /home/${CODER_USER}

COPY config/code-server/settings.json \
    /home/${CODER_USER}/.local/share/code-server/User/settings.json

RUN chown ${CODER_USER}:${CODER_USER} \
        /home/${CODER_USER}/.local/share/code-server/User/settings.json

# code-server config (auth none — Chromium is inside the container)
COPY config/code-server/config.yaml \
    /home/${CODER_USER}/.config/code-server/config.yaml
RUN chown ${CODER_USER}:${CODER_USER} \
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

# .profile: source env (all login shells, interactive AND non-interactive).
# .bashrc has an interactivity guard so it won't source sandbox-env.sh in
# non-interactive login shells (e.g. `bash -l -c "claude"`). .profile has
# no such guard, so NODE_EXTRA_CA_CERTS reaches the claude binary.
RUN printf 'source ~/.profile.d/sandbox-env.sh 2>/dev/null || true\n' \
        >> /home/${CODER_USER}/.profile \
    && chown ${CODER_USER}:${CODER_USER} /home/${CODER_USER}/.profile

# ── opencode config ───────────────────────────────────────────
# Ship a minimal default config into a system path. entrypoint.sh
# copies it into the coder home on first run if no config exists,
# so the volume-persisted config survives container rebuilds.
RUN mkdir -p /etc/opencode
COPY config/opencode/config.json /etc/opencode/config.json
RUN chown root:root /etc/opencode/config.json \
    && chmod 644 /etc/opencode/config.json

# Pre-create the opencode config dir so the volume mount has
# the correct ownership when it is first initialised.
RUN mkdir -p /home/${CODER_USER}/.config/opencode \
    && chown -R ${CODER_USER}:${CODER_USER} /home/${CODER_USER}/.config/opencode

# ── mitm config directory ─────────────────────────────────────
RUN mkdir -p /home/${MITM_USER}/.mitmproxy \
    && chown -R ${MITM_USER}:${MITM_USER} /home/${MITM_USER}/.mitmproxy \
    && chmod 700 /home/${MITM_USER}/.mitmproxy

# ── display home directory ─────────────────────────────────────
RUN mkdir -p /home/${DISPLAY_USER}/.vnc \
    && chown -R ${DISPLAY_USER}:${DISPLAY_USER} /home/${DISPLAY_USER} \
    && chmod 700 /home/${DISPLAY_USER}/.vnc

# ── Openbox config (Chromium/VS Code undecorated + maximized) ──
# COPY doesn't expand ENV vars in paths, so stage via /tmp then move.
COPY config/openbox/rc.xml /tmp/openbox-rc.xml
RUN mkdir -p /home/${DISPLAY_USER}/.config/openbox \
    && mv /tmp/openbox-rc.xml /home/${DISPLAY_USER}/.config/openbox/rc.xml \
    && chown -R ${DISPLAY_USER}:${DISPLAY_USER} /home/${DISPLAY_USER}/.config/openbox

# ── Port ──────────────────────────────────────────────────────
# Only the noVNC pixel-stream port is exposed to the host.
# code-server (:8080) and mitmproxy (:8081) are internal only.
EXPOSE ${AGENT_SANDBOX_PORT}

ENTRYPOINT ["/scripts/entrypoint.sh"]
