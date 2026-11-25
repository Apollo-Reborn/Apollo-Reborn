#!/bin/sh

set -eu

# Build the API-Key-Free Add / Remove Friend form builder (issue #1787) as a
# macOS Foundation executable and run it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-web-json-friends-tests.XXXXXX")
test_binary="$test_build_dir/web_json_friends_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloWebJSONFriends.m" \
    "$test_repo_root/tests/web_json_friends_tests.m" \
    -o "$test_binary"

"$test_binary"
