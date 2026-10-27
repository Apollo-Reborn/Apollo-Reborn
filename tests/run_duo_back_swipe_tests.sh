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
                  'static BOOL ApolloDuoPostsPopReachedBackstop(',
                  'static CGFloat ApolloDuoSplitNativePanReleaseScale(',
                  'static CGFloat ApolloDuoSplitNativePanReleaseScaleForNavigation(',
                  'static void ApolloDuoSplitNativePanReleaseRun(',
                  'static CGPoint ApolloDuoSplitReleaseTranslation(',
                  'BOOL ApolloDuoSplitCanRevealSearchColumnWithSwipe(',
                  'static BOOL ApolloDuoSearchColumnBesideSubreddit(',
                  'BOOL ApolloDuoSplitCanHideSidebarWithSwipe(',
                  'BOOL ApolloDuoSplitCanHideSearchColumnWithTap(',
                  'BOOL ApolloDuoSplitIsPostsListNavigation(']:
    start = split.index(signature)
    policies.append(split[start:split.index('\n}', start) + 2])
# The release window's thread-locals, ahead of the helpers that use them.
start = split.index('static __thread void *sDuoSplitReleaseGesture;')
end = split.index('\n', split.index('static __thread CGFloat sDuoSplitReleaseScale')) + 1
policies.insert(0, split[start:end])
# The split's memory of a closed thread keeps its forget rules in one block,
# free of UIKit. Test that block as it ships.
start = split.index("// The closed thread's memory: its pure pieces")
policies.insert(0, split[start:split.index('// A thread a Back closed beside the feed, held', start)])
# The split's glue forgets a closed thread on every path that opens a feed in
# the Posts columns, even mid column change: the subreddit list's row, a feed
# link, the reroot (list, Search, Settings), a feed pushed during a column
# change and the Back from a feed link. A teardown forgets before it bails.
def body(signature):
    start = split.index(signature)
    return split[start:split.index('\n}', start) + 2]
for signature in ['static BOOL ApolloDuoPostsRouteFeedLink(', 'static UIViewController *ApolloDuoPostsPopFeedLink(',
                  'static BOOL ApolloDuoSplitRoutePush(', '- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:']:
    expected = 2 if 'RoutePush' in signature else 1
    if body(signature).count('ApolloDuoClosedThreadEventFeedOpened') < expected:
        sys.exit('FAIL: %s no longer forgets a closed thread when a feed opens' % signature)
close = body('static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail) {')
if close.find('ApolloDuoPostsForgetClosedThread(') < 0 or close.find('ApolloDuoPostsForgetClosedThread(') > close.index('if (!state.split || state.changing) return;'):
    sys.exit('FAIL: ApolloDuoSplitClose bails before it forgets a closed thread')
sync = body('static void ApolloDuoPostsSyncColumnsWithAnimation(')
if sync.find('ApolloDuoPostsForgetClosedThread(') < 0 or sync.find('ApolloDuoPostsForgetClosedThread(') > sync.index('state.interactiveClose) return;'):
    sys.exit('FAIL: the column sync bails on a gone split before it forgets a closed thread')
fixture = fixture.replace('// INCLUDE_PRODUCTION_SPLIT_POLICIES', '\n'.join(policies))
fixture = fixture.replace('// INCLUDE_PRODUCTION_GESTURES', source)
(build / 'duo_back_swipe_tests.m').write_text(fixture)
PY
# Adjustable Split moves the divider only from a hold on its bar
# (ApolloDuoSplitDivider.m): the pane gestures never read the setting, so
# every route is the same with it on or off.
if grep -q 'AdjustableSplit\|ApolloDuoSplitDivider' "$swipe_root/src/ApolloDuoNavigationGestures.m"; then
    echo "FAIL: the pane gestures read the adjustable split; the setting must not change a route" >&2
    exit 1
fi
# Feed galleries make ancestor pans wait for their own drag. The Duo pane
# Back is a pan too, and must stay exempt in the gallery's wiring loop.
# (Community Highlights makes it wait on purpose and hands it the swipe at the
# first highlight, or the forward swipe at the last;
# run_highlights_carousel_gesture_policy_tests.sh checks that.)
for exemption in 'ApolloFeedGalleryCarousel.xm:1'; do
    file=${exemption%%:*}; expected=${exemption##*:}
    found=$(grep -c 'ApolloDuoIsPaneBackPan(' "$swipe_root/src/$file" || true)
    if [ "$found" -lt "$expected" ]; then
        echo "FAIL: $file no longer exempts the Duo pane Back from its carousel failure requirement" >&2
        exit 1
    fi
done
# Apollo's navigation pans judge their release against the visible pane only
# through the split's translationInView: hook, which reads the scale that the
# screenEdgePanned: and navigationBarPanned: hooks set around the original.
split_source="$swipe_root/src/ApolloDuoSplitView.xm"
for hook in 'return ApolloDuoSplitReleaseTranslation(self, view, %orig(view));' \
            '- (void)screenEdgePanned:(UIPanGestureRecognizer \*)gesture' \
            '- (void)navigationBarPanned:(UIPanGestureRecognizer \*)gesture'; do
    if ! grep -q -- "$hook" "$split_source"; then
        echo "FAIL: ApolloDuoSplitView.xm lost the native pan release hook ($hook)" >&2
        exit 1
    fi
done
found=$(grep -c 'ApolloDuoSplitNativePanReleaseRun(self, gesture, ^{ %orig(gesture); });' "$split_source" || true)
if [ "$found" -lt 2 ]; then
    echo "FAIL: screenEdgePanned: and navigationBarPanned: no longer both scale their release" >&2
    exit 1
fi
# The info-row loupe makes ancestor pans wait for it the same way; the Duo
# pane gestures stay exempt there, so a sideways drag goes to the Back.
if [ "$(grep -c 'ApolloDuoIsPaneGesture(' "$swipe_root/src/ApolloStatsRowTouch.xm" || true)" -lt 1 ]; then
    echo "FAIL: ApolloStatsRowTouch.xm no longer exempts the Duo pane gestures from its loupe failure requirement" >&2
    exit 1
fi
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$swipe_build/duo_back_swipe_tests.m" -o "$swipe_build/duo_back_swipe_tests"
"$swipe_build/duo_back_swipe_tests"
