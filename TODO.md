Notes on issues and things to look-into:

- [ ] Update the firewall rules to ensure that all users are limited to the
      minimum network accesses needed to perform their functions.
- [ ] Develop a method to easily create multiple sanboxed environments for
      multiple projects, potentially by simply cloning this base repo in
      a new directory, allowing the workspace to be separate, but all other
      volumes reused?
    - This should include including additional allow-rules, and extra apt install
      instructions.
    - Potentially also defining them as simple lists in configuration files.
- [ ] Update the mitmproxy allow list feature to provide additional controls
      over HTTP actions, HTTP/HTT.
- [ ] Update the mitmproxy allow list feature to provide additional controls
      over HTTP actions, HTTP/HTTPS.
- [ ] Update the `manage.sh` to ensure any changes made to configuration files
      in the host OS are copied into the container on start.
- [ ] Since code-server 4.96.0 a new prompt on start-up as been added to login
      to github, this is annoying and it would be nice to avoid this.
      The work around currently is to pin it to 4.109.5 as in 4.111.0 it seems
      to be unavoidable.
      None of these option suggested by Claude Code worked:
      ```
      "gitlens.advanced.skipOnboarding": true,
      "gitlens.showWelcomeOnInstall": false,
      "gitlens.showWhatsNewAfterUpgrades": false,
      "gitlens.plusFeatures.enabled": false,
      "gitlens.cloud.integrations.enabled": false,
      "github.gitAuthentication": false,
      "workbench.welcomePage.walkthroughs.openOnInstall": false,
      "github.copilot.enable": {
        "*": false
      },
      "chat.commandCenter.enabled": false,
      "workbench.welcomePage.enabled": false,
      "claudeCode.disableLoginPrompt": true,
      "github.copilot.walkthroughAdded": true,
      "chat.disableAIFeatures": true
      ```
- [X] Update mitmproxy to not include its own self-signed cert and only trust
      normal system certs.
    - Don't add it to the system ca-certificates?
    - Inject it only into the coder's enviroment (browser, python, vscode, etc.)?
- [X] Move logs and pids of sandbox services out of /tmp and into
      directories controlled by the service users.
- [X] Always install latest code-server:
    - Switched to `curl -fsSL https://code-server.dev/install.sh | sh -s --`
      with `${CODE_SERVER_VERSION:+--version "..."}` expansion. Default ARG is
      empty (latest); pass `--build-arg CODE_SERVER_VERSION=x.y.z` to pin.
- [ ] Update the entrypoint.sh such that if the VS Code window is closed
      it's re-opened again after automatically.
- [X] Make the noVNC/tigerVNC screen size dynamic to browser window size?
    - Initial solution was to modify the URL used to connect.
- [ ] Expose the noVNC/tigerVNC clip-board to the host OS?
- [X] Undecorate the VS Code window by default.
    - Openbox rc.xml with `<decor>no</decor><maximized>yes</maximized>` for
      `class="Chromium"`. Staged via /tmp in Containerfile (COPY doesn't
      expand ENV vars) then placed in display user's ~/.config/openbox/rc.xml.
- [o] Address host to guest OS permissions mounting limitations and/or an
      easy way to control what is moved into the workspace.
    - Current workaround is the "sandbox" (link to podman volume) and the
      `./manage.sh load_workspace`command to load the contents of the local
      "workspace" directory into the workspace volume.
- [X] Fix entrypoint.sh, which should call per-service scripts, but doesn't.
    - Extracted inline Step 6 into `scripts/start-code-server.sh`, matching
      the pattern of start-mitmproxy.sh and start-display.sh. Script accepts
      the same positional-arg convention and can restart code-server standalone.
- [X] Fix entrypoint.sh (and related scripts) usage of the configured
      defaults for the setup (e.g. `MITM_USER`, `MITM_PORT`, etc.) so they
      are not hard-coded per file, but read from the environment.
    - Port ARGs/ENVs added to Containerfile (MITM_PORT, VNC_PORT, NOVNC_PORT,
      CODESERVER_PORT). All scripts now read from env with hardcoded fallbacks:
      `${VAR:-default}`. Sub-scripts use double fallback `${1:-${VAR:-default}}`
      so both entrypoint-driven and standalone invocations work correctly.
- [ ] Update VS Code config to trust the workspace directory (and parent) automatically.
- [ ] Generate the mitmproxy cert once, outside the image and import it.
- [ ] Pre-bake extensions into docker image?
- [X] Run display services as non-root user?
    - display user (uid 1102) now owns Xtigervnc, Openbox, noVNC/websockify.
    - coder granted X11 access via xhost +SI:localuser:coder.
- [ ] Re-visit the vnc path lookup in the entrypoint.sh as it has issues.
- [ ] Support Docker as well as Podman?
- [X] Clarify `reload-allowlist` behavior: mitmproxy 10.3.1 registers no SIGHUP
      handler (SIGHUP would terminate the process). The script addon has a built-in
      1-second file-watch poller — `podman cp` updating the mtime is sufficient for
      zero-downtime hot-reload. Removed the SIGHUP + restart from `reload-allowlist`.
