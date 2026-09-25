#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$test_root/src/ApolloDeletedCommentsUI.xm"

require_source() {
    pattern=$1
    description=$2
    if ! grep -F "$pattern" "$source_file" >/dev/null; then
        echo "FAIL: $description" >&2
        exit 1
    fi
}

# A deleted-comment tint is a background treatment. It must never be promoted
# above Apollo's text nodes, and recovered bodies must not inherit the dark
# foreground used by the native deleted placeholder.
# This source regression check does not render UI or verify runtime contrast.
require_source '[cellView insertSubview:highlight atIndex:0];' \
    'deleted-comment tint is inserted behind cell content'
require_source '[cellView sendSubviewToBack:highlight];' \
    'reused deleted-comment tint stays behind cell content'
require_source 'static UIColor *ApolloDeletedCommentsBodyTextColor(void)' \
    'recovered bodies have a dedicated semantic text-color resolver'
require_source 'UIColor *color = ApolloThemeSettingsTextColor();' \
    'body text color follows the effective Apollo theme settings'
require_source 'attributes[NSForegroundColorAttributeName] = ApolloDeletedCommentsBodyTextColor();' \
    'native placeholder foreground is replaced before body rendering'
require_source 'addObserverForName:@"com.christianselig.ApolloSpecificThemeChanged"' \
    'runtime Apollo theme changes are observed'
require_source 'static void ApolloDeletedCommentsCaptureAppStyle(void)' \
    'the active app interface style has a dedicated capture path'
require_source 'static void ApolloDeletedCommentsRebuildVisibleRecoveredBodies(void)' \
    'visible recovered bodies have a dedicated rebuild path'
require_source 'if (first || previous != sApolloDeletedCommentsAppStyle) ApolloDeletedCommentsRebuildVisibleRecoveredBodies();' \
    'runtime theme changes rebuild bodies after the app style is captured'

echo 'deleted_comments_source_regression_check passed'
