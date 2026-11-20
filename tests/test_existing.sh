#!/usr/bin/env bash
# detect_existing_install on the three .env layouts it recognises, and on the
# .env files this script writes itself. It must never change the file.

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
load_setup

PROJECT_DIR="${TEST_TMP}/project"
mkdir -p "${PROJECT_DIR}"
ENV_FILE="${PROJECT_DIR}/.env"

reset_state() {
    clean_env
    ENABLE_HTTPS="unset"
    LEGACY_HOST_PROXY="unset"
    DOMAIN_NAME="unset"
    HTTP_PORT="unset"
}

# detect <description> <expected HTTPS> <expected legacy> <expected domain>
#        <expected port>   (the .env is already in place)
detect() {
    local desc="$1" before
    before=$(cksum < "${ENV_FILE}")
    detect_existing_install
    assert_eq "$2" "${ENABLE_HTTPS}" "${desc}: ENABLE_HTTPS"
    assert_eq "$3" "${LEGACY_HOST_PROXY}" "${desc}: LEGACY_HOST_PROXY"
    assert_eq "$4" "${DOMAIN_NAME}" "${desc}: DOMAIN_NAME"
    assert_eq "$5" "${HTTP_PORT}" "${desc}: HTTP_PORT"
    assert_eq "${before}" "$(cksum < "${ENV_FILE}")" "${desc}: .env unchanged"
}

# ── Bundled Caddy (compose.tls.yml) ──────────────────────────────────────────

reset_state
cat > "${ENV_FILE}" << 'EOF'
MYSQL_PASSWORD='x'
COMPOSE_FILE=docker-compose.yml:compose.tls.yml
SERVER_NAME=omeka.example.edu
CADDY_TLS=internal
EOF
detect "tls overlay" true false omeka.example.edu 80
assert_eq internal "${CADDY_TLS:-}" "tls overlay: CADDY_TLS read from .env"

# The shell's CADDY_TLS wins over .env, as in Compose.
reset_state
CADDY_TLS=acme
detect "tls overlay, CADDY_TLS in the shell" true false omeka.example.edu 80
assert_eq acme "${CADDY_TLS}" "tls overlay: the shell's CADDY_TLS wins"

# The overlay listed among several files, quoted, with a comment.
reset_state
cat > "${ENV_FILE}" << 'EOF'
COMPOSE_FILE='docker-compose.yml:compose.immutable.yml:compose.tls.yml'
SERVER_NAME=omeka.example.edu # the public name
EOF
detect "tls overlay among other files" true false omeka.example.edu 80

# A similarly named file is not the overlay.
reset_state
cat > "${ENV_FILE}" << 'EOF'
COMPOSE_FILE=docker-compose.yml:compose.tls.yml.bak
NGINX_BIND=0.0.0.0
NGINX_PORT=8080
SERVER_NAME=omeka.example.edu
EOF
detect "compose.tls.yml.bak is not the overlay" false false "" 8080

# ── Plain HTTP ───────────────────────────────────────────────────────────────

reset_state
cat > "${ENV_FILE}" << 'EOF'
MYSQL_PASSWORD='x'
NGINX_BIND=0.0.0.0
NGINX_PORT=8080
NGINX_TRUSTED_PROXY_CIDR=192.0.2.1/32
EOF
detect "plain HTTP" false false "" 8080

reset_state
printf 'NGINX_BIND=0.0.0.0\n' > "${ENV_FILE}"
detect "plain HTTP without NGINX_PORT" false false "" 80

# The template default SERVER_NAME=_ is not a domain.
reset_state
printf 'SERVER_NAME=_\n' > "${ENV_FILE}"
detect "SERVER_NAME=_ only" false false "" 80

# ── Legacy: Caddy on the host, nginx on 127.0.0.1 ────────────────────────────

reset_state
cat > "${ENV_FILE}" << 'EOF'
MYSQL_PASSWORD='x'
NGINX_BIND=127.0.0.1
NGINX_PORT=8081
SERVER_NAME=old.example.edu
EOF
detect "legacy host Caddy" false true old.example.edu 8081

# NGINX_BIND absent: the template's default is 127.0.0.1.
reset_state
printf 'SERVER_NAME=old.example.edu\n' > "${ENV_FILE}"
detect "legacy, NGINX_BIND left at its default" false true old.example.edu 80

reset_state
printf 'NGINX_BIND=127.0.0.1\nNGINX_PORT=8081\n' > "${ENV_FILE}"
detect "127.0.0.1 without SERVER_NAME is plain HTTP" false false "" 8081

# ── Round trip with the .env this script writes ──────────────────────────────

# write_fresh <ENABLE_HTTPS> <DOMAIN_NAME> <HTTP_PORT> [CADDY_TLS]
write_fresh() {
    clean_env
    ENV_MYSQL_PASSWORD="pw"
    ENV_SECRET_KEY=$(generate_secret_key)
    ADMIN_EMAIL="admin@example.com"
    ADMIN_PASSWORD="admin-pw"
    SITE_TITLE="Omeka S"
    DEPLOYED_REF="v2.9.0"
    ENABLE_HTTPS="$1"
    DOMAIN_NAME="$2"
    HTTP_PORT="$3"
    if [[ -n "${4:-}" ]]; then CADDY_TLS="$4"; fi
    write_env_file
}

write_fresh false "" 8080
reset_state
detect "fresh HTTP .env" false false "" 8080
remove_admin_credentials
reset_state
detect "fresh HTTP .env, admin block removed" false false "" 8080

write_fresh true omeka.example.edu 80 internal
reset_state
detect "fresh HTTPS .env" true false omeka.example.edu 80
assert_eq internal "${CADDY_TLS:-}" "fresh HTTPS .env: CADDY_TLS read back"

finish
