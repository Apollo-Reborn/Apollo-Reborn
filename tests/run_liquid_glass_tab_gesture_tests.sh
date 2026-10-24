#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-lg-tab-gesture-tests.XXXXXX")
test_binary="$build_dir/liquid_glass_tab_gesture_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics -I "$repo_root/src" \
    "$repo_root/tests/liquid_glass_tab_gesture_tests.m" \
    "$repo_root/src/ApolloLiquidGlassTabGesture.m" \
    -o "$test_binary"

"$test_binary" "$@"
