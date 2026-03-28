#!/usr/bin/env bash
# =============================================================
# install-extensions.sh — install VS Code extensions
# Runs as root, drops to coder for the actual installs.
# =============================================================

set -euo pipefail

CODER_USER="${1:-coder}"

log() { echo "[extensions] $*"; }

install_ext() {
    local ext_id="$1"
    log "Installing: ${ext_id}..."
    runuser -u "${CODER_USER}" -- bash -c "
        source /home/${CODER_USER}/.profile.d/sandbox-env.sh 2>/dev/null || true
        code-server \
            --user-data-dir /home/${CODER_USER}/.local/share/code-server \
            --extensions-dir /home/${CODER_USER}/.local/share/code-server/extensions \
            --install-extension '${ext_id}' 2>&1
    " && log "  OK: ${ext_id}" || log "  WARNING: failed — ${ext_id}"
}

install_ext "Anthropic.claude-code"
install_ext "continue.continue"
install_ext "ms-python.python"
install_ext "ms-python.vscode-pylance"
install_ext "esbenp.prettier-vscode"
install_ext "dbaeumer.vscode-eslint"
install_ext "eamodio.gitlens"
install_ext "streetsidesoftware.code-spell-checker"

log "Done."
