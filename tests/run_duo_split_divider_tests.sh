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
# frame; the release clears the drag before it applies the stop; every
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
snap = finish[finish.index('// A snap.'):]
if not (snap.index('ApolloDuoPostsCloseEventInterrupt') < snap.index('setInteger:') < snap.index('ApolloDuoSplitApplyPostsStop(')):
    fail('a snap clears its drag, then remembers the stop, then applies it')
for outcome in ['if (release.closesThread)', 'if (release.fullScreen)']:
    part = finish[finish.index(outcome):]
    part = part[:part.index('return;')]
    if 'UDKeyDuoSplitStop' in part:
        fail('%s changes the remembered stop' % outcome)
if finish.count('UDKeyDuoSplitStop') != 1:
    fail('only the snap remembers a stop')
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
if 'drag.dividing ? ApolloDuoSplitDividerHolding(' not in sweep or 'drag.overlay.window && held) continue;' not in sweep:
    fail("the split update's stale-drag sweep drops a divider drag its press still holds")
# A stored stop UIKit can't tile beside the rail gives way to Half, and the
# split's minimum thread width is the one the fit is measured against.
if 'ApolloDuoPostsFittedPrimaryWidth(' not in body('static CGFloat ApolloDuoPostsWantedDivider('):
    fail('the Posts divider no longer falls back to Half for a stop that would break the split')
if 'kApolloDuoPostsMinimumThread' not in body('static void ApolloDuoSplitApplySidebarWidth('):
    fail("the split's minimum thread width no longer matches the fit")
# The divider is only where UIKit actually put the thread pane.
if 'ApolloDuoPostsSplitDivider(state)) > 2.0' not in body('CGFloat ApolloDuoSplitDividerPosition('):
    fail('the divider press can be offered where no thread pane begins')
print('OK: split divider wiring')
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -I "$divider_root/src" -framework Foundation -framework CoreGraphics \
    "$divider_build/tests.m" -o "$divider_build/tests"
"$divider_build/tests"
