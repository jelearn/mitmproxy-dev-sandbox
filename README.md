# `mitmproxy` Dev Sandbox

VS Code in a browser, with all outbound HTTPS inspected by mitmproxy.
Pixel-streamed to your host via noVNC — no JavaScript from inside the
container executes on your host OS.

## TLDR;

To get started, after cloning this repo:

0) Install `podman` (>= 4.9.3) or Docker (>= 29.6.0).
    - If for whatever reason both are installed, `podman` is chosen by default.
    - In this scenario, if you prefer Docker, create/edit your `.env` file in
      your checkout to have a line like this: `CONTAINER_RUNTIME=docker`
1) Run `./manage.sh start` to start the containerized sandbox environment.
    - If not already built, it will create the required image for the sandbox.
    - This is the same as: `./manage.sh build`
2) Run `./manage.sh claude` to start a shell into Claude Code.
3) Follow the Claude Code instructions to setup/authorize it to
   access your account (copy URL into browser and paste in
   authorization code).
4) Work on the command-line and/or go to the `code-server` IDE in a browser.
    - Basic command-line: `./manage.sh coder`
    - Agent options:
        - `./manage.sh claude`
        - `./manage.sh opencode`
    - `code-server` via the [local VNC instance](http://localhost:6080/vnc.html?resize=remote&autoconnect=true)
5) To access to the container's sandbox workspace, you have two options which
   depends on your setup.
    - For the most permissive setups, you may have read-write access to: `./sandbox`
      Which was created after `start` and is a link to the volume mount for the
      sandbox environments directory: `/home/coder/workspace`
    - Otherwise, for more restrictive environments it may be read-only, in which
      case you can use the `./manage.sh load_workspace` command to replace the coder
      user's workspace directory with the contents of the a local `./workspace` directory.

### Multiple Sandboxes

If you need multiple environments at the same time, simply clone this repo into another
directory and an entirely separate sandbox can be used in the same way.

In this scenario, you'll need to edit your local `.env` file in the checkout
such that:
- `AGENT_SANDBOX_NAME` is set to a unique name for the new sandbox container.
- `AGENT_SANDBOX_PORT` is set to an unused port on your host other than 6080.

e.g.

```
AGENT_SANDBOX_NAME=alt-sandbox
AGENT_SANDBOX_PORT=7080
```

## Layout

- Future work, ideas, and issues: [TODO](TODO.md)
- Design: [DESIGN](DESIGN.md)
- Agent Guidance: [AGENTS.md](AGENTS.md) (with [CLAUDE.md](CLAUDE.md) delegating to it)

## Troubleshooting

**Chromium shows certificate errors**
The mitmproxy CA cert may not have been installed into Chromium's
NSS database. Check the startup log:
```bash
./manage.sh logs | grep -i 'nss\|certutil\|CA cert'
```
If it failed, reset the CA volume and restart:
```bash
./manage.sh reset-ca && ./manage.sh restart
```

**Claude Code or Continue.dev gets SSL errors**
`NODE_EXTRA_CA_CERTS` points Node.js to the mitmproxy CA cert.
Check it's set in the terminal:
```bash
./manage.sh coder
echo $NODE_EXTRA_CA_CERTS   # should print /opt/mitmproxy-ca/mitmproxy-ca-cert.pem
```

**Something is being blocked unexpectedly**
```bash
./manage.sh proxy-log
# Reproduce the action, watch for [BLOCKED] lines
# Add the domain to config/mitmproxy/allowlist.py
./manage.sh reload-allowlist
```

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Initial code generated with assistance from [Claude](https://claude.ai) by Anthropic.
