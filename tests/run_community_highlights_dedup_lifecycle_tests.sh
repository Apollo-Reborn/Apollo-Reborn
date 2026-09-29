#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-highlights-lifecycle.XXXXXX")
trap 'rm -rf -- "$test_build"' EXIT HUP INT TERM

python3 - "$test_root" "$test_build" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/ApolloSubredditHighlights.xm").read_text()
start = source.index("static void ApolloHLClearTableDeDupState(")
end = source.index("UIView *ApolloHLUnwrapManagedHeader(", start)
prefix = """#import <Foundation/Foundation.h>
#import <objc/runtime.h>
@class UIViewController;
static const void *kApolloHLActiveSubKey = &kApolloHLActiveSubKey;
static char kApolloHLHiddenRowsKey;
static char kApolloHLDeDupSubKey;
static char kApolloHLStickyCountKey;
static char kApolloHLFeedOwnedMaskKey;
static id ApolloHLTypedIvar(id object, NSString *name, Class expectedClass);
static void ApolloHLHideSubsAdd(NSString *sub);
static void ApolloHLHideSubsRemove(NSString *sub);
static void ApolloHLDidCollapseRemove(NSString *sub);
"""
(output / "dedup_lifecycle_tests.m").write_text(
    prefix + source[start:end] +
    (root / "tests/community_highlights_dedup_lifecycle_tests.m").read_text()
)
PY

xcrun --sdk macosx clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
    -framework Foundation "$test_build/dedup_lifecycle_tests.m" \
    -o "$test_build/dedup_lifecycle_tests"
"$test_build/dedup_lifecycle_tests"
