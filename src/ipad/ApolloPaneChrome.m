#import "ApolloPaneChrome.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSidebar.h"
#import "ApolloPaneSplitViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "../ApolloThemeRuntime.h"

static char kComfortableFeed;
static NSString *const kPaneDensityPreference = @"ApolloPaneComfortableFeed";
static UIViewController *ApolloPaneControllerForView(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) return (id)responder;
    }
    return nil;
}

BOOL ApolloPaneUsesUnifiedChrome(UIView *view) {
    UISplitViewController *pane = ApolloPaneSplitControllerFor(ApolloPaneControllerForView(view));
    return pane && !pane.isCollapsed;
}

CGFloat ApolloPaneContextBottomInView(UIView *view) {
    UIViewController *controller = ApolloPaneControllerForView(view);
    if (!ApolloPaneUsesUnifiedChrome(view)) return 0.0;
    UINavigationController *nav = [controller isKindOfClass:UINavigationController.class]
        ? (id)controller : controller.navigationController;
    UINavigationBar *bar = nav.navigationBar;
    if (!bar.window || bar.hidden) return 0.0;
    return MAX(0.0, CGRectGetMaxY([bar convertRect:bar.bounds toView:view]));
}

BOOL ApolloPanePrefersCompactFeed(UIViewController *controller) {
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(controller);
    if (!pane) return NO;
    UINavigationController *primary = [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
    NSNumber *preference = objc_getAssociatedObject(pane, &kComfortableFeed);
    if (!preference) {
        preference = @([NSUserDefaults.standardUserDefaults boolForKey:kPaneDensityPreference]);
        objc_setAssociatedObject(pane, &kComfortableFeed, preference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return controller.navigationController == primary && !preference.boolValue;
}

void ApolloPaneSetComfortableFeed(UIViewController *controller, BOOL comfortable) {
    UISplitViewController *pane = ApolloPaneSplitControllerFor(controller);
    if (pane) {
        objc_setAssociatedObject(pane, &kComfortableFeed, @(comfortable), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSUserDefaults.standardUserDefaults setBool:comfortable forKey:kPaneDensityPreference];
    }
}

static char kPaneLayoutButton;
static char kPaneMenuConfiguration;
static char kPaneDensityPrepared;
static char kPaneFindButton;
static char kPaneOriginalExtendedEdges;

void ApolloPaneApplySearchPlacement(UIViewController *controller) {
    if (!controller.navigationItem.searchController) return;
    UISplitViewController *pane = ApolloPaneSplitControllerFor(controller);
    if (!pane) return;
    if (@available(iOS 26.0, *)) {
        controller.navigationItem.preferredSearchBarPlacement = pane.isCollapsed
            ? UINavigationItemSearchBarPlacementStacked : UINavigationItemSearchBarPlacementIntegratedButton;
        controller.navigationItem.searchBarPlacementAllowsExternalIntegration = NO;
        controller.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO;
    } else if (@available(iOS 16.0, *)) {
        controller.navigationItem.preferredSearchBarPlacement = pane.isCollapsed
            ? UINavigationItemSearchBarPlacementStacked : UINavigationItemSearchBarPlacementInline;
    }
}

static void ApolloPaneReloadNativeFeed(UIViewController *controller) {
    SEL reload = NSSelectorFromString(@"postCellAppearanceUpdatedWithNotification:");
    if ([controller respondsToSelector:reload]) {
        // This native entry invalidates section-controller mappings and reloads
        // the table. A real Notification is required by Swift's nonoptional ABI.
        NSNotification *notification = [NSNotification notificationWithName:@"ApolloPaneDensityChanged" object:nil];
        ((void (*)(id, SEL, id))objc_msgSend)(controller, reload, notification);
    }
}

void ApolloPaneInstallChromeForController(UIViewController *controller) {
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(controller);
    if (!pane || !controller.isViewLoaded) return;
    ApolloPaneApplySearchPlacement(controller);
    UINavigationController *primary = [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
    if (controller.navigationController != primary) {
        Class comments = objc_getClass("_TtC6Apollo22CommentsViewController");
        if (comments && [controller isKindOfClass:comments]) {
            NSNumber *original = objc_getAssociatedObject(controller, &kPaneOriginalExtendedEdges);
            if (!pane.isCollapsed) {
                if (!original) {
                    original = @(controller.edgesForExtendedLayout);
                    objc_setAssociatedObject(controller, &kPaneOriginalExtendedEdges, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                UIRectEdge edges = original.unsignedIntegerValue & ~UIRectEdgeTop;
                if (controller.edgesForExtendedLayout != edges) controller.edgesForExtendedLayout = edges;
            } else if (original) {
                controller.edgesForExtendedLayout = original.unsignedIntegerValue;
                objc_setAssociatedObject(controller, &kPaneOriginalExtendedEdges, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if (comments && [controller isKindOfClass:comments] &&
            ApolloPanePrepareCommentsFind(controller) && !objc_getAssociatedObject(controller, &kPaneFindButton)) {
            __weak UIViewController *weakController = controller;
            UIAction *find = [UIAction actionWithTitle:@"Find in comments" image:[UIImage systemImageNamed:@"magnifyingglass"]
                identifier:nil handler:^(__unused UIAction *action) { ApolloPanePresentCommentsFind(weakController); }];
            UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithPrimaryAction:find];
            button.accessibilityIdentifier = @"ApolloPaneFindComments";
            objc_setAssociatedObject(controller, &kPaneFindButton, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            controller.navigationItem.rightBarButtonItems = [(controller.navigationItem.rightBarButtonItems ?: @[]) arrayByAddingObject:button];
        }
        return;
    }
    Class posts = objc_getClass("_TtC6Apollo19PostsViewController");
    BOOL feed = posts && [controller isKindOfClass:posts];
    if (feed && !objc_getAssociatedObject(controller, &kPaneDensityPrepared)) {
        objc_setAssociatedObject(controller, &kPaneDensityPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloPaneReloadNativeFeed(controller);
    }
    UIBarButtonItem *item = objc_getAssociatedObject(controller, &kPaneLayoutButton);
    if (!item) {
        item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"rectangle.split.2x1"]
            style:UIBarButtonItemStylePlain target:nil action:nil];
        item.accessibilityLabel = @"Pane layout";
        item.accessibilityIdentifier = @"ApolloPaneLayoutMenu";
        objc_setAssociatedObject(controller, &kPaneLayoutButton, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Menus contain stable actions, not per-frame state. Rebuild only when
    // their role/density/window action changes; still restore our item if a
    // native navigation update replaced the bar's array.
    BOOL canOpenWindow = ApolloPaneCanOpenDetailInNewWindow(pane);
    NSUInteger flags = (feed ? 1 : 0) | (ApolloPanePrefersCompactFeed(controller) ? 2 : 0) | (canOpenWindow ? 4 : 0);
    NSNumber *previous = objc_getAssociatedObject(controller, &kPaneMenuConfiguration);
    if (previous && previous.unsignedIntegerValue == flags) {
        NSArray *items = controller.navigationItem.rightBarButtonItems ?: @[];
        if (![items containsObject:item]) controller.navigationItem.rightBarButtonItems = [items arrayByAddingObject:item];
        return;
    }
    objc_setAssociatedObject(controller, &kPaneMenuConfiguration, @(flags), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    __weak ApolloPaneSplitViewController *weakPane = pane;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    if (feed) {
        BOOL compact = ApolloPanePrefersCompactFeed(controller);
        UIAction *compactAction = [UIAction actionWithTitle:@"Compact list" image:[UIImage systemImageNamed:@"list.bullet"]
            identifier:nil handler:^(__unused UIAction *action) {
                UIViewController *owner = weakController;
                if (!owner) return;
                ApolloPaneSetComfortableFeed(owner, NO);
                ApolloPaneReloadNativeFeed(owner);
                ApolloPaneInstallChromeForController(owner);
            }];
        compactAction.state = compact ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIAction *comfortableAction = [UIAction actionWithTitle:@"Comfortable list" image:[UIImage systemImageNamed:@"rectangle.grid.1x2"]
            identifier:nil handler:^(__unused UIAction *action) {
                UIViewController *owner = weakController;
                if (!owner) return;
                ApolloPaneSetComfortableFeed(owner, YES);
                ApolloPaneReloadNativeFeed(owner);
                ApolloPaneInstallChromeForController(owner);
            }];
        comfortableAction.state = compact ? UIMenuElementStateOff : UIMenuElementStateOn;
        [actions addObjectsFromArray:@[compactAction, comfortableAction]];
    }
    [actions addObject:[UIAction actionWithTitle:@"Reset column width" image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
        identifier:nil handler:^(__unused UIAction *action) { [weakPane apollo_resetPreferredPrimaryWidth]; }]];
    if (canOpenWindow) {
        [actions addObject:[UIAction actionWithTitle:@"Open detail in new window"
            image:[UIImage systemImageNamed:@"plus.rectangle.on.rectangle"] identifier:nil
            handler:^(__unused UIAction *action) { ApolloPaneOpenDetailInNewWindow(weakPane); }]];
    }
    item.menu = [UIMenu menuWithTitle:@"Pane layout" children:actions];
    NSArray *existing = controller.navigationItem.rightBarButtonItems ?: @[];
    if (![existing containsObject:item]) controller.navigationItem.rightBarButtonItems = [existing arrayByAddingObject:item];
}
