#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-feed-gallery-gesture.XXXXXX")
trap 'rm -rf "$build"' EXIT INT TERM

xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -I "$test_root/src" \
    "$test_root/tests/feed_gallery_gesture_policy_tests.c" \
    -o "$build/feed-gallery-gesture-tests"
"$build/feed-gallery-gesture-tests"

# Release-time navigation caused the delayed pop/jump regressions. Keep the
# carousel module free of direct navigation commands so only Apollo's native,
# interactive recognizers can act after the pan is yielded at begin time.
if grep -En 'apollo_navigateIfReleasedPastEdge|popViewControllerAnimated|@selector\(goForward\)' \
    "$test_root/src/ApolloFeedGalleryCarousel.xm"; then
    echo "feed gallery carousel still performs release-time navigation" >&2
    exit 1
fi

echo "feed_gallery_gesture_source_check passed"
