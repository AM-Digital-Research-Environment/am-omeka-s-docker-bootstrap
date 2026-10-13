# Security policy

`setup.sh` is meant to be piped into a root shell on a fresh server, so a flaw in it reaches every new installation. Please report vulnerabilities privately rather than in a public issue.

## Reporting a vulnerability

Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Include the affected `setup.sh` commit or date, the distribution you ran it on, and the steps to reproduce.

Only the current `main` branch is supported: the one-line installer always fetches `setup.sh` from `main`, so fixes land there.

## Scope

- **In scope:** `setup.sh` and the files it writes — for example `.env` permissions, the generated Caddyfile and firewall rules, how secrets are generated or displayed, and the trust settings it chooses.
- **Out of scope here:** the deployed Omeka S stack (Dockerfile, nginx, PHP, MySQL, backup scripts). Report those to the [omeka-s-docker](https://github.com/AM-Digital-Research-Environment/omeka-s-docker) template; report flaws in Omeka S itself to the [Omeka project](https://omeka.org/).
