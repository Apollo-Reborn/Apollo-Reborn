#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-web-json-preference.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloWebJSONPreference.m" \
    "$test_repo_root/tests/web_json_preference_tests.m" \
    -o "$test_build_dir/web-json-preference-tests"
"$test_build_dir/web-json-preference-tests"
