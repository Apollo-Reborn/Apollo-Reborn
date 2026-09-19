#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-reserved-regions.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

compiler=clang
if ! command -v clang >/dev/null 2>&1; then
    compiler=cc
fi

"$compiler" -std=c11 -Wall -Wextra -Werror \
    -I "$test_repo_root/src" \
    "$test_repo_root/tests/reserved_region_tests.c" \
    -o "$test_build_dir/reserved_region_tests"
"$test_build_dir/reserved_region_tests"
