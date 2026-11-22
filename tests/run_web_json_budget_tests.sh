#!/bin/bash
# Reddit's request budget as its answers report it (src/ApolloWebJSONBudget.m), compiled as shipped.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -Isrc \
    src/ApolloWebJSONBudget.m tests/web_json_budget_tests.m -o "$work/tests"
"$work/tests"
