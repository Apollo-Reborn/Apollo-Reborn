#!/bin/sh
set -eu
drawer_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
drawer_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-drawer.XXXXXX")
trap 'rm -rf -- "$drawer_build"' EXIT HUP INT TERM
# The interactive drawer keeps its progress and begin/finish rules in
# one block of the split, free of UIKit. Test that block as it ships.
python3 - "$drawer_root" "$drawer_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
split = (root / 'src/ApolloDuoSplitView.xm').read_text()
start = split.index("// The interactive drawer's pure pieces")
end = split.index("// End of the interactive drawer's pure pieces", start)
fixture = (root / 'tests/duo_interactive_drawer_tests.m').read_text()
(build / 'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_INTERACTIVE_DRAWER', split[start:end]))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$drawer_build/tests.m" -o "$drawer_build/tests"
"$drawer_build/tests"
