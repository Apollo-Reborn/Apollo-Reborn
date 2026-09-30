#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-icloud-backup-tests.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -I "$repo/src" \
    "$repo/tests/icloud_backup_support_tests.m" \
    "$repo/src/settings/ApolloICloudBackupSupport.m" \
    -o "$build/tests"
"$build/tests"
