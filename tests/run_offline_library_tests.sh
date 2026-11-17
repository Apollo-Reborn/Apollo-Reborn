#!/bin/sh

set -eu

# Build the Offline Mode library + downloader as a macOS Foundation executable and run it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-offline-library-tests.XXXXXX")
test_binary="$test_build_dir/offline_library_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloOfflineLibrary.m" \
    "$test_repo_root/src/ApolloOfflineDownloader.m" \
    "$test_repo_root/tests/offline_library_tests.m" \
    -o "$test_binary"

"$test_binary"
