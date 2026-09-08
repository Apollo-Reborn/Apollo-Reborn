// ApolloPaneEntryPoints.xm
//
// Compatibility adapter for Apollo's native external-entry callbacks.
//
// Apollo 1.15.11 assumes every tab child is an ApolloNavigationController:
// warm URL, APNs, Handoff/Siri, and shortcut handlers either cast
// selectedViewController directly or index viewControllers and cast the result.
// Pane mode intentionally makes each tab child an ApolloPaneSplitViewController,
// so those handlers otherwise select the right tab and then silently fail to
// push their destination.
//
// During only those native callback bodies, the two getters Apollo uses expose
// each pane's primary navigation controller. UIKit selection setters are run
// with the adapter suspended and translate a synthetic navigation controller
// back to its real pane child. The actual tab hierarchy is never mutated.

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "ApolloPaneSidebar.h"
#import "../ApolloCommon.h"

// UIKit entry callbacks are main-thread APIs. A counter, rather than a BOOL,
// preserves the scope if another hooked entry point is invoked synchronously.
static NSUInteger sApolloPaneNativeEntryDepth = 0;
static NSMutableArray *sApolloPaneEntryTabs;
static UITabBarController *ApolloPaneEntryTabsForDelegate(id delegate) {
    Ivar ivar = class_getInstanceVariable([delegate class], "tabBarController");
    id value = ivar ? object_getIvar(delegate, ivar) : nil;
    return [value isKindOfClass:UITabBarController.class] ? value : nil;
}

static BOOL ApolloPaneNativeEntryCompatibilityActive(UITabBarController *tabs) {
    return sApolloPaneNativeEntryDepth > 0 && ApolloPaneLayoutActive() &&
        sApolloPaneEntryTabs.lastObject == tabs;
}

static void ApolloPaneBeginNativeEntry(UITabBarController *tabs) {
    if (!sApolloPaneEntryTabs) sApolloPaneEntryTabs = [NSMutableArray array];
    [sApolloPaneEntryTabs addObject:tabs ?: NSNull.null];
    sApolloPaneNativeEntryDepth++;
}

static void ApolloPaneEndNativeEntry(void) {
    if (sApolloPaneNativeEntryDepth > 0) sApolloPaneNativeEntryDepth--;
    [sApolloPaneEntryTabs removeLastObject];
}

static NSArray<UIViewController *> *ApolloPaneActualTabChildren(UITabBarController *tabBarController) {
    NSUInteger savedDepth = sApolloPaneNativeEntryDepth;
    sApolloPaneNativeEntryDepth = 0;
    NSArray<UIViewController *> *children = nil;
    @try {
        children = tabBarController.viewControllers;
    } @finally {
        sApolloPaneNativeEntryDepth = savedDepth;
    }
    return children ?: @[];
}

static UIViewController *ApolloPaneActualChildForSyntheticChild(UITabBarController *tabBarController,
                                                                 UIViewController *candidate) {
    if (!candidate) return candidate;
    for (UIViewController *actual in ApolloPaneActualTabChildren(tabBarController)) {
        if (actual == candidate) return actual;
        if ([actual isKindOfClass:[ApolloPaneSplitViewController class]]) {
            UINavigationController *primary =
                [(ApolloPaneSplitViewController *)actual
                    apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
            if (primary == candidate) return actual;
        }
    }
    return candidate;
}

%group ApolloPaneEntryPointsGroup

%hook UITabBarController

- (UIViewController *)selectedViewController {
    UIViewController *actual = %orig;
    if (!ApolloPaneNativeEntryCompatibilityActive(self) ||
        ![actual isKindOfClass:[ApolloPaneSplitViewController class]]) return actual;
    UIViewController *compatible = [(ApolloPaneSplitViewController *)actual
        apollo_navigationControllerForColumn:ApolloPaneColumnPrimary] ?: actual;
    ApolloLog(@"[PaneEntry] exposed selected pane as %@", NSStringFromClass(compatible.class));
    return compatible;
}

- (NSArray<UIViewController *> *)viewControllers {
    NSArray<UIViewController *> *actual = %orig;
    if (!ApolloPaneNativeEntryCompatibilityActive(self)) return actual;

    NSMutableArray<UIViewController *> *compatible =
        [NSMutableArray arrayWithCapacity:actual.count];
    for (UIViewController *child in actual) {
        if ([child isKindOfClass:[ApolloPaneSplitViewController class]]) {
            UINavigationController *primary =
                [(ApolloPaneSplitViewController *)child
                    apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
            [compatible addObject:primary ?: child];
        } else {
            [compatible addObject:child];
        }
    }
    return compatible;
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    if (!ApolloPaneNativeEntryCompatibilityActive(self)) { %orig; return; }
    NSUInteger savedDepth = sApolloPaneNativeEntryDepth;
    sApolloPaneNativeEntryDepth = 0;
    @try {
        %orig(selectedIndex);
    } @finally {
        sApolloPaneNativeEntryDepth = savedDepth;
    }
}

- (void)setSelectedViewController:(UIViewController *)selectedViewController {
    if (!ApolloPaneNativeEntryCompatibilityActive(self)) { %orig; return; }
    UIViewController *actual = ApolloPaneActualChildForSyntheticChild(self, selectedViewController);
    NSUInteger savedDepth = sApolloPaneNativeEntryDepth;
    sApolloPaneNativeEntryDepth = 0;
    @try {
        %orig(actual);
    } @finally {
        sApolloPaneNativeEntryDepth = savedDepth;
    }
}

%end

%hook _TtC6Apollo11AppDelegate

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    ApolloPaneBeginNativeEntry(ApolloPaneEntryTabsForDelegate(self));
    ApolloLog(@"[PaneEntry] AppDelegate URL callback active=%d", ApolloPaneLayoutActive());
    @try {
        return %orig(application, url, options);
    } @finally {
        ApolloPaneEndNativeEntry();
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    ApolloPaneBeginNativeEntry(ApolloPaneEntryTabsForDelegate(self));
    ApolloLog(@"[PaneEntry] AppDelegate notification callback active=%d", ApolloPaneLayoutActive());
    @try {
        %orig(center, response, completionHandler);
    } @finally {
        ApolloPaneEndNativeEntry();
    }
}

%end


%hook _TtC6Apollo13SceneDelegate

- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {
    // Apollo dynamically casts this candidate to ApolloNavigationController to
    // implement native same-tab behavior (scroll to top, then Back when already
    // at top). Pane children are split controllers, so without this scoped
    // translation the cast fails and reselection silently does nothing.
    UIViewController *compatible = viewController;
    if (ApolloPaneLayoutActive() &&
        [viewController isKindOfClass:[ApolloPaneSplitViewController class]]) {
        compatible = [(ApolloPaneSplitViewController *)viewController
            apollo_navigationControllerForColumn:ApolloPaneColumnPrimary] ?: viewController;
    }
    ApolloPaneBeginNativeEntry(tabBarController);
    @try {
        return %orig(tabBarController, compatible);
    } @finally {
        ApolloPaneEndNativeEntry();
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet *)URLContexts {
    ApolloPaneBeginNativeEntry(ApolloPaneEntryTabsForDelegate(self));
    ApolloLog(@"[PaneEntry] SceneDelegate URL callback active=%d", ApolloPaneLayoutActive());
    @try {
        %orig(scene, URLContexts);
    } @finally {
        ApolloPaneEndNativeEntry();
    }
}

- (void)windowScene:(UIWindowScene *)windowScene
 performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem
   completionHandler:(void (^)(BOOL succeeded))completionHandler {
    ApolloPaneBeginNativeEntry(ApolloPaneEntryTabsForDelegate(self));
    ApolloLog(@"[PaneEntry] SceneDelegate shortcut callback active=%d", ApolloPaneLayoutActive());
    @try {
        %orig(windowScene, shortcutItem, completionHandler);
    } @finally {
        ApolloPaneEndNativeEntry();
    }
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
    if ([scene isKindOfClass:UIWindowScene.class] &&
        ApolloPaneReceiveSceneActivity((UIWindowScene *)scene, userActivity)) {
        ApolloPaneOpenPendingSceneLink((UIWindowScene *)scene);
        return;
    }
    ApolloPaneBeginNativeEntry(ApolloPaneEntryTabsForDelegate(self));
    ApolloLog(@"[PaneEntry] SceneDelegate activity callback active=%d", ApolloPaneLayoutActive());
    @try {
        %orig(scene, userActivity);
    } @finally {
        ApolloPaneEndNativeEntry();
    }
}

%end

%end

%ctor {
    if (!ApolloPaneLayoutEnabled()) return;
    %init(ApolloPaneEntryPointsGroup);
    ApolloPaneEntryPointsSetReady();
    ApolloLog(@"[PaneEntry] installed scoped native-entry compatibility adapter");
}
