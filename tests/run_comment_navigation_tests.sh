#!/bin/sh

set -eu

# Compile the actual Foundation-only parsing/selection rules, without UIKit or
# private Apollo classes, so epoch and navigation boundary bugs stay testable.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-comment-navigation-tests.XXXXXX")
test_binary="$test_build_dir/comment_navigation_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloCommentNavigationModel.m" \
    "$test_repo_root/tests/comment_navigation_tests.m" \
    -o "$test_binary"

"$test_binary"
