#!/bin/sh
set -eu
divider_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
divider_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-divider.XXXXXX")
trap 'rm -rf -- "$divider_build"' EXIT HUP INT TERM
# The divider's press and drag keeps its admission, release and recognizer
# rules in src/ApolloDuoSplitDivider.m, apart from the split's columns. Test
# that file as it ships, against UIKit and split stubs.
python3 - "$divider_root" "$divider_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloDuoSplitDivider.m').read_text()
source = source[source.index("// The divider's press and drag"):]
fixture = (root / 'tests/duo_split_divider_tests.m').read_text()
(build / 'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_SPLIT_DIVIDER', source))
PY
# The pane gestures never wait on the divider: nothing makes them require
# its failure, and its own recognizer asks nothing of them. Only UIKit's
# context menus on a band touch are held off (ApolloDuoSplitDividerOutranks).
if grep -n 'requireGestureRecognizerToFail\|shouldRequireFailureOfGestureRecognizer\|shouldBeRequiredToFailByGestureRecognizer' \
        "$divider_root/src/ApolloDuoSplitDivider.m"; then
    echo "FAIL: the divider's press must not take part in failure requirements" >&2
    exit 1
fi
# The split's side: the columns are laid out once, on release, never per drag
# frame; the release clears the drag before it applies the position; every
# interruption of a close lets the divider go too; the setting turned off
# removes a drag first.
python3 - "$divider_root" <<'PY'
from pathlib import Path
import sys
split = (Path(sys.argv[1]) / 'src/ApolloDuoSplitView.xm').read_text()
def fail(message):
    print('FAIL: ' + message, file=sys.stderr)
    sys.exit(1)
def body(signature):
    start = split.index(signature)
    return split[start:split.index('\n}', start) + 2]
for signature in ['BOOL ApolloDuoSplitDividerUpdate(', 'static void ApolloDuoPostsPlaceDivider(']:
    frame = body(signature)
    for layout in ['layoutIfNeeded', 'ApolloDuoSplitApplySidebarWidth', 'ApolloDuoSplitApplyPostsStop', 'setNeedsLayout', '.frame']:
        if layout in frame:
            fail('%s lays out (%s) on a drag frame' % (signature, layout))
finish = body('void ApolloDuoSplitDividerFinish(')
snap = finish[finish.index('// A landing.'):]
if not (snap.index('ApolloDuoPostsCloseEventInterrupt') < snap.index('setDouble:') < snap.index('ApolloDuoSplitApplyPostsStop(')):
    fail('a landing clears its drag, then remembers the position, then applies it')
# The pictures' landing animation is on the render server, flushed, before
# the column change runs; the reveal is a cut (no fade, no effect view); and
# a new drag or press on the divider ends a settle in flight at once.
settle = body('static void ApolloDuoPostsSettleDivider(')
if settle.count('[CATransaction flush]') != 3 or settle.count('relayout();') != 2:
    fail('a settle flushes its animation before every column change')
spring = settle[settle.index('ApolloDuoPostsSpringDragWith('):]
if not (spring.index('ApolloDuoPostsSpringDragWith(') < spring.index('[CATransaction flush]') < spring.index('relayout();')):
    fail('a settle starts its spring and flushes it before the column change')
if snap.count('ApolloDuoSplitApplyPostsStop(') != 1 or snap.index('ApolloDuoSplitApplyPostsStop(') < snap.index('ApolloDuoPostsSettleDivider('):
    fail('a landing re-lays out the columns inside the settle, after its animation is flushed')
if 'UIVisualEffectView' in settle or 'UIBlurEffect' in settle or 'animateWithDuration' in settle:
    fail('the reveal is a cut: no blur and no effect view')
if 'ApolloDuoPostsFinishSettle(state)' not in body('BOOL ApolloDuoSplitDividerBegin(') \
        or 'ApolloDuoPostsFinishSettle(state)' not in body('CGFloat ApolloDuoSplitDividerPosition('):
    fail('a drag or a press that meets a settle in flight must end it, not be refused')
if 'sDuoPostsSettleOverlay == overlay' not in settle:
    fail('the settle forgets itself when it is cut')
for outcome in ['if (release.closesThread)', 'if (release.coversFeed)']:
    part = finish[finish.index(outcome):]
    part = part[:part.index('return;')]
    if 'UDKeyDuoSplitFeedShare' in part:
        fail('%s changes the remembered position' % outcome)
if finish.count('UDKeyDuoSplitFeedShare') != 1:
    fail('only a landing remembers a position')
if 'setInteger' in finish or 'UDKeyDuoSplitStop' in finish:
    fail('the retired stop key is read for migration only, never written')
if 'ApolloDuoSplitDividerLetGo(' not in body('static void ApolloDuoPostsCancelInteractiveClose(ApolloDuoSplitState *state, BOOL animated, CGFloat velocity) {'):
    fail("the close's interruptions no longer let the divider go")
apply = body('static void ApolloDuoSplitApplyPostsStopToState(')
if not (0 <= apply.find('interactiveClose.dividing') < apply.index('state.interactiveClose) return;')):
    fail('the setting turned off keeps a divider drag up')
if 'ApolloDuoSplitDividerInstall(self.view)' not in body('- (void)viewDidLoad {\n    [super viewDidLoad];\n    self.split.delegate = self;'):
    fail('the Posts host no longer installs the divider')
# Routine split updates (a layout, an open's or close's completion, a push)
# keep a divider drag whose press still holds; the sweep only lets go of one
# whose press has ended or whose views left the window.
update = body('static void ApolloDuoSplitUpdate(void) {')
sweep = update[:update.index('ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);')]
if 'drag.dividing ? (ApolloDuoSplitDividerHolding(' not in sweep or '|| drag.navigation)' not in sweep or 'drag.overlay.window && held) continue;' not in sweep:
    fail("the split update's stale-drag sweep drops a divider drag its press or its thread pane's pan still holds")
# The pan-driven drag has the pane's navigation, which is what the sweep keeps it by.
if '.navigation = nav' not in body('BOOL ApolloDuoSplitThreadDividerBegin('):
    fail('a pane-driven divider drag has no navigation, so the routine split update would drop it')
# The production predicate the route tables' fact comes from, which the
# gesture tests can only stub.
if 'ApolloDuoPostsAdjustableSplit() && ApolloDuoSplitBackClosesThread(nav)' not in body('BOOL ApolloDuoSplitThreadDividerDrags('):
    fail('the divider drag fact is no longer the setting on the thread pane at its root')
# A stored position UIKit can't tile beside the rail gives way to Half, and the
# split's minimum thread width is the one the fit is measured against.
if 'ApolloDuoPostsFittedPrimaryWidth(' not in body('static CGFloat ApolloDuoPostsWantedDivider('):
    fail('the Posts divider no longer falls back to Half for a position that would break the split')
if 'kApolloDuoPostsMinimumThread' not in body('static void ApolloDuoSplitApplySidebarWidth('):
    fail("the split's minimum thread width no longer matches the fit")
# The divider is only where UIKit actually put the thread pane.
if 'ApolloDuoPostsSplitDivider(state)) > 2.0' not in body('CGFloat ApolloDuoSplitDividerPosition('):
    fail('the divider press can be offered where no thread pane begins')
# The feed's cover (the post let go past the left limit) is transient: it
# never writes the split button's sticky setting, nor the position; the
# button pressed while covered ends it and persists nothing; the uncover
# drag ends the cover under its picture before the drag is registered, and
# the close of a covered thread replays no geometry of the hidden feed.
cover = finish[finish.index('if (release.coversFeed)'):]
cover = cover[:cover.index('return;')]
if 'ApolloDuoPostsCoverFeed(' not in cover or 'ApolloDuoPostsToggleSplit(' in cover:
    fail('the release past the left limit no longer covers the feed transiently (it ran the sticky toggle)')
for signature in ['static void ApolloDuoPostsCoverFeed(', 'static void ApolloDuoPostsEndCover(',
                  'static void ApolloDuoPostsUncoverFeed(', 'BOOL ApolloDuoSplitThreadUncoverBegin(']:
    part = body(signature)
    if 'ApolloDuoPostsSplitDisabled' in part or 'setBool' in part or 'UDKeyDuoSplitFeedShare' in part:
        fail('%s persists something' % signature)
toggle = body('static void ApolloDuoPostsToggleSplit(')
if toggle.count('ApolloDuoPostsSplitDisabled') != 1 or toggle.index('ApolloDuoPostsSplitDisabled') < toggle.index('} else {') \
        or toggle.index('ApolloDuoPostsEndCover(') > toggle.index('} else {'):
    fail('the split button pressed while covered must end the cover without persisting')
uncover = body('BOOL ApolloDuoSplitThreadUncoverBegin(')
if not (uncover.index('ApolloDuoPostsNewPaneDrag(') < uncover.index('ApolloDuoPostsCloseAdvance(') < uncover.index('[CATransaction flush]')
        < uncover.index('dispatch_async(')) or 'ApolloDuoPostsUncoverFeed(' in uncover or 'layoutIfNeeded' in uncover:
    fail('the uncover drag must picture the full-width thread, register the drag and flush before the column change, which waits for the next turn')
if 'drag.restoreSnapshot = nil' not in uncover or 'drag.uncovering = YES' not in uncover:
    fail('the uncover drag must drop its restore picture and mark the cover as ending')
under = body('static BOOL ApolloDuoPostsUncoverUnderDrag(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *drag) {')
if not (under.index('drag.uncovering = NO') < under.index('ApolloDuoPostsCloseEventInterrupt') < under.index('ApolloDuoPostsUncoverFeed(')
        < under.index('ApolloDuoPostsCloseEventBegin') < under.index('drag.gapInset = ')
        < under.index('ApolloDuoPostsPlaceDivider(')) or 'afterScreenUpdates:YES' in under:
    fail('the column change under the uncover drag must end the cover, measure the gap from the live feed column and never wait for the screen')
if 'drag.uncovering ? ApolloDuoPostsPanesStill(state)' not in body('static BOOL ApolloDuoPostsDividerHolds('):
    fail('an uncover drag is dropped before its column change runs')
if 'drag.uncovering && !ApolloDuoPostsUncoverUnderDrag(state, drag)' not in finish:
    fail('a release before the column change must run it first')
if 'ApolloDuoSplitThreadDividerDrags(nav) && ' not in body('BOOL ApolloDuoSplitThreadCovered(') \
        or 'postsCoveredByDrag' not in body('BOOL ApolloDuoSplitThreadCovered('):
    fail('the covered fact is no longer the divider drag fact on a covered host')
sync = body('static void ApolloDuoPostsSyncColumnsWithAnimation(')
if sync.index('ApolloDuoPostsReviewCover(state);') > sync.index('state.interactiveClose) return;'):
    fail('the column sync must review the cover before it bails')
if '&& !state.host.postsCoveredByDrag;' not in sync:
    fail('the columns pair while the feed is covered')
if 'animate && !state.host.postsCoveredByDrag' not in body('static void ApolloDuoPostsCloseDetail('):
    fail('the close of a covered thread replays the hidden feed')
if '!ApolloDuoSplitThreadCovered(state.secondary)' not in body('static UINavigationController *ApolloDuoSplitRailDragThread('):
    fail('the rail drag is offered while the feed is covered')
if 'ApolloDuoPostsUncoverFeed(state, @"another thread opened")' not in body('static void ApolloDuoPostsOpenDetail(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages, BOOL animated,\n                                     ApolloDuoPostsCloseHandoff *handoff) {'):
    fail('another thread opened over a covered one keeps the cover')
print('OK: split divider wiring')
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -I "$divider_root/src" -framework Foundation -framework CoreGraphics \
    "$divider_build/tests.m" -o "$divider_build/tests"
"$divider_build/tests"
