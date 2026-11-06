#!/bin/sh
set -eu

# Build the All+ r/all feed rewrite (src/ApolloAllPlusNSFW.xm) as a macOS
# executable with host doubles only at its account, setting, log and
# NSURLSession boundaries, and run the buffer / owner / sort scenarios in
# tests/allplus_feed_tests.m. The .xm has no Logos directives, so with its
# #imports stripped it compiles as plain Objective-C.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-allplus-feed-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'src/ApolloAllPlusNSFW.xm').read_text()
assert '%hook' not in source and '%ctor' not in source, 'ApolloAllPlusNSFW.xm grew Logos directives; the feed fixture needs updating'
source = '\n'.join(line for line in source.splitlines() if not line.startswith('#import '))
fixture = (root / 'tests/allplus_feed_tests.m').read_text()
marker = '// INSERT_PRODUCTION_FEED'
assert fixture.count(marker) == 1, 'feed fixture insertion marker missing or duplicated'
(out / 'tests.m').write_text(fixture.replace(marker, source))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloAllPlusMerge.m" \
    "$test_build_dir/tests.m" -o "$test_build_dir/tests"

# Each scenario starts a fresh process: the rewrite's buffer, owner and
# generation are static.
for scenario in cold-start refresh-cache account-switch account-switch-before-load mixed-auth sort-restricted disable-in-flight disable-flag-only; do
    "$test_build_dir/tests" "$scenario"
done
