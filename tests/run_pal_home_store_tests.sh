#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-pal-home-tests.XXXXXX")
trap 'rm -f -- "$test_build_dir/pal_home_tests"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics \
    -I "$test_repo_root/src" "$test_repo_root/src/palhome/ApolloPalHomeStore.m" "$test_repo_root/src/palhome/ApolloPalHomeShelter.m" "$test_repo_root/src/palhome/ApolloPalSpecies.m" "$test_repo_root/src/palhome/ApolloPixelPalCoats.m" \
    "$test_repo_root/tests/pal_home_store_tests.m" -o "$test_build_dir/pal_home_tests"
"$test_build_dir/pal_home_tests"
