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
                  'BOOL ApolloDuoSplitCanReturnFromVisitedProfile(']:
    start = split.index(signature)
    policies.append(split[start:split.index('\n}', start) + 2])
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
if sync.find('ApolloDuoPostsForgetClosedThread(') < 0 or sync.find('ApolloDuoPostsForgetClosedThread(') > sync.index('state.changing) return;'):
    sys.exit('FAIL: the column sync bails on a gone split before it forgets a closed thread')
# An account switch forgets it: the feed page reloads in place, so its identity
# alone would bring the first account's thread back under the second.
if split.count('ApolloDuoClosedThreadEventAccountChanged, 0.0)') < 1 or 'com.christianselig.RedditCurrentAccountChanged' not in split:
    sys.exit('FAIL: the split no longer forgets a closed thread when the account changes')
# Forget Forward Swipe After Scrolling counts the closed thread as a forward
# page: its scroll expiry reads the thread's token and forgets it.
expiry = (root / 'src/ApolloForwardSwipeExpiry.xm').read_text()
for needle in ['ApolloDuoSplitClosedThreadToken(', 'ApolloDuoSplitForgetClosedThreadAfterScrolling(']:
    if needle not in expiry:
        sys.exit('FAIL: ApolloForwardSwipeExpiry.xm no longer uses %s' % needle)
fixture = fixture.replace('// INCLUDE_PRODUCTION_SPLIT_POLICIES', '\n'.join(policies))
fixture = fixture.replace('// INCLUDE_PRODUCTION_GESTURES', source)
(build / 'duo_back_swipe_tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$swipe_build/duo_back_swipe_tests.m" -o "$swipe_build/duo_back_swipe_tests"
"$swipe_build/duo_back_swipe_tests"
