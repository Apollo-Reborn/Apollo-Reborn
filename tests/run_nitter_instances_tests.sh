#!/bin/sh

set -eu

# Build the real Nitter rewrite/normalize/parse module as a macOS Foundation
# executable and run its checks (no network; the tracker fetch isn't exercised).
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-nitter-instances-tests.XXXXXX")
test_binary="$test_build_dir/nitter_instances_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloNitterInstances.m" \
    "$test_repo_root/tests/nitter_instances_tests.m" \
    -o "$test_binary"

"$test_binary"
