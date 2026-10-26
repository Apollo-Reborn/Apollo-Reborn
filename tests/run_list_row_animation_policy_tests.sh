#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-list-row-animation.XXXXXX")
trap 'rm -rf "$build"' EXIT INT TERM

xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -I "$test_root/src" \
    "$test_root/tests/list_row_animation_policy_tests.c" \
    -o "$build/list-row-animation-tests"
"$build/list-row-animation-tests"
