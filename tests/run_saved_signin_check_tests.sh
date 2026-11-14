#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-saved-signin.XXXXXX")
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
    "$test_root/tests/saved_signin_check_tests.m" \
    "$test_root/src/ApolloSavedSignInCheck.m" \
    -framework Foundation \
    -o "$build_dir/saved-signin-check-tests"

"$build_dir/saved-signin-check-tests"
