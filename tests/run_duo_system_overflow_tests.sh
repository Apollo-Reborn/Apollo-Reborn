#!/bin/sh
set -eu
overflow_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
overflow_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-overflow-tests.XXXXXX")
trap 'rm -rf -- "$overflow_build"' EXIT HUP INT TERM
python3 - "$overflow_root" "$overflow_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
s = (root/'src/ApolloNavigationActions.xm').read_text()
helper = s[s.index('@interface ApolloDuoSystemOverflow'):s.index('static NSArray<UIBarButtonItem *> *ApolloActionsDuoNativeItems(')]
fixture = (root/'tests/duo_system_overflow_tests.m').read_text()
search = (root/'src/ApolloSearchNativeBar.xm').read_text()
trailing = search[search.index('NSArray<UIBarButtonItem *> *ApolloNativeFeedSearchDuoTrailingItems('):search.index('static void NSBUpdateDuoControls(')]
(build/'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_HELPERS', helper).replace('// INCLUDE_TRAILING_ITEMS_HELPER', trailing))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined -framework Foundation "$overflow_build/tests.m" -o "$overflow_build/tests"
"$overflow_build/tests"
