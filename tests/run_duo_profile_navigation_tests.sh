#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-profile.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Extract the shipping decisions, not a second implementation of the policy.
# UIKit containment and animation are doubled by the Foundation-only harness.
# An optional source path supports checking the regression against an old rev.
python3 - "$test_repo_root" "$test_build_dir" "${1:-$test_repo_root/src/ApolloDuoSplitView.xm}" <<'PY'
from pathlib import Path
import sys

root, output, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()

def section(start, end):
    return source.split(start, 1)[1].split(end, 1)[0]

promotion = section('    NSArray *stack = [outer.viewControllers copy];', '    NSArray *detail = stack.count')
update = section('        BOOL postsOpen =', '            // Search stays full-width')
routing = section('static BOOL ApolloDuoSplitRoutePush(', '    if (state.feed && !state.changing) {')
# Older prefixes used animated only in the unextracted generic routing tail.
routing = routing.replace('BOOL animated) {', '__unused BOOL animated) {', 1)
test = (root / 'tests/duo_profile_navigation_tests.m').read_text()
test = test.replace('// INCLUDE_PRODUCTION_PROFILE_PROMOTION', promotion)
test = test.replace('// INCLUDE_PRODUCTION_UPDATE_DECISION', 'BOOL postsOpen =' + update + '\n    }')
test = test.replace('// INCLUDE_PRODUCTION_PROFILE_ROUTING',
                    'static BOOL ApolloDuoSplitRoutePush(' + routing + '\n    return NO;\n}')
(output / 'DuoProfileNavigation.m').write_text(test)
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$test_build_dir/DuoProfileNavigation.m" -o "$test_build_dir/duo_profile_navigation_tests"
"$test_build_dir/duo_profile_navigation_tests"
