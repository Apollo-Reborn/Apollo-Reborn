#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
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
# New comments schedule work. A session-duplicate comment may schedule exactly
# one recovery pass for each new comments controller, so late-loaded revisits
# can restore their cards without bringing the per-scroll gather back.
require_source 'static BOOL ApolloAICaptureCommentForController' \
    'comment capture reports whether the model set changed'
require_source 'static char kApolloAIControllerPassScheduledKey;' \
    'capture-driven pass state is controller-local'
require_source 'if ([keys containsObject:key] && !objc_getAssociatedObject(vc, &kApolloAIControllerPassScheduledKey)) return YES;' \
    'the first duplicate callback on a controller schedules its recovery pass'
require_source 'if ([keys containsObject:key]) return NO;' \
    'later duplicate callbacks remain suppressed'
require_count 'if (ApolloAICaptureCommentForController(comment, vc)) {' 2 \
    'controller and cell-node capture paths gate scheduling on capture policy'
require_count 'ApolloAICaptureCommentCellNodeLater((id)self);' 2 \
    'both cell-node lifecycle hooks share the gated capture path'
require_count 'BOOL controllerHadPass = objc_getAssociatedObject(vc, &kApolloAIControllerPassScheduledKey) != nil;' 1 \
    'the scheduler distinguishes a controller first pass from later passes'
require_count 'if (sEnableTapToSummarize && controllerHadPass) {' 1 \
    'the idle tap-card guard applies only after a controller first pass'
require_source 'ApolloAIGetBoxState(headerNode, NO) == ApolloAIBoxStateTapToSummarize' \
    'an existing idle discussion card suppresses repeat gathers'
require_source 'objc_setAssociatedObject(vc, &kApolloAIControllerPassScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);' \
    'a scheduled capture pass marks only its controller'
require_count 'if (ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateTapToSummarize, nil)) {' 1 \
    'post idle state remeasures only on a real transition'
require_count 'if (ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateTapToSummarize, nil)) {' 1 \
    'comment idle state remeasures only on a real transition'

# Behavior model for the two decisions above. Keep this explicit rather than
# relying only on source strings: it proves the intended state transitions for
# a revisit, steady-state scrolling, tap mode, and two controllers showing the
# same post. The source assertions keep the model tied to the shipping gates.
controller_a_had_pass=false
controller_b_had_pass=false

capture_duplicate() {
    controller=$1
    case "$controller" in
        controller_a) [ "$controller_a_had_pass" = false ] ;;
        controller_b) [ "$controller_b_had_pass" = false ] ;;
        *) return 2 ;;
    esac
}

schedule_pass() {
    controller=$1
    tap_mode=$2
    idle_card=$3
    case "$controller" in
        controller_a) had_pass=$controller_a_had_pass ;;
        controller_b) had_pass=$controller_b_had_pass ;;
        *) return 2 ;;
    esac
    if [ "$tap_mode" = true ] && [ "$had_pass" = true ] && [ "$idle_card" = true ]; then
        return 1
    fi
    case "$controller" in
        controller_a) controller_a_had_pass=true ;;
        controller_b) controller_b_had_pass=true ;;
    esac
    return 0
}

capture_duplicate controller_a || {
    echo 'FAIL: first duplicate callback must request a recovery pass' >&2
    exit 1
}
schedule_pass controller_a true true || {
    echo 'FAIL: controller first pass must bypass the idle tap-card guard' >&2
    exit 1
}
if capture_duplicate controller_a; then
    echo 'FAIL: duplicate callbacks after the controller first pass must be suppressed' >&2
    exit 1
fi
if schedule_pass controller_a true true; then
    echo 'FAIL: an idle tap card must suppress later passes until the user taps' >&2
    exit 1
fi
capture_duplicate controller_b || {
    echo 'FAIL: one controller pass must not suppress another controller' >&2
    exit 1
}
schedule_pass controller_b true true || {
    echo 'FAIL: a second controller must receive its own first recovery pass' >&2
    exit 1
}

echo 'ai_summary_scroll_churn_regression_check passed'
