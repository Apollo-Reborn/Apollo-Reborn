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

expected_footer='Swipe Past Gallery to Navigate: at the first or last image, keep swiping to use your normal post swipes (vote, save, back or forward) instead of bouncing. From any image, a swipe that starts at the screen edge goes back or forward. Off by default.'
if ! grep -Fq "$expected_footer" "$test_root/src/settings/CustomAPIViewController.m"; then
    echo "feed gallery settings footer does not describe gesture arbitration" >&2
    exit 1
fi

echo "feed_gallery_gesture_source_check passed"
