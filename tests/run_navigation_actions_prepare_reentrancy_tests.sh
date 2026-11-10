#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-navigation-prepare.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root" "$test_build_dir" "${1:-$test_repo_root/src/ApolloNavigationActions.xm}" <<'PY'
from pathlib import Path
import sys

root, output, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
start = source.index('static void ApolloActionsPrepare(UINavigationItem *item, NSArray *items) {')
end = source.index('\n}', start) + 2
test = (root / 'tests/navigation_actions_prepare_reentrancy_tests.m').read_text()
test = test.replace('// INCLUDE_PRODUCTION_APOLLO_ACTIONS_PREPARE', source[start:end])
(output / 'NavigationActionsPrepare.m').write_text(test)
PY

xcrun --sdk macosx clang -fobjc-arc -fobjc-exceptions -Wall -Wextra \
    -Wno-unused-parameter -framework Foundation \
    "$test_build_dir/NavigationActionsPrepare.m" -o "$test_build_dir/navigation_actions_prepare_tests"
"$test_build_dir/navigation_actions_prepare_tests"
