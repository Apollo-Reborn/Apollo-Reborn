#import <Foundation/Foundation.h>

@interface UIViewController : NSObject
@property (nonatomic, copy) NSString *kind;
@end
@implementation UIViewController
@end

@interface UINavigationController : UIViewController
@property (nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property (nonatomic, strong) id tabBarController;
@property (nonatomic) BOOL lastPushAnimated;
- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated;
@end
@implementation UINavigationController
- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated {
    self.viewControllers = [self.viewControllers arrayByAddingObject:page];
    self.lastPushAnimated = animated;
}
@end

@interface UISplitViewController : UIViewController
@end
@implementation UISplitViewController
@end

@interface ApolloDuoSplitHost : NSObject
@property (nonatomic) BOOL listVisible;
@property (nonatomic) BOOL lastListAnimated;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated;
@end
@implementation ApolloDuoSplitHost
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated {
    self.listVisible = visible;
    self.lastListAnimated = animated;
}
@end

@interface ApolloDuoSplitState : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *tabKind;
@property (nonatomic, strong) UIViewController *root;
@property (nonatomic, strong) UIViewController *tabRoot;
@property (nonatomic, copy) NSArray *profilePrefix;
@property (nonatomic, strong) UINavigationController *outer;
@property (nonatomic, strong) UINavigationController *primary;
@property (nonatomic, strong) UINavigationController *feed;
@property (nonatomic, strong) UINavigationController *secondary;
@property (nonatomic, strong) UISplitViewController *split;
@property (nonatomic, strong) ApolloDuoSplitHost *host;
@property (nonatomic) BOOL changing;
@end
@implementation ApolloDuoSplitState
@end

static BOOL landscape, unfolded;
static NSUInteger closes, dashboardNavigations;
static BOOL lastClosePreserved;
static ApolloDuoSplitState *currentState;
static BOOL ApolloDuoSplitShouldOpen(__unused id tabs) { return landscape; }
static BOOL ApolloDuoSplitIsUnfolded(void) { return unfolded; }
static NSString *ApolloDuoSplitKind(UIViewController *page) { return page.kind; }
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(__unused UINavigationController *nav,
                                                          __unused BOOL create) { return currentState; }
static void ApolloDuoSplitClose(__unused ApolloDuoSplitState *state, BOOL preserve) {
    closes++;
    lastClosePreserved = preserve;
}
static void ApolloDuoSplitNavigateProfile(__unused ApolloDuoSplitState *state,
                                        __unused UIViewController *page, __unused BOOL push) {
    dashboardNavigations++;
}

static NSUInteger PromoteProfile(ApolloDuoSplitState *state) {
    UINavigationController *outer = state.outer;
    NSArray *stack = outer.viewControllers;
    // INCLUDE_PRODUCTION_PROFILE_PROMOTION
    return rootIndex;
}

static void UpdateDecision(ApolloDuoSplitState *state) {
    BOOL open = ApolloDuoSplitShouldOpen(state.outer.tabBarController);
    // INCLUDE_PRODUCTION_UPDATE_DECISION
}

// INCLUDE_PRODUCTION_PROFILE_ROUTING

static NSUInteger checks, failures;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}
static UIViewController *Page(NSString *kind) {
    UIViewController *page = [UIViewController new];
    page.kind = kind;
    return page;
}
static ApolloDuoSplitState *Posts(void) {
    ApolloDuoSplitState *state = [ApolloDuoSplitState new];
    state.kind = @"subreddits";
    state.root = Page(state.kind);
    state.outer = [UINavigationController new];
    state.primary = [UINavigationController new];
    state.feed = [UINavigationController new];
    state.feed.viewControllers = @[Page(@"posts")];
    state.secondary = [UINavigationController new];
    state.secondary.viewControllers = @[];
    state.split = [UISplitViewController new];
    state.host = [ApolloDuoSplitHost new];
    state.host.listVisible = YES;
    state.outer.viewControllers = [@[state.root] arrayByAddingObjectsFromArray:state.feed.viewControllers];
    currentState = state;
    return state;
}

int main(void) {
    @autoreleasepool {
        landscape = NO;
        unfolded = YES;
        ApolloDuoSplitState *portrait = Posts();
        UIViewController *profile = Page(@"account");
        portrait.outer.viewControllers = [portrait.outer.viewControllers arrayByAddingObject:profile];
        Check(PromoteProfile(portrait) == 0, @"unfolded portrait does not promote a visited profile to dashboard root");
        Check([portrait.kind isEqualToString:@"subreddits"] && !portrait.profilePrefix,
              @"portrait retains Posts ownership instead of entering the Account collapse/reopen cycle");

        landscape = YES;
        ApolloDuoSplitState *wide = Posts();
        NSArray *prefix = wide.outer.viewControllers;
        wide.outer.viewControllers = [prefix arrayByAddingObject:profile];
        Check(PromoteProfile(wide) == 2 && wide.root == profile, @"landscape still promotes the visited profile");
        Check([wide.profilePrefix isEqual:prefix] && wide.tabRoot == prefix.firstObject
              && [wide.tabKind isEqualToString:@"subreddits"], @"landscape preserves the native Back prefix");

        landscape = NO;
        for (NSUInteger animation = 0; animation < 2; animation++) {
            BOOL animated = animation != 0;
            for (NSUInteger origin = 0; origin < 2; origin++) {
                ApolloDuoSplitState *state = Posts();
                UIViewController *feedRoot = state.feed.viewControllers.firstObject;
                UINavigationController *nav = origin ? state.outer : state.primary;
                Check(ApolloDuoSplitRoutePush(nav, profile, animated), @"portrait drawer profile push is handled");
                Check(state.feed.viewControllers.count == 2 && state.feed.viewControllers.firstObject == feedRoot
                      && state.feed.viewControllers.lastObject == profile, @"portrait profile push retains the previous feed for native Back");
                Check(!state.host.listVisible && state.feed.lastPushAnimated == animated
                      && state.host.lastListAnimated == animated, @"portrait push dismisses the drawer and preserves animation preference");
            }
        }
        Check(dashboardNavigations == 0, @"portrait never starts landscape dashboard navigation");
        ApolloDuoSplitState *state = Posts();
        Check(!ApolloDuoSplitRoutePush(state.feed, profile, YES), @"profile pushes already on the portrait feed use native navigation");
        state.changing = YES;
        Check(!ApolloDuoSplitRoutePush(state.primary, profile, YES), @"containment changes are not intercepted");
        state.changing = NO;
        Check(!ApolloDuoSplitRoutePush(state.primary, [UINavigationController new], YES)
              && !ApolloDuoSplitRoutePush(state.primary, [UISplitViewController new], YES), @"UIKit containers are never routed as profile content");
        landscape = YES;
        NSUInteger previousNavigations = dashboardNavigations;
        Check(ApolloDuoSplitRoutePush(state.primary, profile, YES) && dashboardNavigations == previousNavigations + 1,
              @"landscape profile selection still opens the dashboard");

        // Profiles can arrive through native Swift pushes, outside RoutePush.
        // Repeated portrait updates must leave both retained stacks alone.
        landscape = NO;
        state = Posts();
        state.feed.viewControllers = @[Page(@"posts"), profile];
        state.secondary.viewControllers = @[profile];
        for (NSUInteger pass = 0; pass < 20; pass++) UpdateDecision(state);
        Check(closes == 0, @"repeated portrait updates never collapse the retained profile stacks");
        landscape = YES;
        for (NSUInteger column = 0; column < 2; column++) {
            state = Posts();
            if (column) state.secondary.viewControllers = @[profile];
            else state.feed.viewControllers = @[Page(@"posts"), profile];
            closes = 0;
            UpdateDecision(state);
            Check(closes == 1 && lastClosePreserved, @"landscape normalizes profiles from either feed or secondary stack");
        }
        state = Posts();
        closes = 0;
        UpdateDecision(state);
        Check(closes == 0, @"ordinary landscape Posts needs no profile normalization");
        wide.feed = nil;
        wide.secondary.viewControllers = @[wide.root];
        UpdateDecision(wide);
        Check(closes == 0, @"the existing landscape profile dashboard is not rebuilt");
        landscape = NO;
        UpdateDecision(wide);
        Check(closes == 1 && !lastClosePreserved, @"the landscape profile dashboard still collapses in portrait");
        closes = 0;
        unfolded = NO;
        UpdateDecision(state);
        Check(closes == 1 && !lastClosePreserved, @"closing Duo still collapses Posts normally");
        printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
