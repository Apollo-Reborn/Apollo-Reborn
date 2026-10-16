#!/bin/sh

set -eu

# Build the real export scrubber (Foundation-only) as a macOS executable and
# run its checks, then confirm every export still goes through it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-log-redaction-tests.XXXXXX")
test_binary="$test_build_dir/log_redaction_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -O2 \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloLogRedaction.m" \
    "$test_repo_root/tests/log_redaction_tests.m" \
    -o "$test_binary"

"$test_binary"

# ApolloCollectLogsFiltered is the one exporter (Settings, report form, crash
# review, AI export): it must keep scrubbing and keep dropping info/debug.
common="$test_repo_root/src/ApolloCommon.m"
grep -q 'return ApolloRedactLogExport(output, ownUsernames, NSHomeDirectory());' "$common" \
    || { echo "FAIL: ApolloCollectLogsFiltered no longer scrubs its output" >&2; exit 1; }
grep -q 'if (entry.level < OSLogEntryLogLevelNotice) continue;' "$common" \
    || { echo "FAIL: ApolloCollectLogsFiltered no longer drops info/debug entries" >&2; exit 1; }
echo "log_redaction_tests: exporter wiring present"
