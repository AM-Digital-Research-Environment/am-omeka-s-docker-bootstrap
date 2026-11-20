#!/usr/bin/env bash
# Tiny assertion helpers for the setup.sh unit tests. Sourced by every
# tests/test_*.sh file; no framework to install.
#
# Each test file sources this, calls load_setup, runs its checks and ends with
# `finish`, which prints a summary line and appends "passed failed skipped" to
# $TEST_RESULTS (set by run.sh) so run.sh can add up the totals.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
SETUP_SH="${REPO_ROOT}/setup.sh"

_passed=0
_failed=0
_skipped=0

# Scratch directory for this test file, removed on exit.
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup-sh-tests.XXXXXX")"
trap 'rm -rf "${TEST_TMP}"' EXIT

pass() { _passed=$((_passed + 1)); }

fail() {
    _failed=$((_failed + 1))
    printf '  FAIL: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do
        printf '        %s\n' "${line}" >&2
    done
}

skip() {
    _skipped=$((_skipped + 1))
    printf '  SKIP: %s\n' "$1" >&2
}

# assert_eq <expected> <actual> <description>
assert_eq() {
    if [[ "$1" == "$2" ]]; then pass; else fail "$3" "expected: [$1]" "actual:   [$2]"; fi
}

# assert_match <extended regex> <actual> <description>
assert_match() {
    if [[ "$2" =~ $1 ]]; then pass; else fail "$3" "pattern: $1" "actual:  [$2]"; fi
}

# assert_line <exact line> <text> <description>: <text> has that whole line.
assert_line() {
    if grep -qxF -- "$1" <<< "$2"; then pass; else fail "$3" "missing line: [$1]"; fi
}

# assert_no_line_matching <basic regex> <text> <description>
assert_no_line_matching() {
    local hits
    hits=$(grep -e "$1" <<< "$2" || true)
    if [[ -z "${hits}" ]]; then pass; else fail "$3" "unexpected: [${hits}]"; fi
}

# assert_contains <needle> <haystack> <description>
assert_contains() {
    if [[ "$2" == *"$1"* ]]; then pass; else fail "$3" "missing: [$1]"; fi
}

# assert_true <description> <command...>: the command succeeds.
assert_true() {
    local desc="$1"
    shift
    if "$@"; then pass; else fail "${desc}" "command failed: $*"; fi
}

# assert_false <description> <command...>: the command fails.
assert_false() {
    local desc="$1"
    shift
    if "$@"; then fail "${desc}" "command succeeded: $*"; else pass; fi
}

# Clears every environment variable setup.sh reads at load time, so the
# developer's or CI's environment cannot leak into the tests.
clean_env() {
    unset NONINTERACTIVE OMEKA_INSTALL_DIR OMEKA_DOMAIN OMEKA_HTTP_PORT \
        BOOTSTRAP_EDGE BOOTSTRAP_REF MYSQL_PASSWORD OMEKA_ADMIN_EMAIL \
        OMEKA_ADMIN_PASSWORD OMEKA_TITLE ACME_CA CADDY_TLS
}

# Defines setup.sh's functions and globals without running main. setup.sh
# turns on `set -euo pipefail`; -e is turned off again so one failed check
# does not end the file (tests that need -e set it in a subshell).
load_setup() {
    clean_env
    # shellcheck source=setup.sh
    SETUP_SH_NO_MAIN=1 . "${SETUP_SH}"
    set +e
}

finish() {
    local name
    name=$(basename "$0")
    printf '%s: %d passed, %d failed, %d skipped\n' "${name}" "${_passed}" "${_failed}" "${_skipped}"
    if [[ -n "${TEST_RESULTS:-}" ]]; then
        printf '%d %d %d\n' "${_passed}" "${_failed}" "${_skipped}" >> "${TEST_RESULTS}"
    fi
    (( _failed == 0 ))
}
