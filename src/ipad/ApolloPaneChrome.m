#import "ApolloPaneChrome.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSidebar.h"
#import "ApolloPaneSplitViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "../ApolloThemeRuntime.h"
#import "../ApolloActionMenu.h"
#import "../ApolloNativeActionMenus.h"
#import "../ApolloCommon.h"
#import "../ApolloImmersiveHeaderBackground.h"

CGRect ApolloPaneHeaderContentRect(UITableView *table, UIViewController *controller, CGFloat width) {
    CGRect content = CGRectMake(0, 0, width, 0);
    if (!ApolloPaneLayoutEnabled() || !ApolloPaneSplitControllerFor(controller)) return content;
    if (@available(iOS 26.0, *)) {
        UILayoutGuide *guide = controller.tabBarController.contentLayoutGuide;
        if (table.window && guide.owningView.window == table.window) {
            CGRect available = [guide.owningView convertRect:guide.layoutFrame toView:table];
            CGFloat left = MAX(CGRectGetMinX(table.bounds), CGRectGetMinX(available));
            CGFloat right = MIN(CGRectGetMaxX(table.bounds), CGRectGetMaxX(available));
            // A portrait sidebar may cover all but a dimmed sliver. Keep the
            // underlying column intact in that overlay presentation.
            if (right - left >= MIN(width, 340.0)) {
                content.origin.x = left - CGRectGetMinX(table.bounds);
                content.size.width = right - left;
            }
        }
    }
    return content;
}

static UITableView *ApolloPaneIdentityTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class] &&
        [((UITableView *)view).backgroundView isKindOfClass:ApolloImmersiveHeaderBackgroundView.class]) return (id)view;
    for (UIView *child in view.subviews) {
        UITableView *table = ApolloPaneIdentityTable(child);
        if (table) return table;
    }
    return nil;
}

dispatch_block_t ApolloPaneCaptureIdentityHeaderScrollAnchors(UIViewController *controller) {
    if (!ApolloPaneLayoutActive() || ![controller isKindOfClass:ApolloPaneSplitViewController.class]) return nil;
    ApolloPaneSplitViewController *pane = (id)controller;
    NSMutableArray *anchors = [NSMutableArray array];
    for (NSNumber *column in @[@(ApolloPaneColumnPrimary), @(ApolloPaneColumnSecondary)]) {
        UIViewController *top = [pane apollo_navigationControllerForColumn:column.integerValue].topViewController;
        UITableView *table = ApolloPaneIdentityTable(top.viewIfLoaded);
        if (table.window) ApolloLog(@"[PaneHeaderAnchor] transition offset=%.1f inset=%.1f resting=%d",
            table.contentOffset.y, table.adjustedContentInset.top,
            fabs(table.contentOffset.y + table.adjustedContentInset.top) <= 1.0);
        if (!table.window || !table.tableHeaderView || table.tracking || table.dragging || table.decelerating ||
            fabs(table.contentOffset.y + table.adjustedContentInset.top) > 1.0) continue;
        CGPoint offset = table.contentOffset;
        __weak UITableView *weakTable = table;
        __weak UIView *weakHeader = table.tableHeaderView;
        __weak UIViewController *weakTop = top;
        [anchors addObject:[^{
            UITableView *current = weakTable;
            UIViewController *owner = weakTop;
            UIView *header = weakHeader;
            if (!owner || !header || !current.window || current.window != owner.viewIfLoaded.window ||
                owner.navigationController.topViewController != owner ||
                current.tableHeaderView != header || current.tracking || current.dragging || current.decelerating) return;
            CGFloat resting = -current.adjustedContentInset.top;
            // Only finish UIKit's resting-offset adjustment. A user/programmatic
            // scroll that departed from both resting offsets cancels the anchor.
            if (fabs(current.contentOffset.y - offset.y) > 1.0 &&
                fabs(current.contentOffset.y - resting) > 1.0) return;
            if (fabs(current.contentOffset.y - resting) > 0.5) {
                [current setContentOffset:CGPointMake(current.contentOffset.x, resting) animated:NO];
                ApolloLog(@"[PaneHeaderAnchor] restored resting offset %.1f", resting);
            }
        } copy]];
    }
    if (!anchors.count) return nil;
    __weak ApolloPaneSplitViewController *weakPane = pane;
    return ^{
        ApolloPaneSplitViewController *owner = weakPane;
        if (!owner.viewIfLoaded.window || owner.tabBarController.selectedViewController != owner) return;
        ApolloPaneRefreshIdentityHeaderGeometry(owner);
        for (dispatch_block_t restore in anchors) restore();
    };
}

void ApolloPaneRefreshIdentityHeaderGeometry(UIViewController *controller) {
    if (!ApolloPaneLayoutActive() ||
        ![controller isKindOfClass:ApolloPaneSplitViewController.class] || !controller.viewIfLoaded.window) return;
    ApolloPaneSplitViewController *pane = (id)controller;
    // Sidebar overlap changes the content guide without necessarily changing
    // the feed controller's bounds or safe area. Finish pending column layout
    // before measuring; this runs in the pane's deferred geometry transaction,
    // never inside a layoutSubviews hook.
    [pane.view layoutIfNeeded];
    for (NSNumber *column in @[@(ApolloPaneColumnPrimary), @(ApolloPaneColumnSecondary)]) {
        UINavigationController *navigation = [pane apollo_navigationControllerForColumn:column.integerValue];
        UIViewController *top = navigation.topViewController;
        if (top.viewIfLoaded.window != pane.view.window || !top.viewIfLoaded.window) continue;
        if (!ApolloPaneRefitSubredditHeaderGeometry(top)) ApolloPaneRefitProfileHeaderGeometry(top);
    }
}

@interface ApolloPaneHeaderBackdrop : UIView
@property(nonatomic, strong) UIImageView *artwork;
@property(nonatomic, strong) UIView *scrim;
@end
@implementation ApolloPaneHeaderBackdrop
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.accessibilityIdentifier = @"ApolloPaneHeaderBackdrop";
        _artwork = [UIImageView new];
        _artwork.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:_artwork];
        _scrim = [UIView new];
        [self addSubview:_scrim];
    }
    return self;
}
@end

static char kPaneHeaderBackdrop;
void ApolloPaneRefreshHeaderBackdrop(UIViewController *controller) {
    NSString *name = NSStringFromClass(controller.class);
    if (![name hasSuffix:@"PostsViewController"] && ![name hasSuffix:@"ProfileViewController"]) return;
    ApolloPaneHeaderBackdrop *backdrop = objc_getAssociatedObject(controller, &kPaneHeaderBackdrop);
    ApolloPaneUpdateHeaderBackdrop(controller, backdrop.artwork.image, backdrop.artwork.alpha);
}

void ApolloPaneHideHeaderBackdrop(UIViewController *controller) {
    ApolloPaneHeaderBackdrop *backdrop = objc_getAssociatedObject(controller, &kPaneHeaderBackdrop);
    backdrop.hidden = YES;
    // The navigation controller outlives popped pages. Detach their plane so
    // it cannot retain an orphaned backdrop after the page itself is released.
    [backdrop removeFromSuperview];
}

void ApolloPaneUpdateHeaderBackdrop(UIViewController *controller, UIImage *artwork, CGFloat progress) {
    UINavigationController *navigation = controller.navigationController;
    UINavigationBar *bar = navigation.navigationBar;
    if (!ApolloPaneLayoutEnabled() || !ApolloPaneSplitControllerFor(controller) || !IsLiquidGlass() ||
        navigation.topViewController != controller || !bar.window || bar.hidden) {
        ApolloPaneHideHeaderBackdrop(controller);
        return;
    }
    ApolloPaneHeaderBackdrop *backdrop = objc_getAssociatedObject(controller, &kPaneHeaderBackdrop);
    if (!backdrop) {
        backdrop = [ApolloPaneHeaderBackdrop new];
        objc_setAssociatedObject(controller, &kPaneHeaderBackdrop, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[PaneChrome] installed continuous identity backdrop");
    }
    UIView *host = bar.superview;
    if (backdrop.superview != host) [host insertSubview:backdrop belowSubview:bar];
    CGRect row = [bar convertRect:bar.bounds toView:host];
    CGRect frame = CGRectMake(row.origin.x + bar.safeAreaInsets.left, 0,
                             MAX(0, row.size.width - bar.safeAreaInsets.left - bar.safeAreaInsets.right),
                             CGRectGetMaxY(row));
    if (!CGRectEqualToRect(backdrop.frame, frame)) {
        backdrop.frame = frame;
        backdrop.artwork.frame = backdrop.bounds;
        backdrop.scrim.frame = backdrop.bounds;
    }
    UIColor *page = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    backdrop.backgroundColor = page;
    backdrop.scrim.backgroundColor = page;
    backdrop.scrim.alpha = 0.72;
    backdrop.artwork.image = artwork;
    backdrop.artwork.alpha = MIN(1, MAX(0, progress));
    backdrop.hidden = NO;
}

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
    ApolloPaneRefreshHeaderBackdrop(controller);
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
