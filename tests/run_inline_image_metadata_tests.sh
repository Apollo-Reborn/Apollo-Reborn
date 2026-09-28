#!/bin/sh
set -eu

CDPATH=''
test_repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-inline-image-metadata.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloInlineImageMetadata.m" \
    "$test_repo_root/tests/inline_image_metadata_tests.m" \
    -o "$test_build_dir/tests"

"$test_build_dir/tests"
