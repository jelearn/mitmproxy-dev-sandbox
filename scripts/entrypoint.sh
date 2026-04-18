#!/usr/bin/env bash
# =============================================================
# entrypoint.sh — mitmproxy dev sandbox startup
#
# Runs as root. Drops to the appropriate user for each service:
#
#   mitm    (uid 1101) — mitmproxy only
#   display (uid 1102) — Xtigervnc, Openbox, noVNC/websockify
#   coder   (uid 1100) — VS Code, Chromium, Claude Code
#
# Startup order:
#   1.  Setup .claude environment files
#   2.  Start mitmproxy as 'mitm'
#   3.  Wait for CA cert, then inject it into coder's environment only
#         a. Build coder-scoped merged CA bundle (system certs + mitmproxy cert)
#         b. Chromium NSS database
#         c. Env vars: NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, SSL_CERT_FILE,
#            CURL_CA_BUNDLE, PIP_CERT, git http.sslCAInfo
#   4.  Apply iptables REDIRECT (exempts mitm uid, not coder)
#   5.  Start display services (Xtigervnc, Openbox, noVNC) as 'display'
#   6.  Start code-server as 'coder'
#   7.  Install VS Code extensions (first run only)
#   8.  Launch Chromium as 'coder'
#   9.  Monitor
# =============================================================

set -euo pipefail

BASE_DIR=$(dirname $0)

CODER_USER="${CODER_USER:-coder}"
MITM_USER="${MITM_USER:-mitm}"
DISPLAY_USER="${DISPLAY_USER:-display}"
DISPLAY_NUM="${DISPLAY_NUM:-:1}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
SCREEN_RES="${SCREEN_RESOLUTION:-1600x900x24}"
WORKSPACE="${WORKSPACE:-/home/${CODER_USER}/workspace}"
MITM_PORT="${MITM_PORT:-8081}"
CODESERVER_PORT="${CODESERVER_PORT:-8080}"

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

# ── Step 1: Setup claude.ai config  ──────────────────────────────────

# TODO: Revisit, this is an attempt to persist more settings
log "Initializing .claude.json on first run, or linking to existing..."
if [[ ! -f "/home/${CODER_USER}/.claude/claude.json" ]]; then
    log "Moving default .claude.json"
    runuser -u "${CODER_USER}" -- touch /home/${CODER_USER}/.claude.json
    runuser -u "${CODER_USER}" -- mv /home/${CODER_USER}/.claude.json /home/${CODER_USER}/.claude/claude.json
elif [[ -f "/home/${CODER_USER}/.claude.json" ]]; then
    log "Deleting default .claude.json"
    runuser -u "${CODER_USER}" -- rm /home/${CODER_USER}/.claude.json
fi
runuser -u "${CODER_USER}" -- ln -s /home/${CODER_USER}/.claude/claude.json /home/${CODER_USER}/.claude.json

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

# 3a. Build a coder-scoped merged CA bundle (system certs + mitmproxy cert).
# We do NOT add the mitmproxy cert to the system CA store — it is injected
# only into the coder user's environment via env vars below.
CODER_CA_BUNDLE="/home/${CODER_USER}/.config/ssl/ca-bundle.pem"
log "Building coder-scoped CA bundle at ${CODER_CA_BUNDLE}..."
mkdir -p "/home/${CODER_USER}/.config/ssl"
cat /etc/ssl/certs/ca-certificates.crt "${MITM_CA}" > "${CODER_CA_BUNDLE}"
chown -R "${CODER_USER}:${CODER_USER}" "/home/${CODER_USER}/.config/ssl"
chmod 644 "${CODER_CA_BUNDLE}"
log "Coder CA bundle ready."

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

# 3c. Inject CA trust into coder's environment.
# Node.js ignores the system CA store; NODE_EXTRA_CA_CERTS appends to its
# built-in bundle. All other tools (curl, Python, git, pip) get the merged
# bundle that combines system certs with the mitmproxy cert.
log "Configuring CA trust environment for '${CODER_USER}'..."
cat > "/home/${CODER_USER}/.profile.d/sandbox-env.sh" <<EOF
# Injected by entrypoint.sh — do not edit manually.
export NODE_EXTRA_CA_CERTS="${MITM_CA}"
export REQUESTS_CA_BUNDLE="${CODER_CA_BUNDLE}"
export SSL_CERT_FILE="${CODER_CA_BUNDLE}"
export CURL_CA_BUNDLE="${CODER_CA_BUNDLE}"
export PIP_CERT="${CODER_CA_BUNDLE}"
EOF
chmod 600 "/home/${CODER_USER}/.profile.d/sandbox-env.sh"
chown "${CODER_USER}:${CODER_USER}" "/home/${CODER_USER}/.profile.d/sandbox-env.sh"

BASHRC="/home/${CODER_USER}/.bashrc"
grep -q 'profile.d/sandbox-env' "${BASHRC}" 2>/dev/null \
    || echo 'source ~/.profile.d/sandbox-env.sh 2>/dev/null || true' >> "${BASHRC}"

# .profile is sourced for all login shells (interactive AND non-interactive),
# unlike .bashrc which is guarded by an interactivity check. This ensures
# NODE_EXTRA_CA_CERTS is set when claude runs via non-interactive login shells
# (e.g. `bash -l -c "claude"` from manage.sh).
PROFILE="/home/${CODER_USER}/.profile"
grep -q 'profile.d/sandbox-env' "${PROFILE}" 2>/dev/null \
    || echo 'source ~/.profile.d/sandbox-env.sh 2>/dev/null || true' >> "${PROFILE}"

# Git identity + CA config
runuser -u "${CODER_USER}" -- bash -c "
    git config --global user.name  '${GIT_AUTHOR_NAME:-Developer}'
    git config --global user.email '${GIT_AUTHOR_EMAIL:-dev@sandbox.local}'
    git config --global init.defaultBranch main
    git config --global safe.directory '*'
    git config --global http.sslCAInfo "${CODER_CA_BUNDLE}"
"
log "CA trust environment configured for '${CODER_USER}'."

# ── Step 4: Apply iptables REDIRECT ──────────────────────────
# firewall.sh exempts MITM_UID (1101 = mitm user) from the
# REDIRECT rule, NOT CODER_UID. coder's traffic always goes
# through mitmproxy.
log "Applying iptables rules..."
/scripts/firewall.sh
log "Firewall active."

# ── Step 5: Start display services ───────────────────────────
# Xtigervnc, Openbox, and noVNC run as the 'display' user.
# start-display.sh grants 'coder' X11 access via xhost and
# echoes the websockify PID so we can wait on it below.
log "Starting display services as '${DISPLAY_USER}'..."
NOVNC_PID=$("${BASE_DIR}/start-display.sh" \
    "${DISPLAY_USER}" "${CODER_USER}" "${DISPLAY_NUM}" \
    "${VNC_PORT}" "${NOVNC_PORT}" "${SCREEN_RES}" "${VNC_PASSWORD:-}")
log "Display services up (noVNC pid ${NOVNC_PID})."

# ── Step 6: Start code-server ─────────────────────────────────
"${BASE_DIR}/start-code-server.sh" \
    "${CODER_USER}" "${WORKSPACE}" "${DISPLAY_NUM}" "${CODESERVER_PORT}"

# ── Step 7: Install VS Code extensions (first run only) ───────
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

# ── Step 8: Launch Chromium ───────────────────────────────────
log "Launching Chromium as '${CODER_USER}'..."
sleep 2  # give Openbox a moment to settle
DISPLAY="${DISPLAY_NUM}" runuser -u "${CODER_USER}" -- bash -c "
    source /home/${CODER_USER}/.profile.d/sandbox-env.sh
    /scripts/launch-chromium.sh >> /home/${CODER_USER}/logs/chromium.log 2>&1 &
"

# ── Step 9: Monitor ───────────────────────────────────────────
log "All services up."
log "  noVNC      : http://localhost:${NOVNC_PORT}"
log "  mitmproxy  : :${MITM_PORT}  (uid ${MITM_USER}/$(id -u ${MITM_USER}))"
log "  code-server: :8080  (uid ${CODER_USER}/$(id -u ${CODER_USER}))"
log ""
log "Use './manage.sh proxy-log' to watch the allowlist in action."

tail -f \
    /home/${MITM_USER}/logs/mitmproxy.log \
    /home/${DISPLAY_USER}/logs/vnc.log \
    /home/${DISPLAY_USER}/logs/openbox.log \
    /home/${DISPLAY_USER}/logs/websockify.log \
    /home/${CODER_USER}/logs/code-server.log \
    /home/${CODER_USER}/logs/chromium.log \
    2>/dev/null

# Container exits when noVNC exits
wait "${NOVNC_PID}"
