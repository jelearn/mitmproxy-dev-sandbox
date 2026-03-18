# ============================================================
# VS Code + mitmproxy Sandbox  (v2 — corrected user separation)
# Base: Ubuntu 24.04
#
# Users:
#   coder  (uid 1000) — runs code-server, Chromium, Claude Code,
#                       and all VS Code processes. Has NO special
#                       network privileges. All outbound :443/:80
#                       is intercepted by mitmproxy.
#
#   mitm   (uid 1001) — runs mitmproxy only. The iptables REDIRECT
#                       exemption is granted to this uid exclusively,
#                       so it is the only process that can make real
#                       outbound HTTPS connections. Cannot sudo.
#                       Cannot write to the workspace.
#
# Architecture:
#   noVNC (pixels only) → Xtigervnc → Openbox → Chromium → code-server
#   All outbound :443 → iptables REDIRECT → mitmproxy (mitm uid)
#                                               ↓
#                                       allowlist.py (Python)
#                                               ↓
#                                    real upstream server (if allowed)
# ============================================================

FROM ubuntu:24.04

LABEL description="VS Code sandbox — code-server + Chromium + noVNC + mitmproxy (separate mitm user)"

ARG DEBIAN_FRONTEND=noninteractive

# UIDs are defined as build args so they can be overridden if needed
ARG CODER_UID=1000
ARG MITM_UID=1001
ARG CODER_USER=coder
ARG MITM_USER=mitm

# ── System packages ──────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Virtual display + window manager + noVNC
    tigervnc-standalone-server \
    tigervnc-common \
    openbox \
    novnc \
    websockify \
    # In-container browser (renders code-server UI inside container)
    chromium-browser \
    # Fonts
    fonts-liberation \
    fonts-dejavu-core \
    fonts-noto \
    # dbus (Chromium needs it)
    dbus-x11 \
    # Python + venv (for mitmproxy)
    python3 \
    python3-pip \
    python3-venv \
    # Network / firewall
    iptables \
    iproute2 \
    dnsutils \
    iputils-ping \
    ca-certificates \
    curl \
    wget \
    # Certificate tooling (certutil for Chromium NSS DB)
    openssl \
    libnss3-tools \
    # Build tools + runtimes
    git \
    build-essential \
    # Misc
    xterm \
    jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 20 LTS ───────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── code-server ───────────────────────────────────────────────
ARG CODE_SERVER_VERSION=4.95.3
RUN curl -fsSL \
    "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_amd64.deb" \
    -o /tmp/code-server.deb \
    && dpkg -i /tmp/code-server.deb \
    && rm /tmp/code-server.deb

# ── Claude Code CLI ───────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ── mitmproxy (in its own venv, owned by the mitm user later) ─
RUN python3 -m venv /opt/mitmproxy-venv \
    && /opt/mitmproxy-venv/bin/pip install --no-cache-dir mitmproxy

# ── Create users ──────────────────────────────────────────────
# coder: the developer user — no sudo, no special network caps
RUN useradd -m -u ${CODER_UID} -s /bin/bash ${CODER_USER}

# mitm: runs mitmproxy only — no login shell, no home dir access
# to the workspace, no sudo. The --no-create-home flag keeps it
# minimal; we create just the .mitmproxy config dir below.
RUN useradd -m -u ${MITM_UID} -s /usr/sbin/nologin ${MITM_USER}

# ── Shared CA cert directory ──────────────────────────────────
# mitmproxy writes its CA cert here; coder reads it to configure
# Node.js and Chromium trust. World-readable dir, cert is 644.
RUN mkdir -p /opt/mitmproxy-ca \
    && chown ${MITM_USER}:${MITM_USER} /opt/mitmproxy-ca \
    && chmod 755 /opt/mitmproxy-ca

# Lock down the mitmproxy venv so only mitm can execute it
RUN chown -R ${MITM_USER}:${MITM_USER} /opt/mitmproxy-venv

# ── coder user directory structure ───────────────────────────
RUN mkdir -p \
        /home/${CODER_USER}/workspace \
        /home/${CODER_USER}/.vnc \
        /home/${CODER_USER}/.config/code-server \
        /home/${CODER_USER}/.local/share/code-server/User \
        /home/${CODER_USER}/.continue \
        /home/${CODER_USER}/.pki/nssdb \
        /home/${CODER_USER}/.profile.d \
    && chown -R ${CODER_USER}:${CODER_USER} /home/${CODER_USER}

# ── Copy scripts and configs ──────────────────────────────────
COPY scripts/entrypoint.sh             /scripts/entrypoint.sh
COPY scripts/firewall.sh               /scripts/firewall.sh
COPY scripts/start-mitmproxy.sh        /scripts/start-mitmproxy.sh
COPY scripts/install-extensions.sh    /scripts/install-extensions.sh
COPY scripts/launch-chromium.sh       /scripts/launch-chromium.sh
COPY config/mitmproxy/allowlist.py    /etc/mitmproxy/allowlist.py
COPY config/code-server.yaml          /home/${CODER_USER}/.config/code-server/config.yaml
COPY config/vscode/settings.json      /home/${CODER_USER}/.local/share/code-server/User/settings.json
COPY config/continue/config.json      /home/${CODER_USER}/.continue/config.json

RUN chmod +x \
        /scripts/entrypoint.sh \
        /scripts/firewall.sh \
        /scripts/start-mitmproxy.sh \
        /scripts/install-extensions.sh \
        /scripts/launch-chromium.sh \
    && chown -R ${CODER_USER}:${CODER_USER} \
        /home/${CODER_USER}/.config \
        /home/${CODER_USER}/.local \
        /home/${CODER_USER}/.continue \
    # allowlist is owned by root/read-only to prevent tampering
    && chown root:root /etc/mitmproxy/allowlist.py \
    && chmod 644 /etc/mitmproxy/allowlist.py

# ── Expose only the noVNC port ────────────────────────────────
# 6080 = noVNC pixel stream (the only port the host needs)
# 8080 = code-server (internal, Chromium connects on loopback)
# 8081 = mitmproxy  (internal, iptables redirects here)
EXPOSE 6080

ENTRYPOINT ["/scripts/entrypoint.sh"]
