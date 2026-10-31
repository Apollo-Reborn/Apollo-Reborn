#!/bin/sh
set -eu

# Build the All+ boost slider (ApolloAPSlider, extracted from
# src/settings/CustomAPIViewController.m) as a macOS executable over the
# Foundation-only UIKit doubles in tests/allplus_slider_tests.m, and check that
# its ancestor gestures come back after taps, drags and cancels. An optional
# source path checks an older revision.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-allplus-slider-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root" "$test_build_dir" \
    "${1:-$test_repo_root/src/settings/CustomAPIViewController.m}" <<'PY'
from pathlib import Path
import sys

root, out, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
start = source.index('@interface ApolloAPSlider : UISlider')
body = source.index('@implementation ApolloAPSlider', start)
slider = source[start:source.index('\n@end', body) + len('\n@end')]
fixture = (root / 'tests/allplus_slider_tests.m').read_text()
marker = '// INSERT_PRODUCTION_SLIDER'
assert fixture.count(marker) == 1, 'slider fixture insertion marker missing or duplicated'
(out / 'tests.m').write_text(fixture.replace(marker, slider))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$test_build_dir/tests.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
