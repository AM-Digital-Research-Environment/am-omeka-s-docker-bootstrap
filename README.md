# Omeka S Docker Bootstrap

[![E2E](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/actions/workflows/e2e.yml/badge.svg)](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/actions/workflows/e2e.yml)

A one-command installer for [Omeka S](https://omeka.org/s/) on a fresh Linux server. It installs Docker, deploys the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template at its **latest tested release**, writes the configuration (admin account included, automatic HTTPS if you want it), starts the site and waits until it is ready.

## Quick start

Run this on a clean Linux server (Ubuntu, Debian, Fedora, Rocky, Alma):

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

`wget -qO- <same URL> | bash` works too. The script asks its questions in your terminal, even through the pipe. To pass options through the pipe, put them after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash -s -- --domain omeka.example.edu
```

At the end it prints the site's address and the admin login. **The admin password is shown only this once**: store it straight away, for example in a password manager.

### Installing a fixed version

The commands above run the newest installer from `main`. For repeatable automation, replace `main` in the URL with a [release](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/releases) tag. This pins the installer only; it still deploys the template's latest release unless you also pass `--ref <tag>`.

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/v1.0.0/setup.sh | bash
```

## What the script does

1. **Checks the server**: Linux distribution, memory (warns below about 4 GB) and free disk (warns below 10 GB).
2. **Installs Docker and Git** if missing, from Docker's official repository.
3. **Downloads the template** to `/opt/omeka-s` at its latest release tag.
4. **Asks** whether you want HTTPS, the admin e-mail address, the site title and, without HTTPS, the HTTP port. It generates the admin password, the MySQL password and an encryption key.
5. **Checks** that the ports are free and, with HTTPS, that the domain points to this server.
6. **Writes `.env`**, the configuration file, readable only by its owner, and offers to open the ports if the ufw or firewalld firewall is active.
7. **Builds and starts** the site and waits until every service is healthy (up to 10 minutes; the first start installs Omeka).
8. **Removes the admin login from `.env`** once the account exists, and prints the summary.

`.env` holds `OMEKA_SECRET_KEY`, which Omeka uses to encrypt stored secrets such as module API keys. **Never change it**; back it up with `.env` (the template's `scripts/backup.sh` does).

## Options

| Flag | Environment variable | Default | Purpose |
|------|---------------------|---------|---------|
| `-y`, `--yes`, `--non-interactive` | `NONINTERACTIVE=true` | off (on without a terminal) | Accept all defaults, never ask |
| `--dir <path>` | `OMEKA_INSTALL_DIR` | `/opt/omeka-s` | Installation directory |
| `--domain <name>` | `OMEKA_DOMAIN` | none | Domain name; turns on HTTPS |
| `--port <port>` | `OMEKA_HTTP_PORT` | `80` | HTTP port (without HTTPS) |
| `--edge` | `BOOTSTRAP_EDGE=true` | off | Deploy the template's `main` branch, not the latest release |
| `--ref <ref>` | `BOOTSTRAP_REF` | none | Deploy an exact template tag, branch or commit |
| `-h`, `--help` | | | Show the help |
| | `OMEKA_ADMIN_EMAIL` | asked (`admin@example.com` without prompts) | Admin e-mail |
| | `OMEKA_ADMIN_PASSWORD` | generated | Admin password |
| | `MYSQL_PASSWORD` | generated, never asked | MySQL password |
| | `OMEKA_TITLE` | `Omeka S` | Site title |
| | `ACME_CA` | Let's Encrypt | HTTPS: another certificate authority, e.g. Let's Encrypt staging |
| | `CADDY_TLS` | none | HTTPS: `internal` for a certificate from Caddy's own authority (no public domain needed) |

The last six only apply to a new installation. At the prompt the admin e-mail must be a real address, as password resets (and, with HTTPS, Let's Encrypt's expiry warnings) go there. Without prompts, set `OMEKA_ADMIN_EMAIL`, or change the placeholder in the Omeka admin later.

```bash
# No prompts: HTTP only, on port 8080
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh \
  | NONINTERACTIVE=true OMEKA_HTTP_PORT=8080 bash

# No prompts: public site with HTTPS
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh \
  | OMEKA_DOMAIN=omeka.example.edu OMEKA_ADMIN_EMAIL=you@example.edu NONINTERACTIVE=true bash
```

## HTTPS

With a domain name, the script switches on the template's bundled [Caddy](https://caddyserver.com/) container. Caddy gets a free Let's Encrypt certificate, renews it, redirects HTTP to HTTPS and sends HSTS (telling browsers to use HTTPS only). The login cookie becomes `Secure`, so it is never sent unencrypted. Nothing is installed on the host.

```
Internet (80, 443) → Caddy container → nginx container → PHP-FPM → MySQL
```

You need:

- **A DNS A record**: the entry that tells the internet which server a name such as `omeka.example.edu` belongs to. It must point to the server's public IP address (plus an AAAA record if the server has IPv6). Your IT department or domain provider creates it.
- **Ports 80 and 443 open and free.** A port is the numbered door a service listens on: 80 for HTTP, 443 for HTTPS. Both must be reachable from the internet, and no other program on the server may use them.

The script checks both first. If the domain does not point to this server, it warns and asks whether to continue (without prompts it continues), because Let's Encrypt issues only 5 identical certificates per week and also limits failed attempts. HTTPS needs template v2.9.0 or later; with an older `--ref` the script stops.

The first certificate can take a minute. Watch it arrive from the installation directory with `docker compose logs -f caddy` (look for "certificate obtained"). Certificates live in the `caddy_data` Docker volume: **keep it**, or Caddy requests new ones and may hit the weekly limit. `scripts/backup.sh` saves it.

To experiment without using up the limit, use Let's Encrypt's staging service (browsers do not trust its certificates), then remove the `ACME_CA` line from `.env` and run `docker compose up -d`:

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh \
  | ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory bash -s -- --domain omeka.example.edu
```

More in the template's [Bundled HTTPS (Caddy)](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/blob/main/docs/PRODUCTION.md#bundled-https-caddy).

**Without HTTPS**, nginx listens on the chosen port, and the script sets `NGINX_TRUSTED_PROXY_CIDR=192.0.2.1/32` so nginx ignores client-supplied `X-Forwarded-*` headers (which could otherwise dodge the admin-login rate limit or pose as HTTPS). Plain HTTP is meant for test installs.

### Installations from earlier versions of this script

Earlier versions installed Caddy on the host (`/etc/caddy/Caddyfile`) in front of nginx on `127.0.0.1:8080`. These sites keep working: the script recognises them, leaves that Caddy alone and does not migrate them. To move to the bundled Caddy, follow the template's [Bundled HTTPS (Caddy)](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/blob/main/docs/PRODUCTION.md#bundled-https-caddy). Until then their login cookie is **not** `Secure`: add `OMEKA_SESSION_COOKIE_SECURE=true` to `.env` and run `docker compose up -d php web` ([HTTPS settings](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/blob/main/docs/PRODUCTION.md#https-settings-in-env)).

## Running it again

Running the script again on an installed site (a directory with a `.env`) is safe. It keeps `.env` unchanged, regenerates nothing, asks nothing beyond the installation directory, starts the site if needed, waits until it is healthy and prints the address. `--domain`, `--port`, `--ref` and `--edge` have no effect then: to change a setting, edit `.env` and run `docker compose up -d` in the installation directory.

## If something goes wrong

If the site is not healthy after 10 minutes, the script stops with exit status 2 and shows each service's status and the last lines of the application log. Look there for an error. Too little memory (under 4 GB) is the most common cause; a slow server may just need a few more minutes. To look further (put `sudo` in front if Docker says permission denied):

```bash
cd /opt/omeka-s
docker compose ps           # which service is not healthy?
docker compose logs php     # the application log
docker compose logs caddy   # certificates (HTTPS only)
docker compose up -d        # start everything again
```

If the first install failed, check the error output: if it shows the admin login, store it now. Otherwise, run the script again once the problem is fixed; it reuses its configuration and shows the login at the end. If you are stuck, [open an issue](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/issues) with the output (remove passwords first). For problems with the running site, see the template's [Troubleshooting](https://github.com/AM-Digital-Research-Environment/omeka-s-docker#troubleshooting).

## Keeping an installation up to date

Use the template's scripts from the installation directory (see its [Keeping it up to date](https://github.com/AM-Digital-Research-Environment/omeka-s-docker#keeping-it-up-to-date)):

```bash
cd /opt/omeka-s
bash scripts/update-omeka.sh --dry-run   # which Omeka S version it would move to
bash scripts/update-omeka.sh             # backs up, rebuilds, restores the old .env if the build fails
bash scripts/update-extensions.sh        # modules and themes, in place (template v2.3.0 and later)
```

The installer deploys a release tag, so changes on the template's `main` branch never reach your site by themselves. The template does not document or test moving an installation to a newer **template release**. Read that release's notes first; these steps combine what it does document, a backup and a rebuild of the code images:

```bash
cd /opt/omeka-s
bash scripts/backup.sh
git fetch --tags
git checkout <new-tag>
bash scripts/rebuild-code.sh --pull   # rebuilds and restarts php and web
docker compose up -d                  # applies changes to the other services
```

## Requirements

- Ubuntu, Debian, Fedora, Rocky Linux or Alma Linux (others try Docker's convenience install script).
- Root or `sudo` access.
- Recommended: 4 GB of memory and 10 GB of free disk. A 2 GB server installs but can run out of memory under load or during a module upgrade.
- For HTTPS: see [HTTPS](#https).

## Continuous testing

The [workflows](.github/workflows/) test the installer:

- **Lint**: ShellCheck and the unit tests in `tests/`.
- **HTTP install**: a full install on a fresh runner against the latest template release, with a real admin login, then a second run on the installed site.
- **HTTPS install**: the same with the bundled Caddy, using Caddy's internal certificate authority.
- **Docker installation**: the Docker setup on Debian, Ubuntu, Fedora and Rocky containers.

## Security

Please report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## Related

- **[omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker)**: the template this script deploys (manual setup, modules, configuration, deployment overlays)

## License

Apache License 2.0
