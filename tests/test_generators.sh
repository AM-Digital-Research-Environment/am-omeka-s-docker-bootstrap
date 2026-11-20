#!/usr/bin/env bash
# generate_password and generate_secret_key: length, character set, no
# repeats, and no SIGPIPE (exit 141) under `set -euo pipefail`.

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
load_setup

# Fork-heavy on Windows; override with TEST_ROUNDS for a longer soak.
rounds="${TEST_ROUNDS:-100}"

# ── generate_password ────────────────────────────────────────────────────────

bad="" seen="" dup=false
for (( i = 0; i < rounds; i++ )); do
    pw=$(generate_password)
    [[ "${pw}" =~ ^[A-Za-z0-9]{24}$ ]] || bad+="[${pw}] "
    if grep -qxF -- "${pw}" <<< "${seen}"; then dup=true; fi
    seen+="${pw}"$'\n'
done
assert_eq "" "${bad}" "generate_password: ${rounds} rounds, all 24 alphanumeric characters"
assert_eq false "${dup}" "generate_password: no repeats in ${rounds} rounds"

# ── generate_secret_key ──────────────────────────────────────────────────────

bad="" seen="" dup=false
for (( i = 0; i < rounds; i++ )); do
    key=$(generate_secret_key)
    # 32 bytes base64-encoded: 43 characters and one '=' of padding.
    [[ "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || bad+="[${key}] "
    if grep -qxF -- "${key}" <<< "${seen}"; then dup=true; fi
    seen+="${key}"$'\n'
done
assert_eq "" "${bad}" "generate_secret_key: ${rounds} rounds, all 44-character base64"
assert_eq false "${dup}" "generate_secret_key: no repeats in ${rounds} rounds"

# Exactly one line, no trailing newline inside the value.
lines=$(generate_secret_key | wc -l | tr -d ' ')
assert_eq 0 "${lines}" "generate_secret_key prints no newline"
assert_true "generated values pass env_quote_ok" env_quote_ok "$(generate_secret_key)"

# ── Strict mode, as setup.sh runs them ───────────────────────────────────────
# Reading an endless /dev/urandom into `head` used to end the script with
# SIGPIPE (exit 141) under pipefail. Run both generators in the script's own
# shell options and make sure the loop gets to the end.

( set -euo pipefail
  for (( i = 0; i < rounds; i++ )); do
      p=$(generate_password)
      k=$(generate_secret_key)
      (( ${#p} == 24 && ${#k} == 44 ))
  done
)
assert_eq 0 "$?" "both generators survive ${rounds} rounds under set -euo pipefail"

finish
