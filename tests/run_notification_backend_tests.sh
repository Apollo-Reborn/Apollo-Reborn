#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-notification-backend-tests.XXXXXX")
test_binary="$test_build_dir/notification_backend_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -O2 \
    -framework Foundation -DAPOLLO_NOTIFICATION_BACKEND_TESTING \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloNotificationBackend.m" \
    "$test_repo_root/tests/notification_backend_tests.m" \
    -o "$test_binary"
"$test_binary"
