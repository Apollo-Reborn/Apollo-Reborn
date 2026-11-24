#!/bin/sh

set -eu

# Build the GraphQL route's Foundation-only half (the request plan and the
# conversion to legacy JSON) as a macOS executable and run it.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gql-legacy-tests.XXXXXX")
test_binary="$test_build_dir/gql_legacy_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation \
    -I "$test_repo_root/src/graphql" \
    "$test_repo_root/src/graphql/ApolloGQLRichText.m" \
    "$test_repo_root/src/graphql/ApolloGQLLegacy.m" \
    "$test_repo_root/src/graphql/ApolloGQLPlan.m" \
    "$test_repo_root/tests/gql_legacy_tests.m" \
    -o "$test_binary"

"$test_binary" "$test_repo_root"
