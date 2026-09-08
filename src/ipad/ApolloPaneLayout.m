// ApolloPaneLayout.m — see ApolloPaneLayout.h

#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "ApolloPaneSidebar.h"
#import "../ApolloCommon.h"   // ApolloLog
#import "../ApolloState.h"    // sIPadPaneLayout
#import <objc/runtime.h>

// Set once, from the main thread, during scene connect. Read from the main
// thread by every consumer. No synchronization needed and none implied — if a
// background reader ever appears, make this atomic rather than adding a lock
// around a single BOOL.
static BOOL sPaneLayoutActive = NO;
static BOOL sPaneRouterReady;
static BOOL sPaneEntryPointsReady;
static NSMapTable<UIWindowScene *, UITabBarController *> *sPaneSceneTabs;

void ApolloPaneRouterSetReady(void) { sPaneRouterReady = YES; }
void ApolloPaneEntryPointsSetReady(void) { sPaneEntryPointsReady = YES; }
BOOL ApolloPaneBootstrapReady(void) {
    if (!sPaneRouterReady || !sPaneEntryPointsReady) return NO;
    static BOOL compatible;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class nav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
        Ivar interaction = class_getInstanceVariable(nav, "interactionController");
        Ivar history = class_getInstanceVariable(nav, "poppedViewControllers");
        compatible = nav && interaction && history &&
            ivar_getOffset(interaction) - ivar_getOffset(history) == sizeof(void *) &&
            class_getInstanceMethod(nav, @selector(pushViewController:animated:)) &&
            class_getInstanceMethod(nav, @selector(popToViewController:animated:)) &&
            class_getInstanceMethod(nav, @selector(setViewControllers:animated:));
#if APOLLO_SIM_BUILD
        if ([NSProcessInfo.processInfo.environment[@"APOLLO_PANE_SIM_REQUIRED_CAPABILITY_FAILURE"] boolValue]) compatible = NO;
#endif
        ApolloLog(@"[PaneBootstrap] router=%d entry=%d navigationContract=%d", sPaneRouterReady, sPaneEntryPointsReady, compatible);
    });
    return compatible;
}
static NSMapTable<UINavigationController *, UISplitViewController *> *sPaneNavigationOwners = nil;
static NSMapTable<UINavigationItem *, UINavigationController *> *sPaneItemOwners;

BOOL ApolloPaneLayoutSupported(void) {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Capability is fixed for this process; layout is not. iOS 27 supports
        // resizable phone scenes without changing their phone idiom. UIKit's
        // inherited size classes drive the split's collapse/expand lifecycle.
        if (@available(iOS 27.0, *)) {
            UIUserInterfaceIdiom idiom = UIDevice.currentDevice.userInterfaceIdiom;
            supported = idiom == UIUserInterfaceIdiomPad || idiom == UIUserInterfaceIdiomPhone;
        } else if (@available(iOS 18.0, *)) {
            supported = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
        }
    });
    return supported;
}

BOOL ApolloPaneLayoutEnabled(void) {
    return ApolloPaneLayoutSupported() && sIPadPaneLayout;
}

BOOL ApolloPaneLayoutActive(void) {
    return sPaneLayoutActive;
}

void ApolloPaneLayoutSetActive(BOOL active) {
    if (sPaneLayoutActive == active) return;
    sPaneLayoutActive = active;
    ApolloLog(@"[PaneLayout] active=%d (supported=%d enabled=%d)",
              active, ApolloPaneLayoutSupported(), ApolloPaneLayoutEnabled());
}

UISplitViewController *ApolloPaneSplitControllerFor(UIViewController *viewController) {
    if (!sPaneLayoutActive) return nil;

    // Walk parents rather than `splitViewController`: UIKit's property only
    // reports an ancestor split controller when the receiver is one of its
    // direct children or inside its columns' navigation stacks, and it can
    // also report a split controller we did NOT install (Apollo embeds none
    // today, but a future one would silently match). Matching on our own class
    // keeps the answer unambiguous.
    for (UIViewController *node = viewController; node != nil; node = node.parentViewController) {
        if ([node isKindOfClass:[ApolloPaneSplitViewController class]]) {
            return (UISplitViewController *)node;
        }
    }

    // UITabBarController may detach every non-selected tab's column hierarchy.
    // A URL/shortcut selects a tab and pushes synchronously, before UIKit's next
    // containment update, so the parent walk can still be empty here.
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UISplitViewController *registered =
            [sPaneNavigationOwners objectForKey:(UINavigationController *)viewController];
        if ([registered isKindOfClass:[ApolloPaneSplitViewController class]]) return registered;
    }
    return nil;
}

void ApolloPaneRegisterNavigationController(UINavigationController *navigationController,
                                            UISplitViewController *splitViewController) {
    if (!navigationController || !splitViewController) return;
    if (!sPaneNavigationOwners) {
        sPaneNavigationOwners = [NSMapTable weakToWeakObjectsMapTable];
    }
    [sPaneNavigationOwners setObject:splitViewController forKey:navigationController];
    ApolloPaneRegisterNavigationItems(navigationController);
}

void ApolloPaneUnregisterNavigationController(UINavigationController *navigationController) {
    if (!navigationController || !sPaneNavigationOwners) return;
    [sPaneNavigationOwners removeObjectForKey:navigationController];
}

BOOL ApolloPaneNavigationControllerIsRegisteredToSplit(
    UINavigationController *navigationController,
    UISplitViewController *splitViewController) {
    if (!navigationController || !splitViewController || !sPaneNavigationOwners) return NO;
    return [sPaneNavigationOwners objectForKey:navigationController] == splitViewController;
}

void ApolloPaneStageMasterTableSelectionIfNeeded(
    UIViewController *sourceViewController,
    UITableView *tableView,
    NSIndexPath *indexPath) {
    if (!ApolloPaneLayoutActive() || !sourceViewController || !tableView || !indexPath) return;
    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(sourceViewController);
    UINavigationController *primary =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
    if (!pane || sourceViewController.navigationController != primary) return;

    id intent = [pane apollo_masterSelectionIntentFromSource:sourceViewController
                                                     surface:tableView
                                                   indexPath:indexPath
                                              itemIdentifier:nil
                                               identityOwner:nil];
    [pane apollo_stageMasterSelectionIntent:intent];
}

void ApolloPaneRegisterScene(UIWindowScene *scene, UITabBarController *tabs) {
    if (!scene || !tabs) return;
    if (!sPaneSceneTabs) sPaneSceneTabs = [NSMapTable weakToWeakObjectsMapTable];
    [sPaneSceneTabs setObject:tabs forKey:scene];
    ApolloPaneLayoutSetActive(YES);
    // UIKit may reconnect an existing tab hierarchy after scene disconnection.
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:ApolloPaneSplitViewController.class]) continue;
        ApolloPaneSplitViewController *pane = (id)child;
        ApolloPaneRegisterNavigationController([pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary], pane);
        ApolloPaneRegisterNavigationController([pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary], pane);
    }
    ApolloPaneInstallSidebar(tabs);
}

NSArray<UISplitViewController *> *ApolloPaneSplitsForScene(UIWindowScene *scene) {
    NSMutableArray *panes = [NSMutableArray array];
    for (UIViewController *child in [sPaneSceneTabs objectForKey:scene].viewControllers)
        if ([child isKindOfClass:ApolloPaneSplitViewController.class]) [panes addObject:child];
    return panes;
}

void ApolloPaneDisconnectScene(UIWindowScene *scene) {
    UITabBarController *tabs = [sPaneSceneTabs objectForKey:scene];
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:ApolloPaneSplitViewController.class]) continue;
        ApolloPaneSplitViewController *pane = (id)child;
        [pane apollo_sceneDidDisconnect];
        ApolloPaneUnregisterNavigationController([pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]);
        ApolloPaneUnregisterNavigationController([pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]);
    }
    [sPaneSceneTabs removeObjectForKey:scene];
    ApolloPaneLayoutSetActive(sPaneSceneTabs.objectEnumerator.allObjects.count > 0);
}

NSArray<UISplitViewController *> *ApolloPaneRegisteredSplits(void) {
    // Event-time snapshot, never a window/view-tree walk. Weak registrations
    // also cover detached, previously visited tabs during synchronous routing.
    NSHashTable *unique = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (UISplitViewController *pane in sPaneNavigationOwners.objectEnumerator) [unique addObject:pane];
    return unique.allObjects;
}

void ApolloPaneRegisterNavigationItems(UINavigationController *nav) {
    if (!nav) return;
    if (!sPaneItemOwners) sPaneItemOwners = [NSMapTable weakToWeakObjectsMapTable];
    for (UIViewController *controller in nav.viewControllers) {
        [sPaneItemOwners setObject:nav forKey:controller.navigationItem];
    }
}

UISplitViewController *ApolloPanePrimarySplitForNavigationItem(UINavigationItem *item) {
    UINavigationController *nav = [sPaneItemOwners objectForKey:item];
    ApolloPaneSplitViewController *pane = (id)[sPaneNavigationOwners objectForKey:nav];
    return nav && nav == [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary] ? pane : nil;
}
