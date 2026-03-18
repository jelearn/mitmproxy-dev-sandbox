#!/usr/bin/env bash
# =============================================================
# manage.sh — VS Code + mitmproxy sandbox (v2)
# =============================================================

set -euo pipefail

CONTAINER="vscode-mitmproxy-sandbox"
IMAGE="vscode-mitmproxy-sandbox:latest"
URL="http://localhost:6080"

BLU='\033[0;34m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${BLU}[manage]${NC} $*"; }
ok()    { echo -e "${GRN}[manage]${NC} $*"; }
warn()  { echo -e "${YLW}[manage]${NC} $*"; }
error() { echo -e "${RED}[manage]${NC} $*" >&2; exit 1; }

require_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
        || error "Container not running. Run: ./manage.sh start"
}

cmd="${1:-help}"

case "${cmd}" in
    build)
        info "Building ${IMAGE}..."
        docker build -t "${IMAGE}" .
        ok "Build complete."
        ;;

    start)
        [[ -f .env ]] || error "No .env file. Create one with ANTHROPIC_API_KEY=..."
        docker-compose up -d
        sleep 3
        ok "noVNC at: ${URL}"
        ;;

    stop)   docker-compose down;        ok "Stopped." ;;
    restart) docker-compose down && docker-compose up -d; ok "Restarted. ${URL}" ;;

    status)
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            ok "RUNNING"
            docker ps --filter "name=${CONTAINER}" \
                --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            echo ""; info "noVNC: ${URL}"

            # Show which user each key process is running as
            echo ""
            info "Process user verification:"
            docker exec "${CONTAINER}" \
                ps -eo user,pid,comm \
                | awk '$3~/mitmdump|code-server|chromium/{printf "  %-12s pid=%-6s %s\n",$1,$2,$3}'
        else
            warn "NOT running."
        fi
        ;;

    logs)
        require_running
        docker logs -f "${CONTAINER}"
        ;;

    # ── Proxy commands ────────────────────────────────────────

    proxy-log)
        require_running
        info "Live proxy traffic (Ctrl-C to stop):"
        docker exec "${CONTAINER}" \
            tail -f /tmp/mitmproxy.log \
            | grep --line-buffered -E '\[(ALLOWED|BLOCKED)\]'
        ;;

    blocked)
        require_running
        info "Recently blocked requests:"
        docker exec "${CONTAINER}" \
            grep '\[BLOCKED\]' /tmp/mitmproxy.log | tail -50 \
            || info "None yet."
        ;;

    allowed)
        require_running
        info "Recently allowed requests:"
        docker exec "${CONTAINER}" \
            grep '\[ALLOWED\]' /tmp/mitmproxy.log | tail -50 \
            || info "None yet."
        ;;

    reload-allowlist)
        require_running
        info "Copying updated allowlist into container..."
        docker cp config/mitmproxy/allowlist.py \
            "${CONTAINER}:/etc/mitmproxy/allowlist.py"
        MITM_PID=$(docker exec "${CONTAINER}" \
            cat /tmp/mitmproxy.pid 2>/dev/null || true)
        if [[ -n "${MITM_PID}" ]]; then
            docker exec "${CONTAINER}" kill -HUP "${MITM_PID}"
            ok "mitmproxy reloaded (pid ${MITM_PID})."
        else
            warn "mitmproxy PID not found — restart to reload."
        fi
        ;;

    verify-users)
        # Confirm mitmproxy is NOT running as coder or root
        require_running
        info "Verifying process ownership..."
        echo ""
        docker exec "${CONTAINER}" \
            ps -eo user,pid,ppid,comm,args \
            | grep -E 'USER|mitmdump|code-server|chromium|tigervnc|websockify|openbox'
        echo ""

        MITM_USER=$(docker exec "${CONTAINER}" \
            ps -eo user,comm | awk '$2=="mitmdump"{print $1}' | head -1)
        CODER_CODESERVER=$(docker exec "${CONTAINER}" \
            ps -eo user,comm | awk '$2=="code-server"{print $1}' | head -1)

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
        docker exec "${CONTAINER}" iptables -t nat -L OUTPUT -n --line-numbers -v
        echo ""
        info "iptables filter OUTPUT:"
        docker exec "${CONTAINER}" iptables -L OUTPUT -n --line-numbers -v
        ;;

    ca-cert)
        require_running
        info "Exporting mitmproxy CA cert to ./mitmproxy-sandbox-ca.pem"
        docker exec "${CONTAINER}" cat /opt/mitmproxy-ca/mitmproxy-ca-cert.pem \
            > ./mitmproxy-sandbox-ca.pem
        ok "Saved. Do NOT import this into your host browser trust store."
        ;;

    # ── Shell access ──────────────────────────────────────────

    shell)
        require_running
        warn "Root shell in container."
        docker exec -it "${CONTAINER}" /bin/bash
        ;;

    coder-shell)
        require_running
        info "Shell as 'coder'..."
        docker exec -it --user coder "${CONTAINER}" /bin/bash
        ;;

    mitm-shell)
        require_running
        warn "Shell as 'mitm' user (proxy process owner)."
        docker exec -it --user mitm "${CONTAINER}" /bin/bash
        ;;

    # ── Volume management ─────────────────────────────────────

    reset-workspace)
        warn "Deletes all workspace files."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        docker-compose down
        docker volume rm "$(basename "$(pwd)")_workspace_data" 2>/dev/null || true
        ok "Workspace removed."
        ;;

    reset-ca)
        warn "Deletes the mitmproxy CA cert volume."
        warn "A new CA is generated on next start and reinstalled into Chromium."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        docker-compose down
        docker volume rm "$(basename "$(pwd}")_mitmproxy_ca" 2>/dev/null || true
        ok "CA volume removed."
        ;;

    clean)
        warn "Removes container and image."
        read -rp "Sure? [y/N] " c; [[ "${c,,}" == "y" ]] || exit 0
        docker-compose down --rmi all 2>/dev/null || true
        ok "Cleaned."
        ;;

    help|*)
        echo ""
        echo "VS Code + mitmproxy Sandbox (v2 — separate mitm user)"
        echo ""
        echo "  ./manage.sh <command>"
        echo ""
        printf "  %-22s %s\n" "build"            "Build the Docker image"
        printf "  %-22s %s\n" "start"            "Start the container"
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
        printf "  %-22s %s\n" "coder-shell"      "Shell as coder"
        printf "  %-22s %s\n" "mitm-shell"       "Shell as mitm"
        printf "  %-22s %s\n" "reset-workspace"  "Delete workspace volume"
        printf "  %-22s %s\n" "reset-ca"         "Delete CA cert volume"
        printf "  %-22s %s\n" "clean"            "Remove container + image"
        echo ""
        ;;
esac
