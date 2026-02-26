#!/bin/bash
# =============================================================================
# Omeka S Docker — One-Click Setup Script
# =============================================================================
# This script bootstraps a fresh Linux server with everything needed to run
# Omeka S: installs Docker, clones the repository, configures the environment,
# optionally installs Caddy for automatic HTTPS, and launches the services.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
#   — or —
#   wget -qO- https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
#   — or —
#   bash setup.sh              (if already cloned)
#
# Supports: Ubuntu, Debian, Fedora, Rocky/Alma Linux
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

log_step()  { echo -e "\n${BLUE}▸${NC} ${BOLD}$*${NC}"; }
log_ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "  ${RED}✖${NC} $*" >&2; }
log_info()  { echo -e "  ${CYAN}ℹ${NC} $*"; }

ask() {
    local prompt="$1" default="$2" reply
    echo -en "  ${CYAN}?${NC} ${prompt} [${default}]: "
    read -r reply
    echo "${reply:-$default}"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" reply
    echo -en "  ${CYAN}?${NC} ${prompt} [${default}]: "
    read -r reply
    reply="${reply:-$default}"
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
    echo -e "  This script will install Docker (if needed), configure,"
    echo -e "  and launch a production-ready Omeka S instance.\n"
}

# ── Global state ─────────────────────────────────────────────────────────────

ENABLE_CADDY=false
DOMAIN_NAME=""
PROJECT_DIR=""
COMPOSE_CMD="docker compose"
DOCKER_CMD="docker"
SUDO=""
DISTRO_ID=""
DISTRO_NAME=""
DISTRO_FAMILY=""

# ── Pre-flight checks ───────────────────────────────────────────────────────

preflight() {
    log_step "Running pre-flight checks"

    # Must be Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This script is designed for Linux servers."
        exit 1
    fi
    log_ok "Running on Linux ($(uname -r))"

    # Detect distro
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID}"
        DISTRO_NAME="${PRETTY_NAME}"
        DISTRO_FAMILY="${ID_LIKE:-${ID}}"
    else
        log_error "Cannot detect Linux distribution (/etc/os-release not found)."
        exit 1
    fi
    log_ok "Detected: ${DISTRO_NAME}"

    # Check available RAM (warn if < 2 GB)
    local total_ram_mb
    total_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    if (( total_ram_mb < 2048 )); then
        log_warn "Only ${total_ram_mb} MB RAM detected. Recommended: 2048 MB or more."
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

    # Need root/sudo for Docker installation
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

        log_ok "Docker installed successfully"
    fi

    # Ensure Docker Compose v2 is available
    if docker compose version &>/dev/null; then
        log_ok "Docker Compose v2: $(docker compose version --short 2>/dev/null)"
    else
        log_error "Docker Compose v2 plugin not found."
        log_info "Install it with: ${SUDO} apt-get install docker-compose-plugin"
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
        # Re-define docker to use sudo for the rest of this script
        DOCKER_CMD="sudo docker"
        COMPOSE_CMD="sudo docker compose"
    else
        DOCKER_CMD="docker"
        COMPOSE_CMD="docker compose"
    fi
}

install_docker_debian() {
    log_info "Installing Docker for Debian/Ubuntu..."

    # Prerequisites
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    # Docker's official GPG key
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | \
        $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

    # Repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${DISTRO_ID} \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Install
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
}

install_docker_fedora() {
    log_info "Installing Docker for Fedora..."

    $SUDO dnf -y install dnf-plugins-core >/dev/null
    $SUDO dnf-3 config-manager --add-repo \
        https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || \
    $SUDO dnf config-manager addrepo --from-repofile=\
        https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null
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

clone_repo() {
    log_step "Setting up Omeka S Docker"

    # Are we already inside the cloned repo?
    if [[ -f "docker-compose.yml" && -f "Dockerfile" && -f ".env.example" ]]; then
        PROJECT_DIR="$(pwd)"
        log_ok "Already inside the project directory: ${PROJECT_DIR}"
        return
    fi

    local default_dir="/opt/omeka-s"
    local install_dir
    install_dir=$(ask "Installation directory" "${default_dir}")

    if [[ -d "${install_dir}" && -f "${install_dir}/docker-compose.yml" ]]; then
        PROJECT_DIR="${install_dir}"
        log_ok "Existing installation found at ${PROJECT_DIR}"
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
}

# ── HTTPS / Caddy ────────────────────────────────────────────────────────────

ask_https() {
    log_step "HTTPS Configuration"

    echo ""
    echo -e "  Caddy can provide ${BOLD}automatic HTTPS${NC} with Let's Encrypt certificates."
    echo -e "  This requires a domain name already pointing to this server."
    echo ""
    echo -e "  ${BOLD}1)${NC} Yes  — set up automatic HTTPS (recommended for production)"
    echo -e "  ${BOLD}2)${NC} No   — use HTTP only (for local/dev or behind an existing proxy)"
    echo ""

    if ask_yes_no "Enable automatic HTTPS with Caddy?" "y"; then
        ENABLE_CADDY=true

        DOMAIN_NAME=$(ask "Domain name (e.g. omeka.example.edu)" "")

        while [[ -z "${DOMAIN_NAME}" ]]; do
            log_warn "A domain name is required for HTTPS."
            DOMAIN_NAME=$(ask "Domain name (e.g. omeka.example.edu)" "")
        done

        # Basic domain format validation
        if [[ ! "${DOMAIN_NAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            log_warn "That doesn't look like a valid domain. Continuing anyway."
        fi

        log_ok "HTTPS will be enabled for ${DOMAIN_NAME}"
        echo ""
        log_info "Make sure ${DOMAIN_NAME} has a DNS A record pointing to this server."
        log_info "Caddy will automatically obtain a certificate from Let's Encrypt."
    else
        ENABLE_CADDY=false
        log_ok "Skipping HTTPS — Omeka S will be available over HTTP"
    fi
}

install_caddy() {
    log_step "Installing Caddy"

    if command -v caddy &>/dev/null; then
        local caddy_version
        caddy_version=$(caddy version 2>/dev/null || true)
        log_ok "Caddy already installed: ${caddy_version}"
        return
    fi

    log_info "Installing Caddy web server..."

    case "${DISTRO_ID}" in
        ubuntu|debian|linuxmint|pop)
            install_caddy_debian
            ;;
        fedora)
            install_caddy_fedora
            ;;
        centos|rhel|rocky|almalinux|ol)
            install_caddy_rhel
            ;;
        *)
            log_warn "Unsupported distro for Caddy package install. Trying static binary..."
            install_caddy_static
            ;;
    esac

    log_ok "Caddy installed: $(caddy version 2>/dev/null)"
}

install_caddy_debian() {
    $SUDO apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    $SUDO chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    $SUDO chmod o+r /etc/apt/sources.list.d/caddy-stable.list
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq caddy >/dev/null
}

install_caddy_fedora() {
    $SUDO dnf install -y 'dnf-command(copr)' >/dev/null 2>&1 || \
        $SUDO dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
    $SUDO dnf copr enable -y @caddy/caddy >/dev/null 2>&1
    $SUDO dnf install -y caddy >/dev/null
}

install_caddy_rhel() {
    $SUDO yum install -y yum-plugin-copr >/dev/null 2>&1 || \
        $SUDO dnf install -y 'dnf-command(copr)' >/dev/null 2>&1 || true
    $SUDO dnf copr enable -y @caddy/caddy >/dev/null 2>&1 || \
        $SUDO yum copr enable -y @caddy/caddy >/dev/null 2>&1
    $SUDO dnf install -y caddy >/dev/null 2>&1 || \
        $SUDO yum install -y caddy >/dev/null
}

install_caddy_static() {
    # Fallback: download the latest static binary
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac

    local tmp_dir
    tmp_dir=$(mktemp -d)
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${arch}" \
        -o "${tmp_dir}/caddy"
    chmod +x "${tmp_dir}/caddy"
    $SUDO mv "${tmp_dir}/caddy" /usr/bin/caddy
    rm -rf "${tmp_dir}"

    # Create caddy user and group
    $SUDO groupadd --system caddy 2>/dev/null || true
    $SUDO useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true

    # Install the systemd unit
    $SUDO mkdir -p /etc/caddy
    cat << 'UNIT' | $SUDO tee /etc/systemd/system/caddy.service >/dev/null
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
    $SUDO systemctl daemon-reload
}

configure_caddy() {
    log_step "Configuring Caddy for ${DOMAIN_NAME}"

    local caddyfile="/etc/caddy/Caddyfile"

    # Write the Caddyfile
    cat << EOF | $SUDO tee "${caddyfile}" >/dev/null
# Omeka S reverse proxy — generated by setup.sh
# Caddy automatically obtains and renews TLS certificates from Let's Encrypt.

${DOMAIN_NAME} {
    reverse_proxy 127.0.0.1:8080 {
        # Pass real client IP to Omeka S (used by nginx's real_ip module)
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    # Reasonable request body limit (matches Omeka S PHP upload limit)
    request_body {
        max_size 100MB
    }

    # Access log
    log {
        output file /var/log/caddy/omeka-access.log
    }
}
EOF

    $SUDO mkdir -p /var/log/caddy
    $SUDO chown caddy:caddy /var/log/caddy

    log_ok "Caddyfile written to ${caddyfile}"
}

start_caddy() {
    log_info "Starting Caddy..."
    $SUDO systemctl enable caddy >/dev/null 2>&1
    $SUDO systemctl restart caddy

    # Brief check that Caddy started
    sleep 2
    if $SUDO systemctl is-active --quiet caddy; then
        log_ok "Caddy is running"
    else
        log_warn "Caddy may not have started correctly. Check with:"
        log_info "  sudo systemctl status caddy"
        log_info "  sudo journalctl -u caddy --no-pager -n 20"
    fi
}

# ── Configure environment ────────────────────────────────────────────────────

generate_password() {
    # Generate a 24-character password using /dev/urandom (alphanumeric)
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

configure_env() {
    log_step "Configuring environment"

    local env_file="${PROJECT_DIR}/.env"

    if [[ -f "${env_file}" ]]; then
        log_warn "An .env file already exists."
        if ! ask_yes_no "Reconfigure it?" "n"; then
            log_ok "Keeping existing configuration"
            return
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Let's configure your Omeka S instance:${NC}"
    echo ""

    # MySQL password
    local auto_password
    auto_password=$(generate_password)
    echo -e "  ${CYAN}?${NC} MySQL password"
    echo -e "    Press ${BOLD}Enter${NC} to use an auto-generated secure password,"
    echo -e "    or type your own."
    local mysql_password
    mysql_password=$(ask "Password" "${auto_password}")

    # Nginx port — depends on whether Caddy is enabled
    local nginx_port
    if $ENABLE_CADDY; then
        # Bind nginx to localhost only — Caddy handles external traffic
        nginx_port="127.0.0.1:8080"
        log_info "Nginx will listen on 127.0.0.1:8080 (Caddy handles ports 80/443)"
    else
        nginx_port=$(ask "HTTP port for Omeka S" "80")
    fi

    # Omeka S version
    local omeka_version
    omeka_version=$(ask "Omeka S version" "4.2.0")

    # Write .env
    cat > "${env_file}" << EOF
# Omeka S Docker — Generated by setup.sh on $(date -Iseconds)

# MySQL password
MYSQL_PASSWORD=${mysql_password}

# Omeka S version
OMEKA_VERSION=${omeka_version}

# Nginx port
# When Caddy is enabled, nginx binds to localhost only (Caddy → 127.0.0.1:8080)
# When Caddy is disabled, nginx binds directly to the specified port
NGINX_PORT=${nginx_port}
EOF

    chmod 600 "${env_file}"
    log_ok "Configuration saved to .env"

    if [[ "${mysql_password}" == "${auto_password}" ]]; then
        log_info "Auto-generated MySQL password (saved in .env):"
        echo -e "    ${BOLD}${mysql_password}${NC}"
        echo ""
        log_warn "Store this password somewhere safe. You'll rarely need it,"
        log_warn "but it's required if you ever connect to the database directly."
    fi
}

# ── Firewall ─────────────────────────────────────────────────────────────────

configure_firewall() {
    # Determine which ports to open
    local ports=()
    if $ENABLE_CADDY; then
        ports=(80 443)
    else
        local port
        port=$(grep -oP 'NGINX_PORT=\K.*' "${PROJECT_DIR}/.env" 2>/dev/null || echo "80")
        # Strip any IP binding prefix (e.g. "127.0.0.1:8080" → "8080")
        port="${port##*:}"
        ports=("${port}")
    fi

    # Only suggest firewall changes if a firewall is active
    if command -v ufw &>/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        log_step "Firewall detected (ufw)"
        for p in "${ports[@]}"; do
            if ask_yes_no "Open port ${p}/tcp in ufw?" "y"; then
                $SUDO ufw allow "${p}/tcp" comment "Omeka S" >/dev/null
                log_ok "Port ${p} opened"
            fi
        done
    elif command -v firewall-cmd &>/dev/null && $SUDO firewall-cmd --state 2>/dev/null | grep -q "running"; then
        log_step "Firewall detected (firewalld)"
        for p in "${ports[@]}"; do
            if ask_yes_no "Open port ${p}/tcp in firewalld?" "y"; then
                $SUDO firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
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
    $COMPOSE_CMD build --pull 2>&1 | while IFS= read -r line; do
        echo -e "    ${line}"
    done

    log_info "Starting services..."
    $COMPOSE_CMD up -d

    # Wait for healthy state
    log_info "Waiting for services to become healthy..."
    local max_wait=180
    local waited=0
    local all_healthy=false

    while (( waited < max_wait )); do
        # Check if all services are healthy
        local unhealthy
        unhealthy=$($COMPOSE_CMD ps --format '{{.Health}}' 2>/dev/null | grep -cv "healthy" || true)
        if (( unhealthy == 0 )); then
            all_healthy=true
            break
        fi
        echo -ne "\r    Waiting... ${waited}s / ${max_wait}s"
        sleep 5
        waited=$((waited + 5))
    done
    echo "" # clear the \r line

    if $all_healthy; then
        log_ok "All services are healthy!"
    else
        log_warn "Some services are still starting. Check with:"
        log_info "  cd ${PROJECT_DIR} && ${COMPOSE_CMD} ps"
        log_info "  cd ${PROJECT_DIR} && ${COMPOSE_CMD} logs -f php"
    fi

    # Start Caddy after Docker services are up
    if $ENABLE_CADDY; then
        configure_caddy
        start_caddy
    fi
}

# ── Detect server IP ────────────────────────────────────────────────────────

get_server_ip() {
    # Try to get the primary non-loopback IP
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || \
    hostname -I 2>/dev/null | awk '{print $1}' || \
    echo "your-server-ip"
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    local ip
    ip=$(get_server_ip)

    local url
    if $ENABLE_CADDY; then
        url="https://${DOMAIN_NAME}"
    else
        local port
        port=$(grep -oP 'NGINX_PORT=\K.*' "${PROJECT_DIR}/.env" 2>/dev/null || echo "80")
        # Strip any IP binding prefix
        port="${port##*:}"
        url="http://${ip}"
        if [[ "${port}" != "80" ]]; then
            url="http://${ip}:${port}"
        fi
    fi

    echo ""
    echo -e "${GREEN}"
    cat << 'DONE'
  ╔══════════════════════════════════════════════════════════╗
  ║              Setup Complete!                             ║
  ╚══════════════════════════════════════════════════════════╝
DONE
    echo -e "${NC}"
    echo -e "  ${BOLD}Access Omeka S at:${NC}  ${CYAN}${url}${NC}"
    echo ""

    if $ENABLE_CADDY; then
        echo -e "  ${BOLD}HTTPS:${NC}  Managed by Caddy (auto Let's Encrypt)"
        echo -e "  ${BOLD}Domain:${NC} ${DOMAIN_NAME}"
        echo ""
        echo -e "  ${BOLD}Caddy commands:${NC}"
        echo -e "    sudo systemctl status caddy     ${CYAN}# Check Caddy status${NC}"
        echo -e "    sudo journalctl -u caddy -f      ${CYAN}# Caddy logs${NC}"
        echo -e "    sudo nano /etc/caddy/Caddyfile   ${CYAN}# Edit Caddy config${NC}"
        echo -e "    sudo systemctl reload caddy      ${CYAN}# Reload after editing${NC}"
        echo ""
    fi

    echo -e "  ${BOLD}Project directory:${NC}  ${PROJECT_DIR}"
    echo ""
    echo -e "  ${BOLD}Docker commands:${NC}"
    echo -e "    cd ${PROJECT_DIR}"
    echo -e "    ${COMPOSE_CMD} logs -f php   ${CYAN}# Watch installation logs${NC}"
    echo -e "    ${COMPOSE_CMD} ps            ${CYAN}# Check service status${NC}"
    echo -e "    ${COMPOSE_CMD} down          ${CYAN}# Stop all services${NC}"
    echo -e "    ${COMPOSE_CMD} up -d         ${CYAN}# Start all services${NC}"
    echo ""
    echo -e "  ${BOLD}Module management:${NC}"
    echo -e "    bash scripts/install-module.sh list       ${CYAN}# List available modules${NC}"
    echo -e "    bash scripts/install-module.sh CSVImport  ${CYAN}# Install a module${NC}"
    echo ""
    echo -e "  ${BOLD}First-time setup:${NC}"
    echo -e "    Omeka S auto-installs on first start. This can take 5-10 minutes."
    echo -e "    Watch progress with: ${COMPOSE_CMD} logs -f php"
    echo -e "    Once ready, visit ${CYAN}${url}${NC} to create your admin account."
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    banner
    preflight
    install_docker
    clone_repo
    ask_https
    if $ENABLE_CADDY; then
        install_caddy
    fi
    configure_env
    launch
    print_summary
}

main "$@"
