# `mitmproxy` Dev Sandbox

VS Code in a browser, with all outbound HTTPS inspected by mitmproxy.
Pixel-streamed to your host via noVNC — no JavaScript from inside the
container executes on your host OS.

## TLDR;

To get started:

0) Install `podman`.
1) Run `./manage.sh start` to start the containerized sandbox environment.
2) Run `./manage.sh claude` to start a shell into Claude Code.
3) Follow the Claude Code instructions to setup/authorize it to
   access your account (copy URL into browser and paste in
   authorization code).
4) Work on the command-line and/or go to [the local VNC instance](http://localhost:6080/vnc.html?resize=remote&autoconnect=true)
   and use VS Code.
5) Use the `./manage.sh load_workspace` to replace the coder user's workspace
   directory with the contents of the a local `./workspace` directory.
6) The contents of the sandbox's workspace directory will be linked to from the
   `./sandbox` directory (created after `start`).

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
./manage.sh coder-shell
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
