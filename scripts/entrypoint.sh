#!/usr/bin/env bash
# =============================================================
# entrypoint.sh — mitmproxy dev sandbox startup
#
# Runs as root. Drops to the appropriate user for each service:
#
#   mitm  (uid 1001) — mitmproxy only
#   coder (uid 1000) — everything else (VS Code, Chromium, etc.)
#
# Startup order:
#   1.  Validate ANTHROPIC_API_KEY
#   2.  Start mitmproxy as 'mitm'
#   3.  Wait for CA cert, then install it for 'coder'
#         a. System CA store
#         b. Chromium NSS database
#         c. Node.js (NODE_EXTRA_CA_CERTS)
#   4.  Apply iptables REDIRECT (exempts mitm uid, not coder)
#   5.  Start Xtigervnc virtual display
#   6.  Start Openbox window manager
#   7.  Start code-server
#   8.  Install VS Code extensions (first run only)
#   9.  Start noVNC pixel stream
#   10. Launch Chromium
#   11. Monitor
# =============================================================

set -euo pipefail

BASE_DIR=$(dirname $0)

CODER_USER="coder"
MITM_USER="mitm"
DISPLAY_NUM=":1"
VNC_PORT=5900
NOVNC_PORT=6080
SCREEN_RES="${SCREEN_RESOLUTION:-1600x900x24}"
WORKSPACE="/home/${CODER_USER}/workspace"
MITM_PORT=8081

# mitmproxy writes its CA cert to this shared directory.
# Owned by mitm (write), world-readable (read by coder/root).
MITM_CA_DIR="/opt/mitmproxy-ca"
MITM_CA="${MITM_CA_DIR}/mitmproxy-ca-cert.pem"

# mitmproxy config/state goes in mitm's home dir, not coder's
MITM_CONF_DIR="/home/${MITM_USER}/.mitmproxy"

log()   { echo "[entrypoint] $(date '+%H:%M:%S') $*"; }

# NOTE: on error drop into bash to inspect
# possibly remove this in future
error() { echo "[entrypoint] ERROR: $*" >&2; bash; exit 1; }

# ── Step 1: Validate API key ──────────────────────────────────
[[ -z "${ANTHROPIC_API_KEY:-}" ]] && \
    error "ANTHROPIC_API_KEY is not set. Add it to your .env file."
log "API key present (${#ANTHROPIC_API_KEY} chars)."

# TODO: Revisit, this is an attempt to persist more settings
log "Initializing .claude.json on first run, or linking to existing..."
if [[ ! -f "/home/${CODER_USER}/.claude/claude.json" ]]; then
    log "Moving default .claude.json"
    mv /home/${CODER_USER}/.claude.json /home/${CODER_USER}/.claude/claude.json
else
    log "Deleting default .claude.json"
    rm /home/${CODER_USER}/.claude.json
fi
ln -s /home/${CODER_USER}/.claude/claude.json /home/${CODER_USER}/.claude.json
chown ${CODER_USER}:${CODER_USER} /home/${CODER_USER}/.claude.json /home/${CODER_USER}/.claude/claude.json

# ── Step 2: Start mitmproxy as 'mitm' ─────────────────────────
# mitm is a no-login user (shell: /usr/sbin/nologin), so we use
# runuser -s /bin/bash to give it a temporary shell for this call.
${BASE_DIR}/start-mitmproxy.sh "${MITM_USER}" "${MITM_PORT}" "${MITM_CONF_DIR}" "${MITM_CA_DIR}"

# ── Step 3: Wait for CA cert ──────────────────────────────────
# mitmproxy generates its CA on first connection, not on startup.
# We make a test connection through it to trigger generation.
log "Waiting for mitmproxy CA cert to be generated..."

# Give mitmdump a moment to bind its port
sleep 2

# Trigger CA generation with a test CONNECT request.
# This will be blocked by allowlist.py (example.com is not allowed)
# but that's fine — we only need mitmproxy to generate the CA cert.
curl -sk \
    --proxy "http://127.0.0.1:${MITM_PORT}" \
    "https://example.com" > /dev/null 2>&1 || true

# Wait for the cert file to appear (mitmproxy writes it to confdir)
CERT_SOURCE="${MITM_CONF_DIR}/mitmproxy-ca-cert.pem"
for i in $(seq 1 30); do
    [[ -f "${CERT_SOURCE}" ]] && break
    sleep 0.5
done
[[ -f "${CERT_SOURCE}" ]] || error "mitmproxy CA cert was not generated within 15 seconds."

# Copy into the shared readable location and set permissions
cp "${CERT_SOURCE}" "${MITM_CA}"
chown "${MITM_USER}:${MITM_USER}" "${MITM_CA}"
chmod 644 "${MITM_CA}"   # world-readable so coder can trust it
log "CA cert available at ${MITM_CA}."

# 3a. System CA store (affects curl, wget, git, pip inside container)
log "Installing CA cert into system store..."
cp "${MITM_CA}" /usr/local/share/ca-certificates/mitmproxy-sandbox-ca.crt
update-ca-certificates --fresh > /dev/null 2>&1
log "System CA store updated."

# 3b. Chromium NSS database (Chromium doesn't use the system store)
log "Installing CA cert into Chromium NSS database for '${CODER_USER}'..."
NSS_DB="/home/${CODER_USER}/.pki/nssdb"
runuser -u "${CODER_USER}" -- bash -c "
    mkdir -p '${NSS_DB}'
    if [[ ! -f '${NSS_DB}/cert9.db' ]]; then
        certutil -N -d sql:'${NSS_DB}' --empty-password
    fi
    certutil -D -d sql:'${NSS_DB}' -n 'mitmproxy-sandbox-ca' 2>/dev/null || true
    certutil -A -d sql:'${NSS_DB}' \
        -n 'mitmproxy-sandbox-ca' \
        -t 'CT,C,C' \
        -i '${MITM_CA}'
"
log "Chromium NSS database updated."

# 3c. Node.js / Claude Code
# Node.js ignores the system CA store; NODE_EXTRA_CA_CERTS tells
# it where to find additional trusted certs. We write this into
# the coder user's environment so every VS Code terminal gets it.
log "Configuring Node.js and git CA trust for '${CODER_USER}'..."
cat > "/home/${CODER_USER}/.profile.d/sandbox-env.sh" <<EOF
# Injected by entrypoint.sh — do not edit manually.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
export NODE_EXTRA_CA_CERTS="${MITM_CA}"
export REQUESTS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
EOF
chmod 600 "/home/${CODER_USER}/.profile.d/sandbox-env.sh"
chown "${CODER_USER}:${CODER_USER}" "/home/${CODER_USER}/.profile.d/sandbox-env.sh"

BASHRC="/home/${CODER_USER}/.bashrc"
grep -q 'profile.d/sandbox-env' "${BASHRC}" 2>/dev/null \
    || echo 'source ~/.profile.d/sandbox-env.sh 2>/dev/null || true' >> "${BASHRC}"

# Git identity + CA config
runuser -u "${CODER_USER}" -- bash -c "
    git config --global user.name  '${GIT_AUTHOR_NAME:-Developer}'
    git config --global user.email '${GIT_AUTHOR_EMAIL:-dev@sandbox.local}'
    git config --global init.defaultBranch main
    git config --global safe.directory '*'
    git config --global http.sslCAInfo '/etc/ssl/certs/ca-certificates.crt'
"
log "Node.js and git CA trust configured."

# ── Step 4: Apply iptables REDIRECT ──────────────────────────
# firewall.sh exempts MITM_UID (1001 = mitm user) from the
# REDIRECT rule, NOT CODER_UID. coder's traffic always goes
# through mitmproxy.
log "Applying iptables rules..."
/scripts/firewall.sh
log "Firewall active."

# ── Step 5: Start Xtigervnc ───────────────────────────────────
log "Starting Xtigervnc on ${DISPLAY_NUM} (${SCREEN_RES})..."
VNC_DIR="/home/${CODER_USER}/.vnc"
mkdir -p "${VNC_DIR}"
chown "${CODER_USER}:${CODER_USER}" "${VNC_DIR}"

if [[ -n "${VNC_PASSWORD:-}" ]]; then
    printf '%s\n%s\n' "${VNC_PASSWORD}" "${VNC_PASSWORD}" \
        | vncpasswd -f > "${VNC_DIR}/passwd"
    chmod 600 "${VNC_DIR}/passwd"
    chown "${CODER_USER}:${CODER_USER}" "${VNC_DIR}/passwd"
    VNC_SEC_ARGS="-SecurityTypes VncAuth -PasswordFile ${VNC_DIR}/passwd"
else
    log "No VNC_PASSWORD set — unauthenticated (localhost only)."
    # NOTE: Possibly remove this option an error out
    # extra INSECURE arg is required
    VNC_SEC_ARGS="-SecurityTypes None --I-KNOW-THIS-IS-INSECURE"
fi

# NOTE: This was removed as it seems to be an invalid parameter
#        -geometry ${SCREEN_RES} \
runuser -u "${CODER_USER}" -- bash -c "
    tigervncserver ${DISPLAY_NUM} \
        -localhost no \
        -rfbport ${VNC_PORT} \
        ${VNC_SEC_ARGS} \
        -fg > /tmp/vnc.log 2>&1 &
"

X_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for i in $(seq 1 30); do
    [[ -S "${X_SOCKET}" ]] && break
    sleep 0.5
done
[[ -S "${X_SOCKET}" ]] || error "Xtigervnc did not start within 15 seconds." 
log "Xtigervnc ready."

# ── Step 6: Start Openbox ─────────────────────────────────────
log "Starting Openbox..."
DISPLAY="${DISPLAY_NUM}" runuser -u "${CODER_USER}" -- bash -c "
    openbox-session > /tmp/openbox.log 2>&1 &
"
sleep 1

# ── Step 7: Start code-server ─────────────────────────────────
log "Starting code-server..."
mkdir -p "${WORKSPACE}"
chown "${CODER_USER}:${CODER_USER}" "${WORKSPACE}"

DISPLAY="${DISPLAY_NUM}" runuser -u "${CODER_USER}" -- bash -c "
    source /home/${CODER_USER}/.profile.d/sandbox-env.sh
    code-server \
        --bind-addr 127.0.0.1:8080 \
        --user-data-dir /home/${CODER_USER}/.local/share/code-server \
        --extensions-dir /home/${CODER_USER}/.local/share/code-server/extensions \
        --auth none \
        '${WORKSPACE}' \
        > /tmp/code-server.log 2>&1 &
"

# Wait until code-server is actually responding
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:8080 > /dev/null 2>&1 && break
    sleep 1
done
log "code-server ready."

# ── Step 8: Install VS Code extensions (first run only) ───────
EXT_STAMP="/home/${CODER_USER}/.local/share/code-server/.extensions-installed"
if [[ ! -f "${EXT_STAMP}" ]]; then
    log "Installing VS Code extensions (first run — may take a few minutes)..."
    /scripts/install-extensions.sh "${CODER_USER}"
    touch "${EXT_STAMP}"
    chown "${CODER_USER}:${CODER_USER}" "${EXT_STAMP}"
    log "Extensions installed."
else
    log "Extensions already installed, skipping."
fi

# ── Step 9: Start noVNC ───────────────────────────────────────
log "Starting noVNC on :${NOVNC_PORT}..."

# TODO: Revisit this, as it finds 2 directories (same name) and includes a newline between
#NOVNC_PATH=$(find /usr/share/novnc /usr/local/share/novnc \
#    -name "vnc.html" -exec dirname '{}' \; 2>/dev/null | sort -u | head -1 \
#    || echo "/usr/share/novnc")
#
NOVNC_PATH=/usr/share/novnc

websockify \
    --web="${NOVNC_PATH}" \
    --wrap-mode=ignore \
    "0.0.0.0:${NOVNC_PORT}" \
    "localhost:${VNC_PORT}" \
    > /tmp/websocketify.log 2>&1 &
NOVNC_PID=$!
log "noVNC started (pid ${NOVNC_PID}). Connect at http://localhost:${NOVNC_PORT}"

# ── Step 10: Launch Chromium ──────────────────────────────────
log "Launching Chromium as '${CODER_USER}'..."
sleep 2  # give Openbox a moment to settle
DISPLAY="${DISPLAY_NUM}" runuser -u "${CODER_USER}" -- bash -c "
    source /home/${CODER_USER}/.profile.d/sandbox-env.sh
    /scripts/launch-chromium.sh > /tmp/chromium.log 2>&1 &
"

# ── Step 11: Monitor ──────────────────────────────────────────
log "All services up."
log "  noVNC      : http://localhost:${NOVNC_PORT}"
log "  mitmproxy  : :${MITM_PORT}  (uid ${MITM_USER}/$(id -u ${MITM_USER}))"
log "  code-server: :8080  (uid ${CODER_USER}/$(id -u ${CODER_USER}))"
log ""
log "Use './manage.sh proxy-log' to watch the allowlist in action."

tail \
    /tmp/mitmproxy.log \
    /tmp/vnc.log \
    /tmp/openbox.log \
    /tmp/websocketify.log \
    /tmp/code-server.log \
    /tmp/chromium.log \
    2>/dev/null

# Container exits when noVNC exits
wait "${NOVNC_PID}"
