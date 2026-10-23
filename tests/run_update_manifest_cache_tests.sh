#!/bin/sh

set -eu

# Compile the production cache and parser; no network or UIKit is involved.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-update-manifest-cache-tests.XXXXXX")
test_binary="$test_build_dir/update_manifest_cache_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloUpdateManifest.m" \
    "$test_repo_root/src/ApolloUpdateManifestCache.m" \
    "$test_repo_root/tests/update_manifest_cache_tests.m" \
    -o "$test_binary"

"$test_binary" "$test_build_dir"
