#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/apollo-icloud-read-state-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun clang -fobjc-arc -fblocks -DAPOLLO_ICLOUD_READ_STATE_TESTS=1 \
    -I "$ROOT/src" -framework Foundation -framework Security \
    "$ROOT/tests/icloud_read_state_tests.m" "$ROOT/src/ApolloICloudReadState.m" \
    -o "$WORK/tests"
"$WORK/tests"
