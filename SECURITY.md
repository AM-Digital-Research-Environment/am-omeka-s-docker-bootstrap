# Security policy

`setup.sh` is meant to be piped into a root shell on a fresh server, so a flaw in it reaches every new installation. Please report vulnerabilities privately rather than in a public issue.

## Reporting a vulnerability

Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Include the affected `setup.sh` release tag or commit, the distribution you ran it on, and the steps to reproduce.

## Supported versions

Fixes land on `main`, which the one-line installer fetches by default, and ship in the next release. Only `main` and the latest [release](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/releases) are supported. If you pin an older release tag in your automation, move the pin to the latest release to get a fix; older releases are not patched.

## Scope

- **In scope:** `setup.sh` and what it changes on the server. For example: how it generates, stores and displays secrets (the MySQL password, `OMEKA_SECRET_KEY`, the admin password shown once in the summary), the permissions of the `.env` it writes and the removal of the admin credentials from it, the firewall rules it adds, and the trust settings it chooses (`NGINX_TRUSTED_PROXY_CIDR` for direct HTTP, the HTTPS overlay it switches on).
- **Out of scope here:** the deployed Omeka S stack, including its bundled Caddy configuration (Dockerfile, nginx, Caddy, PHP, MySQL, backup scripts). Report those to the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template; report flaws in Omeka S itself to the [Omeka project](https://omeka.org/).
