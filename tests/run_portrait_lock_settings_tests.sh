#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-portrait-lock-settings.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
python3 - "$root" "$build" <<'PY'
from pathlib import Path
import re
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/settings/ApolloSettings.xm').read_text()
fixture = (root / 'tests/portrait_lock_settings_tests.m').read_text()
helper = re.search(r'static NSString \*ApolloPortraitLockFooterText\(.*?\n}', source, re.S)
start = source.index('%hook SettingsPortraitLockViewController')
hook = source[start:source.index('%end', start)]
# An unmodified checkout has only viewDidLoad. Run native behavior there too,
# so the regression fails on behavior rather than a missing helper/build error.
start = hook.find('- (NSString *)tableView:')
hook = hook[start:] if start >= 0 else ''
# Compile the real method bodies; only replace Logos dispatch with super dispatch.
signatures = [
    ('- (NSString *)tableView:', '[super tableView:tableView titleForFooterInSection:section]'),
    ('- (UIView *)tableView:', '[super tableView:tableView viewForFooterInSection:section]'),
    ('- (CGFloat)tableView:', '[super tableView:tableView heightForFooterInSection:section]'),
    ('- (void)tableView:', '[super tableView:tableView willDisplayFooterView:view forSection:section]'),
]
methods = []
for signature, orig in signatures:
    begin = hook.find(signature)
    if begin >= 0:
        end = hook.index('\n}', begin) + 2
        methods.append(hook[begin:end].replace('%orig', orig))
# This hook owns explanations only, never row/switch/defaults mutations or a remapper.
for forbidden in ['NSUserDefaults', 'setEnabled:', 'setOn:', 'numberOfRowsInSection', 'cellForRowAtIndexPath', 'indexPathForRow']:
    assert forbidden not in hook, 'Footer hook must not touch preferences/rows: ' + forbidden
fixture = fixture.replace('// INCLUDE_PRODUCTION_HELPER', helper.group() if helper else '')
fixture = fixture.replace('// INCLUDE_PRODUCTION_HOOKS', '\n\n'.join(methods))
(build / 'portrait_lock_settings_tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$build/portrait_lock_settings_tests.m" -o "$build/portrait_lock_settings_tests"
"$build/portrait_lock_settings_tests"
