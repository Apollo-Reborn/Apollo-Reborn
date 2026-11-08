#!/bin/sh
set -eu
drag_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
drag_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-drag.XXXXXX")
trap 'rm -rf -- "$drag_build"' EXIT HUP INT TERM
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I"$drag_root/src" "$drag_root/tests/duo_pane_drag_tests.c" -o "$drag_build/duo_pane_drag_tests"
"$drag_build/duo_pane_drag_tests"
