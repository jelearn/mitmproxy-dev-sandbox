#!/usr/bin/env bash
# =============================================================
# launch-chromium.sh — launch Chromium inside the container
#
# Runs as 'coder'. Points at code-server on localhost:8080.
# Loopback traffic bypasses the iptables REDIRECT rule via an explicit
# RETURN rule in firewall.sh — we only intercept external traffic.
#
# GPU / Rendering:
#   --disable-gpu                      Disable hardware GPU acceleration. Common in
#                                      container environments where no real GPU is available.
#   --disable-software-rasterizer      Disable the SwiftShader software fallback rasterizer,
#                                      preventing slow or crashy software GPU emulation in
#                                      restricted environments.
#   --disable-dev-shm-usage            Use /tmp instead of /dev/shm for rendering. Docker
#                                      containers default to a 64MB /dev/shm which can cause
#                                      crashes.
#
# First-run / onboarding suppression:
#   --no-first-run                     Skip the "Welcome to Chrome" setup wizard.
#   --no-default-browser-check         Suppress the prompt to set Chromium as the default
#                                      browser.
#   --disable-default-apps             Prevent installation of bundled default web apps
#                                      (e.g. Google Docs shortcuts) on first run.
#
# Feature disabling:
#   --disable-extensions               Disable all browser extensions for a clean,
#                                      controlled environment.
#   --disable-background-networking    Turn off background network calls for Safe Browsing
#                                      updates, extension updates, and telemetry.
#   --disable-sync                     Disable Google account sync (bookmarks, history,
#                                      settings, etc.).
#   --disable-translate                Disable the built-in page translation feature and
#                                      its associated background service.
#
# Proxy / networking:
#   --proxy-server="direct://"         Force all connections to be made directly, bypassing
#                                      any system-configured proxy.
#   --proxy-bypass-list="..."          Explicitly exempt loopback addresses from proxying.
#                                      Redundant given direct://, but guards against edge
#                                      cases.
#
# Window / app mode:
#   --start-maximized                  Launch the browser window maximized.
#   --app="${CODE_SERVER_URL}"         Open in app mode (no address bar, tabs, or browser
#                                      chrome) pointed at the code-server instance, making
#                                      it feel like a standalone desktop app.
#
# Sandbox:
#   --no-sandbox                       Added automatically when USERNS_ACTIVE=0, meaning the
#                                      container runtime has no user namespace support active.
#                                      Chromium's renderer sandbox requires CLONE_NEWUSER;
#                                      without a user namespace this is blocked. Podman rootless
#                                      and Docker rootless/userns-remap all set USERNS_ACTIVE=1
#                                      (detected host-side by manage.sh at container start).
# =============================================================

set -euo pipefail

CODESERVER_PORT="${CODESERVER_PORT:-8080}"
CODE_SERVER_URL="http://127.0.0.1:${CODESERVER_PORT}"

for _ in $(seq 1 30); do
    curl -sf "${CODE_SERVER_URL}" > /dev/null 2>&1 && break
    sleep 1
done

# USERNS_ACTIVE is set by manage.sh at container start: "1" when the runtime
# has user namespace support active (Podman rootless, Docker rootless, or Docker
# with userns-remap), "0" when it does not. Without user namespace support,
# Chromium cannot create its renderer sandbox and must fall back to --no-sandbox.
SANDBOX_ARGS=()
if [[ "${USERNS_ACTIVE:-0}" != "1" ]]; then
    echo "[chromium] WARNING: user namespaces unavailable — starting with --no-sandbox."
    SANDBOX_ARGS=("--no-sandbox")
fi

exec chromium \
    "${SANDBOX_ARGS[@]}" \
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
