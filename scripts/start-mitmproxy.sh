#!/usr/bin/env bash
# =============================================================
# start-mitmproxy.sh — (re)start mitmproxy as the 'mitm' user
#
# Called by entrypoint.sh during container startup.
#
# Must be run as root (it uses runuser to drop to mitm).
# =============================================================

set -euo pipefail

MITM_USER=${1:-${MITM_USER:-mitm}}
MITM_PORT=${2:-${MITM_PORT:-8081}}
MITM_CONF_DIR=${3:-"/home/${MITM_USER}/.mitmproxy"}
MITM_CA_DIR=${4:-/opt/mitmproxy-ca}

log() { echo "[mitmproxy] $*"; }
error() { echo "[mitmproxy] ERROR: $*" >&2; exit 1; }

[[ -z "${MITM_USER:-}" ]] && \
    error "Missing user."
[[ -z "${MITM_PORT:-}" ]] && \
    error "Missing port."
[[ -z "${MITM_CONF_DIR:-}" ]] && \
    error "Missing config directory."
[[ -z "${MITM_CA_DIR:-}" ]] && \
    error "Missing CA directory."

MITM_PID_FILE="/home/${MITM_USER}/run/mitmproxy.pid"
MITM_LOG_FILE="/home/${MITM_USER}/logs/mitmproxy.log"

# Stop any existing mitmdump process
if [[ -f "${MITM_PID_FILE}" ]]; then
    OLD_PID=$(cat "${MITM_PID_FILE}")
    if kill -0 "${OLD_PID}" 2>/dev/null; then
        log "Stopping existing mitmproxy (pid ${OLD_PID})..."
        kill "${OLD_PID}"
        sleep 1
    fi
    rm -f "${MITM_PID_FILE}"
fi

log "Starting mitmproxy as '${MITM_USER}' (uid $(id -u ${MITM_USER}))..."

mkdir -p "${MITM_CONF_DIR}"
chown "${MITM_USER}:${MITM_USER}" "${MITM_CONF_DIR}"

runuser -u "${MITM_USER}" -- /bin/bash -c "
    /opt/mitmproxy-venv/bin/mitmdump \
        --mode transparent \
        --listen-host 0.0.0.0 \
        --listen-port ${MITM_PORT} \
        --set confdir=${MITM_CONF_DIR} \
        --set ssl_verify_upstream_trusted_confdir=/etc/ssl/certs \
        --scripts /etc/mitmproxy/allowlist.py \
        >> ${MITM_LOG_FILE} 2>&1 &
    echo \$! > ${MITM_PID_FILE}
"

NEW_PID=$(cat "${MITM_PID_FILE}")
log "mitmproxy started (pid ${NEW_PID}) on :${MITM_PORT}."
log "Running as: $(ps -p ${NEW_PID} -o user= 2>/dev/null || echo 'unknown')"
