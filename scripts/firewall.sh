#!/usr/bin/env bash
# =============================================================
# firewall.sh — iptables rules for mitmproxy transparent proxy
#
# The critical security property of this script:
#
#   The REDIRECT exemption is granted to the 'mitm' user (uid 1101)
#   ONLY. The 'coder' user (uid 1100) has no exemption — all of
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
# All sandbox rules live in three dedicated custom chains, keeping
# them isolated from rules injected by the container runtime:
#
#   SANDBOX_INPUT   — filter table, inbound traffic
#   SANDBOX_OUTPUT  — filter table, outbound traffic
#   SANDBOX_NAT_OUT — nat table, outbound traffic (REDIRECT rules)
#
# The main INPUT/OUTPUT filter chains hold only the jump rules to
# these custom chains and their DROP default policies. nat OUTPUT
# holds only the jump to SANDBOX_NAT_OUT — Docker's DNS DNAT rules
# for 127.0.0.11 are appended before our jump and are never touched.
#
# Rules applied:
#   SANDBOX_INPUT:
#     - ACCEPT loopback
#     - ACCEPT 6080 (for novnc)
#     - ACCEPT established connections
#     - LOG all else (falls through to main INPUT DROP policy)
#   SANDBOX_NAT_OUT:
#     - RETURN   127.0.0.0/8 → direct  (loopback bypasses mitmproxy)
#     - REDIRECT :443 → :8081  (for coder)
#     - REDIRECT :80  → :8081  (for coder)
#   SANDBOX_OUTPUT:
#     - ACCEPT loopback ESTABLISHED/RELATED (all users, return traffic)
#     - ACCEPT loopback (root — unrestricted, needed for entrypoint setup)
#     - ACCEPT loopback :MITM_PORT TCP (mitm only)
#     - ACCEPT loopback :VNC_PORT/:NOVNC_PORT TCP (display only)
#     - DROP  loopback :VNC_PORT/:NOVNC_PORT TCP+UDP (coder)
#     - ACCEPT loopback 1024:65535 TCP+UDP (coder — covers code-server, mitmproxy
#             REDIRECT target, and dev servers; display ports excluded above)
#     - ACCEPT DNS to container resolver (root, coder, mitm, _apt)
#     - ACCEPT outbound :443/:80 for mitm and _apt uid only
#     - LOG all else (falls through to main OUTPUT DROP policy)
#
# Usage:
#   /scripts/firewall.sh          — apply rules
#   /scripts/firewall.sh --flush  — remove all sandbox rules, open policy
#   /scripts/firewall.sh --list   — print current sandbox rules
# =============================================================

set -euo pipefail

MITM_PORT="${MITM_PORT:-8081}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"

# Custom chain names — all sandbox rules live here, never in the main chains.
CHAIN_INPUT="SANDBOX_INPUT"
CHAIN_OUTPUT="SANDBOX_OUTPUT"
CHAIN_NAT="SANDBOX_NAT_OUT"

# Resolve service user UIDs at runtime so the script works even if UIDs
# were changed via Containerfile ARGs.
MITM_UID=$(id -u mitm 2>/dev/null) \
    || { echo "[firewall] ERROR: 'mitm' user not found"; exit 1; }

APT_UID=$(id -u _apt 2>/dev/null) \
    || { echo "[firewall] ERROR: '_apt' user not found"; exit 1; }

CODER_UID=$(id -u coder 2>/dev/null) \
    || { echo "[firewall] ERROR: 'coder' user not found"; exit 1; }

DISPLAY_UID=$(id -u display 2>/dev/null) \
    || { echo "[firewall] ERROR: 'display' user not found"; exit 1; }

log() { echo "[firewall] $*"; }

log "User IDs — coder: ${CODER_UID}, mitm: ${MITM_UID}, display: ${DISPLAY_UID}"
log "REDIRECT exemption will be granted to mitm (${MITM_UID}) ONLY."

flush_rules() {
    # Remove the jump rules from the main chains. Errors are suppressed so
    # this is safe to call even when the chains have never been created.
    iptables       -D INPUT  -j "${CHAIN_INPUT}"  2>/dev/null || true
    iptables       -D OUTPUT -j "${CHAIN_OUTPUT}" 2>/dev/null || true
    iptables -t nat -D OUTPUT -j "${CHAIN_NAT}"   2>/dev/null || true

    # Flush rules from each custom chain, then delete the chain itself.
    # -F must precede -X because -X requires the chain to be empty.
    iptables       -F "${CHAIN_INPUT}"  2>/dev/null || true
    iptables       -X "${CHAIN_INPUT}"  2>/dev/null || true
    iptables       -F "${CHAIN_OUTPUT}" 2>/dev/null || true
    iptables       -X "${CHAIN_OUTPUT}" 2>/dev/null || true
    iptables -t nat -F "${CHAIN_NAT}"   2>/dev/null || true
    iptables -t nat -X "${CHAIN_NAT}"   2>/dev/null || true

    # Reset main-chain policies to ACCEPT so no traffic is blocked after a flush.
    iptables -P INPUT  ACCEPT
    iptables -P OUTPUT ACCEPT
}

create_chains() {
    iptables       -N "${CHAIN_INPUT}"
    iptables       -N "${CHAIN_OUTPUT}"
    iptables -t nat -N "${CHAIN_NAT}"

    # Wire the custom chains into the main chains. In nat OUTPUT our jump is
    # appended after any rules Docker already injected (e.g. DNAT for the
    # 127.0.0.11 DNS resolver), so those pre-existing rules are evaluated
    # first and remain untouched by flush_rules.
    iptables       -A INPUT  -j "${CHAIN_INPUT}"
    iptables       -A OUTPUT -j "${CHAIN_OUTPUT}"
    iptables -t nat -A OUTPUT -j "${CHAIN_NAT}"

    # Traffic that returns from a custom chain without a terminal verdict
    # (ACCEPT/DROP/REJECT) falls back to the main chain's default policy.
    iptables -P INPUT  DROP
    iptables -P OUTPUT DROP
}

case "${1:-}" in
    --list)
        echo "=== ${CHAIN_INPUT} (filter INPUT) ==="
        iptables -L "${CHAIN_INPUT}" -n --line-numbers -v 2>/dev/null \
            || echo "(chain not present)"
        echo ""
        echo "=== ${CHAIN_NAT} (nat OUTPUT) ==="
        iptables -t nat -L "${CHAIN_NAT}" -n --line-numbers -v 2>/dev/null \
            || echo "(chain not present)"
        echo ""
        echo "=== ${CHAIN_OUTPUT} (filter OUTPUT) ==="
        iptables -L "${CHAIN_OUTPUT}" -n --line-numbers -v 2>/dev/null \
            || echo "(chain not present)"
        exit 0
        ;;
    --flush)
        log "Flushing all sandbox rules and resetting to ACCEPT..."
        flush_rules
        log "Done. All traffic now permitted."
        exit 0
        ;;
esac

# Normal startup: flush any prior sandbox rules, then build fresh.
flush_rules
create_chains

# ── SANDBOX_INPUT ─────────────────────────────────────────────
# DROP all incoming except loopback, NoVNC, and established connections.

iptables -A "${CHAIN_INPUT}" -i lo -j ACCEPT
iptables -A "${CHAIN_INPUT}" -p tcp --dport "${NOVNC_PORT}" -j ACCEPT
iptables -A "${CHAIN_INPUT}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
log "Allowed: inbound loopback, NOVNC ${NOVNC_PORT} & already established connections."
iptables -A "${CHAIN_INPUT}" -j LOG --log-prefix "[FW-IN-DROP] " --log-level 4
log "Default INPUT policy: DROP"

# ── SANDBOX_NAT_OUT ───────────────────────────────────────────
# REDIRECT all coder outbound :443/:80 to mitmproxy.

# Loopback addresses must be exempted BEFORE the coder REDIRECT rules so that
# locally-served development servers (e.g. Node.js/npm on any port, including
# :80/:443) are reachable directly without going through mitmproxy. Without
# this rule the REDIRECT below would intercept coder's connections to
# 127.0.0.1:80 and 127.0.0.1:443, routing them to mitmproxy where they would
# be blocked by the allowlist (localhost is not an allowed upstream host).
iptables -t nat -A "${CHAIN_NAT}" \
    -p tcp \
    -d 127.0.0.0/8 \
    -j RETURN
log "RETURN: loopback (127.0.0.0/8) → direct (dev servers bypass mitmproxy)"

iptables -t nat -A "${CHAIN_NAT}" \
    -p tcp --dport 443 \
    -m owner --uid-owner "${CODER_UID}" \
    -j REDIRECT --to-ports "${MITM_PORT}"
log "REDIRECT: outbound :443 → :${MITM_PORT}  (for coder/${CODER_UID})"

iptables -t nat -A "${CHAIN_NAT}" \
    -p tcp --dport 80 \
    -m owner --uid-owner "${CODER_UID}" \
    -j REDIRECT --to-ports "${MITM_PORT}"
log "REDIRECT: outbound :80  → :${MITM_PORT}  (for coder/${CODER_UID})"

# ── SANDBOX_OUTPUT ────────────────────────────────────────────

# ── Loopback — per-uid ────────────────────────────────────────
# Return traffic first, so established loopback connections are never
# interrupted by the per-uid rules below.
iptables -A "${CHAIN_OUTPUT}" -o lo -m state --state ESTABLISHED,RELATED -j ACCEPT
log "Allowed: loopback ESTABLISHED/RELATED"

# root: unrestricted loopback (CA trigger curl in entrypoint, setup tasks)
iptables -A "${CHAIN_OUTPUT}" -o lo -m owner --uid-owner 0 -j ACCEPT
log "Allowed: loopback (root — unrestricted)"

# mitm: only its own listen port
iptables -A "${CHAIN_OUTPUT}" -o lo -p tcp --dport "${MITM_PORT}" \
    -m owner --uid-owner "${MITM_UID}" -j ACCEPT
log "Allowed: loopback :${MITM_PORT} TCP (mitm)"

# display: websockify → Xtigervnc (:VNC_PORT) and its own bind port (:NOVNC_PORT)
iptables -A "${CHAIN_OUTPUT}" -o lo -p tcp --dport "${VNC_PORT}" \
    -m owner --uid-owner "${DISPLAY_UID}" -j ACCEPT
iptables -A "${CHAIN_OUTPUT}" -o lo -p tcp --dport "${NOVNC_PORT}" \
    -m owner --uid-owner "${DISPLAY_UID}" -j ACCEPT
log "Allowed: loopback :${VNC_PORT}/:${NOVNC_PORT} TCP (display — TigerVNC + noVNC)"

# coder: unprivileged range (TCP + UDP), minus display service ports.
# Display port DROPs must precede the broad ACCEPT below.
# Note: :MITM_PORT is intentionally NOT excluded — coder's outbound :443/:80
# is NAT-redirected to loopback :MITM_PORT, and that rewritten packet must
# pass filter OUTPUT here. Blocking it would silently drop all coder HTTPS traffic.
iptables -A "${CHAIN_OUTPUT}" -o lo -p tcp --dport "${VNC_PORT}" \
    -m owner --uid-owner "${CODER_UID}" -j DROP
iptables -A "${CHAIN_OUTPUT}" -o lo -p udp --dport "${VNC_PORT}" \
    -m owner --uid-owner "${CODER_UID}" -j DROP
iptables -A "${CHAIN_OUTPUT}" -o lo -p tcp --dport "${NOVNC_PORT}" \
    -m owner --uid-owner "${CODER_UID}" -j DROP
iptables -A "${CHAIN_OUTPUT}" -o lo -p udp --dport "${NOVNC_PORT}" \
    -m owner --uid-owner "${CODER_UID}" -j DROP
iptables -A "${CHAIN_OUTPUT}" -o lo -p tcp --dport 1024:65535 \
    -m owner --uid-owner "${CODER_UID}" -j ACCEPT
iptables -A "${CHAIN_OUTPUT}" -o lo -p udp --dport 1024:65535 \
    -m owner --uid-owner "${CODER_UID}" -j ACCEPT
log "Allowed: loopback TCP+UDP 1024:65535 (coder — display ports :${VNC_PORT}/:${NOVNC_PORT} excluded)"

# coder: non-loopback traffic to MITM_PORT. After the NAT REDIRECT rewrites
# coder's :443/:80 connections their destination becomes 127.0.0.1:MITM_PORT,
# so this rule handles the case where the original destination was non-loopback.
iptables -A "${CHAIN_OUTPUT}" -p tcp --dport "${MITM_PORT}" \
    -m owner --uid-owner "${CODER_UID}" -j ACCEPT

# ── Non-loopback OUTPUT ───────────────────────────────────────
# Established/related (return traffic for mitm's upstream connections)
iptables -A "${CHAIN_OUTPUT}" -m state --state ESTABLISHED,RELATED -j ACCEPT
log "Allowed: non-loopback ESTABLISHED/RELATED"

# DNS — container resolver only.
# coder requires DNS: hostname resolution (getaddrinfo) happens in userspace
# BEFORE the TCP connection is opened, so the NAT REDIRECT never sees a packet
# until after DNS has already succeeded. Blocking DNS for coder causes all
# hostname lookups to fail or hang, preventing any connection from reaching
# mitmproxy regardless of the REDIRECT rules.
DNS_SERVER=$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')
DNS_SERVER="${DNS_SERVER:-127.0.0.11}"
for uid in 0 "${CODER_UID}" "${MITM_UID}" "${APT_UID}"; do
    iptables -A "${CHAIN_OUTPUT}" -p udp --dport 53 -d "${DNS_SERVER}" \
        -m owner --uid-owner "${uid}" -j ACCEPT
    iptables -A "${CHAIN_OUTPUT}" -p tcp --dport 53 -d "${DNS_SERVER}" \
        -m owner --uid-owner "${uid}" -j ACCEPT
done
log "Allowed: DNS → ${DNS_SERVER} (root, coder, mitm, _apt)"

# Outbound :443 and :80 for the mitm and _apt users ONLY
# (coder's traffic on these ports was already REDIRECTed above)
iptables -A "${CHAIN_OUTPUT}" -p tcp --dport 443 \
    -m owner --uid-owner "${MITM_UID}" -j ACCEPT
iptables -A "${CHAIN_OUTPUT}" -p tcp --dport 80 \
    -m owner --uid-owner "${MITM_UID}" -j ACCEPT
iptables -A "${CHAIN_OUTPUT}" -p tcp --dport 443 \
    -m owner --uid-owner "${APT_UID}" -j ACCEPT
iptables -A "${CHAIN_OUTPUT}" -p tcp --dport 80 \
    -m owner --uid-owner "${APT_UID}" -j ACCEPT
log "Allowed: outbound :443/:80 for mitm uid ${MITM_UID} and APT uid ${APT_UID} only"

# LOG everything else before the main chain's DROP policy catches it.
iptables -A "${CHAIN_OUTPUT}" -j LOG --log-prefix "[FW-OUT-DROP] " --log-level 4
log "Default OUTPUT policy: DROP"

# ── Verification summary ──────────────────────────────────────
ACCEPT_COUNT=$(iptables -L "${CHAIN_OUTPUT}" -n | grep -c "^ACCEPT" || true)
log "Firewall ready. ${ACCEPT_COUNT} ACCEPT rules in ${CHAIN_OUTPUT}."
log ""
log "Summary of trust:"
log "  coder   (uid ${CODER_UID}) — outbound :443/:80 intercepted by mitmproxy; loopback 1024:65535 TCP+UDP (display ports excluded); DNS permitted (required for hostname resolution before NAT redirect)"
log "  mitm    (uid ${MITM_UID}) — outbound :443/:80 + DNS permitted (gated by allowlist.py)"
log "  display (uid ${DISPLAY_UID}) — loopback :${VNC_PORT}/:${NOVNC_PORT} TCP only"
log "  root    (uid 0)          — loopback unrestricted + DNS (entrypoint setup)"
