#!/bin/sh

set -eu

# Build the real route catalog as a macOS Foundation executable and run it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-web-json-routes-tests.XXXXXX")
test_binary="$test_build_dir/web_json_routes_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloWebJSONRoutes.m" \
    "$test_repo_root/tests/web_json_routes_tests.m" \
    -o "$test_binary"

"$test_binary" "$test_repo_root"
