#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gallery-slideshow-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/tests/gallery_slideshow_tests.m" \
    "$test_repo_root/src/ApolloGallerySlideshow.m" \
    -o "$test_build_dir/gallery_slideshow_tests"
"$test_build_dir/gallery_slideshow_tests"
