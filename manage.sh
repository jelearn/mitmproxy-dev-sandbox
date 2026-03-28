#!/usr/bin/env bash
# =============================================================
# manage.sh — VS Code + mitmproxy sandbox (v2)
# =============================================================

set -euo pipefail

BASE_DIR=$(dirname $0)

# TODO: Look these up from somewhere consitent
CODER_USER="coder"
WORKSPACE="/home/${CODER_USER}/workspace"

CONTAINER="mitmproxy-dev-sandbox"
IMAGE="mitmproxy-dev-sandbox:latest"
URL="http://localhost:6080/vnc.html"

BLU='\033[0;34m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${BLU}[manage]${NC} $*"; }
ok()    { echo -e "${GRN}[manage]${NC} $*"; }
warn()  { echo -e "${YLW}[manage]${NC} $*"; }
error() { echo -e "${RED}[manage]${NC} $*" >&2; exit 1; }

require_running() {
    podman ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
        || error "Container not running. Run: ./manage.sh start"
}

sandbox_workspace_link() {
    rm -f sandbox
    ln -fs "$(podman volume inspect --format '{{.Mountpoint}}' mitmproxy-dev-sandbox_workspace_data)" sandbox
}

cmd="${1:-help}"

case "${cmd}" in
    build)
        info "Building ${IMAGE}..."
        podman build -t "${IMAGE}" .
        ok "Build complete."
        ;;

    start)
        [[ -f .env ]] || error "No .env file. Create one with ANTHROPIC_API_KEY=..."
        podman compose up -d
        sleep 3
        sandbox_workspace_link
        ok "noVNC at: ${URL}"
        ;;

    stop)   podman compose down;        ok "Stopped." ;;
    restart) podman compose down && podman compose up -d; sandbox_workspace_link; ok "Restarted. ${URL}" ;;

    load_workspace)
        podman exec "${CONTAINER}" find "${WORKSPACE}" -mindepth 1 -exec rm -rf "{}" \;
        podman cp "${BASE_DIR}/workspace" "${CONTAINER}:/home/coder/"
        podman exec "${CONTAINER}" chown -R "${CODER_USER}:${CODER_USER}" "${WORKSPACE}"
    ;;

    status)
        if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            ok "RUNNING"
            podman ps --filter "name=${CONTAINER}" \
                --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            echo ""; info "noVNC: ${URL}"

            # Show which user each key process is running as
            echo ""
            info "Process user verification:"
            podman exec "${CONTAINER}" \
                ps -eo user,pid,comm \
                | awk '$3~/mitmdump|code-server|chromium/{printf "  %-12s pid=%-6s %s\n",$1,$2,$3}'
        else
            warn "NOT running."
        fi
        ;;

    logs)
        require_running
        podman logs -f "${CONTAINER}"
        ;;

    # ── Proxy commands ────────────────────────────────────────

    proxy-log)
        require_running
        info "Live proxy traffic (Ctrl-C to stop):"
        podman exec "${CONTAINER}" \
            tail -n 80 -f /tmp/mitmproxy.log \
            | grep --line-buffered -E '\[(ALLOWED|BLOCKED)\]'
        ;;

    blocked)
        require_running
        info "Recently blocked requests:"
        podman exec "${CONTAINER}" \
            grep '\[BLOCKED\]' /tmp/mitmproxy.log | tail -50 \
            || info "None yet."
        ;;

    allowed)
        require_running
        info "Recently allowed requests:"
        podman exec "${CONTAINER}" \
            grep '\[ALLOWED\]' /tmp/mitmproxy.log | tail -50 \
            || info "None yet."
        ;;

    reload-allowlist)
        require_running
        info "Copying updated allowlist into container..."
        podman cp "${BASE_DIR}/config/mitmproxy/allowlist.py" \
            "${CONTAINER}:/etc/mitmproxy/allowlist.py"
        MITM_PID=$(podman exec "${CONTAINER}" \
            cat /tmp/mitmproxy.pid 2>/dev/null || true)
        if [[ -n "${MITM_PID}" ]]; then
            podman exec "${CONTAINER}" kill -HUP "${MITM_PID}"
            ok "mitmproxy killed (pid ${MITM_PID})."
        else
            warn "mitmproxy PID not found."
        fi
        podman exec "${CONTAINER}" "/scripts/start-mitmproxy.sh"
        ;;

    verify-users)
        # Confirm mitmproxy is NOT running as coder or root
        require_running
        info "Verifying process ownership..."
        echo ""
        podman exec "${CONTAINER}" \
            ps -eo user,pid,ppid,comm,args \
            | grep -E 'USER|mitmdump|code-server|chromium|tigervnc|websockify|openbox'
        echo ""

        MITM_USER=$(podman exec "${CONTAINER}" \
            ps -eo user,comm | awk '$2=="mitmdump"{print $1}' | head -1)
        CODER_CODESERVER=$(podman exec "${CONTAINER}" \
            ps -ef | grep "/usr/lib/code-server/lib/node /usr/lib/code-server --bind-addr 127.0.0.1" | awk '{print $1}' | head -1)

        [[ "${MITM_USER}" == "mitm" ]] \
            && ok "mitmproxy is running as 'mitm' ✓" \
            || warn "WARNING: mitmproxy is running as '${MITM_USER:-unknown}' — expected 'mitm'"

        [[ "${CODER_CODESERVER}" == "coder" ]] \
            && ok "code-server is running as 'coder' ✓" \
            || warn "WARNING: code-server is running as '${CODER_CODESERVER:-unknown}' — expected 'coder'"
        ;;

    firewall)
        require_running
        info "iptables nat OUTPUT (REDIRECT rules):"
        podman exec "${CONTAINER}" iptables -t nat -L OUTPUT -n --line-numbers -v
        echo ""
        info "iptables filter OUTPUT:"
        podman exec "${CONTAINER}" iptables -L OUTPUT -n --line-numbers -v
        ;;

    ca-cert)
        require_running
        info "Exporting mitmproxy CA cert to ./mitmproxy-sandbox-ca.pem"
        podman exec "${CONTAINER}" cat /opt/mitmproxy-ca/mitmproxy-ca-cert.pem \
            > ./mitmproxy-sandbox-ca.pem
        ok "Saved. Do NOT import this into your host browser trust store."
        ;;

    # ── Shell access ──────────────────────────────────────────

    shell)
        require_running
        warn "Root shell in container."
        podman exec -it "${CONTAINER}" /bin/bash
        ;;

    coder-shell)
        require_running
        info "Shell as 'coder'..."
        podman exec -it --user coder "${CONTAINER}" /bin/bash -l -c "cd ~/workspace; bash"
        ;;

    claude)
        require_running
        info "Running claude as 'coder'..."
        podman exec -it --user coder "${CONTAINER}" /bin/bash -l -c "cd ~/workspace && claude"
        ;;

    mitm-shell)
        require_running
        warn "Shell as 'mitm' user (proxy process owner)."
        podman exec -it --user mitm "${CONTAINER}" /bin/bash
        ;;

    # ── Volume management ─────────────────────────────────────

    reset-workspace)
        warn "Deletes all workspace files."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        podman compose down
        podman volume rm "${CONTAINER}_workspace_data" 2>/dev/null || true
        ok "Workspace removed."
        ;;

    reset-ca)
        warn "Deletes the mitmproxy CA cert volume."
        warn "A new CA is generated on next start and reinstalled into Chromium."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        podman compose down
        podman volume rm "${CONTAINER}_mitmproxy_ca" 2>/dev/null || true
        ok "CA volume removed."
        ;;

    clean)
        warn "Removes container and image."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        podman compose down --rmi all 2>/dev/null || true
        ok "Cleaned."
        ;;

    help|*)
        echo ""
        echo "Managment utility for the mitmproxy development Sandbox"
        echo ""
        echo "  $(basename $0) <command>"
        echo ""
        printf "  %-22s %s\n" "build"            "Build the podman image"
        printf "  %-22s %s\n" "start"            "Start the container"
        printf "  %-22s %s\n" "load_workspace"   "Replaces the ${CODER_USER} user's workspace in sandbox with: ${WORKSPACE}"
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
        printf "  %-22s %s\n" "coder-shell"      "Shell as coder"
        printf "  %-22s %s\n" "mitm-shell"       "Shell as mitm"
        printf "  %-22s %s\n" "reset-workspace"  "Delete workspace volume"
        printf "  %-22s %s\n" "reset-ca"         "Delete CA cert volume"
        printf "  %-22s %s\n" "clean"            "Remove container + image"
        echo ""
        ;;
esac
