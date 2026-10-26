#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-comment-header-shift.XXXXXX")
trap 'rm -rf "$build"' EXIT INT TERM

# The shipping src/ApolloCommentHeaderShift.m, built for the Mac against
# Texture stand-ins (tests/comment_header_shift_tests.m). Only the few UIKit
# types its headers name are doubled.
mkdir -p "$build/stub/UIKit"
cat > "$build/stub/UIKit/UIKit.h" <<'H'
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
typedef struct UIEdgeInsets { CGFloat top, left, bottom, right; } UIEdgeInsets;
static inline UIEdgeInsets UIEdgeInsetsMake(CGFloat top, CGFloat left, CGFloat bottom, CGFloat right) {
    UIEdgeInsets insets = {top, left, bottom, right};
    return insets;
}
typedef NS_ENUM(NSInteger, NSLineBreakMode) { NSLineBreakByWordWrapping = 0 };
@interface UIView : NSObject
@end
@interface UIColor : NSObject
@end
H

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -I "$build/stub" -I "$test_root/src" \
    -framework Foundation -framework CoreGraphics \
    "$test_root/src/ApolloCommentHeaderShift.m" \
    "$test_root/tests/comment_header_shift_tests.m" \
    -o "$build/comment-header-shift-tests"
"$build/comment-header-shift-tests"
