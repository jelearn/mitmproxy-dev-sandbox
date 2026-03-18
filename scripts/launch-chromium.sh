#!/usr/bin/env bash
# =============================================================
# launch-chromium.sh — launch Chromium inside the container
#
# Runs as 'coder'. Points at code-server on localhost:8080.
# Loopback traffic bypasses the iptables REDIRECT rule, which
# is correct — we only want to intercept external traffic.
# =============================================================

set -euo pipefail

CODE_SERVER_URL="http://127.0.0.1:8080"

for i in $(seq 1 30); do
    curl -sf "${CODE_SERVER_URL}" > /dev/null 2>&1 && break
    sleep 1
done

exec chromium-browser \
    --no-sandbox \
    --disable-gpu \
    --disable-software-rasterizer \
    --disable-dev-shm-usage \
    --no-first-run \
    --no-default-browser-check \
    --disable-default-apps \
    --disable-extensions \
    --disable-background-networking \
    --disable-sync \
    --disable-translate \
    --proxy-server="direct://" \
    --proxy-bypass-list="127.0.0.1,localhost" \
    --start-maximized \
    --app="${CODE_SERVER_URL}"
