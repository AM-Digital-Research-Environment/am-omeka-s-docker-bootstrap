#!/usr/bin/env bash
# .env rendering (HTTP and HTTPS), quoting and round trips through env_value,
# refusal of unsafe values, and remove_admin_credentials.

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
load_setup

PROJECT_DIR="${TEST_TMP}/project"
mkdir -p "${PROJECT_DIR}"
ENV_FILE="${PROJECT_DIR}/.env"

# Values with everything single quotes must carry literally.
tricky_mysql='my$ql "pass" #word  x'
tricky_admin='a$b"c #d e\f'
tricky_title='The "Archive" of $HOME # 1 & 2'
secret_key=$(generate_secret_key)

set_common() {
    clean_env
    ENV_MYSQL_PASSWORD="${tricky_mysql}"
    ENV_SECRET_KEY="${secret_key}"
    ADMIN_EMAIL="admin@example.com"
    ADMIN_PASSWORD="${tricky_admin}"
    SITE_TITLE="${tricky_title}"
    DEPLOYED_REF="v2.9.0"
    DOMAIN_NAME=""
    HTTP_PORT=80
    ENABLE_HTTPS=false
}

check_common_lines() {
    local mode="$1" env
    env=$(cat "${ENV_FILE}")
    assert_line "# Template ref: v2.9.0" "${env}" "${mode}: template ref comment"
    assert_line "MYSQL_PASSWORD='${tricky_mysql}'" "${env}" "${mode}: MYSQL_PASSWORD line"
    assert_line "OMEKA_SECRET_KEY='${secret_key}'" "${env}" "${mode}: OMEKA_SECRET_KEY line"
    assert_line "${ADMIN_BLOCK_START}" "${env}" "${mode}: admin block start marker"
    assert_line "OMEKA_ADMIN_EMAIL='${ADMIN_EMAIL}'" "${env}" "${mode}: OMEKA_ADMIN_EMAIL line"
    assert_line "OMEKA_ADMIN_USERNAME='admin'" "${env}" "${mode}: OMEKA_ADMIN_USERNAME line"
    assert_line "OMEKA_ADMIN_PASSWORD='${tricky_admin}'" "${env}" "${mode}: OMEKA_ADMIN_PASSWORD line"
    assert_line "${ADMIN_BLOCK_END}" "${env}" "${mode}: admin block end marker"
    assert_line "OMEKA_TITLE='${tricky_title}'" "${env}" "${mode}: OMEKA_TITLE line"

    # Round trip: what was written is what env_value (and Compose) reads.
    assert_eq "${tricky_mysql}" "$(env_value MYSQL_PASSWORD)" "${mode}: MYSQL_PASSWORD round-trips"
    assert_eq "${secret_key}" "$(env_value OMEKA_SECRET_KEY)" "${mode}: OMEKA_SECRET_KEY round-trips"
    assert_eq "${ADMIN_EMAIL}" "$(env_value OMEKA_ADMIN_EMAIL)" "${mode}: OMEKA_ADMIN_EMAIL round-trips"
    assert_eq "${tricky_admin}" "$(env_value OMEKA_ADMIN_PASSWORD)" "${mode}: OMEKA_ADMIN_PASSWORD round-trips"
    assert_eq "${tricky_title}" "$(env_value OMEKA_TITLE)" "${mode}: OMEKA_TITLE round-trips"
    assert_eq "" "$(env_value NO_SUCH_KEY)" "${mode}: env_value prints nothing for a missing key"

    # Every assignment is KEY=value with no stray characters before the key.
    assert_no_line_matching '^[^#A-Z]' "${env}" "${mode}: only comments, blank lines and assignments"

    if [[ "$(uname -s)" == Linux ]]; then
        assert_eq 600 "$(stat -c %a "${ENV_FILE}")" "${mode}: .env has mode 600"
    else
        skip "${mode}: .env mode 600 not checked ($(uname -s) cannot honour POSIX file modes)"
    fi
    local leftovers
    leftovers=$(find "${PROJECT_DIR}" -name '.env.tmp.*')
    assert_eq "" "${leftovers}" "${mode}: no temporary file left behind"
}

# ── HTTP mode ────────────────────────────────────────────────────────────────

set_common
HTTP_PORT=8080
CADDY_TLS=internal   # must not leak into an HTTP .env
ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
write_env_file
check_common_lines HTTP
env=$(cat "${ENV_FILE}")
assert_line "NGINX_BIND=0.0.0.0" "${env}" "HTTP: NGINX_BIND line"
assert_line "NGINX_PORT=8080" "${env}" "HTTP: NGINX_PORT line"
assert_line "NGINX_TRUSTED_PROXY_CIDR=192.0.2.1/32" "${env}" "HTTP: NGINX_TRUSTED_PROXY_CIDR line"
assert_no_line_matching '^COMPOSE_FILE=' "${env}" "HTTP: no COMPOSE_FILE"
assert_no_line_matching '^SERVER_NAME=' "${env}" "HTTP: no SERVER_NAME"
assert_no_line_matching '^ACME_' "${env}" "HTTP: no ACME_* settings"
assert_no_line_matching '^CADDY_TLS=' "${env}" "HTTP: no CADDY_TLS"
assert_eq 1 "$(grep -c '^NGINX_PORT=' <<< "${env}")" "HTTP: NGINX_PORT written once"

# ── HTTPS mode, placeholder admin address ────────────────────────────────────

set_common
ENABLE_HTTPS=true
DOMAIN_NAME=omeka.example.edu
write_env_file
check_common_lines HTTPS
env=$(cat "${ENV_FILE}")
assert_line "COMPOSE_FILE=docker-compose.yml:compose.tls.yml" "${env}" "HTTPS: COMPOSE_FILE line"
assert_line "SERVER_NAME=omeka.example.edu" "${env}" "HTTPS: SERVER_NAME line"
assert_no_line_matching '^NGINX_' "${env}" "HTTPS: no NGINX_* settings"
assert_no_line_matching '^ACME_EMAIL=' "${env}" "HTTPS: no ACME_EMAIL for an example.com address"
assert_no_line_matching '^ACME_CA=' "${env}" "HTTPS: no ACME_CA unless set"
assert_no_line_matching '^CADDY_TLS=' "${env}" "HTTPS: no CADDY_TLS unless set"

# ── HTTPS mode, real address, ACME_CA and CADDY_TLS ──────────────────────────

set_common
ENABLE_HTTPS=true
DOMAIN_NAME=omeka.example.edu
ADMIN_EMAIL=webmaster@omeka.university.edu
ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
CADDY_TLS=internal
write_env_file
check_common_lines "HTTPS+ACME"
env=$(cat "${ENV_FILE}")
assert_line "ACME_EMAIL='webmaster@omeka.university.edu'" "${env}" "HTTPS: ACME_EMAIL for a real address"
assert_line "ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory" "${env}" "HTTPS: ACME_CA line"
assert_line "CADDY_TLS=internal" "${env}" "HTTPS: CADDY_TLS line"
assert_no_line_matching '^NGINX_' "${env}" "HTTPS+ACME: no NGINX_* settings"
assert_eq "webmaster@omeka.university.edu" "$(env_value ACME_EMAIL)" "HTTPS: ACME_EMAIL round-trips"
assert_eq "internal" "$(env_value CADDY_TLS)" "HTTPS: CADDY_TLS round-trips"

for placeholder in admin@example.com ops@EXAMPLE.ORG x@example.net; do
    set_common
    ENABLE_HTTPS=true
    DOMAIN_NAME=omeka.example.edu
    ADMIN_EMAIL="${placeholder}"
    assert_no_line_matching '^ACME_EMAIL=' "$(render_env)" "HTTPS: no ACME_EMAIL for ${placeholder}"
done

# ── env_value parsing ────────────────────────────────────────────────────────

cat > "${ENV_FILE}" << 'EOF'
# A comment
PLAIN=value
SPACED=value with trailing comment # here
SINGLE='single # not a comment'
DOUBLE="double # not a comment"
INDENTED=   indented
  LEADING=leading spaces before the key
EMPTY=
TWICE=first
TWICE=second
NOT_A_PREFIX_MATCH=wrong
EOF
assert_eq "value" "$(env_value PLAIN)" "env_value: plain value"
assert_eq "value with trailing comment" "$(env_value SPACED)" "env_value: strips an unquoted ' # comment'"
assert_eq "single # not a comment" "$(env_value SINGLE)" "env_value: single-quoted value kept whole"
assert_eq "double # not a comment" "$(env_value DOUBLE)" "env_value: double-quoted value kept whole"
assert_eq "leading spaces before the key" "$(env_value LEADING)" "env_value: key with leading spaces"
assert_eq "" "$(env_value EMPTY)" "env_value: empty value"
assert_eq "second" "$(env_value TWICE)" "env_value: last assignment wins"
assert_eq "" "$(env_value PREFIX_MATCH)" "env_value: no match on a key suffix"

# ── Unsafe values are refused ────────────────────────────────────────────────

assert_false "env_quote_ok rejects a single quote" env_quote_ok "it's"
assert_false "env_quote_ok rejects a line break" env_quote_ok $'a\nb'
assert_false "env_quote_ok rejects a carriage return" env_quote_ok $'a\rb'
assert_false "env_quote_ok rejects a trailing backslash" env_quote_ok 'abc\'
assert_true "env_quote_ok accepts \$ \" # and spaces" env_quote_ok "${tricky_mysql}"
assert_true "env_quote_ok accepts an inner backslash" env_quote_ok 'a\b'

set_common
rm -f "${ENV_FILE}"
ADMIN_PASSWORD="it's"
( write_env_file ) 2>/dev/null
assert_eq 1 "$?" "write_env_file exits 1 on a password with a single quote"
assert_false "write_env_file wrote no .env for an unsafe value" test -e "${ENV_FILE}"

assert_eq "Tom’s Archive" "$(sanitize_title "Tom's Archive" 2>/dev/null)" "sanitize_title: apostrophe becomes ’"
assert_eq "Line one line two" "$(sanitize_title $'Line one\nline two' 2>/dev/null)" "sanitize_title: line break becomes a space"
assert_eq "Archive" "$(sanitize_title 'Archive\\ ' 2>/dev/null)" "sanitize_title: trailing backslashes and spaces go"
assert_eq "Omeka S" "$(sanitize_title '   ' 2>/dev/null)" "sanitize_title: blank falls back to Omeka S"
assert_eq "${tricky_title}" "$(sanitize_title "${tricky_title}" 2>/dev/null)" "sanitize_title: leaves a safe title alone"

# ── remove_admin_credentials ─────────────────────────────────────────────────

for mode in HTTP HTTPS; do
    set_common
    if [[ "${mode}" == HTTPS ]]; then
        ENABLE_HTTPS=true
        DOMAIN_NAME=omeka.example.edu
        CADDY_TLS=internal
    fi
    write_env_file
    before=$(cat "${ENV_FILE}")
    # Expected: the marked block deleted; the blank line that followed it goes
    # too, so no double blank line is left (the template has none either).
    expected=$(sed "/^${ADMIN_BLOCK_START}\$/,/^${ADMIN_BLOCK_END}\$/d" "${ENV_FILE}" | cat -s)
    ADMIN_CREDS_REMOVED=false
    remove_admin_credentials
    after=$(cat "${ENV_FILE}")
    assert_eq "${expected}" "${after}" "${mode}: remove_admin_credentials drops exactly the block"
    assert_eq "$(cat -s <<< "${after}")" "${after}" "${mode}: no double blank line left"
    assert_no_line_matching '^OMEKA_ADMIN_' "${after}" "${mode}: no OMEKA_ADMIN_* left"
    assert_no_line_matching '^# >>>\|^# <<<' "${after}" "${mode}: no block markers left"
    assert_eq true "${ADMIN_CREDS_REMOVED}" "${mode}: ADMIN_CREDS_REMOVED set"
    # Everything outside the block is untouched, in order.
    outside_before=$(grep -v -e '^OMEKA_ADMIN_' -e '^# >>>' -e '^# <<<' <<< "${before}" | grep -v '^#' | grep -v '^$')
    outside_after=$(grep -v '^#' <<< "${after}" | grep -v '^$')
    assert_eq "${outside_before}" "${outside_after}" "${mode}: every other setting kept, in order"
    assert_eq "${tricky_mysql}" "$(env_value MYSQL_PASSWORD)" "${mode}: MYSQL_PASSWORD still readable"
    assert_eq "${secret_key}" "$(env_value OMEKA_SECRET_KEY)" "${mode}: OMEKA_SECRET_KEY still readable"
    if [[ "$(uname -s)" == Linux ]]; then
        assert_eq 600 "$(stat -c %a "${ENV_FILE}")" "${mode}: .env still mode 600 after removal"
    else
        skip "${mode}: mode 600 after removal not checked ($(uname -s) cannot honour POSIX file modes)"
    fi

    # Idempotent: a second pass changes nothing.
    remove_admin_credentials
    assert_eq "${after}" "$(cat "${ENV_FILE}")" "${mode}: a second removal changes nothing"
done

# Stray OMEKA_ADMIN_* lines outside the markers (edited by hand) go as well.
set_common
write_env_file
printf 'OMEKA_ADMIN_PASSWORD=stray\nKEEP_ME=1\n' >> "${ENV_FILE}"
remove_admin_credentials
after=$(cat "${ENV_FILE}")
assert_no_line_matching '^OMEKA_ADMIN_' "${after}" "stray OMEKA_ADMIN_* outside the block removed"
assert_line "KEEP_ME=1" "${after}" "line after a stray OMEKA_ADMIN_* kept"

finish
