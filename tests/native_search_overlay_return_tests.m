#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static NSUInteger checks = 0;

static void Require(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Require(NSBShouldKeepCollapsedAfterOverlayReturn(YES, NO, 0.0, -116.0, 116.0),
                @"an unmatched overlay return preserves a fully collapsed bar at its rest");
        Require(NSBShouldKeepCollapsedAfterOverlayReturn(YES, NO, 0.0, -114.1, 116.0),
                @"the collapsed-rest tolerance covers UIKit settling noise");

        Require(!NSBShouldKeepCollapsedAfterOverlayReturn(NO, NO, 0.0, -116.0, 116.0),
                @"a normal navigation appearance still uses its recorded departure state");
        Require(!NSBShouldKeepCollapsedAfterOverlayReturn(YES, YES, 0.0, -116.0, 116.0),
                @"an active search is never treated as resting collapsed chrome");
        Require(!NSBShouldKeepCollapsedAfterOverlayReturn(YES, NO, 60.0, -116.0, 116.0),
                @"a revealed search bar remains eligible for normal appearance handling");
        Require(!NSBShouldKeepCollapsedAfterOverlayReturn(YES, NO, 0.0, -108.0, 116.0),
                @"a list below the collapsed rest is not mistaken for the issue state");
        Require(!NSBShouldKeepCollapsedAfterOverlayReturn(YES, NO, 0.0, -124.0, 116.0),
                @"an overscrolled list is not mistaken for the issue state");

        printf("native search overlay return: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
