#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-web-search-task.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
python3 - "$repo" "$build" <<'PYGEN'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
s = (root/'src/ApolloWebJSONIdentity.xm').read_text()
start = s.index('static __thread BOOL sApolloWebJSONResendingAfterWebBearerMint')
proxy = s[start:s.index('// Route fallback for API-Key-Free reads', start)]
start = s.index('    if (sWebJSONEnabled && !sApolloWebJSONResendingAfterWebBearerMint')
branch = s[start:s.index('    NSString *requestMethod =', start)]
def function(signature):
    start = s.index(signature)
    return s[start:s.index('\n}', start)+2]
resolution = function('static NSString *ApolloWebJSONClientUsername(') + '\n'
resolution += function('static NSString *ApolloWebJSONWebSessionUsernameForClient(')
test = (root/'tests/web_json_search_task_tests.m').read_text()
(output/'test.m').write_text(test.replace('// PRODUCTION_DEFERRED_TASK', proxy).replace('// PRODUCTION_MINT_BRANCH', branch).replace('// PRODUCTION_ACCOUNT_RESOLUTION', resolution))
PYGEN
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation "$build/test.m" -o "$build/test"
"$build/test"
