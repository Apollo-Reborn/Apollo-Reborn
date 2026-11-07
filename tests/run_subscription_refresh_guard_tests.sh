#!/bin/sh

set -eu

# Build the failed-subscription-refresh guard (Foundation-only) as a macOS
# executable and run its checks (#1635, #1409).
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-subscription-refresh-guard-tests.XXXXXX")
test_binary="$test_build_dir/subscription_refresh_guard_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloSubscriptionRefreshGuard.m" \
    "$test_repo_root/tests/subscription_refresh_guard_tests.m" \
    -o "$test_binary"

"$test_binary"
