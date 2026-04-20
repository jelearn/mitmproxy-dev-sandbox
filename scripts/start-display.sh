#!/usr/bin/env bash
# =============================================================
# start-display.sh — start display services as the 'display' user
#
# Handles Xtigervnc, Openbox, and noVNC/websockify.
# Called by entrypoint.sh during container startup.
#
# Must be run as root (it uses runuser to drop to display/coder).
#
# Echoes the websockify PID to stdout so the caller can wait on it.
# All log output goes to stderr.
# =============================================================

set -euo pipefail

DISPLAY_USER=${1:-${DISPLAY_USER:-display}}
CODER_USER=${2:-${CODER_USER:-coder}}
DISPLAY_NUM=${3:-${DISPLAY_NUM:-:1}}
VNC_PORT=${4:-${VNC_PORT:-5900}}
NOVNC_PORT=${5:-${NOVNC_PORT:-6080}}
SCREEN_RES=${6:-${SCREEN_RESOLUTION:-1600x900x24}}
VNC_PASSWORD=${7:-}

log()   { echo "[display] $*" >&2; }
error() { echo "[display] ERROR: $*" >&2; exit 1; }

LOG_DIR="/home/${DISPLAY_USER}/logs"
RUN_DIR="/home/${DISPLAY_USER}/run"

# ── VNC password or no-auth ───────────────────────────────────
VNC_DIR="/home/${DISPLAY_USER}/.vnc"
mkdir -p "${VNC_DIR}"
chown "${DISPLAY_USER}:${DISPLAY_USER}" "${VNC_DIR}"

if [[ -n "${VNC_PASSWORD}" ]]; then
    printf '%s\n%s\n' "${VNC_PASSWORD}" "${VNC_PASSWORD}" \
        | vncpasswd -f > "${VNC_DIR}/passwd"
    chmod 600 "${VNC_DIR}/passwd"
    chown "${DISPLAY_USER}:${DISPLAY_USER}" "${VNC_DIR}/passwd"
    VNC_SEC_ARGS="-SecurityTypes VncAuth -PasswordFile ${VNC_DIR}/passwd"
else
    log "No VNC_PASSWORD set — unauthenticated (localhost only)."
    VNC_SEC_ARGS="-SecurityTypes None --I-KNOW-THIS-IS-INSECURE"
fi

# ── Xtigervnc ─────────────────────────────────────────────────
log "Starting Xtigervnc on ${DISPLAY_NUM} (${SCREEN_RES})..."
runuser -u "${DISPLAY_USER}" -- bash -c "
    tigervncserver ${DISPLAY_NUM} \
        -localhost no \
        -rfbport ${VNC_PORT} \
        ${VNC_SEC_ARGS} \
        -fg >> ${LOG_DIR}/vnc.log 2>&1 &
    echo \$! > ${RUN_DIR}/vnc.pid
"

X_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for i in $(seq 1 30); do
    [[ -S "${X_SOCKET}" ]] && break
    sleep 0.5
done
[[ -S "${X_SOCKET}" ]] || error "Xtigervnc did not start within 15 seconds."
log "Xtigervnc ready."

# ── Grant coder X11 access ────────────────────────────────────
log "Granting '${CODER_USER}' access to display ${DISPLAY_NUM}..."
DISPLAY="${DISPLAY_NUM}" runuser -u "${DISPLAY_USER}" -- \
    xhost +SI:localuser:"${CODER_USER}"

# ── Openbox ───────────────────────────────────────────────────
log "Starting Openbox..."
DISPLAY="${DISPLAY_NUM}" runuser -u "${DISPLAY_USER}" -- bash -c "
    openbox-session >> ${LOG_DIR}/openbox.log 2>&1 &
    echo \$! > ${RUN_DIR}/openbox.pid
"
sleep 1

# ── noVNC / websockify ────────────────────────────────────────
NOVNC_PATH=/usr/share/novnc
log "Starting noVNC on :${NOVNC_PORT}..."
runuser -u "${DISPLAY_USER}" -- bash -c "
    websockify \
        --web='${NOVNC_PATH}' \
        --wrap-mode=ignore \
        '0.0.0.0:${NOVNC_PORT}' \
        'localhost:${VNC_PORT}' \
        >> ${LOG_DIR}/websockify.log 2>&1 &
    echo \$! > ${RUN_DIR}/websockify.pid
"

NOVNC_PID=$(cat "${RUN_DIR}/websockify.pid")
log "noVNC started (pid ${NOVNC_PID}). Connect at http://localhost:${NOVNC_PORT}"

echo "${NOVNC_PID}"
