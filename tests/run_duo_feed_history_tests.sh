#!/bin/sh
set -eu
history_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
history_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-feed-history.XXXXXX")
trap 'rm -rf -- "$history_build"' EXIT HUP INT TERM

# Execute the shipping restoration and drawer decisions with UIKit doubles.
# An optional source path lets the same checks demonstrate the old regressions.
python3 - "$history_root" "$history_build" "${1:-$history_root/src/ApolloDuoSplitView.xm}" <<'PY'
from pathlib import Path
import sys
root, build, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
signatures = [
    'static BOOL ApolloDuoPostsHasLandscapeColumns(',
    'static BOOL ApolloDuoPostsUsesSplit(',
    'static NSUInteger ApolloDuoFeedStackKeptCount(UINavigationController *feed) {',
    'static void ApolloDuoPostsRestoreFeedLinkDetail(',
    'static NSIndexPath *ApolloDuoListWillSelect(',
]
functions = []
for signature in signatures:
    start = source.index(signature)
    functions.append(source[start:source.index('\n}', start) + 2])
# The previous helper used state.feed directly and had no navigation argument.
if 'UINavigationController *navigation,' not in functions[3]:
    functions[3] = functions[3].replace(
        'ApolloDuoSplitState *state, UIViewController *controller)',
        'ApolloDuoSplitState *state, __unused UINavigationController *navigation, UIViewController *controller)')
fixture = (root / 'tests/duo_feed_history_tests.m').read_text()
(build / 'duo_feed_history_tests.m').write_text(
    fixture.replace('// INCLUDE_PRODUCTION_HISTORY', '\n\n'.join(functions)))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$history_build/duo_feed_history_tests.m" -o "$history_build/duo_feed_history_tests"
"$history_build/duo_feed_history_tests"
