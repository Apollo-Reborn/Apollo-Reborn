#!/bin/sh

set -eu

# Build the real Kagi results-page parser (Foundation-only) as a macOS
# executable and run it against the saved pages in tests/fixtures/kagi.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-kagi-search-parsing-tests.XXXXXX")
test_binary="$test_build_dir/kagi_search_parsing_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloKagiSearchParsing.m" \
    "$test_repo_root/tests/kagi_search_parsing_tests.m" \
    -o "$test_binary"

"$test_binary" "$test_repo_root/tests/fixtures/kagi"
