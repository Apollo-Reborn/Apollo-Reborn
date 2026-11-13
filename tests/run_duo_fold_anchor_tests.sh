#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-fold-anchor.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Extract the shipping fold-anchor code, not a second implementation of it.
# An optional source path lets the same checks run against an older revision.
python3 - "$test_repo_root" "$test_build_dir" "${1:-$test_repo_root/src/ApolloDuoRail.xm}" <<'PY'
from pathlib import Path
import sys

root, output, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
# The anchor key and anything declared with it, up to the table collection.
key = source.index('static char kApolloDuoFoldAnchorKey;')
declarations = source[key:source.index('static void ApolloDuoCollectVisibleTables(', key)]
start = source.index('static void ApolloDuoCaptureFoldAnchor(')
restore = source.index('static void ApolloDuoRestoreFoldAnchor(', start)
end = source.index('\n}', restore) + 2
test = (root / 'tests/duo_fold_anchor_tests.m').read_text()
marker = '// INCLUDE_PRODUCTION_FOLD_ANCHOR'
assert test.count(marker) == 1, 'fold anchor insertion marker missing or duplicated'
(output / 'DuoFoldAnchor.m').write_text(test.replace(marker, declarations + source[start:end]))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$test_build_dir/DuoFoldAnchor.m" -o "$test_build_dir/duo_fold_anchor_tests"
"$test_build_dir/duo_fold_anchor_tests"
