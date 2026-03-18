#!/usr/bin/env bash
# =============================================================
# start-mitmproxy.sh — (re)start mitmproxy as the 'mitm' user
#
# Called by entrypoint.sh during container startup.
# Can also be called manually to restart mitmproxy without
# restarting the whole container:
#
#   podman exec mitmproxy-dev-sandbox /scripts/start-mitmproxy.sh
#
# Must be run as root (it uses runuser to drop to mitm).
# =============================================================

set -euo pipefail

MITM_USER="mitm"
MITM_PORT=8081
MITM_CONF_DIR="/home/${MITM_USER}/.mitmproxy"
MITM_CA_DIR="/opt/mitmproxy-ca"

log() { echo "[mitmproxy] $*"; }

# Stop any existing mitmdump process
if [[ -f /tmp/mitmproxy.pid ]]; then
    OLD_PID=$(cat /tmp/mitmproxy.pid)
    if kill -0 "${OLD_PID}" 2>/dev/null; then
        log "Stopping existing mitmproxy (pid ${OLD_PID})..."
        kill "${OLD_PID}"
        sleep 1
    fi
    rm -f /tmp/mitmproxy.pid
fi

log "Starting mitmproxy as '${MITM_USER}' (uid $(id -u ${MITM_USER}))..."

mkdir -p "${MITM_CONF_DIR}"
chown "${MITM_USER}:${MITM_USER}" "${MITM_CONF_DIR}"

runuser -u "${MITM_USER}" -s /bin/bash -- -c "
    /opt/mitmproxy-venv/bin/mitmdump \
        --mode transparent \
        --listen-host 0.0.0.0 \
        --listen-port ${MITM_PORT} \
        --set confdir=${MITM_CONF_DIR} \
        --set ssl_verify_upstream_trusted_confdir=/etc/ssl/certs \
        --scripts /etc/mitmproxy/allowlist.py \
        >> /tmp/mitmproxy.log 2>&1 &
    echo \$! > /tmp/mitmproxy.pid
"

NEW_PID=$(cat /tmp/mitmproxy.pid)
log "mitmproxy started (pid ${NEW_PID}) on :${MITM_PORT}."
log "Running as: $(ps -p ${NEW_PID} -o user= 2>/dev/null || echo 'unknown')"
