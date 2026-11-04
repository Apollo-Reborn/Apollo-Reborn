#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-session-state.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun clang \
    -fobjc-arc \
    -fblocks \
    -Wall \
    -Wextra \
    -Werror \
    -fsanitize=address,undefined \
    -g \
    -O1 \
    -I"$test_root/src" \
    "$test_root/tests/session_state_tests.m" \
    "$test_root/src/ApolloSessionState.m" \
    -framework Foundation \
    -o "$build_dir/session-state-tests"

"$build_dir/session-state-tests"
