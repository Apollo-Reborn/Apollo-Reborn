#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-meta-feed.XXXXXX")
trap 'rm -rf -- "$test_build"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -Wno-unused-parameter -fsanitize=address,undefined -framework Foundation \
    -I "$test_root/src" "$test_root/tests/meta_feed_recovery_tests.m" \
    -o "$test_build/tests"
"$test_build/tests"
