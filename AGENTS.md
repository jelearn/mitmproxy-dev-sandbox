# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Description

A containerized development sandbox for running AI agents and VS Code.

The objective being to:

- Limit how much agents can access on the host system.
  - Use of containers for runtime execution isolation.
  - Host user access to the environment is limited to terminal and minimal
    browser-based access into the sandbox environment.
    
- Limit how much agents can access within the containerized sandbox environment.
  - User-level isolation within container for running the agent.
  - The network access for the agent user is limited, and is controlled within
    the container based on configuration.
  - The files accessible to the agent within sandbox environment is controlled
    by the host user.

# Key Design Elements

- Containerization for host/guest isolation:
    - Provide a consistent base installation.
    - Limit what agents have access to.
    - Support rootless deployments.
    - Prefer podman over docker to start.
- User-level access controls to filesystem and network.
    - The agent runs as it's own user with limited access to the environment.
    - Is not a sudoer, cannot change to other users, or install anything outside
      it's own home directory.
    - Network access (in and out) is limited using iptables firewall rules to
      ensure all access is through a proxy within the container.
    - Services are run as separate users with only the accesses they need.
- Access to guest container is limited to terminal and minimal browser interface.
    - Pixel-stream the display via noVNC (no container JS executes on the host),
      and limits how much the agent user can maliciously impact the host.
    - The objective being to give the user multiple ways of interacting with
      the containerized enviroment with some level of isolation.

## Project Layout

Documentation:

- [README.md](README.md): The main entry point for users to understand the project.
- [DESIGN.md](DESIGN.md): Contains the details of how the key design elements above are implemented.
- [TODO.md](TODO.md): Contains outstanding issues, features, or ideas for the project.

Key fils and directories:

| File / Directory | Role |
|------|------|
| `manage.sh` | Host-side control script for all container operations |
| `Containerfile` | Podman/Docker Multi-stage image build |
| `compose.yml` | Podman/Docker Compose config (ports, volumes, env) |
| `scripts` | Contains any scripts needed to initialize the sandbox environment |
| `scripts/entrypoint.sh` | Container init: starts all services as correct users |
| `scripts/firewall.sh` | iptables transparent proxy rules |
| `scripts/start-mitmproxy.sh` | Starts/restarts mitmproxy as `mitm` user |
| `config` | Contains any configuration needed for the sandbox environment |
| `config/mitmproxy/allowlist.py` | Python mitmproxy addon: domain/path allow/block logic |
| `config/code-server.yaml` | code-server bind address and auth settings |
| `config/vscode/settings.json` | Any default VS Code settings to apply |

## AI Contributions

General guidance:

- Before generating any code, plan your work first and make sure you review the current contents of the workspace for
  any changes that might have been made outside your context.
- Commits to any workspace code should be done incrementally for specific tasks or features.
- When possible, repeatable tests should be added to the code base to confirm key design features still work
  on an ongoing basis.
    - When not possible, they should be noted in the TODO to address manually.
- When an agent is writing the commit, it should follow the pattern: `${MODEL_NAME} <no-reply@${MODEL_AUTHOR_DOMAIN}>`
    - Where `MODEL_NAME` is the full name and version of the model, and `MODEL_AUTHOR_DOMAIN` is the domain name
      of the model's author.
    - For example: `Claude Sonnet 4.6 <noreply@anthropic.com>`
    - This should be done using the `--author` argument to `git commit`.
        - For example: `git commit --author 'Claude Sonnet 4.6 <noreply@anthropic.com>'`
- Changes should be made with instructive comments explaining why they are required so that the project is as
  instructive as possible.
