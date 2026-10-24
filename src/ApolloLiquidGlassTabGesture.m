#import "ApolloLiquidGlassTabGesture.h"

ApolloLiquidGlassTabGestureDecision
ApolloLiquidGlassTabGestureDecisionForTranslation(CGVector translation,
                                                   BOOL applicationActive,
                                                   BOOL touchCancelled) {
    if (!applicationActive || touchCancelled) {
        return ApolloLiquidGlassTabGestureDecisionPreserveSelection;
    }

    const CGFloat intentThreshold = 8.0;
    CGFloat horizontal = fabs(translation.dx);
    CGFloat vertical = fabs(translation.dy);
    if (MAX(horizontal, vertical) < intentThreshold) {
        return ApolloLiquidGlassTabGestureDecisionPending;
    }
    return vertical > horizontal
        ? ApolloLiquidGlassTabGestureDecisionPreserveSelection
        : ApolloLiquidGlassTabGestureDecisionAllowHorizontal;
}

BOOL ApolloLiquidGlassTabGestureNeedsLifecycleCleanup(BOOL tabControllerAvailable,
                                                       BOOL startingSelectionAvailable) {
    return tabControllerAvailable && startingSelectionAvailable;
}

BOOL ApolloLiquidGlassTabGestureCanClearLifecycleState(NSUInteger scheduledGeneration,
                                                        NSUInteger currentGeneration,
                                                        BOOL applicationActive) {
    return applicationActive && scheduledGeneration == currentGeneration;
}

BOOL ApolloLiquidGlassTabGestureShouldBlockSelection(BOOL preservationArmed,
                                                       BOOL matchingTabController,
                                                       BOOL selectsStartingTab,
                                                       BOOL explicitNavigation) {
    return preservationArmed && matchingTabController && !selectsStartingTab
        && !explicitNavigation;
}

BOOL ApolloLiquidGlassTabBarFrameIsBottom(CGRect tabBarFrame, CGRect windowBounds) {
    if (CGRectIsEmpty(tabBarFrame) || CGRectIsEmpty(windowBounds)) return NO;

    CGFloat tabWidth = CGRectGetWidth(tabBarFrame);
    CGFloat tabHeight = CGRectGetHeight(tabBarFrame);
    CGFloat windowWidth = CGRectGetWidth(windowBounds);
    CGFloat bottomTolerance = MAX(8.0, tabHeight * 0.5);
    return tabWidth > tabHeight && tabWidth >= windowWidth * 0.5
        && CGRectGetMidY(tabBarFrame) > CGRectGetMidY(windowBounds)
        && CGRectGetMaxY(tabBarFrame) >= CGRectGetMaxY(windowBounds) - bottomTolerance;
}
