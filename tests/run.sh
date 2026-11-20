#!/usr/bin/env bash
# Runs the setup.sh unit tests: every tests/test_*.sh in its own bash process.
# Plain Bash, no framework. Works on Linux and in Git Bash on Windows.
#
#   bash tests/run.sh                 # all files
#   bash tests/run.sh tests/test_env.sh   # selected files
#
# Exit status: 0 when every check passed (skips allowed), 1 otherwise.

set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if (( $# > 0 )); then
    files=("$@")
else
    files=("${tests_dir}"/test_*.sh)
fi

TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/setup-sh-results.XXXXXX")"
export TEST_RESULTS
trap 'rm -f "${TEST_RESULTS}"' EXIT

status=0
for file in "${files[@]}"; do
    if ! bash "${file}"; then
        status=1
    fi
done

passed=0 failed=0 skipped=0 files_reported=0
while read -r p f s; do
    passed=$((passed + p))
    failed=$((failed + f))
    skipped=$((skipped + s))
    files_reported=$((files_reported + 1))
done < "${TEST_RESULTS}"

# A file that died before `finish` reports nothing: count that as a failure.
if (( files_reported != ${#files[@]} )); then
    echo "ERROR: $(( ${#files[@]} - files_reported )) test file(s) ended without a summary." >&2
    status=1
fi

echo "----"
echo "Total: ${passed} passed, ${failed} failed, ${skipped} skipped (${#files[@]} files)"
exit "${status}"
