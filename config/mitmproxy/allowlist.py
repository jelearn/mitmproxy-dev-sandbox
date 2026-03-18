"""
allowlist.py — mitmproxy addon for domain + path filtering

Runs inside mitmproxy (as the 'mitm' user, NOT as 'coder').
Every HTTPS request the container makes is evaluated here.
Requests not matching ALLOW_RULES receive a 403 and are dropped.

Adding rules:
    Each entry is (exact_hostname, path_prefix).
    - Hostname is matched exactly — "anthropic.com" does NOT
      cover "api.anthropic.com". List subdomains explicitly.
    - Path prefix uses str.startswith(). Use "/" to allow all
      paths on a host.

Reloading without restart:
    Edit this file, then run:
        ./manage.sh reload-allowlist
    This copies the file into the container and sends SIGHUP
    to mitmdump, which reloads all addon scripts.
"""

from mitmproxy import http


# ── Allowlist ─────────────────────────────────────────────────
ALLOW_RULES: list[tuple[str, str]] = [

    # Anthropic API — Continue.dev and Claude Code CLI
    ("api.anthropic.com",             "/v1/"),
    ("statsig.anthropic.com",         "/v1/"),

    # npm
    ("registry.npmjs.org",            "/"),
    ("registry.yarnpkg.com",          "/"),

    # PyPI
    ("pypi.org",                      "/pypi/"),
    ("pypi.org",                      "/simple/"),
    ("files.pythonhosted.org",        "/packages/"),

    # GitHub
    ("github.com",                    "/"),
    ("api.github.com",                "/"),
    ("raw.githubusercontent.com",     "/"),
    ("objects.githubusercontent.com", "/"),
    ("codeload.github.com",           "/"),

    # Open VSX (code-server extension marketplace)
    ("open-vsx.org",                  "/"),
    ("api.open-vsx.org",              "/"),

    # Extra Open VSX Extensions
    ("openvsx.eclipsecontent.org", "/streetsidesoftware/code-spell-checker/"),
    ("openvsx.eclipsecontent.org", "/Continue/continue/"),
    ("openvsx.eclipsecontent.org", "/ms-python/"),
    ("openvsx.eclipsecontent.org", "/esbenp/prettier-vscode/"),
    ("openvsx.eclipsecontent.org", "/dbaeumer/vscode-eslint"),
    ("openvsx.eclipsecontent.org", "/eamodio/gitlens/"),
]

# Build an index for O(1) host lookup
_INDEX: dict[str, list[str]] = {}
for _host, _path in ALLOW_RULES:
    _INDEX.setdefault(_host, []).append(_path)


def _is_allowed(host: str, path: str) -> bool:
    prefixes = _INDEX.get(host)
    if not prefixes:
        return False
    return any(path.startswith(p) for p in prefixes)


class AllowlistAddon:

    def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        path = flow.request.path

        if _is_allowed(host, path):
            print(f"[ALLOWED]  {host}{path}")
            return

        # Block and return a descriptive 403
        flow.response = http.Response.make(
            403,
            (
                f"Blocked by sandbox allowlist.\n"
                f"Host : {host}\n"
                f"Path : {path}\n\n"
                f"To allow this domain, add it to "
                f"/etc/mitmproxy/allowlist.py and run:\n"
                f"  ./manage.sh reload-allowlist\n"
            ),
            {"Content-Type": "text/plain"},
        )
        print(f"[BLOCKED]  {host}{path}")


addons = [AllowlistAddon()]
