#!/bin/sh
set -eu
jump_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
jump_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
jump_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-comment-jump.XXXXXX")
trap 'rm -rf "$jump_build"' EXIT HUP INT TERM
python3 - "$jump_root" "$jump_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSearchNativeBar.xm').read_text()
start = source.index('// MARK: - Comment jump lookup')
end = source.index('// MARK: - End comment jump lookup', start)
hooks = source[start:end] + '\nstatic void InstallJumpHooks(void) {\n%init;\n}\n'
fixture = (root / 'tests/comment_jump_tests.m').read_text()
(build / 'Jump.xm').write_text(fixture.replace('// PRODUCTION_HOOKS', hooks))
(build / 'substrate.h').write_text('#import <objc/runtime.h>\nvoid MSHookMessageEx(Class, SEL, IMP, IMP *);\n')
PY
for jump_generator in internal MobileSubstrate; do
    perl "$jump_logos" -c "generator=$jump_generator" "$jump_build/Jump.xm" > "$jump_build/Jump.mm"
    xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -framework Foundation -framework CoreGraphics -I "$jump_build" \
        "$jump_build/Jump.mm" -o "$jump_build/jump-tests"
    "$jump_build/jump-tests"
done
