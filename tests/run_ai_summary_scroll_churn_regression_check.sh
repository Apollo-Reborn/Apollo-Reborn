#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$test_root/src/ApolloAISummary.xm"

require_source() {
    pattern=$1
    description=$2
    if ! grep -F "$pattern" "$source_file" >/dev/null; then
        echo "FAIL: $description" >&2
        exit 1
    fi
}

require_count() {
    pattern=$1
    expected=$2
    description=$3
    actual=$(grep -F -c "$pattern" "$source_file" || true)
    if [ "$actual" -ne "$expected" ]; then
        echo "FAIL: $description (expected $expected, found $actual)" >&2
        exit 1
    fi
}

# Texture calls didLoad/preload/model-update paths repeatedly while scrolling.
# Only a newly captured comment may schedule another gather, and an installed
# tap-to-summarize card must remain idle until the user actually taps it.
require_source 'static BOOL ApolloAICaptureCommentForController' \
    'comment capture reports whether the model set changed'
require_source 'if ([keys containsObject:key]) return NO;' \
    'duplicate comments do not look like new work'
require_count 'if (ApolloAICaptureCommentForController(comment, vc)) {' 4 \
    'all four lifecycle capture paths gate scheduling on a new comment'
require_source 'ApolloAIGetBoxState(headerNode, NO) == ApolloAIBoxStateTapToSummarize' \
    'an existing idle discussion card suppresses repeat gathers'
require_count 'if (ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateTapToSummarize, nil)) {' 1 \
    'post idle state remeasures only on a real transition'
require_count 'if (ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateTapToSummarize, nil)) {' 1 \
    'comment idle state remeasures only on a real transition'

echo 'ai_summary_scroll_churn_regression_check passed'
