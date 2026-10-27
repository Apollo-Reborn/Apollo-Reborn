#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-web-search.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
python3 - "$repo" "$build" <<'PYGEN'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
s = (root/'src/ApolloWebJSON.m').read_text()
def function(signature):
    start = s.index(signature)
    return s[start:s.index('\n}', start)+2]
code = next(line for line in s.splitlines() if line.startswith('NSString *const ApolloWebJSONSyntheticBearerToken =')) + '\n'
code += s[s.index('BOOL ApolloWebJSONBearerIsSynthetic'):s.index('// Both markers below')]
code += s[s.index('static NSString *const kApolloWebJSONProbeMarker'):s.index('#pragma mark - Keychain-backed credential storage')]
code += function('BOOL ApolloWebJSONPathNeedsWebBearer(')
code += function('NSString *ApolloWebJSONWebSessionUsernameForBearer(')
code += s[s.index('static NSString *const kApolloWebJSONRoutesTriedMarkerPrefix'):s.index('#if APOLLO_SIM_BUILD', s.index('static NSString *const kApolloWebJSONRoutesTriedMarkerPrefix'))]
code += function('static NSURLRequest *ApolloWebJSONWebBearerRequest(')
code += function('NSURLRequest *ApolloWebJSONRewriteRequest(')
(output/'test.m').write_text((root/'tests/web_json_search_tests.m').read_text().replace('// PRODUCTION_SEARCH_TRANSPORT', code))
PYGEN
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function \
    -fsanitize=address,undefined -framework Foundation -I "$repo/src" \
    "$repo/src/ApolloWebJSONRoutes.m" "$build/test.m" -o "$build/test"
"$build/test"
