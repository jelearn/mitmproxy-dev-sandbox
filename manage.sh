#!/usr/bin/env bash
# =============================================================
# manage.sh — VS Code + mitmproxy sandbox (v2)
# =============================================================

set -euo pipefail

BASE_DIR=$(dirname "$0")
BASE_PATH=$(readlink -f "${BASE_DIR}")

# TODO: Look these up from somewhere consitent
CODER_USER="coder"
WORKSPACE_GUEST="/home/${CODER_USER}/workspace"
WORKSPACE_HOST="${BASE_DIR}/workspace"

if [[ -f "${BASE_DIR}/.env" ]]; then
    # shellcheck source=/dev/null  # .env is intentionally absent from the repo
    source "${BASE_DIR}/.env"
fi

AGENT_SANDBOX_PORT="${AGENT_SANDBOX_PORT:-6080}"

# The directory name of the repository is used as the container prefix so that
# cloning the repo to a different directory produces an independent sandbox.
CONTAINER_PREFIX=$(basename "${BASE_PATH}")
CONTAINER_NAME=${AGENT_SANDBOX_NAME:-${CONTAINER_PREFIX}}
# TODO: Have this set by default in vnc.html or system settings
URL="http://localhost:${AGENT_SANDBOX_PORT}/vnc.html?resize=remote&autoconnect=true"

# Image name — derived from CONTAINER_NAME for a 1:1 mapping between image and container
IMAGE_NAME="${CONTAINER_NAME}"

# Named volumes — prefixed with CONTAINER_NAME to preserve the naming convention that
# podman compose previously used (<project>_<volume>), keeping existing data intact.
VOL_WORKSPACE="${CONTAINER_NAME}_workspace_data"
VOL_VSCODE_EXT="${CONTAINER_NAME}_vscode_extensions"
VOL_CLAUDE_AI="${CONTAINER_NAME}_claude_ai"
VOL_OPENCODE="${CONTAINER_NAME}_opencode_config"
VOL_MITMPROXY_CA="${CONTAINER_NAME}_mitmproxy_ca"

BLU='\033[0;34m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${BLU}[manage]${NC} $*"; }
ok()    { echo -e "${GRN}[manage]${NC} $*"; }
warn()  { echo -e "${YLW}[manage]${NC} $*"; }
error() { echo -e "${RED}[manage]${NC} $*" >&2; exit 1; }

require_running() {
    podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" \
        || error "Container not running. Run: ./manage.sh start"
}

sandbox_workspace_link() {
    # TODO:  This is only really needed in SE Linux environments,
    #        really it can be the same as the "workspace" directory otherwise.
    rm -f "${BASE_DIR}/sandbox"
    SANDBOX_PATH=$(podman volume inspect --format '{{.Mountpoint}}' "${VOL_WORKSPACE}")
    ln -fs "${SANDBOX_PATH}" "${BASE_DIR}/sandbox"
}

# Create any named volumes that do not already exist.
ensure_volumes() {
    local vol
    for vol in "${VOL_WORKSPACE}" "${VOL_VSCODE_EXT}" "${VOL_CLAUDE_AI}" \
               "${VOL_OPENCODE}" "${VOL_MITMPROXY_CA}"; do
        podman volume inspect "${vol}" > /dev/null 2>&1 \
            || podman volume create "${vol}" > /dev/null
    done
}

# Create the dedicated bridge network if it does not already exist.
# podman run defaults to slirp4netns for rootless containers; an explicit bridge
# network is required so that iptables rules inside the container behave the same
# way they would on a standard kernel bridge (matching previous podman compose behaviour).
ensure_network() {
    podman network inspect "${CONTAINER_NAME}_net" > /dev/null 2>&1 \
        || podman network create "${CONTAINER_NAME}_net" > /dev/null
}

load_allowlist() {
    info "Copying updated allowlist into container..."
    podman cp "${BASE_DIR}/config/mitmproxy/allowlist.py" \
        "${CONTAINER_NAME}:/etc/mitmproxy/allowlist.py"
    sleep 2
    ok "Allowlist reloaded (mitmproxy file-watch picks up changes within ~1s)."
}

load_opencode() {
    info "Copying updated opencode config into container..."
    podman cp "${BASE_DIR}/config/opencode/config.json" \
        "${CONTAINER_NAME}:/home/${CODER_USER}/.config/opencode/config.json"
    ok "opencode config reloaded (next time you run opencode)."
}

load_latest_config() {
    load_allowlist
    load_opencode
}

# Start the container with all settings previously defined in compose.yml.
container_start() {
    podman run -d \
        --replace \
        --name "${CONTAINER_NAME}" \
        --network "${CONTAINER_NAME}_net" \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl net.ipv6.conf.default.disable_ipv6=1 \
        --sysctl net.ipv6.conf.lo.disable_ipv6=1 \
        --cap-add NET_ADMIN \
        --security-opt no-new-privileges=true \
        -p "127.0.0.1:${AGENT_SANDBOX_PORT}:6080" \
        -e "SCREEN_RESOLUTION=${SCREEN_RESOLUTION:-1600x900x24}" \
        -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Developer}" \
        -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-dev@sandbox.local}" \
        --memory 8g \
        --cpus 4.0 \
        --shm-size 1g \
        --restart unless-stopped \
        -v "${VOL_WORKSPACE}:/home/coder/workspace" \
        -v "${VOL_VSCODE_EXT}:/home/coder/.local/share/code-server/extensions" \
        -v "${VOL_CLAUDE_AI}:/home/coder/.claude" \
        -v "${VOL_OPENCODE}:/home/coder/.config/opencode" \
        -v "${VOL_MITMPROXY_CA}:/opt/mitmproxy-ca" \
        "${IMAGE_NAME}"
    load_latest_config
}

# Stop and remove the container (idempotent — safe to call when not running).
container_stop() {
    podman stop "${CONTAINER_NAME}" 2>/dev/null && ok "Container stopped" || true
    podman rm   "${CONTAINER_NAME}" 2>/dev/null && ok "Container removed" || true
}

build_image() {
    info "Building image..."
    podman build -t "${IMAGE_NAME}" -f "${BASE_DIR}/Containerfile" "${BASE_DIR}"
    ok "Build complete."
}

cmd="${1:-help}"

case "${cmd}" in
    build)
        build_image
        ;;

    start)
        if ! podman image exists "${IMAGE_NAME}"; then
            info "Image '${IMAGE_NAME}' does not exist..."
            build_image
        fi

        ensure_volumes
        ensure_network
        container_start
        sleep 3
        sandbox_workspace_link
        ok "noVNC at: ${URL}"
        ;;

    stop)
        container_stop
        ok "Stopped."
        ;;

    restart)
        container_stop
        ensure_volumes
        ensure_network
        container_start
        sandbox_workspace_link
        ok "Restarted. ${URL}"
        ;;

    load_workspace)
        require_running
        if [[ ! -d "${WORKSPACE_HOST}" ]]; then
            error "Local workspace does not exist: ${WORKSPACE_HOST}"
        fi
        # NOTE: The deletion method using rm -rf means that a directory may be found
        # and still deleted, so we ignore all failures, then check that everything is gone after
        # to be sure.
        podman exec "${CONTAINER_NAME}" find "${WORKSPACE_GUEST}" -mindepth 1 -exec rm -rf "{}" \; || true
        podman exec -e WORKSPACE_GUEST="${WORKSPACE_GUEST}" "${CONTAINER_NAME}" \
            sh -c 'test -z "$(find "${WORKSPACE_GUEST}" -mindepth 1 -print -quit )"' \
            || error "Workspace not fully removed."
        podman cp "${WORKSPACE_HOST}" "${CONTAINER_NAME}:/home/coder/"
        podman exec "${CONTAINER_NAME}" chown -R "${CODER_USER}:${CODER_USER}" "${WORKSPACE_GUEST}"
        ok "Workspace loaded."
    ;;

    status)
        if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            ok "RUNNING"
            podman ps --filter "name=${CONTAINER_NAME}" \
                --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            echo ""; info "noVNC: ${URL}"

            # Show which user each key process is running as
            echo ""
            info "Process user verification:"
            podman exec "${CONTAINER_NAME}" \
                ps -eo user,pid,comm \
                | awk '$3~/mitmdump|code-server|chromium/{printf "  %-12s pid=%-6s %s\n",$1,$2,$3}'
        else
            warn "NOT running."
        fi
        ;;

    logs)
        require_running
        podman logs -f "${CONTAINER_NAME}"
        ;;

    # ── Proxy commands ────────────────────────────────────────

    proxy-log)
        require_running
        info "Live proxy traffic (Ctrl-C to stop):"
        podman exec "${CONTAINER_NAME}" \
            tail -n 80 -f /home/mitm/logs/mitmproxy.log \
            | grep --line-buffered -E '\[(ALLOWED|BLOCKED|ALLOWLIST)\]'
        ;;

    blocked)
        require_running
        info "Recently blocked requests:"
        podman exec "${CONTAINER_NAME}" \
            grep '\[BLOCKED\]' /home/mitm/logs/mitmproxy.log | tail -50 \
            || info "None yet."
        ;;

    allowed)
        require_running
        info "Recently allowed requests:"
        podman exec "${CONTAINER_NAME}" \
            grep '\[ALLOWED\]' /home/mitm/logs/mitmproxy.log | tail -50 \
            || info "None yet."
        ;;

    reload-allowlist)
        require_running
        load_allowlist
        info "Run './manage.sh proxy-log' to confirm the new rules are active."
        ;;

    verify-users)
        # Confirm mitmproxy is NOT running as coder or root
        require_running
        info "Verifying process ownership..."
        echo ""
        podman exec "${CONTAINER_NAME}" \
            ps -eo user,pid,ppid,comm,args \
            | grep -E 'USER|mitmdump|code-server|chromium|tigervnc|websockify|openbox'
        echo ""

        MITM_USER=$(podman exec "${CONTAINER_NAME}" \
            ps -eo user,comm | awk '$2=="mitmdump"{print $1}' | head -1)
        CODER_CODESERVER=$(podman exec "${CONTAINER_NAME}" \
            ps -ef | grep "/usr/lib/code-server/lib/node /usr/lib/code-server --bind-addr 127.0.0.1" | awk '{print $1}' | head -1)
        DISPLAY_VNC=$(podman exec "${CONTAINER_NAME}" \
            ps -eo user,comm | awk '$2~/[Xx]tigervnc|[Xx]vnc/{print $1}' | head -1)

        if [[ "${MITM_USER}" == "mitm" ]]; then
            ok "mitmproxy is running as 'mitm' ✓"
        else
            warn "WARNING: mitmproxy is running as '${MITM_USER:-unknown}' — expected 'mitm'"
        fi

        if [[ "${CODER_CODESERVER}" == "coder" ]]; then
            ok "code-server is running as 'coder' ✓"
        else
            warn "WARNING: code-server is running as '${CODER_CODESERVER:-unknown}' — expected 'coder'"
        fi

        if [[ "${DISPLAY_VNC}" == "display" ]]; then
            ok "Xtigervnc is running as 'display' ✓"
        else
            warn "WARNING: Xtigervnc is running as '${DISPLAY_VNC:-unknown}' — expected 'display'"
        fi
        ;;

    firewall)
        require_running
        info "iptables filter INPUT:"
        podman exec "${CONTAINER_NAME}" iptables -L INPUT -n --line-numbers -v
        echo ""
        info "iptables nat OUTPUT (REDIRECT rules):"
        podman exec "${CONTAINER_NAME}" iptables -t nat -L OUTPUT -n --line-numbers -v
        echo ""
        info "iptables filter OUTPUT:"
        podman exec "${CONTAINER_NAME}" iptables -L OUTPUT -n --line-numbers -v
        ;;

    ca-cert)
        require_running
        info "Exporting mitmproxy CA cert to ./mitmproxy-sandbox-ca.pem"
        podman exec "${CONTAINER_NAME}" cat /opt/mitmproxy-ca/mitmproxy-ca-cert.pem \
            > ./mitmproxy-sandbox-ca.pem
        ok "Saved. Do NOT import this into your host browser trust store."
        ;;

    # ── Shell access ──────────────────────────────────────────

    shell)
        require_running
        warn "Root shell in container."
        podman exec -it "${CONTAINER_NAME}" /bin/bash
        ;;

    coder)
        require_running
        info "Shell as 'coder'..."
        podman exec -it --user coder "${CONTAINER_NAME}" /bin/bash -l -c "cd ~/workspace; bash"
        ;;

    claude)
        require_running
        info "Running claude as 'coder'..."
        podman exec -it --user coder "${CONTAINER_NAME}" /bin/bash -l -c "cd ~/workspace && claude"
        ;;

    opencode)
        require_running
        info "Running opencode as 'coder'..."
        podman exec -it --user coder "${CONTAINER_NAME}" /bin/bash -l -c "cd ~/workspace && opencode"
        ;;

    display)
        require_running
        warn "Shell as 'display' user (proxy process owner)."
        podman exec -it --user display "${CONTAINER_NAME}" /bin/bash -l
        ;;

    mitm)
        require_running
        warn "Shell as 'mitm' user (proxy process owner)."
        podman exec -it --user mitm "${CONTAINER_NAME}" /bin/bash -l
        ;;

    # ── Volume management ─────────────────────────────────────

    reset-workspace)
        warn "Deletes all workspace files."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        container_stop
        podman volume rm "${VOL_WORKSPACE}" 2>/dev/null || true
        ok "Workspace removed."
        ;;

    reset-ca)
        warn "Deletes the mitmproxy CA cert volume."
        warn "A new CA is generated on next start and reinstalled into Chromium."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        container_stop
        podman volume rm "${VOL_MITMPROXY_CA}" 2>/dev/null || true
        ok "CA volume removed."
        ;;

    clean)
        warn "Removes container, image, and network."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        container_stop
        podman rmi "${IMAGE_NAME}" 2>/dev/null || true
        podman network rm "${CONTAINER_NAME}_net" 2>/dev/null || true
        ok "Cleaned."
        ;;

    help|*)
        echo ""
        echo "Managment utility for the mitmproxy development Sandbox"
        echo ""
        echo "  $(basename "$0") <command>"
        echo ""
        printf "  %-22s %s\n" "build"            "Build the podman image"
        printf "  %-22s %s\n" "start"            "Start the container"
        printf "  %-22s %s\n" "load_workspace"   "Replaces the ${CODER_USER} user's workspace in sandbox with: ${WORKSPACE_GUEST}"
        printf "  %-22s %s\n" "stop / restart"   "Stop or restart"
        printf "  %-22s %s\n" "status"           "Status + process user summary"
        printf "  %-22s %s\n" "logs"             "Tail all logs"
        echo ""
        printf "  %-22s %s\n" "proxy-log"        "Live ALLOWED/BLOCKED feed"
        printf "  %-22s %s\n" "blocked"          "Recent blocked requests"
        printf "  %-22s %s\n" "allowed"          "Recent allowed requests"
        printf "  %-22s %s\n" "reload-allowlist" "Reload allowlist.py without restart"
        printf "  %-22s %s\n" "verify-users"     "Confirm mitmproxy!=coder, coder!=root"
        printf "  %-22s %s\n" "firewall"         "Show iptables rules"
        printf "  %-22s %s\n" "ca-cert"          "Export CA cert to host (inspect only)"
        echo ""
        printf "  %-22s %s\n" "shell"            "Root shell"
        printf "  %-22s %s\n" "claude"           "Run Claude Code as coder"
        printf "  %-22s %s\n" "opencode"         "Run opencode as coder"
        printf "  %-22s %s\n" "coder"            "Shell as coder"
        printf "  %-22s %s\n" "display"          "Shell as display"
        printf "  %-22s %s\n" "mitm"             "Shell as mitm"
        printf "  %-22s %s\n" "reset-workspace"  "Delete workspace volume"
        printf "  %-22s %s\n" "reset-ca"         "Delete CA cert volume"
        printf "  %-22s %s\n" "clean"            "Remove container, image, and network"
        echo ""
        ;;
esac
