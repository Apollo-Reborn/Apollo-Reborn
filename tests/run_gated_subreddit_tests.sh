#!/bin/sh

set -eu

# Build the Foundation-only half of the gated-subreddit warning (reading
# Reddit's answer, building the request its warning page's "continue" sends)
# as a macOS executable and run it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gated-subreddit-tests.XXXXXX")
test_binary="$test_build_dir/gated_subreddit_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloGatedSubreddit.m" \
    "$test_repo_root/tests/gated_subreddit_tests.m" \
    -o "$test_binary"

"$test_binary"
