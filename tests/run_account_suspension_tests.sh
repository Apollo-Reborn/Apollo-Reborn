#!/bin/bash
# Reddit account suspension state (src/ApolloAccountSuspension.m), compiled as shipped.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-const-variable \
    -fsanitize=address,undefined -framework Foundation -Isrc \
    src/ApolloAccountSuspension.m tests/account_suspension_tests.m -o "$work/tests"
# The binary's defaults domain is its own name, and the test clears its key when done.
"$work/tests"
