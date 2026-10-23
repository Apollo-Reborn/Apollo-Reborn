#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-deleted-comments-race.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun clang \
    -fobjc-arc \
    -fblocks \
    -DAPOLLO_DELETED_COMMENTS_TESTING=1 \
    -I"$test_root/src" \
    -fsanitize=thread \
    -g \
    -O1 \
    "$test_root/tests/deleted_comments_observed_link_race_tests.m" \
    "$test_root/src/ApolloDeletedCommentsData.m" \
    -framework Foundation \
    -o "$build_dir/deleted-comments-observed-link-race-tests"

"$build_dir/deleted-comments-observed-link-race-tests"
