#!/usr/bin/env bash
# =============================================================
# start-code-server.sh — start code-server as the 'coder' user
#
# Called by entrypoint.sh during container startup.
# Can also be called manually to restart code-server without
# restarting the whole container:
#
#   podman exec mitmproxy-dev-sandbox /scripts/start-code-server.sh
#
# Must be run as root (it uses runuser to drop to coder).
# =============================================================

set -euo pipefail

CODER_USER=${1:-${CODER_USER:-coder}}
WORKSPACE=${2:-${WORKSPACE:-/home/${CODER_USER}/workspace}}
DISPLAY_NUM=${3:-${DISPLAY_NUM:-:1}}
CODESERVER_PORT=${4:-${CODESERVER_PORT:-8080}}

log()   { echo "[code-server] $*"; }
error() { echo "[code-server] ERROR: $*" >&2; exit 1; }

LOG_FILE="/home/${CODER_USER}/logs/code-server.log"

log "Starting code-server as '${CODER_USER}' (uid $(id -u ${CODER_USER}))..."

# Ensure workspace exists and is owned by coder before code-server opens it.
mkdir -p "${WORKSPACE}"
chown "${CODER_USER}:${CODER_USER}" "${WORKSPACE}"

# Source sandbox-env.sh so NODE_EXTRA_CA_CERTS and friends are set for the
# code-server process — without these, HTTPS extensions and Claude Code fail.
DISPLAY="${DISPLAY_NUM}" runuser -u "${CODER_USER}" -- bash -c "
    source /home/${CODER_USER}/.profile.d/sandbox-env.sh 2>/dev/null || true
    code-server \
        --bind-addr 127.0.0.1:${CODESERVER_PORT} \
        --user-data-dir /home/${CODER_USER}/.local/share/code-server \
        --extensions-dir /home/${CODER_USER}/.local/share/code-server/extensions \
        --auth none \
        '${WORKSPACE}' \
        >> ${LOG_FILE} 2>&1 &
"

# Poll until code-server responds — it takes a few seconds to bind its port.
for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${CODESERVER_PORT}" > /dev/null 2>&1 && break
    sleep 1
done
curl -sf "http://127.0.0.1:${CODESERVER_PORT}" > /dev/null 2>&1 \
    || error "code-server did not respond within 30 seconds."

log "code-server ready on :${CODESERVER_PORT}."
