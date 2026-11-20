#!/usr/bin/env bash
# parse_args: every flag, the --flag=value forms, unknown options and missing
# values; --help, run as a file and through a pipe.

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
load_setup

reset_args() {
    clean_env
    NONINTERACTIVE=false
    EDGE=false
    BOOTSTRAP_REF=""
    DOMAIN_NAME=""
}

# ── Flags without a value ────────────────────────────────────────────────────

for flag in -y --yes --non-interactive; do
    reset_args
    parse_args "${flag}"
    assert_eq true "${NONINTERACTIVE}" "${flag} sets NONINTERACTIVE"
done

reset_args
parse_args --edge
assert_eq true "${EDGE}" "--edge sets EDGE"

reset_args
parse_args
assert_eq false "${NONINTERACTIVE}" "no arguments leaves NONINTERACTIVE alone"
assert_eq false "${EDGE}" "no arguments leaves EDGE alone"

# ── Flags with a value, both spellings ───────────────────────────────────────

for form in split equals; do
    reset_args
    if [[ "${form}" == split ]]; then
        parse_args --ref v2.9.0 --dir /srv/omeka --domain omeka.example.edu --port 8080
    else
        parse_args --ref=v2.9.0 --dir=/srv/omeka --domain=omeka.example.edu --port=8080
    fi
    assert_eq v2.9.0 "${BOOTSTRAP_REF}" "--ref (${form}) sets BOOTSTRAP_REF"
    assert_eq /srv/omeka "${OMEKA_INSTALL_DIR:-}" "--dir (${form}) sets OMEKA_INSTALL_DIR"
    assert_eq omeka.example.edu "${OMEKA_DOMAIN:-}" "--domain (${form}) sets OMEKA_DOMAIN"
    assert_eq omeka.example.edu "${DOMAIN_NAME}" "--domain (${form}) sets DOMAIN_NAME"
    assert_eq 8080 "${OMEKA_HTTP_PORT:-}" "--port (${form}) sets OMEKA_HTTP_PORT"
done

# A value may itself contain '=' (only the first one splits).
reset_args
parse_args --ref=feature=x
assert_eq feature=x "${BOOTSTRAP_REF}" "--ref=value keeps a later '=' in the value"

# Flags combine, and the last occurrence wins.
reset_args
parse_args -y --edge --port 81 --port=82
assert_eq true "${NONINTERACTIVE}" "combined: -y"
assert_eq true "${EDGE}" "combined: --edge"
assert_eq 82 "${OMEKA_HTTP_PORT:-}" "combined: the last --port wins"

# ── Errors ───────────────────────────────────────────────────────────────────

for bad in --bogus -x --domainname=x extra; do
    reset_args
    err=$( (parse_args "${bad}") 2>&1 >/dev/null )
    rc=$?
    assert_eq 1 "${rc}" "unknown option '${bad}' exits 1"
    assert_contains "Unknown option: ${bad}" "${err}" "unknown option '${bad}' is named in the error"
done

for flag in --ref --dir --domain --port; do
    reset_args
    err=$( (parse_args "${flag}") 2>&1 >/dev/null )
    rc=$?
    assert_true "${flag} without a value fails (got ${rc})" test "${rc}" -ne 0
    assert_contains "${flag} needs a value" "${err}" "${flag} without a value says so"
    # An empty value counts as missing too.
    err=$( (parse_args "${flag}" "") 2>&1 >/dev/null )
    rc=$?
    assert_true "${flag} with an empty value fails (got ${rc})" test "${rc}" -ne 0
done

# ── --help ───────────────────────────────────────────────────────────────────

for flag in -h --help; do
    out=$( (parse_args "${flag}") 2>/dev/null )
    rc=$?
    assert_eq 0 "${rc}" "parse_args ${flag} exits 0"
    assert_contains "Usage:" "${out}" "parse_args ${flag} prints the usage"
done

# Run as a file: help on stdout, nothing on stderr, exit 0, nothing else runs.
clean_env
out=$(bash "${SETUP_SH}" --help 2>"${TEST_TMP}/err")
rc=$?
assert_eq 0 "${rc}" "bash setup.sh --help exits 0"
assert_contains "Usage:" "${out}" "bash setup.sh --help prints Usage:"
assert_contains "--domain <name>" "${out}" "bash setup.sh --help lists --domain"
assert_contains "Exit status:" "${out}" "bash setup.sh --help documents the exit status"
assert_eq "" "$(cat "${TEST_TMP}/err")" "bash setup.sh --help writes nothing to stderr"

# Through a pipe, as in `curl ... | bash -s -- --help`: there is no script file.
out_piped=$(bash -s -- --help < "${SETUP_SH}" 2>"${TEST_TMP}/err")
rc=$?
assert_eq 0 "${rc}" "bash -s -- --help < setup.sh exits 0"
assert_eq "${out}" "${out_piped}" "piped --help prints the same text as the file"
assert_eq "" "$(cat "${TEST_TMP}/err")" "piped --help writes nothing to stderr"

out=$(bash "${SETUP_SH}" --bogus 2>"${TEST_TMP}/err")
rc=$?
assert_eq 1 "${rc}" "bash setup.sh --bogus exits 1"
assert_eq "" "${out}" "bash setup.sh --bogus prints nothing on stdout"
assert_contains "Unknown option: --bogus" "$(cat "${TEST_TMP}/err")" "bash setup.sh --bogus names the option"

# The header comment and usage() must document the same options.
header_opts=$(sed -n '1,/^set -euo pipefail/p' "${SETUP_SH}" | grep -oE -- '--[a-z][a-z-]+' | sort -u)
usage_opts=$(usage | grep -oE -- '--[a-z][a-z-]+' | sort -u)
assert_eq "${header_opts}" "${usage_opts}" "header comment and usage() list the same options"
for opt in --yes --non-interactive --dir --domain --port --edge --ref --help; do
    assert_line "${opt}" "${usage_opts}" "usage() documents ${opt}"
done

finish
