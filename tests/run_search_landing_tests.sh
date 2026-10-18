#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-search-landing-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloSearchLandingPreferences.m" \
    "$test_repo_root/src/ApolloSearchRecents.m" \
    "$test_repo_root/tests/search_landing_tests.m" \
    -o "$test_build_dir/search_landing_tests"
"$test_build_dir/search_landing_tests"

# Compile the actual Swift readers against concrete class-array fixtures. The
# model harness above cannot exercise Swift storage or returned-object lifetime.
xcrun --sdk macosx swiftc -parse-as-library -O -warnings-as-errors \
    "$test_repo_root/src/ApolloSwiftIvarBridge.swift" \
    "$test_repo_root/tests/search_ivar_bridge_tests.swift" \
    -o "$test_build_dir/search_ivar_bridge_tests"
"$test_build_dir/search_ivar_bridge_tests"
