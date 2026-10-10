#import <Foundation/Foundation.h>

@interface UIBarButtonItem : NSObject
@end
@implementation UIBarButtonItem
@end

// Equal-but-distinct items prove cleanup removes the stored Accounts instance,
// not another control that happens to compare equal to it.
@interface EquivalentBarButtonItem : UIBarButtonItem
@end
@implementation EquivalentBarButtonItem
- (BOOL)isEqual:(id)other { return [other isKindOfClass:EquivalentBarButtonItem.class]; }
- (NSUInteger)hash { return 1; }
@end

@interface UINavigationItem : NSObject
@property (nonatomic, copy) NSArray<UIBarButtonItem *> *leftBarButtonItems;
@property (nonatomic, copy) NSArray<UIBarButtonItem *> *rightBarButtonItems;
@property (nonatomic) NSUInteger leftWrites;
@property (nonatomic) NSUInteger rightWrites;
- (void)setLeftBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated;
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated;
@end
@implementation UINavigationItem
@synthesize leftBarButtonItems = _leftBarButtonItems;
@synthesize rightBarButtonItems = _rightBarButtonItems;
- (void)setLeftBarButtonItems:(NSArray<UIBarButtonItem *> *)items {
    _leftBarButtonItems = [items copy];
    self.leftWrites++;
}
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items {
    _rightBarButtonItems = [items copy];
    self.rightWrites++;
}
- (void)setLeftBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(__unused BOOL)animated {
    self.leftBarButtonItems = items;
}
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(__unused BOOL)animated {
    self.rightBarButtonItems = items;
}
@end

@interface UIViewController : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UINavigationItem *navigationItem;
@end
@implementation UIViewController
@end

@class ApolloDuoSplitState;
@interface UINavigationController : UIViewController
@property (nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property (nonatomic, strong) id tabBarController;
@property (nonatomic, weak) ApolloDuoSplitState *duoState;
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

@interface UITabBarController : UIViewController
@property (nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@end
@implementation UITabBarController
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
static id mainTabs;
static id ApolloMainTabBarController(void) { return mainTabs; }
static BOOL ApolloDuoSplitShouldOpen(__unused id tabs) { return landscape; }
static BOOL ApolloDuoSplitIsUnfolded(void) { return unfolded; }
static NSString *ApolloDuoSplitKind(UIViewController *page) { return page.kind; }
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav,
                                                          __unused BOOL create) { return nav.duoState; }
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
// INCLUDE_PRODUCTION_PROFILE_OWNERSHIP
// INCLUDE_PRODUCTION_ARRAY_IDENTITY
// INCLUDE_PRODUCTION_ACCOUNTS_REMOVAL

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
    page.navigationItem = [UINavigationItem new];
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
    for (UINavigationController *navigation in @[state.outer, state.primary, state.feed, state.secondary]) {
        navigation.duoState = state;
    }
    return state;
}

static UINavigationController *Navigation(UIViewController *root) {
    UINavigationController *navigation = [UINavigationController new];
    navigation.viewControllers = root ? @[root] : @[];
    return navigation;
}

static void CheckProfileOwnership(void) {
    UIViewController *own = Page(@"account");
    UIViewController *visited = Page(@"account");
    mainTabs = nil;
    Check(!ApolloDuoSplitIsOwnAccountController(own), @"an unavailable tab controller does not imply own Account");
    mainTabs = [NSObject new];
    Check(!ApolloDuoSplitIsOwnAccountController(own), @"a non-tab root does not imply own Account");

    UITabBarController *tabs = [UITabBarController new];
    mainTabs = tabs;
    UINavigationController *accountNavigation = Navigation(own);
    tabs.viewControllers = @[Navigation(Page(@"subreddits")), accountNavigation, visited, Navigation(nil)];
    Check(ApolloDuoSplitIsOwnAccountController(own), @"the native Account tab root owns Accounts before user data loads");
    Check(!ApolloDuoSplitIsOwnAccountController(nil) && !ApolloDuoSplitIsOwnAccountController(visited),
          @"nil and a profile outside a tab navigation stack do not own Accounts");
    accountNavigation.viewControllers = @[own, visited];
    own.title = @"old-account";
    visited.title = @"new-account";
    own.title = @"new-account";
    Check(ApolloDuoSplitIsOwnAccountController(own) && !ApolloDuoSplitIsOwnAccountController(visited),
          @"account switching keeps tab ownership even when a visited profile has the same username");

    // Promotion changes the dashboard root and navigation containment, but
    // never turns a visited profile into the user's Account tab.
    landscape = YES;
    for (NSString *kind in @[@"subreddits", @"search", @"account"]) {
        ApolloDuoSplitState *state = [ApolloDuoSplitState new];
        state.kind = kind;
        state.root = [kind isEqualToString:@"account"] ? own : Page(kind);
        state.outer = Navigation(state.root);
        state.outer.duoState = state;
        state.outer.tabBarController = tabs;
        tabs.viewControllers = [kind isEqualToString:@"account"] ? @[state.outer] : @[state.outer, accountNavigation];
        state.outer.viewControllers = @[state.root, visited];
        Check(ApolloDuoSplitIsOwnAccountController(own) && !ApolloDuoSplitIsOwnAccountController(visited),
              [NSString stringWithFormat:@"%@ pushed profile stays visited on the closed/native stack", kind]);
        Check(PromoteProfile(state) == 1 && state.root == visited,
              [NSString stringWithFormat:@"%@ profile uses production landscape promotion", kind]);
        Check(ApolloDuoSplitIsOwnAccountController(own) && !ApolloDuoSplitIsOwnAccountController(visited),
              @"ownership remains correct while preparing the dashboard before split installation");
        state.split = [UISplitViewController new];
        state.outer.viewControllers = @[Page(@"host")];
        state.secondary = Navigation(visited);
        state.secondary.duoState = state;
        Check(!ApolloDuoSplitIsOwnAccountController(visited),
              @"becoming the landscape detail navigation root does not grant Accounts");
        Check(ApolloDuoSplitIsOwnAccountController(own),
              @"the original Account tab retains ownership while a visited dashboard is visible");
        // Model the retained native stack after rotating or folding back.
        state.outer.viewControllers = [state.profilePrefix arrayByAddingObject:visited];
        state.root = state.tabRoot;
        state.kind = state.tabKind;
        state.tabRoot = nil;
        state.profilePrefix = nil;
        state.split = nil;
        Check(ApolloDuoSplitIsOwnAccountController(own) && !ApolloDuoSplitIsOwnAccountController(visited),
              @"rotating or folding out of the dashboard preserves profile ownership");
    }

    UIViewController *replacement = Page(@"account");
    accountNavigation.viewControllers = @[replacement];
    tabs.viewControllers = @[accountNavigation];
    Check(ApolloDuoSplitIsOwnAccountController(replacement) && !ApolloDuoSplitIsOwnAccountController(own),
          @"replacing the native Account root transfers ownership and invalidates the old controller");
    ApolloDuoSplitState *accountState = [ApolloDuoSplitState new];
    accountState.root = replacement;
    accountState.split = [UISplitViewController new];
    accountNavigation.duoState = accountState;
    accountNavigation.viewControllers = @[Page(@"host")];
    Check(ApolloDuoSplitIsOwnAccountController(replacement) && !ApolloDuoSplitIsOwnAccountController(own),
          @"an own-account dashboard resolves its retained root behind the host controller");
    accountState.tabRoot = replacement;
    accountState.root = visited;
    Check(ApolloDuoSplitIsOwnAccountController(replacement) && !ApolloDuoSplitIsOwnAccountController(visited),
          @"a visited dashboard on Account uses tabRoot instead of its promoted profile root");
    mainTabs = nil;
}

static void CheckAccountsRemoval(void) {
    UIViewController *profile = Page(@"account");
    UINavigationItem *item = profile.navigationItem;
    UIBarButtonItem *accounts = [EquivalentBarButtonItem new];
    UIBarButtonItem *lookalike = [EquivalentBarButtonItem new];
    UIBarButtonItem *back = [UIBarButtonItem new];
    UIBarButtonItem *more = [UIBarButtonItem new];
    item.leftBarButtonItems = @[back, accounts, lookalike];
    item.rightBarButtonItems = @[accounts, more];
    item.leftWrites = item.rightWrites = 0;
    ApolloActionsRemoveProfileAccountsItem(profile, accounts);
    Check(ApolloActionsArraysIdentical(item.leftBarButtonItems, @[back, lookalike]),
          @"Accounts cleanup preserves leading Back and an equal-but-distinct control in order");
    Check(ApolloActionsArraysIdentical(item.rightBarButtonItems, @[more]),
          @"Accounts cleanup preserves the exact native More item");
    Check(item.leftWrites == 1 && item.rightWrites == 1, @"cleanup writes each changed side once");
    for (NSUInteger pass = 0; pass < 20; pass++) ApolloActionsRemoveProfileAccountsItem(profile, accounts);
    Check(item.leftWrites == 1 && item.rightWrites == 1,
          @"repeated layout cleanup performs no navigation-item writes after convergence");

    for (NSUInteger side = 0; side < 2; side++) {
        item.leftBarButtonItems = side ? @[back] : @[accounts, back];
        item.rightBarButtonItems = side ? @[more, accounts] : @[more];
        item.leftWrites = item.rightWrites = 0;
        ApolloActionsRemoveProfileAccountsItem(profile, accounts);
        Check(ApolloActionsArraysIdentical(item.leftBarButtonItems, @[back])
              && ApolloActionsArraysIdentical(item.rightBarButtonItems, @[more]),
              @"cleanup repairs both horizontal and trailing-rail Accounts placement");
        Check(item.leftWrites == (side ? 0 : 1) && item.rightWrites == (side ? 1 : 0),
              @"cleanup does not republish the unaffected side");
    }
    item.leftBarButtonItems = nil;
    item.rightBarButtonItems = nil;
    item.leftWrites = item.rightWrites = 0;
    ApolloActionsRemoveProfileAccountsItem(profile, accounts);
    Check(item.leftBarButtonItems == nil && item.rightBarButtonItems == nil
          && item.leftWrites == 0 && item.rightWrites == 0,
          @"a not-yet-loaded profile keeps its absent native items without setter churn");
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
        CheckProfileOwnership();
        CheckAccountsRemoval();
        printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
