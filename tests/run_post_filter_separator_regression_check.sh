#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$test_root/src/ApolloPostFilters.xm"

require_source() {
    pattern=$1
    description=$2
    if ! grep -F -- "$pattern" "$source_file" >/dev/null; then
        echo "FAIL: $description" >&2
        exit 1
    fi
}

reject_source() {
    pattern=$1
    description=$2
    if grep -F -- "$pattern" "$source_file" >/dev/null; then
        echo "FAIL: $description" >&2
        exit 1
    fi
}

require_source 'static BOOL ApolloPFSetNodeCollapsed(id node, BOOL collapsed)' \
    'separator collapse has a reversible state transition'
require_source 'ApolloPFSetNodeCollapsedLocked(node, collapsed)' \
    'separator transition uses a helper while holding Texture node lock'
require_source '((void (*)(id, SEL))objc_msgSend)(node, @selector(lock));' \
    'separator transition enters the Texture recursive node lock'
require_source '} @finally {' \
    'separator transition guarantees Texture node unlock'
require_source '((void (*)(id, SEL))objc_msgSend)(node, @selector(unlock));' \
    'separator transition releases the Texture recursive node lock'
reject_source '@synchronized(node)' \
    'separator transition does not introduce a second node lock order'
require_source 'ApolloPFHeightSnapshot snapshot = {};' \
    'normal separator dimensions are captured before collapse'
reject_source 'ApolloPFHeightSnapshot snapshot = {0};' \
    'Objective-C++ snapshot initialization does not trigger missing-braces errors'
require_source 'ApolloPFWriteDimension(style, @selector(setHeight:), snapshot.height);' \
    'normal separator height is restored after reuse'
require_source 'SEL selector = @selector(nodeForRowAtIndexPath:);' \
    'a changed post targets only its trailing separator'
require_source 'BOOL had = [set containsObject:postPath];' \
    'hidden post identity retains its table section'
require_source 'NSUInteger indexes[] = {section, row - 1};' \
    'separator lookup cannot inherit hidden state from another section'
require_source '- (void)didEnterPreloadState {' \
    'preloaded separators reconcile after concurrent post measurement'
require_source '- (void)didEnterDisplayState {' \
    'displayed separators get a final race-safe reconciliation'
require_source 'if (ApolloPFNodeIsCollapsed(self)) {' \
    'layoutSpecThatFits follows the decision already made for this layout pass'
require_source 'static BOOL ApolloPFSeparatorShouldCollapseOnMain(id separatorNode)' \
    'main-queue reconciliation reads the current table geometry'
require_source 'id postNode = ((id (*)(id, SEL, id))objc_msgSend)(owning, nodeSelector, postPath);' \
    'main-queue reconciliation resolves the actual preceding node'
require_source 'ApolloPFCellShouldHide(postNode);' \
    'main-queue reconciliation derives truth from the preceding post model'
require_source 'if (hidden) [set addObject:[postPath copy]];' \
    'current hidden truth resynchronizes the row-keyed set'
require_source 'ApolloPFSeparatorShouldCollapseOnMain(separatorNode)' \
    'separator refresh uses current main-queue truth after row deletions'
reject_source 'static NSInteger ApolloPFNodeRow(id cellNode)' \
    'removed row-only helper stays deleted'
reject_source '@selector(relayoutItems)' \
    'separator repair no longer performs a table-wide synchronous relayout'

collapse_writes=$(grep -Fc 'ApolloPFSetNodeCollapsed(self, collapse);' "$source_file")
if [ "$collapse_writes" -ne 1 ]; then
    echo 'FAIL: exactly calculateLayoutThatFits may decide separator collapse per pass' >&2
    exit 1
fi

echo 'post_filter_separator_regression_check passed'
