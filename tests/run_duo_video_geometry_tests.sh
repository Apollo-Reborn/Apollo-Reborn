#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-video.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    -I "$test_repo_root/src" "$test_repo_root/tests/duo_video_geometry_tests.m" \
    -o "$test_build_dir/duo_video_geometry_tests"
"$test_build_dir/duo_video_geometry_tests"
