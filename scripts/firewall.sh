#!/usr/bin/env bash
# =============================================================
# firewall.sh — iptables rules for mitmproxy transparent proxy
#
# The critical security property of this script:
#
#   The REDIRECT exemption is granted to the 'mitm' user (uid 1001)
#   ONLY. The 'coder' user (uid 1000) has no exemption — all of
#   coder's outbound :443/:80 traffic is intercepted by mitmproxy
#   without exception.
#
#   This means even if a process running as coder tried to bypass
#   mitmproxy (e.g. by hardcoding an IP address or using a
#   non-standard port), it would still be blocked by the DROP
#   default policy. Only the mitm user can make real outbound
#   HTTPS connections — and those connections are gated by the
#   Python allowlist in allowlist.py.
#
# Rules applied:
#   nat OUTPUT:
#     - REDIRECT :443 → :8081  (for all uids except mitm)
#     - REDIRECT :80  → :8081  (for all uids except mitm)
#   filter OUTPUT:
#     - ACCEPT loopback
#     - ACCEPT ESTABLISHED/RELATED
#     - ACCEPT DNS to container resolver
#     - ACCEPT outbound :443/:80 for mitm uid only
#     - DROP everything else
#
# Usage:
#   /scripts/firewall.sh          — apply rules
#   /scripts/firewall.sh --flush  — remove all rules, open policy
#   /scripts/firewall.sh --list   — print current rules
# =============================================================

set -euo pipefail

MITM_PORT=8081

# Resolve the mitm user's uid. We look it up at runtime rather
# than hardcoding so the script works even if the UID was changed
# via the Dockerfile ARG.
MITM_UID=$(id -u mitm 2>/dev/null) \
    || { echo "[firewall] ERROR: 'mitm' user not found"; exit 1; }

CODER_UID=$(id -u coder 2>/dev/null) \
    || { echo "[firewall] ERROR: 'coder' user not found"; exit 1; }

log() { echo "[firewall] $*"; }

log "User IDs — coder: ${CODER_UID}, mitm: ${MITM_UID}"
log "REDIRECT exemption will be granted to mitm (${MITM_UID}) ONLY."

case "${1:-}" in
    --list)
        echo "=== nat OUTPUT ==="
        iptables -t nat -L OUTPUT -n --line-numbers -v
        echo ""
        echo "=== filter OUTPUT ==="
        iptables -L OUTPUT -n --line-numbers -v
        exit 0
        ;;
    --flush)
        log "Flushing all rules and resetting to ACCEPT..."
        iptables -t nat -F OUTPUT 2>/dev/null || true
        iptables -F OUTPUT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT
        log "Done. All outbound traffic now permitted."
        exit 0
        ;;
esac

# ── Flush existing rules ──────────────────────────────────────
iptables -t nat -F OUTPUT 2>/dev/null || true
iptables -F OUTPUT 2>/dev/null || true

# ── nat table: REDIRECT all outbound :443/:80 to mitmproxy ───
# The ! --uid-owner excludes the mitm user so its own outbound
# connections (to the real upstream servers) are not looped back.
# coder is NOT excluded here — coder's traffic always hits mitm.

iptables -t nat -A OUTPUT \
    -p tcp --dport 443 \
    -m owner ! --uid-owner "${MITM_UID}" \
    -j REDIRECT --to-ports "${MITM_PORT}"
log "REDIRECT: outbound :443 → :${MITM_PORT}  (all uids except mitm/${MITM_UID})"

iptables -t nat -A OUTPUT \
    -p tcp --dport 80 \
    -m owner ! --uid-owner "${MITM_UID}" \
    -j REDIRECT --to-ports "${MITM_PORT}"
log "REDIRECT: outbound :80  → :${MITM_PORT}  (all uids except mitm/${MITM_UID})"

# ── filter table: OUTPUT rules ────────────────────────────────

# Loopback (code-server ↔ Chromium, mitmproxy ↔ REDIRECT socket)
iptables -A OUTPUT -o lo -j ACCEPT
log "Allowed: loopback"

# Established/related (return traffic for mitm's upstream connections)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
log "Allowed: ESTABLISHED/RELATED"

# DNS — container resolver only, needed by mitmproxy to resolve hosts
DNS_SERVER=$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')
DNS_SERVER="${DNS_SERVER:-127.0.0.11}"
iptables -A OUTPUT -p udp --dport 53 -d "${DNS_SERVER}" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d "${DNS_SERVER}" -j ACCEPT
log "Allowed: DNS → ${DNS_SERVER}"

# Outbound :443 and :80 for the mitm user ONLY
# (coder's traffic on these ports was already REDIRECTed above)
iptables -A OUTPUT -p tcp --dport 443 \
    -m owner --uid-owner "${MITM_UID}" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 80 \
    -m owner --uid-owner "${MITM_UID}" -j ACCEPT
log "Allowed: outbound :443/:80 for mitm uid ${MITM_UID} only"

# Allow mitmproxy to bind on its own listen port (local)
iptables -A OUTPUT -p tcp --dport "${MITM_PORT}" -d 127.0.0.1 -j ACCEPT

# DROP and log everything else
iptables -P OUTPUT DROP
iptables -A OUTPUT -j LOG --log-prefix "[FW-DROP] " --log-level 4
log "Default OUTPUT policy: DROP"

# ── Verification summary ──────────────────────────────────────
ACCEPT_COUNT=$(iptables -L OUTPUT -n | grep -c "^ACCEPT" || true)
log "Firewall ready. ${ACCEPT_COUNT} ACCEPT rules in filter OUTPUT."
log ""
log "Summary of trust:"
log "  coder (uid ${CODER_UID}) — ALL outbound intercepted by mitmproxy"
log "  mitm  (uid ${MITM_UID}) — outbound :443/:80 permitted (gated by allowlist.py)"
