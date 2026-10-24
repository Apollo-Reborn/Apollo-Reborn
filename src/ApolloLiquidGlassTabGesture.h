#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ApolloLiquidGlassTabGestureDecision) {
    ApolloLiquidGlassTabGestureDecisionPending,
    ApolloLiquidGlassTabGestureDecisionAllowHorizontal,
    ApolloLiquidGlassTabGestureDecisionPreserveSelection,
};

FOUNDATION_EXPORT ApolloLiquidGlassTabGestureDecision
ApolloLiquidGlassTabGestureDecisionForTranslation(CGVector translation,
                                                   BOOL applicationActive,
                                                   BOOL touchCancelled);

FOUNDATION_EXPORT BOOL
ApolloLiquidGlassTabGestureNeedsLifecycleCleanup(BOOL tabControllerAvailable,
                                                  BOOL startingSelectionAvailable);

FOUNDATION_EXPORT BOOL
ApolloLiquidGlassTabBarFrameIsBottom(CGRect tabBarFrame, CGRect windowBounds);
