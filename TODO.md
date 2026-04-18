Notes on issues and things to look-into:

- [ ] Update the firewall rules to ensure that all users are limited to the
      minimum network accesses needed to perform their functions.
- [ ] Develop a method to easily create multiple sanboxed environments for
      multiple projects, potentially by simply cloning this base repo in
      a new directory, allowing the workspace to be separate, but all other
      volumes reused?
- [X] Update mitmproxy to not include its own self-signed cert and only trust
      normal system certs.
    - Don't add it to the system ca-certificates?
    - Inject it only into the coder's enviroment (browser, python, vscode, etc.)?
- [X] Move logs and pids of sandbox services out of /tmp and into
      directories controlled by the service users.
- [ ] Always install latest code-server:
    - e.g. curl -fsSL https://code-server.dev/install.sh | sh
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
- [ ] Fix entrypoint.sh, which should call per-service scripts, but doesn't.
- [ ] Fix entrypoint.sh (and related scripts) usage of the configured
      defaults for the setup (e.g. `MITM_USER`, `MITM_PORT`, etc.) so they
      are not hard-coded per file, but read from the environment.
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
