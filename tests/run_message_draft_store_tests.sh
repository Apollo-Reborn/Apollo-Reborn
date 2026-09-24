#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-message-draft-tests.XXXXXX")
test_binary="$test_build_dir/message_draft_store_tests"
linkage_binary="$test_build_dir/message_draft_linkage_tests"
store_object="$test_build_dir/ApolloMessageDraftStore.o"
trap 'rm -f -- "$test_binary" "$linkage_binary" "$store_object"; rmdir -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -DAPOLLO_MESSAGE_DRAFTS_TESTING \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloMessageDraftStore.m" \
    "$test_repo_root/tests/message_draft_store_tests.m" \
    -o "$test_binary"
"$test_binary"

xcrun --sdk macosx clang -c -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -DAPOLLO_MESSAGE_DRAFTS_TESTING -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloMessageDraftStore.m" -o "$store_object"
xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/tests/message_draft_linkage_tests.mm" "$store_object" \
    -o "$linkage_binary"
"$linkage_binary"

if grep -Fq 'ApolloMessageDraftStoreBarrier' "$test_repo_root/src/settings/CustomAPIViewController.m" || grep -Fq 'ApolloMessageDraftStoreBarrier' "$test_repo_root/src/ApolloAccountSwitcherViewController.xm"; then
    printf '%s\n' 'user-triggered draft cleanup must not use a synchronous barrier' >&2
    exit 1
fi
grep -Fq 'ApolloMessageDraftStoreMarkAllPendingDelete' "$test_repo_root/src/settings/CustomAPIViewController.m"
grep -Fq 'ApolloMessageDraftStoreMarkAccountPendingDelete' "$test_repo_root/src/ApolloAccountSwitcherViewController.xm"
grep -Fq 'Either' "$test_repo_root/src/ApolloMessageDraftStore.m"
