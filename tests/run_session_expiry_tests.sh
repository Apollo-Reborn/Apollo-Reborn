#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-session-expiry.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
python3 - "$repo" "$build" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
s=(root/'src/ApolloWebJSON.m').read_text()
code=s[s.index('static NSObject *ApolloWebJSONExpiryLock'):s.index('#pragma mark - Set-Cookie rotation capture')]
a=s.index('void ApolloWebJSONNoteResponse('); b=s.index('\n}',a)+2
code += s[a:b]
(output/'test.m').write_text((root/'tests/session_expiry_tests.m').read_text().replace('// PRODUCTION_EXPIRY',code))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined -framework Foundation "$build/test.m" -o "$build/test"
"$build/test"
