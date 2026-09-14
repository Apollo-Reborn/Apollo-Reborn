#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
if [ ! -f "$test_logos" ]; then
    printf 'Logos not found at %s; set THEOS or LOGOS.\n' "$test_logos" >&2
    exit 1
fi
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-find-in-comments.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Compile the actual production installer and hook with both generators. Only
# their UIKit-independent section is extracted; no hand-maintained hook copy.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloFindInComments.xm').read_text()
state_start = source.index('static BOOL sFICMultiActive')
state_end = source.index('// MARK: - helpers', state_start)
hook_start = source.index('// MARK: - hooks: multi-term matching')
hook_end = source.index('// MARK: - hooks: selection entry points', hook_start)
prefix = '#import <Foundation/Foundation.h>\n#import <objc/runtime.h>\n#import <objc/message.h>\n'
test_source = prefix + source[state_start:state_end] + source[hook_start:hook_end]
test_source += '\n' + (root / 'tests/find_in_comments_hook_tests.m').read_text()
(output / 'FindInCommentsHook.xm').write_text(test_source)
(output / 'substrate.h').write_text(
    '#import <objc/runtime.h>\n'
    'void MSHookMessageEx(Class, SEL, IMP, IMP *);\n')
PY

for test_generator in MobileSubstrate internal; do
    test_substrate=0
    if [ "$test_generator" = MobileSubstrate ]; then test_substrate=1; fi
    perl "$test_logos" -c "generator=$test_generator" \
        "$test_build_dir/FindInCommentsHook.xm" > "$test_build_dir/FindInCommentsHook.mm"
    xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -DFIC_TEST_SUBSTRATE="$test_substrate" -framework Foundation \
        -I "$test_build_dir" "$test_build_dir/FindInCommentsHook.mm" \
        -o "$test_build_dir/find_in_comments_hook_tests"
    "$test_build_dir/find_in_comments_hook_tests"
done
