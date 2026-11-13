#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
s = Path('src/ApolloListEmptyState.xm').read_text()
a = s.index('typedef NS_ENUM(NSInteger, ApolloListKind)')
b = s.index('// End of the rate-limit decisions.', a)
Path(sys.argv[1], 'ListRateLimit.inc').write_text(s[a:b])
PY
xcrun clang -fobjc-arc -fblocks -framework Foundation -I"$work" tests/list_rate_limit_tests.m -o "$work/tests"
"$work/tests"
