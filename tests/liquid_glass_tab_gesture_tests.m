#import <Foundation/Foundation.h>
#import "ApolloLiquidGlassTabGesture.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"LiquidGlassTabGestureTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

int main(void) {
    @autoreleasepool {
        Require(ApolloLiquidGlassTabGestureDecisionForTranslation(CGVectorMake(2.0, -5.0), YES, NO)
                    == ApolloLiquidGlassTabGestureDecisionPending,
                @"small movement stays pending so taps still work");
        Require(ApolloLiquidGlassTabGestureDecisionForTranslation(CGVectorMake(6.0, -60.0), YES, NO)
                    == ApolloLiquidGlassTabGestureDecisionPreserveSelection,
                @"an upward Home gesture with sideways drift preserves the starting tab");
        Require(ApolloLiquidGlassTabGestureDecisionForTranslation(CGVectorMake(-5.0, 40.0), YES, NO)
                    == ApolloLiquidGlassTabGestureDecisionPreserveSelection,
                @"vertical movement in either direction is not tab navigation");
        Require(ApolloLiquidGlassTabGestureDecisionForTranslation(CGVectorMake(60.0, -6.0), YES, NO)
                    == ApolloLiquidGlassTabGestureDecisionAllowHorizontal,
                @"an active horizontal drag keeps native Liquid Lens tab switching");
        Require(ApolloLiquidGlassTabGestureDecisionForTranslation(CGVectorMake(60.0, -6.0), NO, NO)
                    == ApolloLiquidGlassTabGestureDecisionPreserveSelection,
                @"app inactivity preserves the starting tab even after horizontal movement");
        Require(ApolloLiquidGlassTabGestureDecisionForTranslation(CGVectorMake(60.0, -6.0), YES, YES)
                    == ApolloLiquidGlassTabGestureDecisionPreserveSelection,
                @"a cancelled drag preserves the starting tab");
        Require(ApolloLiquidGlassTabGestureNeedsLifecycleCleanup(YES, YES),
                @"reactivation cleanup depends on tracked selection state, not a live weak touch");
        Require(!ApolloLiquidGlassTabGestureNeedsLifecycleCleanup(NO, YES),
                @"cleanup does not run without a tracked tab controller");
        Require(ApolloLiquidGlassTabGestureCanClearLifecycleState(7, 7, YES),
                @"the matching active gesture generation may clear lifecycle state");
        Require(!ApolloLiquidGlassTabGestureCanClearLifecycleState(7, 8, YES),
                @"a delayed callback cannot clear a newer gesture's state");
        Require(!ApolloLiquidGlassTabGestureCanClearLifecycleState(7, 7, NO),
                @"cleanup waits while the app is inactive");
        Require(ApolloLiquidGlassTabGestureShouldBlockSelection(YES, YES, NO, NO),
                @"a rejected Liquid Lens gesture blocks its own nonstarting selection");
        Require(!ApolloLiquidGlassTabGestureShouldBlockSelection(YES, YES, NO, YES),
                @"an explicit warm navigation may select another tab during gesture cleanup");
        Require(!ApolloLiquidGlassTabGestureShouldBlockSelection(YES, YES, YES, NO),
                @"restoring the starting tab remains allowed");
        Require(!ApolloLiquidGlassTabGestureShouldBlockSelection(YES, NO, NO, NO),
                @"another tab controller is outside the tracked gesture");
        Require(ApolloLiquidGlassTabBarFrameIsBottom(CGRectMake(0.0, 760.0, 390.0, 84.0),
                                                      CGRectMake(0.0, 0.0, 390.0, 844.0)),
                @"an iPhone bottom tab bar is eligible");
        Require(ApolloLiquidGlassTabBarFrameIsBottom(CGRectMake(0.0, 1260.0, 1024.0, 106.0),
                                                      CGRectMake(0.0, 0.0, 1024.0, 1366.0)),
                @"an iPad bottom tab bar is eligible");
        Require(!ApolloLiquidGlassTabBarFrameIsBottom(CGRectMake(0.0, 0.0, 96.0, 1366.0),
                                                       CGRectMake(0.0, 0.0, 1024.0, 1366.0)),
                @"an iPad sidebar tab bar is outside the fix");
        Require(!ApolloLiquidGlassTabBarFrameIsBottom(CGRectMake(0.0, 0.0, 1024.0, 96.0),
                                                       CGRectMake(0.0, 0.0, 1024.0, 1366.0)),
                @"a top tab bar is outside the fix");
    }
    puts("liquid glass tab gesture tests passed");
    return 0;
}
