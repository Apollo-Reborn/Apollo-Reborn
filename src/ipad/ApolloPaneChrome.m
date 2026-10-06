#import "ApolloPaneChrome.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSidebar.h"
#import "ApolloPaneSplitViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "../ApolloThemeRuntime.h"
#import "../ApolloActionMenu.h"
#import "../ApolloNativeActionMenus.h"

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

static char kPaneDensityPrepared;
static char kPaneOriginalExtendedEdges;
static char kPaneHeaderColor;
static char kPaneMenuOwner;
static __weak UIViewController *sPaneMenuOwner;

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
    // The two columns share a quiet, theme-colored header plane. Let content
    // scroll beneath that plane, not visibly behind one half of the controls.
    // Item appearances preserve Apollo's title/button styling and do not mutate
    // a navigation bar from inside its layout pass.
    UIColor *color = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    UIColor *resolved = [color resolvedColorWithTraitCollection:controller.traitCollection];
    if (![objc_getAssociatedObject(controller, &kPaneHeaderColor) isEqual:resolved]) {
        UINavigationBarAppearance *appearance = [controller.navigationController.navigationBar.standardAppearance copy];
        appearance.backgroundEffect = nil;
        appearance.backgroundImage = nil;
        appearance.backgroundColor = color;
        appearance.shadowColor = UIColor.separatorColor;
        controller.navigationItem.standardAppearance = appearance;
        controller.navigationItem.scrollEdgeAppearance = appearance;
        controller.navigationItem.compactAppearance = appearance;
        if (@available(iOS 15.0, *)) controller.navigationItem.compactScrollEdgeAppearance = appearance;
        objc_setAssociatedObject(controller, &kPaneHeaderColor, resolved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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
        // Native search owns the one visible Find affordance. The pane's
        // keyboard command still enters through ApolloPanePresentCommentsFind.
        if (comments && [controller isKindOfClass:comments]) {
            ApolloPanePrepareCommentsFind(controller);
            ApolloPaneApplySearchPlacement(controller);
        }
        return;
    }
    Class posts = objc_getClass("_TtC6Apollo19PostsViewController");
    BOOL feed = posts && [controller isKindOfClass:posts];
    if (feed && !objc_getAssociatedObject(controller, &kPaneDensityPrepared)) {
        objc_setAssociatedObject(controller, &kPaneDensityPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloPaneReloadNativeFeed(controller);
    }
}

UIViewController *ApolloPaneSetMenuOwner(UIViewController *controller) {
    UIViewController *previous = sPaneMenuOwner;
    sPaneMenuOwner = ApolloPaneSplitControllerFor(controller) ? controller : nil;
    return previous;
}

void ApolloPaneCaptureMenuOwner(id actionController) {
    if (!sPaneMenuOwner || ![actionController isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) return;
    if (objc_getAssociatedObject(actionController, &kPaneMenuOwner)) return;
    NSHashTable *owner = [NSHashTable weakObjectsHashTable];
    [owner addObject:sPaneMenuOwner];
    objc_setAssociatedObject(actionController, &kPaneMenuOwner, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIViewController *ApolloPaneMenuOwner(id actionController) {
    return [objc_getAssociatedObject(actionController, &kPaneMenuOwner) anyObject];
}

@interface ApolloPaneViewOption : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) BOOL selected;
@property (nonatomic, copy) dispatch_block_t perform;
@end
@implementation ApolloPaneViewOption
@end

static ApolloPaneViewOption *ApolloPaneOption(NSString *title, NSString *symbol, BOOL selected,
                                               dispatch_block_t perform) {
    ApolloPaneViewOption *option = [ApolloPaneViewOption new];
    option.title = title;
    option.symbol = symbol;
    option.selected = selected;
    option.perform = perform;
    return option;
}

// One action model drives both glass submenus and classic action sheets.
static NSArray<ApolloPaneViewOption *> *ApolloPaneViewOptions(UIViewController *controller) {
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(controller);
    if (!pane) return nil;
    __weak UIViewController *weakController = controller;
    __weak ApolloPaneSplitViewController *weakPane = pane;
    NSMutableArray<ApolloPaneViewOption *> *actions = [NSMutableArray array];
    if ([controller isKindOfClass:objc_getClass("_TtC6Apollo19PostsViewController")]) {
        BOOL compact = ApolloPanePrefersCompactFeed(controller);
        for (NSNumber *comfortable in @[@NO, @YES]) {
            [actions addObject:ApolloPaneOption(comfortable.boolValue ? @"Comfortable list" : @"Compact list",
                comfortable.boolValue ? @"rectangle.grid.1x2" : @"list.bullet", comfortable.boolValue != compact, ^{
                    UIViewController *owner = weakController;
                    if (!owner.viewIfLoaded.window) return;
                    ApolloPaneSetComfortableFeed(owner, comfortable.boolValue);
                    ApolloPaneReloadNativeFeed(owner);
                    ApolloPaneInstallChromeForController(owner);
                })];
        }
    }
    if (!pane.isCollapsed) {
        [actions addObject:ApolloPaneOption(@"Reset column width", @"arrow.counterclockwise", NO,
            ^{ [weakPane apollo_resetPreferredPrimaryWidth]; })];
    }
    if (ApolloPaneCanShowNavigationSidebar(controller.tabBarController)) {
        __weak UITabBarController *weakTabs = controller.tabBarController;
        [actions addObject:ApolloPaneOption(@"Show navigation sidebar", @"sidebar.leading", NO,
            ^{ ApolloPaneShowNavigationSidebar(weakTabs); })];
    }
    return actions;
}

void ApolloPaneRegisterViewOptions(void) {
    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"IPadViewOptions";
    spec.matches = ^BOOL(id sheet, __unused NSString *title) {
        UIViewController *owner = ApolloPaneMenuOwner(sheet);
        if ([owner isKindOfClass:objc_getClass("_TtC6Apollo22CommentsViewController")]) {
            return ApolloPaneCanOpenDetailInNewWindow(ApolloPaneSplitControllerFor(owner));
        }
        return [owner isKindOfClass:objc_getClass("_TtC6Apollo19PostsViewController")];
    };
    spec.title = ^NSString *(id sheet, __unused UITableViewCell *donor) {
        UIViewController *owner = ApolloPaneMenuOwner(sheet);
        return [owner isKindOfClass:objc_getClass("_TtC6Apollo22CommentsViewController")]
            ? @"Open in new window" : @"View options";
    };
    spec.image = ^UIImage *(id sheet, __unused UITableViewCell *donor) {
        BOOL detail = [ApolloPaneMenuOwner(sheet) isKindOfClass:objc_getClass("_TtC6Apollo22CommentsViewController")];
        return ApolloActionMenuSymbolIcon(detail ? @"plus.rectangle.on.rectangle" : @"slider.horizontal.3");
    };
    spec.perform = ^(id sheet) {
        UIViewController *owner = ApolloPaneMenuOwner(sheet);
        ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(owner);
        if (!owner.viewIfLoaded.window || !pane) return;
        if ([owner isKindOfClass:objc_getClass("_TtC6Apollo22CommentsViewController")]) {
            if (ApolloPaneCanOpenDetailInNewWindow(pane)) ApolloPaneOpenDetailInNewWindow(pane);
            return;
        }
        // Classic Apollo sheets get the same actions in an anchored action
        // sheet after their dismissal; glass menus use the submenu below.
        NSArray<ApolloPaneViewOption *> *options = ApolloPaneViewOptions(owner);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"View options" message:nil
            preferredStyle:UIAlertControllerStyleActionSheet];
        for (ApolloPaneViewOption *option in options) {
            NSString *title = option.selected ? [option.title stringByAppendingString:@" (Current)"] : option.title;
            [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *selected) {
                    option.perform();
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        alert.popoverPresentationController.sourceView = owner.navigationController.navigationBar;
        alert.popoverPresentationController.sourceRect = owner.navigationController.navigationBar.bounds;
        [owner presentViewController:alert animated:YES completion:nil];
    };
    spec.buildElement = ^(id sheet, NSMutableArray<UIMenuElement *> *children) {
        UIViewController *owner = ApolloPaneMenuOwner(sheet);
        if ([owner isKindOfClass:objc_getClass("_TtC6Apollo22CommentsViewController")]) {
            UISplitViewController *pane = ApolloPaneSplitControllerFor(owner);
            if (!ApolloPaneCanOpenDetailInNewWindow(pane)) return;
            __weak UISplitViewController *weakPane = pane;
            __weak id weakSheet = sheet;
            [children addObject:[UIAction actionWithTitle:@"Open in new window"
                image:ApolloActionMenuSymbolIcon(@"plus.rectangle.on.rectangle") identifier:nil
                handler:^(__unused UIAction *action) {
                    dispatch_block_t open = ^{ ApolloPaneOpenDetailInNewWindow(weakPane); };
                    if (!ApolloNativeActionMenuPerformAfterDismissal(weakSheet, open)) open();
                }]];
        } else {
            NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
            __weak id weakSheet = sheet;
            for (ApolloPaneViewOption *option in ApolloPaneViewOptions(owner)) {
                UIAction *action = [UIAction actionWithTitle:option.title image:ApolloActionMenuSymbolIcon(option.symbol)
                    identifier:nil handler:^(__unused UIAction *selected) {
                        // Changing density/geometry must wait for the menu to
                        // release its source navigation surface.
                        if (!ApolloNativeActionMenuPerformAfterDismissal(weakSheet, option.perform)) option.perform();
                    }];
                action.state = option.selected ? UIMenuElementStateOn : UIMenuElementStateOff;
                [actions addObject:action];
            }
            if (actions.count) [children addObject:[UIMenu menuWithTitle:@"View options"
                image:ApolloActionMenuSymbolIcon(@"slider.horizontal.3") identifier:nil options:0 children:actions]];
        }
    };
    ApolloActionMenuRegister(spec);
}
