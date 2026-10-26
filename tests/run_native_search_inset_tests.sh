#!/bin/sh
set -eu
inset_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
inset_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-nsb-inset.XXXXXX")
trap 'rm -rf -- "$inset_build"' EXIT HUP INT TERM
# The native search bar's top inset rule, as it ships.
python3 - "$inset_root" "$inset_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSearchNativeBar.xm').read_text()
start = source.index('static CGFloat NSBRelativizedTop(')
rule = source[start:source.index('\n}', start) + 2]
slack = source[source.index('static const CGFloat kNSBBandSlack'):]
slack = slack[:slack.index('\n') + 1]
fixture = (root / 'tests/native_search_inset_tests.m').read_text()
(build / 'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_TOP_RULE', slack + rule))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$inset_build/tests.m" -o "$inset_build/tests"
"$inset_build/tests"
