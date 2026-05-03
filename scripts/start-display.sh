#!/usr/bin/env bash
# =============================================================
# start-display.sh — start display services as the 'display' user
#
# Handles Xtigervnc, Openbox, and noVNC/websockify.
# Called by entrypoint.sh during container startup.
#
# Must be run as root (it uses runuser to drop to display/coder).
#
# Startup order:
#   1. Ensure /run/user/<uid> exists (dbus needs this directory for its socket)
#   2. Start D-Bus session bus explicitly before Xtigervnc so the address is
#      known and stable — avoids the race against the asynchronous dbus-launch
#      call inside the system /etc/X11/Xtigervnc-session script.
#   3. Write a custom ~/.vnc/xstartup that sources .dbus-env so Openbox
#      inherits the deterministic session address on every container start.
#   4. Start Xtigervnc (which execs xstartup, which starts Openbox).
#   5. Grant coder X11 access via xhost.
#   6. Wait for Openbox to be running before proceeding.
#   7. Start noVNC/websockify.
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

log()   { echo "[display] $(date '+%H:%M:%S') $*" >&2; }
error() { echo "[display] $(date '+%H:%M:%S') ERROR: $*" >&2; exit 1; }

LOG_DIR="/home/${DISPLAY_USER}/logs"
RUN_DIR="/home/${DISPLAY_USER}/run"

# ── VNC password or no-auth ───────────────────────────────────
VNC_DIR="/home/${DISPLAY_USER}/.vnc"
mkdir -p "${VNC_DIR}"
chown "${DISPLAY_USER}:${DISPLAY_USER}" "${VNC_DIR}"

# socket directory, requiring stickybit for users creating
# their sockets
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

if [[ -n "${VNC_PASSWORD}" ]]; then
    printf '%s\n%s\n' "${VNC_PASSWORD}" "${VNC_PASSWORD}" \
        | vncpasswd -f > "${VNC_DIR}/passwd"
    chmod 600 "${VNC_DIR}/passwd"
    chown "${DISPLAY_USER}:${DISPLAY_USER}" "${VNC_DIR}/passwd"
    VNC_SEC_ARGS=(-SecurityTypes VncAuth -PasswordFile "${VNC_DIR}/passwd")
else
    log "No VNC_PASSWORD set — unauthenticated (localhost only)."
    VNC_SEC_ARGS=(-SecurityTypes None --I-KNOW-THIS-IS-INSECURE)
fi

# ── Runtime user directory ────────────────────────────────────
# dbus-daemon places its session socket under /run/user/<uid>.
# systemd-logind normally creates this at login, but it does not
# run inside a container, so we create it explicitly here.
DISPLAY_UID=$(id -u "${DISPLAY_USER}")
mkdir -p "/run/user/${DISPLAY_UID}"
chmod 700 "/run/user/${DISPLAY_UID}"
chown "${DISPLAY_USER}:${DISPLAY_USER}" "/run/user/${DISPLAY_UID}"

# ── D-Bus session bus ─────────────────────────────────────────
# Start dbus before Xtigervnc rather than relying on the implicit
# dbus-launch inside /etc/X11/Xtigervnc-session. That call is
# asynchronous and on first container start may not complete before
# Openbox or other services attempt to connect to the bus.
# Starting here gives us the address immediately and lets us write it
# to .dbus-env for all downstream consumers.
DBUS_ENV_FILE="/home/${DISPLAY_USER}/.dbus-env"

# Remove any stale env file from a previous stopped container run
# so we always write fresh socket credentials.
rm -f "${DBUS_ENV_FILE}"

log "Starting D-Bus session bus as '${DISPLAY_USER}'..."

# dbus-launch --sh-syntax outputs sh-syntax assignments for
# DBUS_SESSION_BUS_ADDRESS and DBUS_SESSION_BUS_PID, and blocks
# until dbus-daemon is ready before returning — so the daemon is
# up as soon as this command substitution returns.
DBUS_LAUNCH_OUT=$(runuser -u "${DISPLAY_USER}" -- dbus-launch --sh-syntax)
[[ -n "${DBUS_LAUNCH_OUT}" ]] || error "dbus-launch produced no output — cannot continue."

# Persist to a file so xstartup, Openbox, and other consumers can
# source it to connect to the session bus.
printf '%s\n' "${DBUS_LAUNCH_OUT}" > "${DBUS_ENV_FILE}"
chmod 600 "${DBUS_ENV_FILE}"
chown "${DISPLAY_USER}:${DISPLAY_USER}" "${DBUS_ENV_FILE}"

pgrep -u "${DISPLAY_USER}" dbus-daemon > /dev/null 2>&1 \
    || error "D-Bus daemon process not found after launch."
log "D-Bus session bus ready."

# ── Custom xstartup ───────────────────────────────────────────
# tigervncserver uses ~/.vnc/xstartup when present, in preference to
# the system /etc/X11/Xtigervnc-session. This custom script sources
# .dbus-env before launching Openbox so the session always uses our
# explicitly-started bus rather than racing against the system script's
# own dbus-launch invocation.
cat > "${VNC_DIR}/xstartup" << 'XSTARTUP'
#!/usr/bin/env bash
# shellcheck source=/dev/null
source "${HOME}/.dbus-env" 2>/dev/null || true
mkdir -p "${HOME}/logs"
exec openbox-session >> "${HOME}/logs/openbox.log" 2>&1
XSTARTUP
chmod 755 "${VNC_DIR}/xstartup"
chown "${DISPLAY_USER}:${DISPLAY_USER}" "${VNC_DIR}/xstartup"

# ── Xtigervnc ─────────────────────────────────────────────────
# Build a safely-quoted arg string from the array so it can be
# embedded in the bash -c string without shellcheck word-split issues.
VNC_SEC_STR=$(printf '%q ' "${VNC_SEC_ARGS[@]}")

log "Starting Xtigervnc on ${DISPLAY_NUM} (${SCREEN_RES})..."
runuser -u "${DISPLAY_USER}" -- bash -c "
    tigervncserver '${DISPLAY_NUM}' \
        -localhost no \
        -rfbport '${VNC_PORT}' \
        ${VNC_SEC_STR} \
        -fg >> '${LOG_DIR}/vnc.log' 2>&1 &
    echo \$! > '${RUN_DIR}/vnc.pid'
"

X_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for _ in $(seq 1 30); do
    [[ -S "${X_SOCKET}" ]] && break
    sleep 0.5
done
[[ -S "${X_SOCKET}" ]] || error "Xtigervnc did not start within 15 seconds."
log "Xtigervnc ready."

# ── Grant coder X11 access ────────────────────────────────────
log "Granting '${CODER_USER}' access to display ${DISPLAY_NUM}..."
DISPLAY="${DISPLAY_NUM}" runuser -u "${DISPLAY_USER}" -- \
    xhost +SI:localuser:"${CODER_USER}"

# ── Wait for Openbox ──────────────────────────────────────────
# xstartup (exec'd by tigervncserver) starts openbox-session once
# Xtigervnc is ready. Poll rather than sleeping a fixed interval so
# we proceed as soon as it is up.
log "Waiting for Openbox..."
for _ in $(seq 1 20); do
    pgrep -u "${DISPLAY_USER}" openbox > /dev/null 2>&1 && break
    sleep 0.5
done
pgrep -u "${DISPLAY_USER}" openbox > /dev/null 2>&1 \
    || error "Openbox did not start within 10 seconds."
OPENBOX_PID=$(pgrep -u "${DISPLAY_USER}" openbox | head -1)
printf '%s\n' "${OPENBOX_PID}" > "${RUN_DIR}/openbox.pid"
log "Openbox ready (pid ${OPENBOX_PID})."

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
