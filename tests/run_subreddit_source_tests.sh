#!/bin/sh
set -eu

unset CDPATH
test_repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-subreddit-source.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Compile the shipping parser into a Foundation-only host harness so validation
# is exercised without copying its implementation into the test.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/Tweak.xm").read_text()
helpers = source.split("static BOOL ApolloSubredditSourceLineIsValid", 1)[1]
helpers = "static BOOL ApolloSubredditSourceLineIsValid" + helpers.split(
    "static NSArray<NSString *> *ApolloConfiguredSubredditSources", 1
)[0]
test = (root / "tests/subreddit_source_tests.m").read_text()
(output / "subreddit_source_tests.m").write_text(
    test.replace("// PRODUCTION_HELPERS", helpers)
)
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -framework Foundation "$test_build_dir/subreddit_source_tests.m" \
    -o "$test_build_dir/subreddit_source_tests"
"$test_build_dir/subreddit_source_tests"
