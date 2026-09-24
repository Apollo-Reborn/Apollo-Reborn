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
require_source '[cellView insertSubview:highlight atIndex:0];' \
    'deleted-comment tint is inserted behind cell content'
require_source '[cellView sendSubviewToBack:highlight];' \
    'reused deleted-comment tint stays behind cell content'
require_source 'static UIColor *ApolloDeletedCommentsBodyTextColor(void)' \
    'recovered bodies have a dedicated semantic text-color resolver'
require_source 'ApolloThemeRuntimeColor(ApolloThemeTokenLabel)' \
    'body text color follows the active Apollo theme label token'
require_source 'attributes[NSForegroundColorAttributeName] = ApolloDeletedCommentsBodyTextColor();' \
    'native placeholder foreground is replaced before body rendering'

echo 'deleted_comments_visual_test passed'
