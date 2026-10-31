#!/bin/sh
set -eu
fold_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fold_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-fold.XXXXXX")
trap 'rm -rf -- "$fold_build"' EXIT HUP INT TERM
python3 - "$fold_root" "$fold_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloNavigationActions.xm').read_text()
start = source.index('static void ApolloActionsArmFoldedRows(')
arm = source[start:source.index('// Every slot spec asks', start)]
fixture = (root / 'tests/duo_folded_rows_lifecycle_tests.m').read_text()
(build / 'duo_folded_rows_lifecycle_tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_ARM', arm))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$fold_build/duo_folded_rows_lifecycle_tests.m" -o "$fold_build/duo_folded_rows_lifecycle_tests"
"$fold_build/duo_folded_rows_lifecycle_tests"
