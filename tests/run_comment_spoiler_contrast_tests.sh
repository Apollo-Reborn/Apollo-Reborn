#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-spoiler-contrast.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

cc -std=c11 -Wall -Wextra -Werror \
    -I"$repo_root/src" \
    "$repo_root/tests/comment_spoiler_contrast_tests.c" \
    "$repo_root/src/ApolloCommentSpoilerContrast.c" \
    -lm \
    -o "$build_dir/comment_spoiler_contrast_tests"

"$build_dir/comment_spoiler_contrast_tests"
