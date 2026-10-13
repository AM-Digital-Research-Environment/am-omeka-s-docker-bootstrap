# Omeka S Docker Bootstrap

[![E2E](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/actions/workflows/e2e.yml/badge.svg)](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/actions/workflows/e2e.yml)

One-click setup script for deploying [Omeka S](https://omeka.org/s/) on a fresh Linux server. This script automates the entire process: installing Docker, cloning the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template **at its latest tested release**, configuring the environment (including the admin account), and launching the services.

## Quick Start

Run this single command on a clean Linux VM (Ubuntu, Debian, Fedora, Rocky, Alma):

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

Prompts read from your terminal, so the `curl | bash` form stays interactive. At the end, the script prints the URL of your new site and the generated admin credentials.

### Installing a fixed version

The commands above always run the newest installer from `main`. For repeatable automation, pin a [release](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/releases) of the installer by replacing `main` in the URL with its tag:

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/v1.0.0/setup.sh | bash
```

This pins the installer only. It still deploys the template's latest release unless you also pass `--ref <tag>` (see [Options](#options)).

## What the Script Does

1. **Pre-flight checks** — verifies Linux, detects distro, checks RAM and disk space
2. **Installs Docker and Git** (if not already present)
3. **Clones** the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template and checks out its **latest release tag** (use `--edge` for the `main` branch, or `--ref <tag>` for a specific version)
4. **Asks if you want automatic HTTPS** — installs [Caddy](https://caddyserver.com/) with Let's Encrypt
5. **Configures** MySQL password, the Omeka S admin account, site title, and HTTP port
6. **Opens firewall ports** (if ufw or firewalld is active)
7. **Builds and launches** the Docker stack
8. **Waits for healthy services** and prints a summary with the access URL and admin login

## Options

Every option can be passed as a flag or as an environment variable, so the script works both interactively and in automation:

| Flag | Environment variable | Default | Purpose |
|------|---------------------|---------|---------|
| `-y`, `--yes`, `--non-interactive` | `NONINTERACTIVE=true` | off (auto-on without a TTY) | Accept all defaults, never prompt |
| `--dir <path>` | `OMEKA_INSTALL_DIR` | `/opt/omeka-s` | Installation directory |
| `--domain <name>` | `OMEKA_DOMAIN` | — | Domain name; providing one implies HTTPS with Caddy |
| `--port <port>` | `OMEKA_HTTP_PORT` | `80` | HTTP port (only without Caddy) |
| `--edge` | `BOOTSTRAP_EDGE=true` | off | Deploy the template's `main` branch instead of the latest release |
| `--ref <ref>` | `BOOTSTRAP_REF` | — | Deploy an exact template tag/branch/commit |
| — | `MYSQL_PASSWORD` | auto-generated | MySQL password |
| — | `OMEKA_ADMIN_EMAIL` | `admin@example.com` | Admin account email |
| — | `OMEKA_ADMIN_PASSWORD` | auto-generated | Admin account password |
| — | `OMEKA_TITLE` | `Omeka S` | Site title |

Non-interactive examples:

```bash
# HTTP-only install on port 8080, all defaults
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh \
  | NONINTERACTIVE=true OMEKA_HTTP_PORT=8080 bash

# Production install with HTTPS
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh \
  | OMEKA_DOMAIN=omeka.example.edu OMEKA_ADMIN_EMAIL=you@example.edu NONINTERACTIVE=true bash
```

## Releases, not moving targets

The installer checks out the template's **latest release tag** (`v*`), so new installs always get a state that has passed the template's CI — development on the template's `main` branch can never break a one-click install. Use `--edge` if you deliberately want the newest unreleased state.

### Keeping an installation up to date

Day-to-day updates use the template's own scripts, run from the installation directory (see the template's [Keeping it up to date](https://github.com/AM-Digital-Research-Environment/omeka-s-docker#keeping-it-up-to-date) for details):

```bash
cd /opt/omeka-s
bash scripts/update-omeka.sh --dry-run   # see which Omeka S version it would move to
bash scripts/update-omeka.sh             # backs up, rebuilds, restores the old .env if the build fails
bash scripts/update-extensions.sh        # modules and themes, in place (template v2.3.0 and later)
```

To move to a newer **template release**, back up first:

```bash
cd /opt/omeka-s
bash scripts/backup.sh
git fetch --tags
git checkout <new-tag>
docker compose up -d --build
```

## HTTPS with Caddy

When you choose automatic HTTPS during setup (or pass `--domain`), the script:

- Installs Caddy on the host as a systemd service
- Binds nginx to `127.0.0.1:8080` (localhost only)
- Configures Caddy to reverse-proxy ports 80/443 to the Docker stack
- Automatically obtains and renews Let's Encrypt TLS certificates

**Requirement:** A domain name with a DNS A record already pointing to your server.

```
Internet (HTTPS:443) → Caddy (host) → nginx (127.0.0.1:8080) → PHP-FPM → MySQL
```

Without Caddy, nginx binds `0.0.0.0` on the chosen port so the site is directly reachable, and the script sets `NGINX_TRUSTED_PROXY_CIDR=192.0.2.1/32` so nginx ignores client-supplied `X-Forwarded-For` / `X-Forwarded-Proto` headers (otherwise a client could dodge the admin-login rate limit or pose as HTTPS). The template honours this setting from `v2.3.0`; older releases ignore it and trust forwarded headers from any private address. Direct HTTP is meant for test installs; put TLS in front of a public site.

## Supported Distributions

- Ubuntu
- Debian
- Fedora
- Rocky Linux
- Alma Linux

Other distributions will attempt Docker's convenience install script as a fallback.

## Requirements

- A Linux server (see supported distributions above)
- Root or sudo access
- For HTTPS: a domain name pointing to the server
- Recommended: 4 GB+ RAM, 10 GB+ free disk space. The template's default per-service memory limits add up to about 3.5 GiB; a 2 GB server installs but can run out of memory under load or during a module upgrade, and the script warns below that.

## Continuous testing

A [weekly workflow](.github/workflows/e2e.yml) runs the installer end-to-end on a fresh runner against the latest template release and probes the resulting site, so breakage in the template↔installer contract surfaces here instead of on someone's new server.

## Security

Please report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## Related

- **[omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker)** — the Docker template this script deploys (manual setup instructions, module management, configuration reference, deployment overlays)

## License

Apache License 2.0
