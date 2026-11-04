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
                  'BOOL ApolloDuoSplitCanRevealPostsListWithSwipe(']:
    start = split.index(signature)
    policies.append(split[start:split.index('\n}', start) + 2])
fixture = fixture.replace('// INCLUDE_PRODUCTION_SPLIT_POLICIES', '\n'.join(policies))
fixture = fixture.replace('// INCLUDE_PRODUCTION_GESTURES', source)
(build / 'duo_back_swipe_tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$swipe_build/duo_back_swipe_tests.m" -o "$swipe_build/duo_back_swipe_tests"
"$swipe_build/duo_back_swipe_tests"
