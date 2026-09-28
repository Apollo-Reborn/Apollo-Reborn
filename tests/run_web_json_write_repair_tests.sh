#!/bin/sh

set -eu

# Build the real write-response repair as a macOS Foundation executable. Each named
# scenario runs in its own process to isolate the module's pending-write statics.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-web-json-write-repair-tests.XXXXXX")
test_binary="$test_build_dir/web_json_write_repair_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -DAPOLLO_WEBJSON_WRITE_REPAIR_TESTING \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloWebJSONWriteRepair.m" \
    "$test_repo_root/tests/web_json_write_repair_tests.m" \
    -o "$test_binary"

test_failures=0
for test_scenario in \
    legacy-edit-captured \
    modern-degraded-edit-captured \
    modern-edit-keeps-response-score \
    legacy-edit-uncaptured \
    legacy-create \
    modern-healthy-noop \
    error-envelope-untouched \
    data-in-data-out \
    selftext-edit-prefetched \
    selftext-edit-prefetch-pending \
    selftext-capture-ignores-comments; do
    if ! "$test_binary" "$test_scenario"; then
        test_failures=$((test_failures + 1))
    fi
done

if [ "$test_failures" -ne 0 ]; then
    printf 'web_json_write_repair_tests: %s scenario(s) failed\n' "$test_failures" >&2
    exit 1
fi
printf 'web_json_write_repair_tests: all 11 scenarios passed\n'
