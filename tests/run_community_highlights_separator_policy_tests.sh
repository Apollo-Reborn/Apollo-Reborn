#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-highlights-separator.XXXXXX")
trap 'rm -rf -- "$test_build"' EXIT HUP INT TERM

python3 - "$test_root" "$test_build" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/ApolloSubredditHighlights.xm").read_text()
start = source.index("static BOOL ApolloHLSeparatorRowShouldCollapse(")
end = source.index("static BOOL ApolloHLSeparatorShouldCollapse(", start)
(output / "separator_policy_tests.m").write_text(
    "#import <Foundation/Foundation.h>\n" +
    source[start:end] +
    (root / "tests/community_highlights_separator_policy_tests.m").read_text()
)
PY

xcrun --sdk macosx clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -framework Foundation "$test_build/separator_policy_tests.m" \
    -o "$test_build/separator_policy_tests"
"$test_build/separator_policy_tests"
