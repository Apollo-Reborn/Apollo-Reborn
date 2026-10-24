#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-subreddit-hits.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSubredditIndexPolish.xm').read_text()
width = '\n'.join(line for line in source.splitlines() if line.startswith(('static const CGFloat ApolloSubredditIndexGestureWidth =', 'static const CGFloat ApolloSubredditIndexDuoGestureWidth =')))
begin = source.index('- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {')
end = source.index('\n}', begin) + 2
method = source[begin:end].replace('(UIEvent *)event', '(id)event')
test = (root / 'tests/subreddit_index_hit_tests.m').read_text()
test = test.replace('// INCLUDE_PRODUCTION_GESTURE_WIDTH', width)
test = test.replace('// INCLUDE_PRODUCTION_POINT_INSIDE', method)
begin = source.index('- (NSInteger)indexForPoint:(CGPoint)point {')
end = source.index('\n}', begin) + 2
test = test.replace('// INCLUDE_PRODUCTION_INDEX_FOR_POINT', source[begin:end])
def function(start):
    begin = source.index(start)
    return source[begin:source.index('\n}', begin) + 2]
helper = 'static void ApolloSubredditIndexSetNativeIndexReplaced('
policy = 'static char kApolloSubredditNativeIndexInteractionKey;\n' + function(helper)
test = test.replace('// INCLUDE_PRODUCTION_NATIVE_INDEX_POLICY', policy)
test = test.replace('// INCLUDE_PRODUCTION_HIDE_NATIVE_INDEX', function('static void ApolloSubredditIndexHideNativeIndex('))
(output / 'test.m').write_text(test)
PY
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    "$test_build_dir/test.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
