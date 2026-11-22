#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-subreddit-scrub.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSubredditIndexPolish.xm').read_text()
def block(start, end_marker):
    begin = source.index(start)
    return source[begin:source.index(end_marker, begin) + len(end_marker)]
slop = block('static const CGFloat ApolloSubredditIndexScrubSlop =', ';')
interface = block('@interface ApolloSubredditIndexScrubGestureRecognizer', '@end')
implementation = block('@implementation ApolloSubredditIndexScrubGestureRecognizer', '\n@end')
compatibility = block('static BOOL ApolloNativeIndexHooksAreCompatible(', '\n}')
test = (root / 'tests/subreddit_index_scrub_tests.m').read_text()
test = test.replace('// INCLUDE_PRODUCTION_SCRUB_RECOGNIZER', '\n'.join([slop, interface, implementation]))
test = test.replace('// INCLUDE_PRODUCTION_NATIVE_INDEX_COMPATIBILITY', compatibility)
(output / 'test.m').write_text(test)
PY
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$test_build_dir/test.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
