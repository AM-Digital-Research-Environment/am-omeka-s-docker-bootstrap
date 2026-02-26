# Omeka S Docker Bootstrap

One-click setup script for deploying [Omeka S](https://omeka.org/s/) on a fresh Linux server. This script automates the entire process: installing Docker, cloning the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template, configuring the environment, and launching the services.

## Quick Start

Run this single command on a clean Linux VM (Ubuntu, Debian, Fedora, Rocky, Alma):

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

## What the Script Does

1. **Pre-flight checks** -- verifies Linux, detects distro, checks RAM and disk space
2. **Installs Docker and Git** (if not already present)
3. **Clones** the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template repository
4. **Asks if you want automatic HTTPS** -- installs [Caddy](https://caddyserver.com/) with Let's Encrypt
5. **Configures** MySQL password, HTTP port, and Omeka S version
6. **Opens firewall ports** (if ufw or firewalld is active)
7. **Builds and launches** the Docker stack
8. **Waits for healthy services** and prints a summary with access URL

## HTTPS with Caddy

When you choose automatic HTTPS during setup, the script:

- Installs Caddy on the host as a systemd service
- Binds nginx to `127.0.0.1:8080` (localhost only)
- Configures Caddy to reverse-proxy ports 80/443 to the Docker stack
- Automatically obtains and renews Let's Encrypt TLS certificates

**Requirement:** A domain name with a DNS A record already pointing to your server.

```
Internet (HTTPS:443) → Caddy (host) → nginx (127.0.0.1:8080) → PHP-FPM → MySQL
```

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
- Recommended: 2 GB+ RAM, 10 GB+ free disk space

## Related

- **[omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker)** -- the Docker template this script deploys (manual setup instructions, module management, configuration reference)

## License

Apache License 2.0
