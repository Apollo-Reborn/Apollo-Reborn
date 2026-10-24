#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-native-capture-context.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
native = (root / 'src/ApolloNativeActionMenus.xm').read_text()
actions = (root / 'src/ApolloActionMenu.xm').read_text()
layout = (root / 'src/ApolloActionMenuLayout.m').read_text()
def function(source, signature):
    begin = source.index(signature)
    return source[begin:source.index('\n}', begin) + 2]
context = '\n'.join(line for line in layout.splitlines() if line.startswith('ApolloActionMenuContext const '))
for name in ['NSArray<ApolloActionMenuContext> *ApolloActionMenuAllContexts(', 'BOOL ApolloActionMenuContextIsValid(',
             'BOOL ApolloActionMenuContextIsModerator(', 'ApolloActionMenuContext ApolloActionMenuModeratorContextFollowing(',
             'BOOL ApolloActionMenuContextIsCustomized(']:
    context += '\n' + function(layout, name)
context += '\n' + layout[layout.index('static const NSTimeInterval kApolloActionMenuArmWindow'):]
context += '\nstatic char kApolloActionMenuControllerContextKey;\n'
for name in ['static BOOL ApolloActionMenuControllerIsModeratorOnly(', 'void ApolloActionMenuCaptureContextForController(',
             'void ApolloActionMenuArmModeratorFollowUp(', 'static NSUInteger ApolloActionMenuRankForSpec(']:
    context += '\n' + function(actions, name)
begin = actions.index('static const NSUInteger kApolloActionMenuNativeElementsOffset')
end = actions.index('#pragma mark - Per-controller slot memoization', begin)
context += '\n#define dlsym FixtureDlsym\n' + actions[begin:end] + '\n#undef dlsym\n'
begin = actions.index('@interface ApolloActionMenuSlotState :')
end = actions.index('// Apollo\'s own actionsDescription Swift string', begin)
context += '\n' + actions[begin:end]
for name in ['static ApolloActionMenuSlotState *ApolloActionMenuSlotsForController(', 'void ApolloActionMenuPrepareController(']:
    context += '\n' + function(actions, name)
capture = 'static BOOL sApolloNativeCapturingController;\nstatic id sApolloNativeCapturedController;\n'
for name in ['id ApolloNativeActionMenuCaptureController(', 'static NSInteger ApolloNativeActionMenuRowForActionKind(',
             'static BOOL ApolloNativeActionMenuPerformPendingDirectAction(']:
    capture += '\n' + function(native, name)
capture += '\n' + function(actions, 'void ApolloActionMenuTagElementWithNativeKind(')
capture += '\n' + function(native, 'static UIMenu *ApolloNativeActionMenuBuildMenu(')
capture += '\n' + function(native, 'UIMenu *ApolloNativeActionMenuBuildCaptured(')
test = (root / 'tests/native_menu_capture_context_tests.m').read_text()
test = test.replace('// INCLUDE_PRODUCTION_CONTEXT_AND_PREPARATION', context)
(output / 'test.m').write_text(test.replace('// INCLUDE_PRODUCTION_CAPTURE_AND_BUILD', capture))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreFoundation \
    "$test_build_dir/test.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
