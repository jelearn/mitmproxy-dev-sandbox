# Design Notes

## Key fix in v2: mitmproxy runs as a dedicated 'mitm' user

In v1, mitmproxy ran as the same `coder` user as VS Code. This created
a flaw: the iptables REDIRECT exemption was granted to `coder`'s uid,
meaning any process running as `coder` could make direct outbound
connections, bypassing the proxy entirely.

In v2, two separate users exist with strictly separated roles:

| User   | UID  | Role | Network privilege |
|--------|------|------|-------------------|
| `coder` | 1000 | VS Code, Chromium, Claude Code, terminals | None — ALL outbound :443/:80 intercepted by mitmproxy |
| `mitm`  | 1001 | mitmproxy only | Outbound :443/:80 permitted (gated by allowlist.py) |

The iptables REDIRECT exemption is granted to `mitm` (uid 1001) only.
`coder` has no special network treatment — it cannot bypass the proxy
regardless of what it tries to do.

`mitm` has a no-login shell (`/usr/sbin/nologin`) and owns only the
mitmproxy process and its config directory. It cannot write to the
workspace or read the API key.

---

## Verifying the separation

After starting the container:

```bash
./manage.sh verify-users
```

This checks that `mitmdump` is running as `mitm` and `code-server` is
running as `coder`, and prints the full process list for inspection.

You can also confirm manually:

```bash
podman exec mitmproxy-dev-sandbox \
    ps -eo user,pid,comm | grep -E 'mitmdump|code-server|chromium'
```

Expected output:
```
mitm   <pid>  mitmdump
coder  <pid>  code-server
coder  <pid>  chromium
```

---

## Architecture

```
Host browser → localhost:6080
                    │ pixels + input only
               noVNC + websockify
                    │
              Xtigervnc :5900
                    │
             Openbox (coder)
             ┌──────┴───────┐
      code-server:8080   Chromium
         (coder)         (coder)
             └──────┬───────┘
                    │ all outbound :443/:80
              iptables REDIRECT → :8081
                    │
            mitmproxy (mitm only)
                    │
             allowlist.py
            ┌───────┴────────┐
          ALLOW             BLOCK
      (upstream)           (403)
```

---

## Setup

### 1. Create .env
```bash
cat > .env <<'EOF'
VNC_PASSWORD=choose-a-strong-password
SCREEN_RESOLUTION=1600x900x24
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com
EOF
chmod 600 .env
```

### 2. Build
```bash
chmod +x manage.sh
./manage.sh build
```

### 3. Start
```bash
./manage.sh start
```

### 4. Connect
Open **http://localhost:6080** and click Connect.

---

## Editing the allowlist

```bash
# Edit the allowlist on your host
vim config/mitmproxy/allowlist.py

# Reload into the running container — no restart needed
./manage.sh reload-allowlist

# Watch the effect live
./manage.sh proxy-log
```

---

## Monitoring

```bash
./manage.sh proxy-log      # live ALLOWED/BLOCKED feed
./manage.sh blocked        # recent blocked requests
./manage.sh allowed        # recent allowed requests
./manage.sh verify-users   # confirm process ownership
./manage.sh firewall       # show iptables rules
```

---

## Fedora notes

SELinux may block volume mounts:
```bash
sudo chcon -Rt svirt_sandbox_file_t ./scripts ./config
```

---

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

