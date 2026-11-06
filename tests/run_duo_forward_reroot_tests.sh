#!/bin/sh
set -eu
forward_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
forward_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-forward.XXXXXX")
trap 'rm -rf -- "$forward_build"' EXIT HUP INT TERM
python3 - "$forward_root" "$forward_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloDuoSplitView.xm').read_text()
helpers = []
for signature in ['static BOOL ApolloDuoSplitStackMovesForward(',
                  'static void ApolloDuoSplitForgetForward(']:
    start = source.index(signature)
    helpers.append(source[start:source.index('\n}', start) + 2])
fixture = (root / 'tests/duo_forward_reroot_tests.m').read_text()
(build / 'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_FORWARD_HELPERS', '\n'.join(helpers)))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$forward_build/tests.m" -o "$forward_build/tests"
"$forward_build/tests"
