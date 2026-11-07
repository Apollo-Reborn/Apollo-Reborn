#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/duo-divider-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$repo/src" "$repo/tests/duo_divider_geometry_tests.c" -o "$build/tests"
"$build/tests"
