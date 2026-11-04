#import "ApolloDuoSplitView.h"
#import "ApolloDuoUIKitCompatibility.h"
#import "ApolloDuoSubsChrome.h"

#import "ApolloCommon.h"
#import "ApolloDeviceGeometry.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"
#import "ApolloThemeRuntime.h"
#import "ApolloNavigationActions.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

// Completes RedditList chrome on Duo. Open Regular width otherwise
// leading-aligns the title and often hides the iPhone Edit / floating
// +. Closed Compact already has stock chrome — we only nudge the +
// off corners / the cover gear. Regular iPhone is a restore/no-op.
//
// Reuses Apollo's editButtonItem and tappedAddBarButtonItem:. Does
// not invent a second add-subreddit flow. Does not write
// layoutMargins or re-toggle constraints (25f8a7b hang).

static char kApolloDuoSubsChromeAppliedKey;
static char kApolloDuoSubsChromeFABKey;
static char kApolloDuoSubsChromeEditButtonKey;
static char kApolloDuoSubsChromeTitleViewKey;
static char kApolloDuoSubsChromeSavedRightItemsKey;
static char kApolloDuoSubsChromeSavedLargeTitleKey;
static char kApolloDuoSubsChromeSavedTitleKey;
static char kApolloDuoSubsChromeClaimedFABKey;
static char kApolloDuoSubsChromeRetryKey;
static char kApolloDuoSubsChromeEditPresentedKey;
static char kApolloDuoSubsChromeNativeEditItemKey;
static char kApolloDuoSubsChromeNativeEditButtonKey;
static char kApolloDuoEditOnlyAppliedKey;
static char kApolloDuoEditOnlySavedLeftItemsKey;
static char kApolloDuoEditOnlySavedRightItemsKey;
static char kApolloDuoEditOnlySavedSupplementKey;
static char kApolloDuoSubsPopupBarKey;
static char kApolloDuoSubsPopupLeftItemsKey;
static char kApolloDuoSubsPopupRightItemsKey;

static void ApolloDuoSubsChromeToggleEditing(UIViewController *controller);

static BOOL ApolloDuoSubsChromeNameLooksLikeRedditList(const char *name) {
    return name && strstr(name, "RedditListViewController") != NULL;
}

BOOL ApolloDuoSubsChromeControllerIsRedditList(UIViewController *controller) {
    return controller && ApolloDuoSubsChromeNameLooksLikeRedditList(class_getName(controller.class));
}

static BOOL ApolloDuoSubsChromeExpectsTrailingRail(UIViewController *controller) {
    if (!controller.isViewLoaded) return NO;
    if (ApolloDuoCurrentMode() == ApolloDuoModeClosed) return YES;
    if (controller.view.safeAreaInsets.right > 60.0) return YES;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    UITabBar *bar = [tabs isKindOfClass:UITabBarController.class] ? tabs.tabBar : nil;
    CGRect frame = bar.frame;
    return bar && !bar.hidden && CGRectGetWidth(frame) < 100.0
        && CGRectGetHeight(frame) > 200.0
        && CGRectGetMidX(frame) > CGRectGetWidth(controller.view.bounds) * 0.70;
}

static void ApolloDuoSubsChromeRetryAfterNativeLayout(UIViewController *controller) {
    NSInteger attempt = [objc_getAssociatedObject(controller, &kApolloDuoSubsChromeRetryKey) integerValue];
    if (attempt >= 4) return;
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeRetryKey, @(attempt + 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController.view.window) ApolloDuoSubsChromeApply(strongController);
    });
}

static UIBarButtonItem *ApolloDuoSubsChromeAddBarButtonItem(UIViewController *controller) {
    Ivar ivar = class_getInstanceVariable(controller.class, "addBarButtonItem");
    if (!ivar) ivar = class_getInstanceVariable(controller.class, "_addBarButtonItem");
    id value = ivar ? object_getIvar(controller, ivar) : nil;
    return [value isKindOfClass:[UIBarButtonItem class]] ? value : nil;
}

static void ApolloDuoSubsChromeApplyPopupItems(UIViewController *controller, UINavigationBar *bar) {
    UIBarButtonItem *add = ApolloDuoSubsChromeAddBarButtonItem(controller);
    UIBarButtonItem *edit = controller.editButtonItem;
    ApolloNavigationActionsSetNativeEditingAccent(edit, IsLiquidGlass() && controller.isEditing);
    if (@available(iOS 27.1, *)) {
        if (add.axisBehavior != UIBarButtonItemAxisBehaviorHorizontalOnly) {
            add.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        }
        if (edit.axisBehavior != UIBarButtonItemAxisBehaviorHorizontalOnly) {
            edit.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        }
    }
    // A bar item must have only one rendering owner. In particular, leaving
    // Add on the hidden managed bar lets Duo's screen rail claim its view.
    UINavigationItem *nativeItem = controller.navigationItem;
    if (nativeItem.leftBarButtonItems.count) nativeItem.leftBarButtonItems = nil;
    if (nativeItem.rightBarButtonItems.count) nativeItem.rightBarButtonItems = nil;
    UINavigationItem *popupItem = bar.topItem;
    NSArray *left = add ? @[add] : @[];
    NSArray *right = edit ? @[edit] : @[];
    if (![popupItem.leftBarButtonItems ?: @[] isEqualToArray:left]) popupItem.leftBarButtonItems = left;
    if (![popupItem.rightBarButtonItems ?: @[] isEqualToArray:right]) popupItem.rightBarButtonItems = right;
}

void ApolloDuoSubsChromeSetPopupNavigationBar(UIViewController *controller, UINavigationBar *bar) {
    UINavigationBar *previous = objc_getAssociatedObject(controller, &kApolloDuoSubsPopupBarKey);
    if (bar == previous) return;
    if (previous) {
        ApolloNavigationActionsSetNativeEditingAccent(controller.editButtonItem, NO);
        // Release the standalone item's ownership before native navigation
        // rebuilds the cover bar with these same actions.
        previous.topItem.leftBarButtonItems = nil;
        previous.topItem.rightBarButtonItems = nil;
        [previous setItems:@[] animated:NO];
        controller.navigationItem.leftBarButtonItems = objc_getAssociatedObject(controller, &kApolloDuoSubsPopupLeftItemsKey);
        controller.navigationItem.rightBarButtonItems = objc_getAssociatedObject(controller, &kApolloDuoSubsPopupRightItemsKey);
        objc_setAssociatedObject(controller, &kApolloDuoSubsPopupLeftItemsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, &kApolloDuoSubsPopupRightItemsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(controller, &kApolloDuoSubsPopupBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!bar) return;
    objc_setAssociatedObject(controller, &kApolloDuoSubsPopupLeftItemsKey,
                             controller.navigationItem.leftBarButtonItems ?: @[], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(controller, &kApolloDuoSubsPopupRightItemsKey,
                             controller.navigationItem.rightBarButtonItems ?: @[], OBJC_ASSOCIATION_COPY_NONATOMIC);
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@""];
    item.hidesBackButton = YES;
    [bar setItems:@[item] animated:NO];
    ApolloDuoSubsChromeApplyPopupItems(controller, bar);
}

static BOOL ApolloDuoSubsChromeItemLooksLikeEdit(UIBarButtonItem *item, UIBarButtonItem *editItem) {
    if (!item) return NO;
    if (editItem && item == editItem) return YES;
    NSString *title = item.title;
    return [title isEqualToString:@"Edit"] || [title isEqualToString:@"Done"];
}

static BOOL ApolloDuoSubsChromeItemLooksLikeAdd(UIBarButtonItem *item, UIBarButtonItem *addItem) {
    if (!item) return NO;
    if (addItem && item == addItem) return YES;
    if (item.action == NSSelectorFromString(@"tappedAddBarButtonItem:")) return YES;
    NSString *label = item.accessibilityLabel;
    return [label isEqualToString:@"Add"] || [label isEqualToString:@"New"];
}

static BOOL ApolloDuoSubsChromeViewLooksLikeFAB(UIView *view) {
    if (![view isKindOfClass:[UIControl class]]) return NO;
    CGFloat w = CGRectGetWidth(view.bounds);
    CGFloat h = CGRectGetHeight(view.bounds);
    if (w < 40.0 || w > 72.0 || h < 40.0 || h > 72.0) return NO;
    return fabs(w - h) <= 10.0;
}

static BOOL ApolloDuoSubsChromeTrailingRailFrame(UIViewController *controller,
                                                  CGRect *outFrame) {
    // During UIKit's root navigation rebuild the compatibility layer can
    // briefly report Phone even though the vertical tab rail is already live.
    // The visible rail geometry is the durable source of truth here.
    if (!controller.isViewLoaded) return NO;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return NO;
    UITabBar *bar = tabs.tabBar;
    if (!bar || bar.hidden || !bar.window) return NO;

    // UIKit installs the vertical UITabBar directly in the tab controller's
    // full-screen coordinate space. Its frame is already the reliable screen
    // geometry; converting its bounds through the SwiftUI-backed host applies
    // an extra content-safe-area offset.
    CGRect rawBarFrame = bar.frame;
    if (CGRectGetWidth(rawBarFrame) < 100.0
        && CGRectGetHeight(rawBarFrame) > 200.0
        && CGRectGetMidX(rawBarFrame) > CGRectGetWidth(controller.view.bounds) * 0.70) {
        const CGFloat platterWidth = 48.0;
        const CGFloat itemPitch = 50.0;
        const CGFloat platterPadding = 12.0;
        NSUInteger itemCount = MAX(bar.items.count, tabs.viewControllers.count);
        // Apollo always exposes its five primary tabs. iOS 27's new UITab API
        // can leave both legacy collections empty even while all five buttons
        // are visible, so retain the known primary-tab count as the floor.
        itemCount = MAX(itemCount, (NSUInteger)5);
        CGFloat platterHeight = itemPitch * itemCount + platterPadding;
        // The raw 69pt iOS 27 tab container ends at the screen edge. Its
        // 48pt glass platter begins 3pt before that container and leaves the
        // remaining 24pt for the Duo's rounded screen corner. Derive that
        // physical edge inset from the raw frame; window.safeAreaInsets.right
        // includes the rail itself and would shift Edit an extra 76pt left.
        const CGFloat physicalEdgeInset = 24.0;
        UIWindow *window = controller.view.window;
        CGRect hostBounds = window ? window.bounds : controller.view.bounds;
        CGFloat platterX = CGRectGetWidth(hostBounds)
            - physicalEdgeInset - platterWidth;
        CGRect platterFrame = CGRectMake(platterX,
                                         CGRectGetHeight(hostBounds)
                                             - physicalEdgeInset - platterHeight,
                                         platterWidth,
                                         platterHeight);
        if (outFrame) *outFrame = platterFrame;
        return YES;
    }

    // The iOS 27 vertical UITabBar itself spans the full window height and
    // extends to the screen edge. Its visible Liquid Glass platter is a
    // separate sibling under the tab container. Find that platter so the
    // Edit button aligns with the 48pt rail and, crucially, sits above the
    // platter rather than above the full-height UITabBar frame.
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:tabs.view];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 240) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        const char *name = class_getName(view.class);
        if (!name || !strstr(name, "UITabBarExpansionPlatterContainer")) continue;
        // UIKit's SwiftUI-backed floating bar uses a hosted coordinate space
        // where direct sibling conversion produces an offset result. Resolve
        // through window coordinates, which match the on-screen glass frame.
        CGRect candidate = [view convertRect:view.bounds
                                      toView:controller.view.window];
        CGFloat width = CGRectGetWidth(candidate);
        CGFloat height = CGRectGetHeight(candidate);
        if (width < 40.0 || width >= 100.0 || height < 200.0) continue;
        if (CGRectGetMidX(candidate) < CGRectGetWidth(controller.view.bounds) * 0.70) continue;
        if (outFrame) *outFrame = candidate;
        return YES;
    }

    // Keep a geometry fallback for future UIKit class-name changes. It is
    // sufficient to recognize a trailing rail, but only use it for placement
    // when it has already been reduced to a finite vertical platter.
    CGRect frame = rawBarFrame;
    if (CGRectGetWidth(frame) >= 100.0 || CGRectGetHeight(frame) < 200.0) return NO;
    if (CGRectGetMidX(frame) < CGRectGetWidth(controller.view.bounds) * 0.70) return NO;
    if (CGRectGetMinY(frame) < 80.0 && CGRectGetMaxY(frame) > CGRectGetHeight(controller.view.bounds) - 20.0) {
        return NO;
    }
    if (outFrame) *outFrame = frame;
    return YES;
}

static UIButton *ApolloDuoSubsChromeMakeEditButton(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0.0, 0.0, 48.0, 48.0);
    button.hidden = YES;
    button.accessibilityHint = @"Toggles editing for the Subreddits list.";
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UIViewController *strongController = weakController;
        ApolloDuoSubsChromeToggleEditing(strongController);
    }] forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeEditButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

static void ApolloDuoSubsChromeUpdateEditButton(UIButton *button,
                                                 UIViewController *controller) {
    BOOL editing = controller.isEditing;
    NSString *title = editing ? @"Done" : @"Edit";
    NSString *symbolName = editing ? @"checkmark" : @"pencil";
    UIImageSymbolConfiguration *symbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:symbolName
                              withConfiguration:symbolConfiguration];
    // Rebuild the Edit state from a neutral semantic colour. UIKit can retain
    // the previous prominent configuration's blue base tint after the button
    // leaves the screen and is reattached, which made the pencil blue after a
    // Done -> tab switch -> Edit cycle.
    UIColor *foreground = editing ? UIColor.whiteColor : UIColor.labelColor;
    symbol = [symbol imageWithTintColor:foreground
                          renderingMode:UIImageRenderingModeAlwaysOriginal];
    button.accessibilityLabel = title;
    if (@available(iOS 26.0, *)) {
        UIButtonConfiguration *configuration = editing
            ? [UIButtonConfiguration prominentGlassButtonConfiguration]
            : [UIButtonConfiguration glassButtonConfiguration];
        configuration.title = nil;
        configuration.image = symbol;
        configuration.baseForegroundColor = foreground;
        if (editing) configuration.baseBackgroundColor = UIColor.systemBlueColor;
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        configuration.contentInsets = NSDirectionalEdgeInsetsZero;
        button.configuration = configuration;
    } else {
        [button setTitle:nil forState:UIControlStateNormal];
        [button setImage:symbol forState:UIControlStateNormal];
        button.backgroundColor = editing ? UIColor.systemBlueColor : UIColor.tertiarySystemFillColor;
        button.layer.cornerRadius = 24.0;
    }
    button.tintColor = foreground;
}

static void ApolloDuoSubsChromeRemoveSideEdit(UIViewController *controller) {
    UIButton *button = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeEditButtonKey);
    if (button.superview) [button removeFromSuperview];
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeEditButtonKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloDuoSubsChromeRemoveFloatingEdit(UIViewController *controller) {
    ApolloDuoSubsChromeRemoveSideEdit(controller);
}

static BOOL ApolloDuoSubsChromeSideAddFrame(UIViewController *controller,
                                             CGRect railFrame,
                                             CGRect *outFrame) {
    UIView *root = controller.view.window;
    if (!root) return NO;
    UIView *sideEdit = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeEditButtonKey);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 420) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view == sideEdit || [view isDescendantOfView:sideEdit]) continue;
        for (UIView *subview in view.subviews) [stack addObject:subview];
        const char *name = class_getName(view.class);
        if (!name || !strstr(name, "UIPlatformGlassInteractionView")) continue;
        CGRect frame = [view convertRect:view.bounds toView:root];
        CGFloat width = CGRectGetWidth(frame);
        CGFloat height = CGRectGetHeight(frame);
        if (width < 40.0 || width > 64.0 || height < 40.0 || height > 64.0) continue;
        if (CGRectGetMaxY(frame) >= CGRectGetMinY(railFrame)) continue;
        if (fabs(CGRectGetMidX(frame) - CGRectGetMidX(railFrame)) > 16.0) continue;
        CGRect canonicalFrame = CGRectMake(round(CGRectGetMidX(frame) - 24.0),
                                           round(CGRectGetMidY(frame) - 24.0),
                                           48.0,
                                           48.0);
        if (outFrame) *outFrame = canonicalFrame;
        return YES;
    }
    return NO;
}

static BOOL ApolloDuoSubsChromeEnsureSideEdit(UIViewController *controller) {
    CGRect railFrame = CGRectZero;
    if (!ApolloDuoSubsChromeTrailingRailFrame(controller, &railFrame)) {
        ApolloDuoSubsChromeRemoveSideEdit(controller);
        if (ApolloDuoSubsChromeExpectsTrailingRail(controller)) {
            ApolloDuoSubsChromeRetryAfterNativeLayout(controller);
            return YES;
        }
        return NO;
    }

    UIButton *button = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeEditButtonKey);
    if (!button) button = ApolloDuoSubsChromeMakeEditButton(controller);
    UIView *host = controller.view.window ?: controller.view;
    if (button.superview != host) {
        [button removeFromSuperview];
        [host addSubview:button];
    }
    ApolloDuoSubsChromeUpdateEditButton(button, controller);

    const CGFloat size = 48.0;
    CGRect addFrame = CGRectZero;
    BOOL hasSideAdd = ApolloDuoSubsChromeSideAddFrame(controller, railFrame, &addFrame);
    if (!hasSideAdd) {
        button.hidden = YES;
        ApolloDuoSubsChromeRetryAfterNativeLayout(controller);
        return YES;
    }
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeRetryKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const CGFloat gap = CGRectGetHeight(addFrame) >= 46.0 ? 12.0 : 17.0;
    CGFloat editY = round(CGRectGetMaxY(addFrame) + gap);
    CGRect frame = CGRectMake(CGRectGetMidX(railFrame) - size * 0.5,
                              editY,
                              size,
                              size);
    if (!CGRectEqualToRect(button.frame, frame)) button.frame = frame;
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin
        | UIViewAutoresizingFlexibleTopMargin;
    [host bringSubviewToFront:button];

    if (![objc_getAssociatedObject(button, &kApolloDuoSubsChromeEditPresentedKey) boolValue]) {
        objc_setAssociatedObject(button, &kApolloDuoSubsChromeEditPresentedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        button.hidden = NO;
        button.alpha = 0.0;
        button.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0.0, -12.0),
                                                   CGAffineTransformMakeScale(0.86, 0.86));
        [button layoutIfNeeded];
        [UIView animateWithDuration:0.48
                              delay:0.0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.25
                            options:UIViewAnimationOptionBeginFromCurrentState
                                  | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            button.alpha = 1.0;
            button.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        button.hidden = NO;
    }
    return YES;
}

static BOOL ApolloDuoSubsChromeCanUseNativeSideEdit(UIViewController *controller) {
    if (!IsLiquidGlass()) return NO;
    CGRect railFrame = CGRectZero;
    if (!ApolloDuoSubsChromeTrailingRailFrame(controller, &railFrame)
        && !ApolloDuoSubsChromeExpectsTrailingRail(controller)) {
        return NO;
    }
    if (@available(iOS 27.1, *)) return YES;
    return NO;
}

static UITableView *ApolloDuoSubsChromeListTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *tableView = ApolloDuoSubsChromeListTable(subview);
        if (tableView) return tableView;
    }
    return nil;
}

static void ApolloDuoSubsChromeRestoreListAnchor(UITableView *tableView,
                                                  NSIndexPath *indexPath,
                                                  CGFloat rowDelta,
                                                  CGPoint fallbackOffset) {
    if (!tableView || tableView.dragging || tableView.tracking || tableView.decelerating) return;
    CGPoint offset = fallbackOffset;
    if (indexPath
        && indexPath.section < [tableView numberOfSections]
        && indexPath.row < [tableView numberOfRowsInSection:indexPath.section]) {
        CGRect rowFrame = [tableView rectForRowAtIndexPath:indexPath];
        offset.y = CGRectGetMinY(rowFrame) + rowDelta;
    }
    CGFloat minY = -tableView.adjustedContentInset.top;
    CGFloat maxY = MAX(minY,
        tableView.contentSize.height - CGRectGetHeight(tableView.bounds)
            + tableView.adjustedContentInset.bottom);
    offset.y = MIN(MAX(offset.y, minY), maxY);
    [tableView setContentOffset:offset animated:NO];
}

static void ApolloDuoSubsChromeToggleEditing(UIViewController *controller) {
    if (!controller) return;
    // RedditList's setEditing hook restores by row identity because editing
    // inserts the Moderator shortcut. Index-path restoration would fight it.
    if (ApolloDuoSubsChromeControllerIsRedditList(controller)) {
        [controller setEditing:!controller.isEditing animated:YES];
        return;
    }
    UITableView *tableView = ApolloDuoSubsChromeListTable(controller.view);
    NSIndexPath *anchor = tableView.indexPathsForVisibleRows.firstObject;
    CGPoint fallbackOffset = tableView.contentOffset;
    CGFloat rowDelta = 0.0;
    if (anchor) {
        rowDelta = tableView.contentOffset.y
            - CGRectGetMinY([tableView rectForRowAtIndexPath:anchor]);
    }

    [controller setEditing:!controller.isEditing animated:YES];
    ApolloDuoSubsChromeRestoreListAnchor(tableView, anchor, rowDelta, fallbackOffset);

    // UITableView applies its final editing geometry at the end of the cell
    // transition. Restore the same visible row once more after that pass, but
    // leave a user's new drag or fling alone.
    __weak UITableView *weakTableView = tableView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.34 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloDuoSubsChromeRestoreListAnchor(weakTableView, anchor, rowDelta, fallbackOffset);
    });
}

static UIBarButtonItem *ApolloDuoSubsChromeNativeEditItem(UIViewController *controller) {
    UIBarButtonItem *item = objc_getAssociatedObject(controller,
        &kApolloDuoSubsChromeNativeEditItemKey);
    if (item) return item;

    __weak UIViewController *weakController = controller;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:48.0],
        [button.heightAnchor constraintEqualToConstant:48.0],
    ]];
    button.accessibilityHint = @"Toggles editing for this list.";
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        ApolloDuoSubsChromeToggleEditing(weakController);
    }] forControlEvents:UIControlEventTouchUpInside];
    item = [[UIBarButtonItem alloc] initWithCustomView:button];
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeNativeEditItemKey,
                             item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeNativeEditButtonKey,
                             button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return item;
}

static BOOL ApolloDuoChromeHasVerticalNavigationRail(UIViewController *controller) {
    if (!controller.isViewLoaded) return NO;
    return ApolloDuoRailHasVisibleSideBar()
        || ApolloDuoCurrentMode() != ApolloDuoModePhone;
}

static void ApolloDuoChromeRestoreEditButton(UIViewController *controller) {
    if (![objc_getAssociatedObject(controller, &kApolloDuoEditOnlyAppliedKey) boolValue]) return;
    NSArray *left = objc_getAssociatedObject(controller, &kApolloDuoEditOnlySavedLeftItemsKey);
    NSArray *right = objc_getAssociatedObject(controller, &kApolloDuoEditOnlySavedRightItemsKey);
    NSNumber *supplement = objc_getAssociatedObject(controller, &kApolloDuoEditOnlySavedSupplementKey);
    controller.navigationItem.leftBarButtonItems = left.count ? left : nil;
    controller.navigationItem.rightBarButtonItems = right.count ? right : nil;
    controller.navigationItem.leftItemsSupplementBackButton = supplement.boolValue;
    objc_setAssociatedObject(controller, &kApolloDuoEditOnlyAppliedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloDuoChromeApplyEditButton(UIViewController *controller) {
    if (!controller) return;
    if (!ApolloDuoChromeHasVerticalNavigationRail(controller)) {
        ApolloDuoChromeRestoreEditButton(controller);
        return;
    }

    UINavigationItem *navigationItem = controller.navigationItem;
    if (![objc_getAssociatedObject(controller, &kApolloDuoEditOnlyAppliedKey) boolValue]) {
        objc_setAssociatedObject(controller, &kApolloDuoEditOnlySavedLeftItemsKey,
                                 navigationItem.leftBarButtonItems ?: @[],
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(controller, &kApolloDuoEditOnlySavedRightItemsKey,
                                 navigationItem.rightBarButtonItems ?: @[],
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(controller, &kApolloDuoEditOnlySavedSupplementKey,
                                 @(navigationItem.leftItemsSupplementBackButton),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, &kApolloDuoEditOnlyAppliedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIBarButtonItem *nativeEdit = controller.editButtonItem;
    UIBarButtonItem *duoEdit = ApolloDuoSubsChromeNativeEditItem(controller);
    UIButton *button = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeNativeEditButtonKey);
    ApolloDuoSubsChromeUpdateEditButton(button, controller);
    button.hidden = NO;
    duoEdit.title = nil;
    duoEdit.image = nil;
    duoEdit.accessibilityLabel = controller.isEditing ? @"Done" : @"Edit";
    duoEdit.accessibilityHint = @"Toggles editing for Filters & Blocks.";
    if (@available(iOS 26.0, *)) {
        duoEdit.identifier = @"ApolloReborn.filters.edit";
        duoEdit.hidesSharedBackground = YES;
        duoEdit.sharesBackground = NO;
    }
    if (@available(iOS 27.1, *)) {
        duoEdit.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
    }

    NSMutableArray<UIBarButtonItem *> *left = [NSMutableArray array];
    for (UIBarButtonItem *item in navigationItem.leftBarButtonItems ?: @[]) {
        if (item != duoEdit && !ApolloDuoSubsChromeItemLooksLikeEdit(item, nativeEdit)) {
            [left addObject:item];
        }
    }
    [left addObject:duoEdit];

    NSMutableArray<UIBarButtonItem *> *right = [NSMutableArray array];
    for (UIBarButtonItem *item in navigationItem.rightBarButtonItems ?: @[]) {
        if (item != duoEdit && !ApolloDuoSubsChromeItemLooksLikeEdit(item, nativeEdit)) {
            [right addObject:item];
        }
    }
    if (!navigationItem.leftItemsSupplementBackButton) navigationItem.leftItemsSupplementBackButton = YES;
    if (![navigationItem.leftBarButtonItems isEqualToArray:left]) {
        navigationItem.leftBarButtonItems = left;
    }
    if (![(navigationItem.rightBarButtonItems ?: @[]) isEqualToArray:right]) {
        navigationItem.rightBarButtonItems = right.count ? right : nil;
    }
}

static void ApolloDuoSubsChromeConfigureNativeSideItems(UIBarButtonItem *editItem,
                                                         UIBarButtonItem *addItem,
                                                         UIViewController *controller) {
    BOOL editing = controller.isEditing;
    NSString *accessibilityLabel = editing ? @"Done" : @"Edit";
    UIButton *nativeButton = objc_getAssociatedObject(controller,
        &kApolloDuoSubsChromeNativeEditButtonKey);
    ApolloDuoSubsChromeUpdateEditButton(nativeButton, controller);
    nativeButton.hidden = NO;
    editItem.title = nil;
    editItem.image = nil;
    editItem.accessibilityLabel = accessibilityLabel;
    editItem.accessibilityHint = @"Toggles editing for the Subreddits list.";

    if (@available(iOS 26.0, *)) {
        editItem.identifier = @"ApolloReborn.subreddits.edit";
        addItem.identifier = @"ApolloReborn.subreddits.add";
        editItem.hidesSharedBackground = YES;
        addItem.hidesSharedBackground = NO;
        editItem.sharesBackground = NO;
        addItem.sharesBackground = NO;
    }
    if (@available(iOS 27.1, *)) {
        editItem.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
        addItem.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
    }
}

static UIView *ApolloDuoSubsChromeFindNativeFAB(UIViewController *controller) {
    UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey);
    UIBarButtonItem *addItem = ApolloDuoSubsChromeAddBarButtonItem(controller);
    UIView *custom = addItem.customView;
    if (ApolloDuoSubsChromeViewLooksLikeFAB(custom) && custom.superview
        && custom != ours
        && custom.superview != controller.navigationController.navigationBar
        && ![custom isDescendantOfView:controller.navigationController.navigationBar]) {
        return custom;
    }

    UIView *root = controller.isViewLoaded ? controller.view : nil;
    if (!root) return nil;
    CGFloat rootW = CGRectGetWidth(root.bounds);
    CGFloat rootH = CGRectGetHeight(root.bounds);
    UIView *best = nil;
    CGFloat bestScore = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 80) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (!ApolloDuoSubsChromeViewLooksLikeFAB(view)) continue;
        if (ours && view == ours) continue;
        if ([view isDescendantOfView:controller.navigationController.navigationBar]) continue;
        CGRect inRoot = [root convertRect:view.bounds fromView:view];
        if (CGRectGetMidX(inRoot) < rootW * 0.55) continue;
        if (CGRectGetMidY(inRoot) < rootH * 0.45) continue;
        CGFloat score = CGRectGetMaxX(inRoot) + CGRectGetMaxY(inRoot);
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }
    return best;
}

static UIButton *ApolloDuoSubsChromeMakeFAB(UIViewController *controller) {
    SEL addSel = NSSelectorFromString(@"tappedAddBarButtonItem:");
    if (![controller respondsToSelector:addSel]) return nil;

    const CGFloat size = (CGFloat)ApolloDuoSubsChromeFABSize;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0.0, 0.0, size, size);
    button.accessibilityLabel = @"Add";
    button.adjustsImageWhenHighlighted = YES;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightSemibold];
    UIImage *plus = [UIImage systemImageNamed:@"plus" withConfiguration:config];
    if (plus) {
        [button setImage:[plus imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
    } else {
        [button setTitle:@"+" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
    }
    [button addTarget:controller action:addSel forControlEvents:UIControlEventTouchUpInside];
    button.layer.cornerRadius = size * 0.5;
    button.clipsToBounds = NO;
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.22;
    button.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    button.layer.shadowRadius = 6.0;
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeFABKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

static void ApolloDuoSubsChromePaintFAB(UIButton *button, UIView *host) {
    if (!button) return;
    UIColor *accent = ApolloThemeAccentColor() ?: button.tintColor ?: [UIColor systemBlueColor];
    UIColor *resolved = accent;
    if (host && [accent respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [accent resolvedColorWithTraitCollection:host.traitCollection];
    }
    BOOL light = ApolloColorIsLight(resolved);
    button.backgroundColor = resolved;
    UIColor *glyph = light ? [UIColor blackColor] : [UIColor whiteColor];
    button.tintColor = glyph;
    [button setTitleColor:glyph forState:UIControlStateNormal];
}

static void ApolloDuoSubsChromeRestoreFABLayout(UIViewController *controller) {
    NSDictionary *saved = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeClaimedFABKey);
    if (!saved) return;
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeClaimedFABKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *button = saved[@"button"];
    button.translatesAutoresizingMaskIntoConstraints = [saved[@"translatesMask"] boolValue];
    button.autoresizingMask = [saved[@"autoresizingMask"] unsignedIntegerValue];
    for (NSLayoutConstraint *constraint in saved[@"constraints"]) {
        // A native rebuild may have moved the button to a different container.
        // Restore only constraints whose items still share a hierarchy; UIKit
        // owns any replacement constraints installed during that rebuild.
        UIView *first = [constraint.firstItem isKindOfClass:UILayoutGuide.class]
            ? ((UILayoutGuide *)constraint.firstItem).owningView : constraint.firstItem;
        UIView *second = [constraint.secondItem isKindOfClass:UILayoutGuide.class]
            ? ((UILayoutGuide *)constraint.secondItem).owningView : constraint.secondItem;
        BOOL canActivate = first && !constraint.secondItem;
        for (UIView *ancestor = first; !canActivate && ancestor; ancestor = ancestor.superview) {
            canActivate = second && (ancestor == second || [second isDescendantOfView:ancestor]);
        }
        if (canActivate && !constraint.active) constraint.active = YES;
    }
    [button.superview setNeedsLayout];
}

static void ApolloDuoSubsChromeClaimFABLayout(UIView *button, UIViewController *controller) {
    if (!button || !controller) return;
    NSDictionary *saved = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeClaimedFABKey);
    if (saved[@"button"] == button) return;
    ApolloDuoSubsChromeRestoreFABLayout(controller);
    BOOL translatesMask = button.translatesAutoresizingMaskIntoConstraints;
    UIViewAutoresizing autoresizingMask = button.autoresizingMask;
    NSArray<NSLayoutConstraint *> *constraints = button.constraints;
    NSMutableArray<NSLayoutConstraint *> *disabled = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in constraints) {
        if (constraint.active) {
            constraint.active = NO;
            [disabled addObject:constraint];
        }
    }
    UIView *superview = button.superview;
    if (superview) {
        for (NSLayoutConstraint *constraint in superview.constraints) {
            if ((constraint.firstItem == button || constraint.secondItem == button)
                && constraint.active) {
                constraint.active = NO;
                [disabled addObject:constraint];
            }
        }
    }
    button.translatesAutoresizingMaskIntoConstraints = YES;
    // Keep the snapshot on the controller, not the button: constraints retain
    // their views and storing them on a descendant can retain its own ancestor.
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeClaimedFABKey,
                             @{@"button": button, @"constraints": disabled,
                               @"translatesMask": @(translatesMask),
                               @"autoresizingMask": @(autoresizingMask)},
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoSubsChromePositionFAB(UIView *button,
                                           UIViewController *controller,
                                           UIView *container,
                                           UIEdgeInsets chrome,
                                           BOOL coverLift) {
    if (!button || !container) return;
    CGFloat width = CGRectGetWidth(button.bounds);
    CGFloat height = CGRectGetHeight(button.bounds);
    if (width < 1.0) width = (CGFloat)ApolloDuoSubsChromeFABSize;
    if (height < 1.0) height = (CGFloat)ApolloDuoSubsChromeFABSize;
    double bottom = (double)chrome.bottom;
    if (coverLift && bottom < (double)ApolloDuoCoverPillBottom) {
        bottom = (double)ApolloDuoCoverPillBottom;
    }
    double right = (double)chrome.right;
    if (coverLift && right < (double)ApolloDuoCoverPillWidth) {
        right = (double)ApolloDuoCoverPillWidth;
    }
    ApolloDuoRailRect want = ApolloDuoSubsChromeFABFrame(CGRectGetWidth(container.bounds),
                                                         CGRectGetHeight(container.bounds),
                                                         right,
                                                         bottom,
                                                         (double)width,
                                                         (double)height);
    if (!ApolloDuoSubsChromeShouldNudgeFrame(button.frame.origin.x,
                                            button.frame.origin.y,
                                            want.x,
                                            want.y)
        && fabs(button.frame.size.width - want.width) < 0.5
        && fabs(button.frame.size.height - want.height) < 0.5) {
        return;
    }
    if (button != objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey)) {
        ApolloDuoSubsChromeClaimFABLayout(button, controller);
    }
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin
        | UIViewAutoresizingFlexibleTopMargin;
    button.frame = CGRectMake(want.x, want.y, want.width, want.height);
}

static void ApolloDuoSubsChromeRestore(UIViewController *controller) {
    ApolloDuoSubsChromeRestoreFABLayout(controller);
    if (!controller || !objc_getAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey)) {
        return;
    }

    NSNumber *savedMode = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey);
    if (savedMode) {
        controller.navigationItem.largeTitleDisplayMode = (UINavigationItemLargeTitleDisplayMode)savedMode.integerValue;
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *savedTitle = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey);
    if (savedTitle) {
        controller.navigationItem.title = savedTitle.length ? savedTitle : nil;
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *titleView = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey);
    if (titleView && controller.navigationItem.titleView == titleView) {
        controller.navigationItem.titleView = nil;
    }
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray *savedItems = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey);
    if (savedItems) {
        controller.navigationItem.rightBarButtonItems =
            savedItems.count ? savedItems : nil;
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey);
    if (ours.superview) [ours removeFromSuperview];
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeFABKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoSubsChromeRemoveSideEdit(controller);
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoSubsChromeEnsureTitle(UIViewController *controller, int mode, BOOL regularWidth) {
    NSString *current = controller.navigationItem.title.length
        ? controller.navigationItem.title
        : controller.title;
    if (![current isEqualToString:@"Subreddits"]) {
        if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey)) {
            objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey,
                                     current ?: @"",
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        controller.navigationItem.title = @"Subreddits";
        if (controller.title.length == 0) controller.title = @"Subreddits";
    }

    if (ApolloDuoSubsChromeShouldForceInlineTitle(mode, regularWidth)) {
        UINavigationItemLargeTitleDisplayMode currentMode =
            controller.navigationItem.largeTitleDisplayMode;
        if (currentMode != UINavigationItemLargeTitleDisplayModeNever) {
            if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey)) {
                objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey,
                                         @(currentMode),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controller.navigationItem.largeTitleDisplayMode =
                UINavigationItemLargeTitleDisplayModeNever;
        }
    }

    // Non-glass Regular width leading-aligns the native title. A
    // full-band titleView with a centered label is the stock look
    // without fighting Liquid Glass capsules (--glass uses the
    // existing title recenterer plus content-band math).
    if (IsLiquidGlass()) {
        UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey);
        if (ours && controller.navigationItem.titleView == ours) {
            controller.navigationItem.titleView = nil;
        }
        return;
    }
    if (!ApolloDuoSubsChromeShouldForceInlineTitle(mode, regularWidth)) return;
    if (controller.navigationItem.titleView
        && controller.navigationItem.titleView
            != objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey)) {
        return;
    }

    UIView *host = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey);
    UILabel *label = nil;
    if ([host isKindOfClass:[UIView class]]) {
        for (UIView *child in host.subviews) {
            if ([child isKindOfClass:[UILabel class]]) { label = (UILabel *)child; break; }
        }
    }
    if (!host) {
        host = [[UIView alloc] initWithFrame:CGRectZero];
        host.userInteractionEnabled = NO;
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontForContentSizeCategory = YES;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.75;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:label];
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey, host,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.text = @"Subreddits";
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    if ([UIFont respondsToSelector:@selector(systemFontOfSize:weight:)]) {
        font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    }
    label.font = font;
    UIColor *chrome = ApolloNavigationChromeColor() ?: label.textColor ?: [UIColor labelColor];
    label.textColor = chrome;

    UINavigationBar *bar = controller.navigationController.navigationBar;
    CGFloat barWidth = bar ? CGRectGetWidth(bar.bounds) : CGRectGetWidth(controller.view.bounds);
    UIEdgeInsets chromeInsets = ApolloDeviceChromeInsetsForView(bar ?: controller.view);
    CGFloat lead = (CGFloat)ApolloDuoSubsChromeTitleLeading(mode, (double)chromeInsets.left);
    CGFloat trail = (CGFloat)ApolloDuoSubsChromeTitleTrailing((double)chromeInsets.right);
    CGFloat width = (CGFloat)ApolloDuoSubsChromeTitleMaxWidth(lead, barWidth - trail, 0.0);
    if (width < 80.0) width = 80.0;
    CGRect frame = host.frame;
    if (ApolloDuoSubsChromeShouldNudgeFrame(frame.origin.x, frame.size.width, 0.0, (double)width)
        || fabs(frame.size.height - 44.0) > 0.5) {
        host.frame = CGRectMake(0.0, 0.0, width, 44.0);
        label.frame = host.bounds;
    }
    if (controller.navigationItem.titleView != host) {
        controller.navigationItem.titleView = host;
    }
}

static void ApolloDuoSubsChromeEnsureEdit(UIViewController *controller) {
    UIBarButtonItem *systemEditItem = controller.editButtonItem;
    UIBarButtonItem *addItem = ApolloDuoSubsChromeAddBarButtonItem(controller);
    NSArray<UIBarButtonItem *> *items = controller.navigationItem.rightBarButtonItems ?: @[];
    BOOL hasEdit = NO;
    BOOL hasAdd = NO;
    for (UIBarButtonItem *item in items) {
        if (ApolloDuoSubsChromeItemLooksLikeEdit(item, systemEditItem)) hasEdit = YES;
        if (ApolloDuoSubsChromeItemLooksLikeAdd(item, addItem)) hasAdd = YES;
    }
    BOOL nativeSideEdit = ApolloDuoSubsChromeCanUseNativeSideEdit(controller)
        && (addItem || hasAdd);
    BOOL sideEdit = nativeSideEdit ? YES : ApolloDuoSubsChromeEnsureSideEdit(controller);
    if (hasEdit && !hasAdd && !sideEdit) return;

    if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey)) {
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey,
                                 items,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    if (nativeSideEdit) {
        ApolloDuoSubsChromeRemoveSideEdit(controller);
        UIBarButtonItem *nativeEditItem = ApolloDuoSubsChromeNativeEditItem(controller);
        UIBarButtonItem *visibleAddItem = nil;
        for (UIBarButtonItem *item in items) {
            if (item == nativeEditItem || ApolloDuoSubsChromeItemLooksLikeEdit(item, systemEditItem)) {
                continue;
            }
            if (ApolloDuoSubsChromeItemLooksLikeAdd(item, addItem)) {
                visibleAddItem = item;
                break;
            }
        }
        if (!visibleAddItem) {
            for (UIBarButtonItem *item in items) {
                if (item != nativeEditItem
                    && !ApolloDuoSubsChromeItemLooksLikeEdit(item, systemEditItem)) {
                    visibleAddItem = item;
                    break;
                }
            }
        }
        if (!visibleAddItem) visibleAddItem = addItem;
        if (!visibleAddItem) return;
        ApolloDuoSubsChromeConfigureNativeSideItems(nativeEditItem, visibleAddItem, controller);

        // Apollo already publishes Add as its leading item. On the Duo,
        // UIKit moves both navigation-item sides into the trailing vertical
        // chrome. Reusing Add in the trailing array makes UIKit render the
        // same item twice, so this side owns only Edit.
        NSArray<UIBarButtonItem *> *nativeItems = @[nativeEditItem];
        BOOL identical = nativeItems.count == items.count;
        for (NSUInteger index = 0; identical && index < nativeItems.count; index++) {
            identical = nativeItems[index] == items[index];
        }
        if (!identical) {
            controller.navigationItem.rightBarButtonItems = nativeItems;
        }
        return;
    }

    NSMutableArray<UIBarButtonItem *> *next = [NSMutableArray array];
    for (UIBarButtonItem *item in items) {
        // A trailing Duo rail already gives Add its own native glass button.
        // Keep that item in the navigation model and put Edit immediately
        // below its visible platter. Other Duo postures still use the custom
        // floating Add button and therefore remove the bar item here.
        if (!sideEdit && ApolloDuoSubsChromeItemLooksLikeAdd(item, addItem)) continue;
        if (sideEdit && ApolloDuoSubsChromeItemLooksLikeEdit(item, systemEditItem)) continue;
        [next addObject:item];
    }
    if (!sideEdit && !hasEdit && systemEditItem) {
        // index 0 is the trailing-most item — Edit sits at the top right.
        [next insertObject:systemEditItem atIndex:0];
    }
    if (next.count != items.count || (!sideEdit && !hasEdit)) {
        controller.navigationItem.rightBarButtonItems = next.count
            ? next
            : (sideEdit || !systemEditItem ? nil : @[systemEditItem]);
    }
}

static void ApolloDuoSubsChromeEnsureFAB(UIViewController *controller,
                                         UIEdgeInsets chrome,
                                         BOOL coverLift) {
    if (!controller.isViewLoaded) return;
    UIView *container = controller.view;
    UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey);
    CGRect trailingRailFrame = CGRectZero;
    if (ApolloDuoSubsChromeTrailingRailFrame(controller, &trailingRailFrame)
        || ApolloDuoSubsChromeExpectsTrailingRail(controller)) {
        // UIKit already presents the native Add item above the vertical rail.
        // A second custom FAB produced the large blue + over the list.
        if (ours.superview) [ours removeFromSuperview];
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeFABKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoSubsChromeRestoreFABLayout(controller);
        return;
    }
    UIView *button = ApolloDuoSubsChromeFindNativeFAB(controller);
    if (button && ours && button != ours && ours.superview) {
        [ours removeFromSuperview];
    }
    if (!button) {
        button = ours ?: ApolloDuoSubsChromeMakeFAB(controller);
        if (!button) return;
        if (!ours) {
            ApolloLog(@"[DuoSubsChrome] installed floating + on RedditList");
        }
        ours = button;
        [container addSubview:button];
    } else if (!button.superview) {
        [container addSubview:button];
    }
    if (button.superview != container && button.superview) {
        container = button.superview;
    }
    BOOL editing = controller.isEditing;
    if (button.hidden != editing) button.hidden = editing;
    if (button == ours && [button isKindOfClass:[UIButton class]]) {
        ApolloDuoSubsChromePaintFAB((UIButton *)button, container);
    }
    if (!editing) {
        ApolloDuoSubsChromePositionFAB(button, controller, container, chrome, coverLift);
        if (button == ours) [container bringSubviewToFront:button];
    }
}

void ApolloDuoSubsChromeApply(UIViewController *controller) {
    if (!ApolloDuoSubsChromeControllerIsRedditList(controller)) return;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        ApolloDuoSubsChromeRestore(controller);
        return;
    }

    if (ApolloDuoSplitIsSidebarController(controller)) {
        ApolloDuoSubsChromeRemoveSideEdit(controller);
        ApolloDuoSubsChromeRestoreFABLayout(controller);
        UINavigationBar *popupBar = objc_getAssociatedObject(controller, &kApolloDuoSubsPopupBarKey);
        if (popupBar) {
            ApolloDuoSubsChromeApplyPopupItems(controller, popupBar);
        }
        // Before binding and during teardown, preserve the managed item's
        // native state. The standalone bar is the sole popup item owner.
        return;
    }

    // The inner portrait display has no sidebar, but still needs its native
    // text Edit item. The legacy Duo mode labels every portrait as Closed.
    // Prefer the actual regular-width navigation layout over that mode.
    if (ApolloDuoSplitIsUnfoldedPortrait()) {
        ApolloDuoSubsChromeRestore(controller);
        return;
    }

    int mode = ApolloDuoCurrentMode();
    CGRect trailingRailFrame = CGRectZero;
    BOOL hasTrailingRail = ApolloDuoSubsChromeTrailingRailFrame(controller,
                                                                &trailingRailFrame);
    // UIKit can briefly publish Phone while rebuilding a Closed Duo scene.
    // The visible trailing vertical platter is stronger evidence than that
    // transient mode value and keeps Subreddits chrome attached after launch.
    if (!ApolloDuoSubsChromeShouldApply(mode) && hasTrailingRail) {
        mode = ApolloDuoModeClosed;
    }
    if (!ApolloDuoSubsChromeShouldApply(mode)) {
        ApolloDuoSubsChromeRestore(controller);
        return;
    }

    BOOL regularWidth = controller.traitCollection.horizontalSizeClass
        == UIUserInterfaceSizeClassRegular;
    UIEdgeInsets chrome = ApolloDeviceChromeInsetsForView(controller.view);
    BOOL coverLift = ApolloDuoCoverChromeIsActive();

    ApolloDuoSubsChromeEnsureTitle(controller, mode, regularWidth);
    ApolloDuoSubsChromeEnsureEdit(controller);
    ApolloDuoSubsChromeEnsureFAB(controller, chrome, coverLift);

    if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey)) {
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[DuoSubsChrome] applied mode=%d regular=%d cover=%d editing=%d",
                  mode, regularWidth ? 1 : 0, coverLift ? 1 : 0,
                  controller.isEditing ? 1 : 0);
    }
}
