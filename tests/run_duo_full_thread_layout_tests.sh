#!/bin/sh
set -eu
thread_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
thread_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-full-thread.XXXXXX")
trap 'rm -rf -- "$thread_build"' EXIT HUP INT TERM
python3 - "$thread_root" "$thread_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloDuoRail.xm').read_text()
start = source.index('static CGRect ApolloDuoFullThreadFrame(')
helper = source[start:source.index('\n}', start) + 2]
fixture = (root / 'tests/duo_full_thread_layout_tests.m').read_text()
(build / 'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_FRAME_HELPER', helper))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$thread_build/tests.m" -o "$thread_build/tests"
"$thread_build/tests"
