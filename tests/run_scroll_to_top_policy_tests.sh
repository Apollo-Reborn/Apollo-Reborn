#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-scroll-top.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$root/tests/scroll_to_top_policy_tests.m" -o "$build/scroll_to_top_policy_tests"
"$build/scroll_to_top_policy_tests"
