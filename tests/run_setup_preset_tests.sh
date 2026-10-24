#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-setup-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/settings/ApolloSetupPreset.m" \
    "$test_repo_root/tests/setup_preset_tests.m" -o "$test_build_dir/setup-tests"
"$test_build_dir/setup-tests"
