#!/bin/sh

set -eu

# Build the real RedGIFs failure classifier (Foundation-only) as a macOS
# executable and check it against the API answers and AVFoundation errors
# recorded for issue #1340.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-redgifs-failure-reason-tests.XXXXXX")
test_binary="$test_build_dir/redgifs_failure_reason_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloRedgifsFailureReason.m" \
    "$test_repo_root/tests/redgifs_failure_reason_tests.m" \
    -o "$test_binary"

"$test_binary"
