#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-reddit-gallery-repair-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloMediaMetadata.m" \
    "$test_repo_root/tests/reddit_gallery_repair_tests.m" \
    -o "$test_build_dir/reddit_gallery_repair_tests"
"$test_build_dir/reddit_gallery_repair_tests"
