#!/bin/sh

set -eu

# Build the All+ r/all merge core (Foundation-only) as a macOS executable and
# run it against the shared vectors in tests/fixtures/allplus_conformance.json.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-allplus-merge-tests.XXXXXX")
test_binary="$test_build_dir/allplus_merge_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloAllPlusMerge.m" \
    "$test_repo_root/tests/allplus_merge_tests.m" \
    -o "$test_binary"

"$test_binary" "$test_repo_root/tests/fixtures/allplus_conformance.json"
