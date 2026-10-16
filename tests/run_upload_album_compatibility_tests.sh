#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-upload-album-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloUploadAlbumCompatibility.m" \
    "$test_repo_root/tests/upload_album_compatibility_tests.m" \
    -o "$test_build_dir/upload_album_tests"
"$test_build_dir/upload_album_tests"
