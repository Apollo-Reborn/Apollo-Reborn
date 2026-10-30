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

# The carousel must keep deciding with the tested policy, and keep the Duo's
# pane Back swipe waiting on its pan.
source="$test_root/src/ApolloSubredditHighlights.xm"
for symbol in 'ApolloHLNavigationPanRuleAllows(' 'ApolloHLCarouselAtStart(' 'ApolloHLCarouselAtEnd(' \
    'isEqualToString:kApolloHLDuoPaneBackName]' 'ApolloDuoPaneBackPanAdmits(recognizer, forward)' \
    'ahlDuoPaneSwipeTracksTouchForward:YES]'; do
    if ! grep -Fq "$symbol" "$source"; then
        echo "highlights carousel no longer uses $symbol" >&2
        exit 1
    fi
done

# The carousel finds the Duo's pane Back swipe by name.
if ! grep -Fq '@"ApolloReborn.Duo.PaneBack"' "$test_root/src/ApolloDuoNavigationGestures.m" ||
    ! grep -Fq 'kApolloHLDuoPaneBackName = @"ApolloReborn.Duo.PaneBack";' "$source"; then
    echo "the Duo pane Back swipe name and the carousel's copy of it differ" >&2
    exit 1
fi

echo "highlights_carousel_gesture_source_check passed"
