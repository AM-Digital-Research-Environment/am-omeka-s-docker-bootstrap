#!/bin/bash
# =============================================================================
# Omeka S Docker — One-Click Setup Script
# =============================================================================
# This script bootstraps a fresh Linux server with everything needed to run
# Omeka S: installs Docker, clones the omeka-s-docker template at its latest
# release, writes .env (with optional automatic HTTPS through the template's
# bundled Caddy), starts the stack and waits until it is healthy.
#
# Run it again on an installed site (a project directory with a .env) and it
# changes nothing: it keeps .env as it is and just brings the stack up.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
#   — or —
#   wget -qO- https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
#   — or —
#   bash setup.sh [options]    (if already downloaded)
#   Options through a pipe:  curl -fsSL <url> | bash -s -- --domain omeka.example.edu
#
# The usage() function below prints the options and environment variables;
# keep it in sync with this header.
#
# Options (each also settable via environment variable):
#   -y, --yes, --non-interactive   Never prompt, accept defaults      (NONINTERACTIVE=true)
#   --dir <path>                   Installation directory             (OMEKA_INSTALL_DIR)
#   --domain <name>                Domain name — enables HTTPS        (OMEKA_DOMAIN)
#   --port <port>                  HTTP port when not using HTTPS     (OMEKA_HTTP_PORT)
#   --edge                         Deploy the template's main branch
#                                  instead of the latest release      (BOOTSTRAP_EDGE=true)
#   --ref <tag|branch|sha>         Deploy an exact template ref       (BOOTSTRAP_REF)
#   -h, --help                     Show this help
#
# Additional environment variables (fresh installs only):
#   MYSQL_PASSWORD          MySQL password (default: generated, never asked)
#   OMEKA_ADMIN_EMAIL       Admin account email (asked; non-interactive
#                           default: admin@example.com)
#   OMEKA_ADMIN_PASSWORD    Admin account password (default: generated)
#   OMEKA_TITLE             Site title (default: "Omeka S")
#   ACME_CA                 HTTPS only: ACME directory URL, e.g. Let's Encrypt
#                           staging, written to .env
#   CADDY_TLS               HTTPS only: "internal" for a certificate from
#                           Caddy's own CA (no public DNS needed), written to .env
#
# Prompts read from /dev/tty, so interactive use works with `curl | bash`.
# Without a TTY (CI, cron), the script automatically switches to
# non-interactive mode and accepts all defaults.
#
# Exit status: 0 on success, 2 when the stack was started but did not become
# healthy in time, 1 for any other error.
#
# For tests: SETUP_SH_NO_MAIN=1 defines everything without running main, so
# the script can be sourced.
#
# Supports: Ubuntu, Debian, Fedora, RHEL/CentOS/Rocky/Alma Linux
# =============================================================================

set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# All logging goes to stderr: several helpers below are called inside
# command substitution, where anything written to stdout would be captured
# into the variable instead of shown to the user.
log_step()  { echo >&2 -e "\n${BLUE}▸${NC} ${BOLD}$*${NC}"; }
log_ok()    { echo >&2 -e "  ${GREEN}✔${NC} $*"; }
log_warn()  { echo >&2 -e "  ${YELLOW}⚠${NC} $*"; }
log_error() { echo >&2 -e "  ${RED}✖${NC} $*"; }
log_info()  { echo >&2 -e "  ${CYAN}ℹ${NC} $*"; }

# Interactivity: prompts must read from /dev/tty because with `curl | bash`
# stdin is the script itself — a plain `read` would eat script lines.
NONINTERACTIVE="${NONINTERACTIVE:-false}"

detect_interactivity() {
    # -r/-w on /dev/tty can succeed without a controlling terminal, so try to
    # actually open it.
    if [[ "${NONINTERACTIVE}" != "true" ]] && ! { true < /dev/tty > /dev/tty; } 2>/dev/null; then
        NONINTERACTIVE=true
        log_warn "No TTY available — running non-interactively with defaults."
    fi
}

ask() {
    local prompt="$1" default="$2" reply=""
    if [[ "${NONINTERACTIVE}" == "true" ]]; then
        log_info "${prompt}: ${default} (default)"
        echo "${default}"
        return
    fi
    echo >&2 -en "  ${CYAN}?${NC} ${prompt} [${default}]: "
    read -r reply < /dev/tty || reply=""
    echo "${reply:-$default}"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" reply=""
    if [[ "${NONINTERACTIVE}" == "true" ]]; then
        reply="$default"
        log_info "${prompt} ${reply} (default)"
    else
        echo >&2 -en "  ${CYAN}?${NC} ${prompt} [${default}]: "
        read -r reply < /dev/tty || reply=""
        reply="${reply:-$default}"
    fi
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

banner() {
    echo -e "${BLUE}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║               Omeka S Docker Setup                      ║
  ║         Digital Archive — One-Click Installer           ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "  This script installs Docker (if needed), sets up Omeka S with a"
    echo -e "  generated configuration (optionally with automatic HTTPS), starts"
    echo -e "  it and waits until it is ready. On an existing installation it"
    echo -e "  keeps the configuration and only starts the services.\n"
}

# Self-contained (no reading of $0): under `curl ... | bash -s -- --help`
# there is no script file to read. Keep in sync with the header comment.
usage() {
    cat << 'USAGE'
Omeka S Docker — one-click setup

Installs Docker if needed, clones the omeka-s-docker template at its latest
release, writes .env, starts the stack and waits until it is healthy.
On a directory that already has a .env, nothing is changed: the existing
configuration is kept and the stack is started.

Usage:
  curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
  curl -fsSL <same URL> | bash -s -- [options]
  bash setup.sh [options]

Options (each also settable via environment variable):
  -y, --yes, --non-interactive   Never prompt, accept defaults      (NONINTERACTIVE=true)
  --dir <path>                   Installation directory             (OMEKA_INSTALL_DIR)
                                 default: /opt/omeka-s
  --domain <name>                Domain name — enables HTTPS        (OMEKA_DOMAIN)
  --port <port>                  HTTP port when not using HTTPS     (OMEKA_HTTP_PORT)
                                 default: 80
  --edge                         Deploy the template's main branch
                                 instead of the latest release      (BOOTSTRAP_EDGE=true)
  --ref <tag|branch|sha>         Deploy an exact template ref       (BOOTSTRAP_REF)
  -h, --help                     Show this help

Additional environment variables (fresh installs only):
  MYSQL_PASSWORD          MySQL password (default: generated, never asked)
  OMEKA_ADMIN_EMAIL       Admin account email (asked; non-interactive
                          default: admin@example.com)
  OMEKA_ADMIN_PASSWORD    Admin account password (default: generated)
  OMEKA_TITLE             Site title (default: "Omeka S")
  ACME_CA                 HTTPS only: ACME directory URL, e.g. Let's Encrypt
                          staging, written to .env
  CADDY_TLS               HTTPS only: "internal" for a certificate from
                          Caddy's own CA (no public DNS needed), written to .env

HTTPS uses the template's bundled Caddy (template v2.9.0 or later): the
domain must point to this server and ports 80 and 443 must be free.

Exit status: 0 on success, 2 when the stack was started but did not become
healthy in time, 1 for any other error.
USAGE
}

# ── Global state ─────────────────────────────────────────────────────────────

ENABLE_HTTPS=false
DOMAIN_NAME="${OMEKA_DOMAIN:-}"
HTTP_PORT="${OMEKA_HTTP_PORT:-80}"
EXISTING_INSTALL=false     # true when the project directory already has a .env
LEGACY_HOST_PROXY=false    # true for an old .env with Caddy on the host
PROJECT_DIR=""
COMPOSE_CMD="docker compose"
SUDO=""
DISTRO_ID=""
DISTRO_NAME=""
EDGE="${BOOTSTRAP_EDGE:-false}"
BOOTSTRAP_REF="${BOOTSTRAP_REF:-}"
DEPLOYED_REF=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
SITE_TITLE=""
ENV_MYSQL_PASSWORD=""      # value written as MYSQL_PASSWORD
ENV_SECRET_KEY=""          # value written as OMEKA_SECRET_KEY
WAIT_TIMEOUT=600   # seconds `docker compose up --wait` may take
ENV_WRITTEN=false          # true once this run wrote a fresh .env
ADMIN_CREDS_REMOVED=false  # true once OMEKA_ADMIN_* left .env again
# Marker lines around the first-install admin block in .env.
ADMIN_BLOCK_START="# >>> First admin account (removed by setup.sh after the first install)"
ADMIN_BLOCK_END="# <<< First admin account"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes|--non-interactive) NONINTERACTIVE=true ;;
            --edge)      EDGE=true ;;
            --ref)       BOOTSTRAP_REF="${2:?--ref needs a value}"; shift ;;
            --ref=*)     BOOTSTRAP_REF="${1#*=}" ;;
            --dir)       OMEKA_INSTALL_DIR="${2:?--dir needs a value}"; shift ;;
            --dir=*)     OMEKA_INSTALL_DIR="${1#*=}" ;;
            --domain)    OMEKA_DOMAIN="${2:?--domain needs a value}"; DOMAIN_NAME="${OMEKA_DOMAIN}"; shift ;;
            --domain=*)  OMEKA_DOMAIN="${1#*=}"; DOMAIN_NAME="${OMEKA_DOMAIN}" ;;
            --port)      OMEKA_HTTP_PORT="${2:?--port needs a value}"; shift ;;
            --port=*)    OMEKA_HTTP_PORT="${1#*=}" ;;
            -h|--help)   usage; exit 0 ;;
            *)
                log_error "Unknown option: $1 (see --help)"
                exit 1
                ;;
        esac
        shift
    done
}

# ── Pre-flight checks ───────────────────────────────────────────────────────

preflight() {
    log_step "Running pre-flight checks"

    # Must be Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This script is designed for Linux servers."
        exit 1
    fi
    log_ok "Running on Linux ($(uname -r))"

    detect_distro
    log_ok "Detected: ${DISTRO_NAME}"
    detect_sudo
    check_resources
}

# Sets DISTRO_ID and DISTRO_NAME from /etc/os-release (read in a subshell, so
# its variables do not leak into this script).
detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect Linux distribution (/etc/os-release not found)."
        exit 1
    fi
    DISTRO_ID=$(. /etc/os-release && echo "${ID:-}")
    DISTRO_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-${ID:-unknown}}")
}

# Sets SUDO: empty as root, "sudo" otherwise (Docker installation and the
# firewall need root).
detect_sudo() {
    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo &>/dev/null; then
            log_error "This script needs root privileges. Run with: sudo bash setup.sh"
            exit 1
        fi
        SUDO="sudo"
        log_info "Will use sudo for system-level commands."
    else
        SUDO=""
        log_ok "Running as root"
    fi
}

check_resources() {
    # Check available RAM. The template recommends ~4 GB: its default
    # per-service memory ceilings add up to about 3.5 GiB. MemTotal sits a
    # little below a VM's nominal size (the kernel reserves some), so the
    # thresholds leave headroom: a "4 GB" server passes, a "2 GB" one warns.
    local total_ram_mb
    total_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    if (( total_ram_mb < 1800 )); then
        log_error "Only ${total_ram_mb} MB RAM detected — well below the recommended 4 GB."
        log_warn "The install may succeed, but expect out-of-memory errors under load or during upgrades."
    elif (( total_ram_mb < 3500 )); then
        log_warn "Only ${total_ram_mb} MB RAM detected. Recommended: 4 GB or more (out-of-memory errors are likely under load or during upgrades)."
    else
        log_ok "RAM: ${total_ram_mb} MB"
    fi

    # Check available disk (warn if < 10 GB free)
    local free_disk_gb
    free_disk_gb=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
    if (( free_disk_gb < 10 )); then
        log_warn "Only ${free_disk_gb} GB free disk space. Recommended: 10 GB or more."
    else
        log_ok "Free disk: ${free_disk_gb} GB"
    fi
}

# ── Docker installation ─────────────────────────────────────────────────────

install_docker() {
    log_step "Checking Docker"

    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null || true)
        log_ok "Docker already installed: ${docker_version}"
    else
        log_info "Docker not found — installing..."

        if ! ask_yes_no "Install Docker Engine via the official repository?" "y"; then
            log_error "Docker is required. Aborting."
            exit 1
        fi

        install_docker_packages
        log_ok "Docker installed successfully"
    fi

    # Ensure Docker Compose v2 is available
    if docker compose version &>/dev/null; then
        log_ok "Docker Compose v2: $(docker compose version --short 2>/dev/null)"
    else
        log_error "Docker Compose v2 plugin not found."
        case "${DISTRO_ID}" in
            ubuntu|debian|linuxmint|pop)
                log_info "Install it with: ${SUDO:+${SUDO} }apt-get install docker-compose-plugin" ;;
            fedora)
                log_info "Install it with: ${SUDO:+${SUDO} }dnf install docker-compose-plugin" ;;
            centos|rhel|rocky|almalinux|ol)
                log_info "Install it with: ${SUDO:+${SUDO} }yum install docker-compose-plugin" ;;
            *)
                log_info "Install Docker's Compose v2 plugin: https://docs.docker.com/compose/install/linux/" ;;
        esac
        log_info "(It comes from Docker's own package repository, not the distribution's.)"
        exit 1
    fi

    # Ensure Docker daemon is running
    if ! docker info &>/dev/null; then
        log_info "Starting Docker daemon..."
        $SUDO systemctl start docker
        $SUDO systemctl enable docker
    fi
    log_ok "Docker daemon is running"

    # Add current user to docker group (avoids requiring sudo for docker commands)
    if [[ $EUID -ne 0 ]] && ! groups | grep -qw docker; then
        log_info "Adding your user to the 'docker' group..."
        $SUDO usermod -aG docker "$USER"
        log_warn "You may need to log out and back in for group changes to take effect."
        log_info "For now, the script will use sudo for docker commands."
        # Use sudo for compose for the rest of this script
        COMPOSE_CMD="sudo docker compose"
    else
        COMPOSE_CMD="docker compose"
    fi
}

# Adds Docker's package repository and installs Docker Engine with the
# Compose and Buildx plugins. Packages only: no daemon start, systemd or
# group changes, so it also runs in a plain distro container. Needs only
# DISTRO_ID (detect_distro) and SUDO.
install_docker_packages() {
    case "${DISTRO_ID}" in
        ubuntu|debian|linuxmint|pop)
            install_docker_debian
            ;;
        fedora)
            install_docker_fedora
            ;;
        centos|rhel|rocky|almalinux|ol)
            install_docker_rhel
            ;;
        *)
            # Try the convenience script as a fallback
            log_warn "Unsupported distro '${DISTRO_ID}'. Trying Docker's convenience script..."
            install_docker_convenience
            ;;
    esac
}

install_docker_debian() {
    log_info "Installing Docker for Debian/Ubuntu..."

    # Prerequisites
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    # Docker publishes packages for Debian and Ubuntu only. Linux Mint and
    # Pop!_OS are Ubuntu derivatives: they use Ubuntu's repository, under the
    # Ubuntu release they are built on (UBUNTU_CODENAME), not their own name.
    local repo_distro codename
    case "${DISTRO_ID}" in
        linuxmint|pop) repo_distro="ubuntu" ;;
        *)             repo_distro="${DISTRO_ID}" ;;
    esac
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
    if [[ -z "${codename}" ]]; then
        log_error "Cannot tell which ${repo_distro} release this is (no VERSION_CODENAME in /etc/os-release)."
        exit 1
    fi

    # Docker's official GPG key
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${repo_distro}/gpg" | \
        $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

    # Repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${repo_distro} ${codename} stable" | \
        $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Install
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
}

install_docker_fedora() {
    log_info "Installing Docker for Fedora..."

    local repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
    $SUDO dnf -y install dnf-plugins-core >/dev/null
    # Fedora 41+ ships dnf5, whose config-manager has a different syntax.
    # Errors stay visible: a failure here would otherwise end the script
    # silently under `set -e`.
    if command -v dnf5 &>/dev/null; then
        $SUDO dnf config-manager addrepo --overwrite --from-repofile="${repo_url}"
    else
        $SUDO dnf config-manager --add-repo "${repo_url}"
    fi
    $SUDO dnf install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
}

install_docker_rhel() {
    log_info "Installing Docker for RHEL/CentOS/Rocky/Alma..."

    $SUDO yum install -y yum-utils >/dev/null
    $SUDO yum-config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
    $SUDO yum install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
}

install_docker_convenience() {
    curl -fsSL https://get.docker.com | $SUDO sh
}

# ── Install git ──────────────────────────────────────────────────────────────

install_git() {
    if command -v git &>/dev/null; then
        return
    fi

    log_step "Installing git"

    case "${DISTRO_ID}" in
        ubuntu|debian|linuxmint|pop)
            # The package lists may be empty or stale when Docker was already
            # there and nothing refreshed them.
            $SUDO apt-get update -qq
            $SUDO apt-get install -y -qq git >/dev/null
            ;;
        fedora)
            $SUDO dnf install -y git >/dev/null
            ;;
        centos|rhel|rocky|almalinux|ol)
            $SUDO yum install -y git >/dev/null
            ;;
        *)
            log_error "Please install git manually, then re-run this script."
            exit 1
            ;;
    esac

    log_ok "git installed"
}

# ── Clone repository ─────────────────────────────────────────────────────────

REPO_URL="https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git"

checkout_release() {
    # Pin the deployment to a known-good template state. By default: the
    # latest release tag (tested by the template's CI). --edge stays on main;
    # --ref deploys an exact tag/branch/commit.
    if [[ -n "${BOOTSTRAP_REF}" ]]; then
        log_info "Checking out requested ref '${BOOTSTRAP_REF}'..."
        git -C "${PROJECT_DIR}" checkout -q "${BOOTSTRAP_REF}"
        DEPLOYED_REF="${BOOTSTRAP_REF}"
        log_ok "Deployed template at ${BOOTSTRAP_REF}"
        return
    fi

    if [[ "${EDGE}" == "true" ]]; then
        DEPLOYED_REF="main (edge)"
        log_ok "Deploying template main branch (--edge)"
        return
    fi

    local latest_tag
    latest_tag=$(git -C "${PROJECT_DIR}" tag --list 'v*' --sort=-version:refname | head -n1)
    if [[ -n "${latest_tag}" ]]; then
        git -C "${PROJECT_DIR}" checkout -q "${latest_tag}"
        DEPLOYED_REF="${latest_tag}"
        log_ok "Deployed template at latest release: ${latest_tag}"
    else
        DEPLOYED_REF="main (no releases found)"
        log_warn "No release tags found — using the main branch."
    fi
}

clone_repo() {
    log_step "Setting up Omeka S Docker"

    # Are we already inside the cloned repo?
    if [[ -f "docker-compose.yml" && -f "Dockerfile" && -f ".env.example" ]]; then
        PROJECT_DIR="$(pwd)"
        log_ok "Already inside the project directory: ${PROJECT_DIR}"
        use_existing_checkout
        return
    fi

    local default_dir="${OMEKA_INSTALL_DIR:-/opt/omeka-s}"
    local install_dir
    install_dir=$(ask "Installation directory" "${default_dir}")

    if [[ -d "${install_dir}" && -f "${install_dir}/docker-compose.yml" ]]; then
        PROJECT_DIR="${install_dir}"
        log_ok "Existing checkout found at ${PROJECT_DIR}"
        use_existing_checkout
        return
    fi

    install_git

    log_info "Cloning repository..."
    if [[ -d "${install_dir}" ]]; then
        log_warn "Directory ${install_dir} exists but doesn't contain the project."
        if ! ask_yes_no "Remove it and clone fresh?" "n"; then
            log_error "Aborting."
            exit 1
        fi
        $SUDO rm -rf "${install_dir}"
    fi

    $SUDO git clone "${REPO_URL}" "${install_dir}"
    # If we cloned as root, give the current user ownership
    if [[ -n "${SUDO}" && $EUID -ne 0 ]]; then
        $SUDO chown -R "$(id -u):$(id -g)" "${install_dir}"
    fi

    PROJECT_DIR="${install_dir}"
    log_ok "Cloned to ${PROJECT_DIR}"

    checkout_release
}

# An existing checkout is used as it is: never moved to another ref. With a
# .env it is an installed site (see detect_existing_install); without one it
# gets a fresh configuration.
use_existing_checkout() {
    DEPLOYED_REF=$(git -C "${PROJECT_DIR}" describe --tags --always 2>/dev/null || echo "unknown")
    log_info "Template checkout: ${DEPLOYED_REF} (left as it is)"
    if [[ -n "${BOOTSTRAP_REF}" || "${EDGE}" == "true" ]]; then
        log_warn "--ref/--edge only apply to a fresh clone; the existing checkout is not moved."
    fi
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        EXISTING_INSTALL=true
        if [[ -n "${OMEKA_DOMAIN:-}" || -n "${OMEKA_HTTP_PORT:-}" ]]; then
            log_warn "--domain/--port only apply to a new installation; this one keeps the"
            log_warn "address already set in ${PROJECT_DIR}/.env (edit that file to change it)."
        fi
    fi
}

# ── Existing installation ────────────────────────────────────────────────────

# Prints the value of KEY from the project's .env (last assignment wins, as in
# Compose), without surrounding quotes or a trailing " # comment". Prints
# nothing when the key is absent.
env_value() {
    local key="$1" line value
    line=$(grep -E "^[[:space:]]*${key}=" "${PROJECT_DIR}/.env" | tail -n1 || true)
    [[ -n "${line}" ]] || return 0
    value="${line#*=}"
    if [[ "${value}" =~ ^\'(.*)\'[[:space:]]*$ || "${value}" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
        value="${BASH_REMATCH[1]}"
    else
        value="${value%% #*}"
        value="${value%"${value##*[![:space:]]}"}"
    fi
    printf '%s\n' "${value}"
}

# Derives the mode, domain and port from an existing .env without changing
# it. Three layouts are recognised:
#   - bundled Caddy:   COMPOSE_FILE lists compose.tls.yml, SERVER_NAME = domain
#   - legacy host Caddy (written by earlier versions of this script):
#                      NGINX_BIND=127.0.0.1 plus a SERVER_NAME; that Caddy is
#                      left alone, the site is https://SERVER_NAME
#   - plain HTTP:      NGINX_PORT (default 80)
detect_existing_install() {
    local compose_file server_name nginx_bind
    compose_file=$(env_value COMPOSE_FILE)
    server_name=$(env_value SERVER_NAME)
    nginx_bind=$(env_value NGINX_BIND)
    HTTP_PORT=$(env_value NGINX_PORT)
    HTTP_PORT="${HTTP_PORT:-80}"
    LEGACY_HOST_PROXY=false
    # Compose prefers the shell's value over .env; so does the summary.
    CADDY_TLS="${CADDY_TLS:-$(env_value CADDY_TLS)}"

    if [[ ":${compose_file}:" == *":compose.tls.yml:"* ]]; then
        ENABLE_HTTPS=true
        DOMAIN_NAME="${server_name}"
    elif [[ "${nginx_bind:-127.0.0.1}" == "127.0.0.1" && -n "${server_name}" && "${server_name}" != "_" ]]; then
        ENABLE_HTTPS=false
        LEGACY_HOST_PROXY=true
        DOMAIN_NAME="${server_name}"
    else
        ENABLE_HTTPS=false
        DOMAIN_NAME=""
    fi
}

# Re-run on an installed site: nothing is asked, regenerated or rewritten.
# The stack is (re)started with the configuration it already has.
run_existing_install() {
    log_step "Existing installation found at ${PROJECT_DIR}"
    detect_existing_install
    log_ok "Keeping the existing configuration (.env is not modified)"
    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
        log_info "Mode: HTTPS via the bundled Caddy for ${DOMAIN_NAME}"
    elif [[ "${LEGACY_HOST_PROXY}" == "true" ]]; then
        log_info "Mode: behind the Caddy on this host for ${DOMAIN_NAME} (left untouched)"
    else
        log_info "Mode: HTTP on port ${HTTP_PORT}"
    fi

    cd "${PROJECT_DIR}"
    log_step "Starting Omeka S"
    # `up` builds the image only if it is missing; an installed site is not
    # rebuilt behind the operator's back.
    start_and_wait

    # A first run that wrote .env but never got healthy leaves the admin block
    # in it; the install has run now, so finish what that run started.
    if grep -qxF "${ADMIN_BLOCK_START}" .env; then
        ADMIN_EMAIL=$(env_value OMEKA_ADMIN_EMAIL)
        ADMIN_PASSWORD=$(env_value OMEKA_ADMIN_PASSWORD)
        finish_first_install
    fi
}

# ── HTTPS (the template's bundled Caddy)─────────────────────────────────────

# A single DNS name, as Caddy and nginx expect it in SERVER_NAME.
valid_domain() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

ask_https() {
    log_step "HTTPS Configuration"

    # A domain passed via --domain / OMEKA_DOMAIN implies HTTPS.
    if [[ -n "${DOMAIN_NAME}" ]]; then
        DOMAIN_NAME="${DOMAIN_NAME,,}"
        if ! valid_domain "${DOMAIN_NAME}"; then
            log_error "'${DOMAIN_NAME}' is not a valid domain name (expected something like omeka.example.edu)."
            exit 1
        fi
        ENABLE_HTTPS=true
        log_ok "HTTPS will be enabled for ${DOMAIN_NAME} (domain provided)"
    elif [[ "${NONINTERACTIVE}" == "true" ]]; then
        ENABLE_HTTPS=false
        log_ok "Non-interactive: HTTP only (pass --domain or set OMEKA_DOMAIN for HTTPS)"
        return
    else
        echo >&2 ""
        echo >&2 -e "  Omeka S can be served over ${BOLD}HTTPS${NC} with a free, automatically renewed"
        echo >&2 -e "  Let's Encrypt certificate. This needs a domain name whose DNS already"
        echo >&2 -e "  points to this server, and ports 80 and 443 reachable from the internet."
        echo >&2 ""
        echo >&2 -e "  ${BOLD}y${NC} — set up automatic HTTPS (recommended for a public site)"
        echo >&2 -e "  ${BOLD}n${NC} — HTTP only (local/test machine, or behind an existing proxy)"
        echo >&2 ""

        if ! ask_yes_no "Enable automatic HTTPS?" "y"; then
            ENABLE_HTTPS=false
            log_ok "Skipping HTTPS — Omeka S will be available over HTTP"
            return
        fi
        ENABLE_HTTPS=true
        while :; do
            DOMAIN_NAME=$(ask "Domain name (e.g. omeka.example.edu)" "")
            DOMAIN_NAME="${DOMAIN_NAME,,}"
            if valid_domain "${DOMAIN_NAME}"; then
                break
            fi
            log_warn "Please enter a domain name such as omeka.example.edu (no http://, no slash)."
        done
        log_ok "HTTPS will be enabled for ${DOMAIN_NAME}"
    fi

    require_tls_overlay

    case "${CADDY_TLS:-}" in
        ""|acme|internal) ;;
        *)
            log_error "CADDY_TLS must be 'acme' or 'internal' (got '${CADDY_TLS}')."
            exit 1
            ;;
    esac
    if [[ -n "${ACME_CA:-}" && ! "${ACME_CA}" =~ ^https://[^[:space:]\'\"\#]+$ ]]; then
        log_error "ACME_CA must be an https:// URL (got '${ACME_CA}')."
        exit 1
    fi
}

# HTTPS comes from the template's compose.tls.yml overlay, added in v2.9.0.
# Stop rather than fall back to HTTP: the user asked for HTTPS.
require_tls_overlay() {
    if [[ -f "${PROJECT_DIR}/compose.tls.yml" ]]; then
        return
    fi
    log_error "HTTPS needs template v2.9.0 or later, but the checkout in ${PROJECT_DIR}"
    log_error "(${DEPLOYED_REF:-unknown ref}) has no compose.tls.yml."
    log_info "Re-run without --ref / BOOTSTRAP_REF to get the latest release, or with"
    log_info "--ref v2.9.0 or newer. For an existing checkout: git -C ${PROJECT_DIR} fetch --tags"
    log_info "and check out a newer tag. Or leave out --domain to install HTTP only."
    exit 1
}

# Prints the listening socket(s) on a TCP port and succeeds if there is one.
# Without ss nothing can be checked, so the port counts as free.
port_listeners() {
    local port="$1" out
    command -v ss &>/dev/null || return 1
    out=$($SUDO ss -Hltnp "sport = :${port}" 2>/dev/null) || return 1
    [[ -n "${out}" ]] || return 1
    printf '%s\n' "${out}"
}

# Exits with a hint when something already listens on one of the ports.
require_free_ports() {
    local port listeners program busy=false
    if ! command -v ss &>/dev/null; then
        log_warn "Cannot check whether port(s) $* are free ('ss' is not installed)."
        return
    fi
    for port in "$@"; do
        if listeners=$(port_listeners "${port}"); then
            busy=true
            program=$(grep -o 'users:(("[^"]*"' <<< "${listeners}" | head -n1 | cut -d'"' -f2 || true)
            log_error "Port ${port} is already in use${program:+ by '${program}'}."
            case "${program}" in
                docker-proxy)
                    log_info "  Another Docker container publishes it: see 'docker ps'. An earlier"
                    log_info "  Omeka S stack can be stopped with 'docker compose down' in its directory." ;;
                nginx|apache2|httpd|caddy|lighttpd|traefik|haproxy)
                    log_info "  Another web server runs on this machine. If it is not needed:"
                    log_info "    sudo systemctl disable --now ${program}" ;;
                *)
                    log_info "  See what it is with: sudo ss -ltnp 'sport = :${port}'" ;;
            esac
        fi
    done
    if [[ "${busy}" == "true" ]]; then
        if [[ "${ENABLE_HTTPS}" == "true" ]]; then
            log_info "HTTPS needs ports 80 and 443 to itself. Free them, or install HTTP only on"
            log_info "another port (--port 8080, no --domain) behind the existing web server."
        else
            log_info "Choose another port (--port, or OMEKA_HTTP_PORT), or free this one."
        fi
        exit 1
    fi
    log_ok "Port(s) $* free"
}

# IPv4/IPv6 addresses configured on this host, one per line.
host_addresses() {
    {
        # Either tool may be missing; an empty list only softens the warning.
        hostname -I 2>/dev/null | tr ' ' '\n' || true
        ip -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' || true
    } | sed '/^$/d' | sort -u
}

# Warns (and asks, interactively) when the domain does not resolve, or not to
# this host. Let's Encrypt validates over the public DNS, so a wrong record
# means failed attempts, and repeated failures run into its rate limits.
check_domain_dns() {
    if [[ "${CADDY_TLS:-}" == "internal" ]]; then
        log_info "CADDY_TLS=internal: certificate from Caddy's own CA, DNS not checked."
        return
    fi
    if ! command -v getent &>/dev/null; then
        log_warn "Cannot check DNS for ${DOMAIN_NAME} ('getent' is not available)."
        return
    fi

    local resolved own match=false
    resolved=$(getent ahosts "${DOMAIN_NAME}" 2>/dev/null | awk '{ print $1 }' | sort -u || true)

    if [[ -z "${resolved}" ]]; then
        log_warn "${BOLD}${DOMAIN_NAME} does not resolve to any address.${NC}"
        log_warn "Caddy cannot get a certificate until the domain has a DNS A record"
        log_warn "(and AAAA for IPv6) pointing to this server's public IP address."
        log_warn "Let's Encrypt allows only 5 identical certificates per week and limits"
        log_warn "failed attempts too, so create the record first and wait until it works:"
        log_info "  getent ahosts ${DOMAIN_NAME}"
        if [[ "${NONINTERACTIVE}" == "true" ]]; then
            log_warn "Non-interactive: continuing anyway. Caddy retries on its own once DNS works."
            return
        fi
        if ! ask_yes_no "Continue anyway?" "n"; then
            log_error "Stopped. Set up DNS, then run this script again."
            exit 1
        fi
        return
    fi

    own=$(host_addresses)
    local addr
    while IFS= read -r addr; do
        if grep -qxF -- "${addr}" <<< "${own}"; then
            match=true
            break
        fi
    done <<< "${resolved}"

    if [[ "${match}" == "true" ]]; then
        log_ok "${DOMAIN_NAME} resolves to this server"
        return
    fi
    log_warn "${DOMAIN_NAME} resolves to $(tr '\n' ' ' <<< "${resolved}")but none of"
    log_warn "these addresses is configured on this server."
    log_warn "That is normal behind NAT or on cloud servers whose public IP is not on the"
    log_warn "network interface. Otherwise fix the DNS record, or the certificate will fail."
    if [[ "${NONINTERACTIVE}" != "true" ]] && ! ask_yes_no "Continue?" "y"; then
        log_error "Stopped. Fix DNS, then run this script again."
        exit 1
    fi
}

# Pre-checks before anything is written or started.
pre_launch_checks() {
    log_step "Checking ports and DNS"
    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
        require_free_ports 80 443
        check_domain_dns
    else
        require_free_ports "${HTTP_PORT}"
    fi
}

# ── Configure environment ────────────────────────────────────────────────────

generate_password() {
    # Generate a 24-character password using /dev/urandom (alphanumeric).
    # Bound the read on the INPUT side: piping an endless /dev/urandom stream
    # into `head` sends tr SIGPIPE (exit 141) once head closes the pipe, which
    # `set -euo pipefail` treats as fatal.
    local pw
    pw=$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9')
    echo "${pw:0:24}"
}

generate_secret_key() {
    # 32 random bytes, base64-encoded (44 characters, one line), like the
    # template's `openssl rand -base64 32` without needing openssl. head
    # bounds the read, so nothing upstream gets SIGPIPE (see above).
    head -c 32 /dev/urandom | base64 | tr -d '\n'
}

# Docker Compose reads a single-quoted .env value literally, with two
# exceptions that differ between Compose versions: a backslash before a
# single quote, and so a single quote itself or a trailing backslash (which
# would escape the closing quote), cannot be written reliably. Line breaks
# would end the value. Refuse such values rather than write a broken .env.
env_quote_ok() {
    local value="$1"
    [[ "${value}" != *"'"* && "${value}" != *$'\n'* && "${value}" != *$'\r'* && "${value}" != *\\ ]]
}

env_quote_check() {
    local name="$1" value="$2"
    if ! env_quote_ok "${value}"; then
        log_error "${name} cannot contain a single quote ('), a line break, or end with a backslash."
        log_info "Choose another value (or leave ${name} unset to have one generated)."
        exit 1
    fi
}

# Makes a site title safe for a single-quoted .env value, saying what changed:
# a straight apostrophe becomes a typographic one (’), line breaks become
# spaces, trailing backslashes go. The title can be edited in the Omeka admin
# afterwards anyway.
sanitize_title() {
    local title="$1" original="$1"
    title="${title//\'/’}"
    title="${title//$'\r'/ }"
    title="${title//$'\n'/ }"
    while [[ "${title}" == *\\ || "${title}" == *[[:space:]] ]]; do
        title="${title%?}"
    done
    if [[ "${title}" != "${original}" ]]; then
        log_info "Site title adjusted for .env: ${title}"
    fi
    if [[ -z "${title//[[:space:]]/}" ]]; then
        title="Omeka S"
    fi
    printf '%s\n' "${title}"
}

# A plausible address: something@domain.tld, nothing that would break .env.
valid_email() {
    [[ "$1" =~ ^[^[:space:]\'\"@]+@[^[:space:]\'\"@]+\.[^[:space:]\'\"@]+$ ]]
}

is_placeholder_email() {
    [[ "${1,,}" =~ @example\.(com|org|net)$ ]]
}

# Sets ADMIN_EMAIL. Interactively a real address is required: password-reset
# mails (and, with HTTPS, Let's Encrypt's expiry warnings) go there.
ask_admin_email() {
    if [[ "${NONINTERACTIVE}" == "true" ]]; then
        ADMIN_EMAIL="${OMEKA_ADMIN_EMAIL:-admin@example.com}"
        if ! valid_email "${ADMIN_EMAIL}"; then
            log_error "OMEKA_ADMIN_EMAIL '${ADMIN_EMAIL}' is not a valid email address."
            exit 1
        fi
        log_info "Admin account email: ${ADMIN_EMAIL}"
        if is_placeholder_email "${ADMIN_EMAIL}"; then
            log_warn "${ADMIN_EMAIL} is a placeholder: password-reset mails will go nowhere."
            log_warn "Set OMEKA_ADMIN_EMAIL, or change the address in the Omeka admin after logging in."
        fi
        return
    fi
    while :; do
        ADMIN_EMAIL=$(ask "Admin account email (for password resets)" "${OMEKA_ADMIN_EMAIL:-}")
        if ! valid_email "${ADMIN_EMAIL}"; then
            log_warn "Please enter a valid email address, such as name@university.edu."
        elif is_placeholder_email "${ADMIN_EMAIL}"; then
            log_warn "example.com addresses receive no mail; please enter a real address."
        else
            break
        fi
    done
}

configure_env() {
    log_step "Configuring environment"

    echo >&2 ""
    echo >&2 -e "  ${BOLD}Let's configure your Omeka S instance:${NC}"
    echo >&2 ""

    # MySQL password: never asked. Nobody types it in anywhere, and a random
    # one is safer than anything chosen at a prompt.
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        ENV_MYSQL_PASSWORD="${MYSQL_PASSWORD}"
        log_ok "Using MySQL password from environment"
    else
        ENV_MYSQL_PASSWORD=$(generate_password)
        log_ok "MySQL password generated (stored in .env)"
    fi
    env_quote_check "MYSQL_PASSWORD" "${ENV_MYSQL_PASSWORD}"

    # Admin account: creating it here avoids the placeholder account the
    # template's installer would otherwise create.
    ask_admin_email
    if [[ -n "${OMEKA_ADMIN_PASSWORD:-}" ]]; then
        ADMIN_PASSWORD="${OMEKA_ADMIN_PASSWORD}"
        log_ok "Using admin password from environment"
    else
        ADMIN_PASSWORD=$(generate_password)
        log_info "Admin password generated (shown once, in the summary at the end)."
    fi
    env_quote_check "OMEKA_ADMIN_PASSWORD" "${ADMIN_PASSWORD}"

    # Site title
    SITE_TITLE=$(ask "Site title" "${OMEKA_TITLE:-Omeka S}")
    SITE_TITLE=$(sanitize_title "${SITE_TITLE}")

    # HTTP port. With HTTPS, the bundled Caddy owns ports 80/443 and nginx is
    # not published on the host at all.
    if [[ "${ENABLE_HTTPS}" != "true" ]]; then
        HTTP_PORT=$(ask "HTTP port for Omeka S" "${OMEKA_HTTP_PORT:-80}")
        if [[ ! "${HTTP_PORT}" =~ ^[0-9]+$ ]] || (( HTTP_PORT < 1 || HTTP_PORT > 65535 )); then
            log_error "'${HTTP_PORT}' is not a valid port number."
            exit 1
        fi
    fi

    # Checked before .env exists: a re-run with .env present keeps it as is.
    pre_launch_checks

    ENV_SECRET_KEY=$(generate_secret_key)
    if (( ${#ENV_SECRET_KEY} != 44 )); then
        log_error "Could not generate OMEKA_SECRET_KEY (is base64 installed?)."
        exit 1
    fi

    write_env_file
    ENV_WRITTEN=true
    log_ok "Configuration saved to .env"
}

# Writes ${PROJECT_DIR}/.env from variables only (no prompts), mode 0600:
#   ENV_MYSQL_PASSWORD, ENV_SECRET_KEY, ADMIN_EMAIL, ADMIN_PASSWORD,
#   SITE_TITLE, DEPLOYED_REF (comment only), ENABLE_HTTPS, and then
#   HTTPS:  DOMAIN_NAME, optional ACME_CA and CADDY_TLS
#   HTTP:   HTTP_PORT
# Exits if a value cannot be written safely (see env_quote_ok).
write_env_file() {
    local env_file="${PROJECT_DIR}/.env"
    local tmp_file="${env_file}.tmp.$$"

    env_quote_check "MYSQL_PASSWORD" "${ENV_MYSQL_PASSWORD}"
    env_quote_check "OMEKA_SECRET_KEY" "${ENV_SECRET_KEY}"
    env_quote_check "OMEKA_ADMIN_EMAIL" "${ADMIN_EMAIL}"
    env_quote_check "OMEKA_ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
    env_quote_check "OMEKA_TITLE" "${SITE_TITLE}"

    # Built in a file only the owner can read, then moved into place.
    (
        umask 077
        render_env > "${tmp_file}"
    )
    chmod 600 "${tmp_file}"
    mv -f "${tmp_file}" "${env_file}"
}

# Prints the .env content for write_env_file.
render_env() {
    cat << EOF
# Omeka S Docker — Generated by setup.sh on $(date -Iseconds)
# Template ref: ${DEPLOYED_REF:-unknown}

# Values in single quotes are taken literally by Docker Compose ($, ", #
# and spaces need no escaping), but cannot contain a single quote.

# MySQL password
MYSQL_PASSWORD='${ENV_MYSQL_PASSWORD}'

# Encryption key for secrets Omeka stores (module API keys and similar).
# NEVER change it after the first start: anything already encrypted with it
# becomes unreadable. Back it up together with the rest of this file.
OMEKA_SECRET_KEY='${ENV_SECRET_KEY}'

${ADMIN_BLOCK_START}
# Read only by the very first start, which creates this account. setup.sh
# deletes this block once that install has finished; changing these values
# later would not change the real account (use the Omeka admin for that).
OMEKA_ADMIN_EMAIL='${ADMIN_EMAIL}'
OMEKA_ADMIN_USERNAME='admin'
OMEKA_ADMIN_PASSWORD='${ADMIN_PASSWORD}'
${ADMIN_BLOCK_END}

OMEKA_TITLE='${SITE_TITLE}'
EOF

    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
        # nginx keeps the template's default NGINX_TRUSTED_PROXY_CIDR, which
        # covers the Docker bridge Caddy connects from.
        cat << EOF

# HTTPS: the template's bundled Caddy (compose.tls.yml) listens on ports 80
# and 443 and obtains and renews the certificate for SERVER_NAME by itself.
# Its certificates live in the caddy_data Docker volume: keep that volume.
# See docs/PRODUCTION.md, "Bundled HTTPS (Caddy)", in this directory.
COMPOSE_FILE=docker-compose.yml:compose.tls.yml
SERVER_NAME=${DOMAIN_NAME}
EOF
        if ! is_placeholder_email "${ADMIN_EMAIL}"; then
            echo "ACME_EMAIL='${ADMIN_EMAIL}'"
        fi
        if [[ -n "${ACME_CA:-}" ]]; then
            echo "ACME_CA=${ACME_CA}"
        fi
        if [[ -n "${CADDY_TLS:-}" ]]; then
            echo "CADDY_TLS=${CADDY_TLS}"
        fi
    else
        # With no proxy in front, nginx must not believe client-supplied
        # X-Forwarded-For / X-Forwarded-Proto: that would let a client dodge the
        # admin-login rate limit and pose as HTTPS.
        cat << EOF

# Where nginx listens on the host: all interfaces, so the site is reachable
# from outside.
NGINX_BIND=0.0.0.0
NGINX_PORT=${HTTP_PORT}

# Direct HTTP, no reverse proxy: trust no peer's forwarded headers.
# 192.0.2.1 is a documentation-only address, not a proxy to configure.
# If you later put a reverse proxy in front, set this to its address as seen
# by the web container (see the template's docs/PRODUCTION.md).
NGINX_TRUSTED_PROXY_CIDR=192.0.2.1/32
EOF
    fi
}

# The template reads OMEKA_ADMIN_* only on the first install, and the php
# container warns on every later start while OMEKA_ADMIN_PASSWORD is still
# set. Once that install is done (php is healthy only after it), delete the
# block from .env: the credentials are then shown once, in the summary.
remove_admin_credentials() {
    local env_file="${PROJECT_DIR}/.env"
    local tmp_file="${env_file}.tmp.$$"
    (
        umask 077
        awk -v start="${ADMIN_BLOCK_START}" -v end="${ADMIN_BLOCK_END}" '
            $0 == start { skip = 1; next }
            skip && $0 == end { skip = 0; drop_blank = 1; next }
            skip { next }
            /^OMEKA_ADMIN_(EMAIL|USERNAME|PASSWORD)=/ { next }
            drop_blank && $0 == "" { drop_blank = 0; next }
            { drop_blank = 0; print }
        ' "${env_file}" > "${tmp_file}"
    )
    chmod 600 "${tmp_file}"
    mv -f "${tmp_file}" "${env_file}"
    ADMIN_CREDS_REMOVED=true
}

# After a fresh install: drop the admin credentials from .env and recreate
# php so they leave its environment too.
finish_first_install() {
    log_step "Removing the admin password from .env"
    remove_admin_credentials
    log_ok "OMEKA_ADMIN_* removed from .env (only needed by the first install)"
    # Compose prefers this shell's variables over .env: when the account came
    # in through the environment, php would be recreated with it again.
    unset OMEKA_ADMIN_EMAIL OMEKA_ADMIN_USERNAME OMEKA_ADMIN_PASSWORD
    start_and_wait
}

# ── Firewall ─────────────────────────────────────────────────────────────────

configure_firewall() {
    # Determine which ports to open (port/protocol). 443/udp carries HTTP/3;
    # browsers fall back to TCP without it.
    local ports=() p
    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
        ports=(80/tcp 443/tcp 443/udp)
    else
        ports=("${HTTP_PORT}/tcp")
    fi

    # Only suggest firewall changes if a firewall is active
    if command -v ufw &>/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        log_step "Firewall detected (ufw)"
        for p in "${ports[@]}"; do
            if ask_yes_no "Open port ${p} in ufw?" "y"; then
                $SUDO ufw allow "${p}" comment "Omeka S" >/dev/null
                log_ok "Port ${p} opened"
            fi
        done
    elif command -v firewall-cmd &>/dev/null && $SUDO firewall-cmd --state 2>/dev/null | grep -q "running"; then
        log_step "Firewall detected (firewalld)"
        for p in "${ports[@]}"; do
            if ask_yes_no "Open port ${p} in firewalld?" "y"; then
                $SUDO firewall-cmd --permanent --add-port="${p}" >/dev/null
                log_ok "Port ${p} opened"
            fi
        done
        $SUDO firewall-cmd --reload >/dev/null
    fi
}

# ── Build & Launch ───────────────────────────────────────────────────────────

launch() {
    log_step "Building and starting Omeka S"

    cd "${PROJECT_DIR}"

    configure_firewall

    log_info "Building the Docker image (this may take a few minutes on first run)..."
    if ! $COMPOSE_CMD build --pull 2>&1 | while IFS= read -r line; do
        echo >&2 -e "    ${line}"
    done; then
        log_error "Building the Docker image failed (see the output above)."
        log_info "A network hiccup is the usual cause: simply run this script again."
        exit 1
    fi

    start_and_wait
    if [[ "${ENV_WRITTEN}" == "true" ]]; then
        finish_first_install
    fi
}

# Starts the stack and blocks until every service reports healthy. First boot
# includes the Omeka S installation (database, modules), which takes a few
# minutes. Compose's own --wait fails on an unhealthy or exited container
# instead of mistaking it for a healthy one, and returns non-zero on timeout.
start_and_wait() {
    log_info "Starting services and waiting until they are healthy (up to 10 minutes)..."
    if $COMPOSE_CMD up -d --wait --wait-timeout "${WAIT_TIMEOUT}"; then
        log_ok "All services are healthy"
        return 0
    fi

    echo >&2 ""
    log_error "Omeka S did not become healthy within $(( WAIT_TIMEOUT / 60 )) minutes."
    echo >&2 ""
    log_info "Service status:"
    $COMPOSE_CMD ps >&2 || true
    echo >&2 ""
    log_info "Last lines of the php service log:"
    $COMPOSE_CMD logs --no-color --tail 30 php >&2 || true
    echo >&2 ""
    log_info "What to do: read the log lines above for an error. A slow server may"
    log_info "simply need more time: wait a few minutes, then check again with"
    log_info "  cd ${PROJECT_DIR} && ${COMPOSE_CMD} ps"
    log_info "Too little memory (under 4 GB) is the most common cause of a failed start."
    if [[ "${ADMIN_CREDS_REMOVED}" == "true" ]]; then
        # Omeka itself is installed; the credentials are no longer in .env,
        # so this is the last chance to see them.
        echo >&2 ""
        log_warn "Omeka S was installed. Store this admin login now, it is not saved anywhere:"
        log_info "  Email:    ${ADMIN_EMAIL}"
        log_info "  Password: ${ADMIN_PASSWORD}"
    fi
    exit 2
}

# ── Detect server IP ────────────────────────────────────────────────────────

get_server_ip() {
    # The source address of the default route (no packet is sent), else the
    # first configured address. Each step can print nothing without failing,
    # so test the output rather than the exit status.
    local addr
    addr=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)
    if [[ -z "${addr}" ]]; then
        addr=$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)
    fi
    echo "${addr:-your-server-ip}"
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    local ip
    ip=$(get_server_ip)

    local url
    if [[ "${ENABLE_HTTPS}" == "true" || "${LEGACY_HOST_PROXY}" == "true" ]]; then
        url="https://${DOMAIN_NAME}"
    else
        url="http://${ip}"
        if [[ "${HTTP_PORT}" != "80" ]]; then
            url="http://${ip}:${HTTP_PORT}"
        fi
    fi

    echo ""
    echo -e "${GREEN}"
    if [[ "${EXISTING_INSTALL}" == "true" ]]; then
        cat << 'DONE'
  ╔══════════════════════════════════════════════════════════╗
  ║              Omeka S is running                          ║
  ╚══════════════════════════════════════════════════════════╝
DONE
    else
        cat << 'DONE'
  ╔══════════════════════════════════════════════════════════╗
  ║              Setup Complete!                             ║
  ╚══════════════════════════════════════════════════════════╝
DONE
    fi
    echo -e "${NC}"
    echo -e "  ${BOLD}Access Omeka S at:${NC}  ${CYAN}${url}${NC}"
    if [[ -n "${DEPLOYED_REF}" ]]; then
        echo -e "  ${BOLD}Template version:${NC}   ${DEPLOYED_REF}"
    fi
    echo ""

    if [[ "${EXISTING_INSTALL}" == "true" ]]; then
        echo -e "  ${BOLD}Existing configuration kept:${NC} this run changed nothing in .env."
        echo -e "  To change settings, edit ${PROJECT_DIR}/.env by hand, then run"
        echo -e "  '${COMPOSE_CMD} up -d' in that directory."
        if [[ "${LEGACY_HOST_PROXY}" == "true" ]]; then
            echo -e "  HTTPS comes from the Caddy installed on this host by an earlier version"
            echo -e "  of this script (/etc/caddy/Caddyfile); it was left untouched."
        fi
        echo ""
    fi

    if [[ -n "${ADMIN_PASSWORD}" ]]; then
        echo -e "  ${BOLD}Admin login${NC} ${YELLOW}(shown only this once, not saved anywhere: store it now,${NC}"
        echo -e "  ${YELLOW}e.g. in a password manager)${NC}"
        echo -e "    Email:    ${BOLD}${ADMIN_EMAIL}${NC}"
        echo -e "    Password: ${BOLD}${ADMIN_PASSWORD}${NC}"
        echo -e "    Log in at ${CYAN}${url}/login${NC}. Change the password later under your"
        echo -e "    user's Password tab in the Omeka admin."
        echo ""
    fi

    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
        if [[ "${CADDY_TLS:-}" == "internal" ]]; then
            echo -e "  ${BOLD}HTTPS:${NC}  bundled Caddy container, certificate from Caddy's own CA"
            echo -e "          (browsers warn until its root certificate is trusted)"
        else
            echo -e "  ${BOLD}HTTPS:${NC}  bundled Caddy container, automatic Let's Encrypt certificate"
            if [[ "${EXISTING_INSTALL}" != "true" ]]; then
                echo -e "          The first certificate can take a minute; until then the browser"
                echo -e "          may show a security error. Watch it arrive with"
                echo -e "          ${COMPOSE_CMD} logs -f caddy   ${CYAN}# look for \"certificate obtained\"${NC}"
            fi
        fi
        echo -e "          Keep the ${BOLD}caddy_data${NC} Docker volume: it holds the certificate."
        echo -e "          Deleting it forces new certificates, and Let's Encrypt allows only"
        echo -e "          5 identical ones per week."
        echo ""
    fi

    echo -e "  ${BOLD}Project directory:${NC}  ${PROJECT_DIR}"
    echo ""
    echo -e "  ${BOLD}Docker commands:${NC}"
    echo -e "    cd ${PROJECT_DIR}"
    echo -e "    ${COMPOSE_CMD} logs -f php   ${CYAN}# Application logs${NC}"
    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
        echo -e "    ${COMPOSE_CMD} logs -f caddy ${CYAN}# HTTPS / certificate logs${NC}"
    fi
    echo -e "    ${COMPOSE_CMD} ps            ${CYAN}# Check service status${NC}"
    echo -e "    ${COMPOSE_CMD} down          ${CYAN}# Stop all services${NC}"
    echo -e "    ${COMPOSE_CMD} up -d         ${CYAN}# Start all services${NC}"
    echo ""
    echo -e "  ${BOLD}Module management:${NC}"
    echo -e "    bash scripts/install-module.sh list       ${CYAN}# List available modules${NC}"
    echo -e "    bash scripts/install-module.sh CSVImport  ${CYAN}# Install a module${NC}"
    echo ""
    echo -e "  ${BOLD}Keeping it up to date${NC} (run from ${PROJECT_DIR}):"
    echo -e "    bash scripts/update-omeka.sh --dry-run  ${CYAN}# New Omeka S version (backs up first)${NC}"
    # Added in template v2.3.0; an older --ref checkout doesn't have it.
    if [[ -f "${PROJECT_DIR}/scripts/update-extensions.sh" ]]; then
        echo -e "    bash scripts/update-extensions.sh       ${CYAN}# Modules and themes, in place${NC}"
    fi
    echo -e "    bash scripts/backup.sh                 ${CYAN}# Always before moving to a new template tag${NC}"
    echo -e "    Details: ${CYAN}https://github.com/AM-Digital-Research-Environment/omeka-s-docker#keeping-it-up-to-date${NC}"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    detect_interactivity
    banner
    preflight
    install_docker
    clone_repo
    if [[ "${EXISTING_INSTALL}" == "true" ]]; then
        run_existing_install
    else
        ask_https
        configure_env
        launch
    fi
    print_summary
}

# The last statement, so a truncated download never runs a partial script.
# SETUP_SH_NO_MAIN=1 only defines the functions (for tests that source this
# file). Not based on BASH_SOURCE, which `curl | bash` does not set usefully.
if [[ "${SETUP_SH_NO_MAIN:-}" != "1" ]]; then
    main "$@"
fi
