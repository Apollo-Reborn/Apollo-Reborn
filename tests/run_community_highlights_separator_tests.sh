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

def extract(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

helpers = "\n".join([
    extract("static NSMutableSet<NSString *> *ApolloHLHideSubs(void)",
            "// Lowercased subreddit -> number of leading stickied posts"),
    extract("static void ApolloHLClearTableDeDupState(",
            "UIView *ApolloHLUnwrapManagedHeader("),
    extract("static void ApolloHLTeardown(",
            "// Mid-search predicate from ApolloSearchInPlace.xm"),
    extract("static id ApolloHLOwningTableNode(",
            "static void ApolloHLCollapseOrphanSeparators("),
])
fixture = (root / "tests/community_highlights_separator_tests.mm").read_text()
assert fixture.count("// PRODUCTION_HELPERS") == 1
(output / "separator_tests.mm").write_text(fixture.replace("// PRODUCTION_HELPERS", helpers))
PY

# Match Logos' Objective-C++ mode. Teardown's pre-existing compatibility argument
# is unused in production; keep every other warning fatal in this harness.
xcrun --sdk macosx clang++ -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined \
    -framework Foundation "$test_build/separator_tests.mm" \
    -o "$test_build/separator_tests"
"$test_build/separator_tests"
