#!/bin/sh

set -eu

# Build the real listing-path classifier as a macOS Foundation executable and run it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-show-hidden-posts-tests.XXXXXX")
test_binary="$test_build_dir/show_hidden_posts_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloShowHiddenPosts.m" \
    "$test_repo_root/tests/show_hidden_posts_tests.m" \
    -o "$test_binary"

"$test_binary"
