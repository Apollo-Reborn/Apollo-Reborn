#!/bin/sh
set -eu
swipe_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swipe_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-back.XXXXXX")
trap 'rm -rf -- "$swipe_build"' EXIT HUP INT TERM
python3 - "$swipe_root" "$swipe_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloDuoNavigationGestures.m').read_text()
source = source[source.index('// Apollo\'s pans'):]
fixture = (root / 'tests/duo_back_swipe_tests.m').read_text()
split = (root / 'src/ApolloDuoSplitView.xm').read_text()
policies = []
for signature in ['UINavigationController *ApolloDuoSplitDetailNavigation(',
                  'BOOL ApolloDuoSplitAllowsNavigationSwipe(',
                  'BOOL ApolloDuoSplitCanRevealPostsListWithSwipe(',
                  'BOOL ApolloDuoSplitCanReturnFromVisitedProfile(',
                  'BOOL ApolloDuoSplitPopRevealsContent(',
                  'BOOL ApolloDuoSplitIsActive(',
                  'BOOL ApolloDuoSplitBackClosesThread(',
                  'static BOOL ApolloDuoPostsPopReachedBackstop(']:
    start = split.index(signature)
    policies.append(split[start:split.index('\n}', start) + 2])
fixture = fixture.replace('// INCLUDE_PRODUCTION_SPLIT_POLICIES', '\n'.join(policies))
fixture = fixture.replace('// INCLUDE_PRODUCTION_GESTURES', source)
(build / 'duo_back_swipe_tests.m').write_text(fixture)
PY
# Feed galleries make ancestor pans wait for their own drag. The Duo pane
# Back is a pan too, and must stay exempt in the gallery's wiring loop.
# (Community Highlights makes it wait on purpose and hands it the swipe at the
# first highlight; run_highlights_carousel_gesture_policy_tests.sh checks that.)
for exemption in 'ApolloFeedGalleryCarousel.xm:1'; do
    file=${exemption%%:*}; expected=${exemption##*:}
    found=$(grep -c 'ApolloDuoIsPaneBackPan(' "$swipe_root/src/$file" || true)
    if [ "$found" -lt "$expected" ]; then
        echo "FAIL: $file no longer exempts the Duo pane Back from its carousel failure requirement" >&2
        exit 1
    fi
done
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$swipe_build/duo_back_swipe_tests.m" -o "$swipe_build/duo_back_swipe_tests"
"$swipe_build/duo_back_swipe_tests"
