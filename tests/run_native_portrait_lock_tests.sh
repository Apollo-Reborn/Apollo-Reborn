#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-native-portrait-lock.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM

# Execute production helper/method bodies against Foundation-only UIKit doubles.
# Only Logos dispatch syntax and imports are translated; policy is not duplicated.
python3 - "$root" "$build" "${1:-$root/src/ApolloPortraitLock.xm}" <<'PY'
from pathlib import Path
import re
import sys
root, build, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
source = re.sub(r'^#import[^\n]*\n', '', source, flags=re.M)
source = source.replace('%hook _TtC6Apollo22RotationOfferingButton', '@implementation TestRotationButton')
source = source.replace('%hook _TtC6Apollo21MediaViewerController', '@implementation TestMediaViewer')
source = source.replace('%end', '@end')
source = source.replace('%orig(suppressed ? 0.0 : alpha);', '[super setAlpha:(suppressed ? 0.0 : alpha)];')
source = source.replace('%orig(size, coordinator);', '[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];')
# Remaining %orig calls have no explicit arguments in production.
method = None
out = []
for line in source.splitlines():
    if line.startswith('- (void)'):
        method = line
    if '%orig;' in line:
        if 'didMoveToSuperview' in method:
            call = '[super didMoveToSuperview];'
        elif 'viewDidAppear:' in method:
            call = '[super viewDidAppear:animated];'
        elif 'viewDidLayoutSubviews' in method:
            call = '[super viewDidLayoutSubviews];'
        elif 'rotationOfferingButtonTappedWithSender:' in method:
            call = '[super rotationOfferingButtonTappedWithSender:sender];'
        else:
            raise AssertionError(f'unhandled production method: {method}')
        line = line.replace('%orig;', call)
    out.append(line)
source = '\n'.join(out)
assert '%' not in source, 'untranslated Logos syntax'
fixture = (root / 'tests/native_portrait_lock_tests.m').read_text()
marker = '// INSERT_PRODUCTION_NATIVE_PORTRAIT_LOCK'
assert fixture.count(marker) == 1
(build / 'tests.m').write_text(fixture.replace(marker, source))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -Wno-unused-parameter -fsanitize=address,undefined -framework Foundation \
    "$build/tests.m" -o "$build/tests"
"$build/tests"
