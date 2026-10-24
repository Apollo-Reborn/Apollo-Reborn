#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-menu-anchor.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloNativeActionMenus.xm').read_text()
begin = source.index('static UIView *ApolloNativeActionMenuResolveSourceView(')
end = source.index('\n}', begin) + 2
test = (root / 'tests/native_menu_anchor_tests.m').read_text()
(output / 'test.m').write_text(test.replace('// INCLUDE_PRODUCTION_SOURCE_RESOLVER', source[begin:end]))
PY
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation "$test_build_dir/test.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
