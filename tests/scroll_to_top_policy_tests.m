#import <Foundation/Foundation.h>
#import "../src/ApolloScrollToTopPolicy.h"

static NSUInteger checks;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Check(ApolloScrollToTopNeedsContentTapShield(YES, YES, YES, 0.0, 24.0),
              @"the top edge is shielded while the adaptive header can minimize");
        Check(ApolloScrollToTopNeedsContentTapShield(YES, YES, YES, 24.9, 24.0),
              @"one-point tolerance covers fractional status-bar geometry");
        Check(!ApolloScrollToTopNeedsContentTapShield(YES, YES, YES, 25.1, 24.0),
              @"content below the status bar remains interactive");
        Check(!ApolloScrollToTopNeedsContentTapShield(NO, YES, YES, 10.0, 24.0),
              @"ordinary iPhones keep their existing status-bar path");
        Check(!ApolloScrollToTopNeedsContentTapShield(YES, NO, YES, 10.0, 24.0),
              @"a visible-header configuration does not add a content shield");
        Check(!ApolloScrollToTopNeedsContentTapShield(YES, YES, NO, 10.0, 24.0),
              @"an offscreen owner cannot intercept another page");
        Check(!ApolloScrollToTopNeedsContentTapShield(YES, YES, YES, -0.1, 24.0),
              @"points outside the window are rejected");
        Check(!ApolloScrollToTopNeedsContentTapShield(YES, YES, YES, 0.0, 0.0),
              @"a scene without a status bar gets no invented hit region");
    }
    printf("scroll-to-top policy tests passed (%lu checks)\n", (unsigned long)checks);
    return 0;
}
