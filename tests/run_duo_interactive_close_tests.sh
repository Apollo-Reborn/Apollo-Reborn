#!/bin/sh
set -eu
close_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
close_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-close.XXXXXX")
trap 'rm -rf -- "$close_build"' EXIT HUP INT TERM
# The interactive thread close keeps its geometry, spring and phase rules in
# one block of the split, free of UIKit. Test that block as it ships.
python3 - "$close_root" "$close_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
split = (root / 'src/ApolloDuoSplitView.xm').read_text()
start = split.index("// The interactive thread close's pure pieces")
end = split.index('// What an interactive close hands to ApolloDuoPostsCloseDetail', start)
fixture = (root / 'tests/duo_interactive_close_tests.m').read_text()
(build / 'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_INTERACTIVE_CLOSE', split[start:end]))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$close_build/tests.m" -o "$close_build/tests"
"$close_build/tests"
