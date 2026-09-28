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
require_source '@synchronized(node) {' \
    'separator transition is atomic across Texture and main-queue callers'
require_source 'ApolloPFHeightSnapshot snapshot = {0};' \
    'normal separator dimensions are captured before collapse'
require_source 'ApolloPFWriteDimension(style, @selector(setHeight:), snapshot.height);' \
    'normal separator height is restored after reuse'
require_source 'SEL selector = NSSelectorFromString(@"nodeForRowAtIndexPath:");' \
    'a changed post targets only its trailing separator'
require_source 'BOOL had = [set containsObject:postPath];' \
    'hidden post identity retains its table section'
require_source 'NSUInteger indexes[] = {section, row - 1};' \
    'separator lookup cannot inherit hidden state from another section'
require_source '- (void)didEnterPreloadState {' \
    'preloaded separators reconcile after concurrent post measurement'
require_source '- (void)didEnterDisplayState {' \
    'displayed separators get a final race-safe reconciliation'
reject_source '@selector(relayoutItems)' \
    'separator repair no longer performs a table-wide synchronous relayout'

echo 'post_filter_separator_regression_check passed'
