#!/bin/bash
set -euo pipefail
subreddit_root=$(cd "$(dirname "$0")/.." && pwd)
subreddit_tmp=$(mktemp -d /tmp/apollo-subreddit-info-tests.XXXXXX)
trap 'rm -rf "$subreddit_tmp"' EXIT
python3 - "$subreddit_root" "$subreddit_tmp" <<'PY'
from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSubredditInfoCache.m').read_text()
header = (root / 'src/ApolloSubredditInfoCache.h').read_text()

def between(start, end):
    # Name the marker that moved instead of failing with a bare ValueError.
    a = source.find(start)
    if a < 0:
        sys.exit(f'run_subreddit_info_cache_tests: start marker not found in ApolloSubredditInfoCache.m: {start!r}')
    b = source.find(end, a)
    if b < 0:
        sys.exit(f'run_subreddit_info_cache_tests: end marker not found after {start!r}: {end!r}')
    return source[a:b]

# Compile production parsing, persistence and request construction without UIKit.
model = header[header.index('@interface ApolloSubredditInfo :'):header.index('@interface ApolloSubredditInfoCache :')]
model += between('@implementation ApolloSubredditInfo\n', '// Retry budget')
constants = between('static NSTimeInterval const ApolloSubredditInfoCacheTTL', 'void ApolloSubredditPrepareNativeIcons')
methods = between('- (NSString *)normalizedSubredditName:', '- (NSString *)cachePath')
methods += between('- (NSURL *)URLFromString:', '- (void)loadDiskCache')
methods += between('- (NSString *)escapedSubredditForPath:', '- (void)finishRequestForKey:')

fixture = (root / 'tests/subreddit_info_cache_tests.m').read_text()
fixture = fixture.replace('// INSERT_PRODUCTION_MODEL', model)
fixture = fixture.replace('// INSERT_PRODUCTION_CONSTANTS', constants)
fixture = fixture.replace('// INSERT_PRODUCTION_METHODS', methods)
(out / 'tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wno-nullability-completeness \
    -I "$subreddit_root/src" -framework Foundation \
    "$subreddit_tmp/tests.m" "$subreddit_root/src/ApolloNativeSubredditIcons.m" -o "$subreddit_tmp/tests"
"$subreddit_tmp/tests"
