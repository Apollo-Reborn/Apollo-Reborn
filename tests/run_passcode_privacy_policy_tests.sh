#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-passcode-privacy-tests.XXXXXX")
test_binary="$test_build_dir/passcode_privacy_policy_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloPasscodePrivacyPolicy.m" \
    "$test_repo_root/tests/passcode_privacy_policy_tests.m" \
    -o "$test_binary"
"$test_binary"
