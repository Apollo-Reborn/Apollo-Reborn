#!/bin/sh
set -eu

unset CDPATH
test_repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-random-subreddit.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -I "$test_repo_root/src" \
    -framework Foundation \
    "$test_repo_root/src/ApolloRandomSubreddit.m" \
    "$test_repo_root/src/ApolloSubredditName.m" \
    "$test_repo_root/tests/random_subreddit_tests.m" \
    -o "$test_build_dir/random_subreddit_tests"
"$test_build_dir/random_subreddit_tests"
