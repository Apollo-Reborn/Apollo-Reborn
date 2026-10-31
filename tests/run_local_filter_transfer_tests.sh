#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-local-filter-transfer.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

clang -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation \
    -I"$repo_root/src" \
    "$repo_root/tests/local_filter_transfer_tests.m" \
    "$repo_root/src/ApolloLocalFilterTransfer.m" \
    -o "$build_dir/local_filter_transfer_tests"

"$build_dir/local_filter_transfer_tests"
