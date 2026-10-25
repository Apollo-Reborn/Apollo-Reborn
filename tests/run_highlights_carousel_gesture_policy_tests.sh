#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-highlights-gesture.XXXXXX")
trap 'rm -rf "$build"' EXIT INT TERM

xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -I "$test_root/src" \
    "$test_root/tests/highlights_carousel_gesture_policy_tests.c" \
    -o "$build/highlights-gesture-tests"
"$build/highlights-gesture-tests"

# The carousel must keep deferring to the policy.
if ! grep -Fq 'ApolloHLCarouselShouldYieldToNavigation(' "$test_root/src/ApolloSubredditHighlights.xm"; then
    echo "highlights carousel no longer consults the navigation yield policy" >&2
    exit 1
fi

echo "highlights_carousel_gesture_source_check passed"
