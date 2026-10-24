#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-native-menu-source.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloNativeActionMenus.xm').read_text()
start = source.index('static UIView *ApolloNativeActionMenuResolveSourceView(')
end = source.index('\n}', start) + 2
test = (root / 'tests/native_menu_source_tests.m').read_text()
test = test.replace('// INCLUDE_PRODUCTION_SOURCE_RESOLVER', source[start:end])
actions = (root / 'src/ApolloNavigationActions.xm').read_text()
start = actions.index('- (BOOL)collapseEnabled {')
end = actions.index('\n}', start) + 2
test = test.replace('// INCLUDE_PRODUCTION_COLLAPSE_POLICY', actions[start:end])
def function(start_text):
    begin = actions.index(start_text)
    return actions[begin:actions.index('\n}', begin) + 2]
visibility = function('static inline BOOL ApolloActionsBarItemHidden(')
visibility += '\n' + function('static void ApolloActionsRestoreDuoOverflow(UINavigationItem *item) {')
begin = actions.index('    for (UIBarButtonItem *entry in controls) {')
end = actions.index('    objc_setAssociatedObject(item, &kActionsDuoOverflowItemsKey, controls', begin)
visibility += '\nstatic void ApolloTestHideOverflowControls(NSArray *controls) {\n' + actions[begin:end] + '\n}'
test = test.replace('// INCLUDE_PRODUCTION_OVERFLOW_VISIBILITY', visibility)
dispatch = function('static BOOL ApolloActionsMoreName(') + '\n' + function('static UIBarButtonItem *ApolloActionsFindMoreItem(')
dispatch += '\n' + function('static NSString *ApolloActionsItemTitle(')
dispatch += '\n' + function('static void ApolloActionsInvokeItem(') + '\n' + function('static UIMenu *ApolloActionsMenuForItem(')
test = test.replace('// INCLUDE_PRODUCTION_ITEM_DISPATCH', dispatch)
test = test.replace('// INCLUDE_PRODUCTION_OVERFLOW_ELEMENTS', function('static NSArray<UIMenuElement *> *ApolloActionsOverflowElements('))
test = test.replace('// INCLUDE_PRODUCTION_RAIL_POLICY', function('static BOOL ApolloActionsUsesDuoOverflow('))
begin = actions.index('- (void)setHidden:(BOOL)hidden {')
setter = actions[begin:actions.index('\n}', begin) + 2].replace('%orig(', '_hidden = (')
(output / 'test.m').write_text(test.replace('// INCLUDE_PRODUCTION_HIDDEN_SETTER', setter))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation "$test_build_dir/test.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
