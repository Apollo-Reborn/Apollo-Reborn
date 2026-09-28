#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-post-filter-separator.XXXXXX")
trap 'rm -rf -- "$test_build"' EXIT HUP INT TERM

python3 - "$test_root" "$test_build" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/ApolloPostFilters.xm").read_text()
start = source.index("typedef struct { NSInteger unit; CGFloat value; } ApolloPFDim;")
end = source.index("#pragma mark - Trailing-separator collapse", start)
prefix = (
    "#import <Foundation/Foundation.h>\n"
    "#import <objc/message.h>\n"
    "#import <objc/runtime.h>\n"
    "#import <math.h>\n"
)
(output / "separator_state_tests.mm").write_text(
    prefix + source[start:end] + (root / "tests/post_filter_separator_state_tests.m").read_text()
)
PY

xcrun --sdk macosx clang++ -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -framework Foundation "$test_build/separator_state_tests.mm" \
    -o "$test_build/separator_state_tests"
"$test_build/separator_state_tests"
