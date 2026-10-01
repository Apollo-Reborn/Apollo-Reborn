#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-icloud-store-tests.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework Security \
    -I "$repo/src" \
    "$repo/tests/icloud_backup_store_tests.m" \
    "$repo/src/settings/ApolloICloudBackupStore.m" \
    "$repo/src/settings/ApolloICloudBackupSupport.m" \
    -o "$build/tests"
"$build/tests"
