#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
s = Path('src/ApolloChatsFilter.xm').read_text()
a = s.index('static const NSTimeInterval kApolloInboxParentsReuseTTL')
b = s.index('%hook RDKClient', a)
Path(sys.argv[1], 'InboxParents.inc').write_text(s[a:b])
PY
xcrun clang -fobjc-arc -fblocks -framework Foundation -I"$work" tests/inbox_parents_reuse_tests.m -o "$work/tests"
"$work/tests"
