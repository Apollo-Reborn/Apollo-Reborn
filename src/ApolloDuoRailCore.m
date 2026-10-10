// Adapt Apollo's content to UIKit's native trailing tab rail. UIKit owns the
// tab bar and UISplitViewController owns columns; no replacement rail or
// manual navigation/table frame expansion is installed here.
#import "ApolloDuoSplitView.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"
#import "ApolloCommon.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloAutoHideTabBar.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdbool.h>
#import <stdatomic.h>

static char kApolloDuoRailModeKey;
static char kApolloDuoAdaptiveBarsKey;
static char kApolloDuoRailSavedIndicatorInsetsKey;

static BOOL ApolloDuoRailDualDisplays(void) {
    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
    for (UIScreen *screen in [UIScreen screens]) {
        // AirPlay / cable mirroring adds another, usually larger screen on
        // ordinary iPhones. It must not enable Duo-only chrome or disable
        // Pixel Pals on the phone's own display.
        if (screen.mirroredScreen) continue;
        CGSize size = screen.bounds.size;
        if (size.width <= 0.0 || size.height <= 0.0) continue;
        BOOL seen = NO;
        for (NSValue *value in sizes) {
            CGSize existing = value.CGSizeValue;
            if (fabs(existing.width - size.width) < 1.0 && fabs(existing.height - size.height) < 1.0) {
                seen = YES;
                break;
            }
        }
        if (!seen) [sizes addObject:[NSValue valueWithCGSize:size]];
    }
    if (sizes.count < 2) return NO;
    CGSize a = sizes[0].CGSizeValue;
    CGSize b = sizes[1].CGSizeValue;
    return ApolloDisplayScreensAreDual(a.width, a.height, b.width, b.height);
}

static int ApolloDuoRailModeForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) {
        return ApolloDuoModePhone;
    }
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return ApolloDuoModePhone;
    }
    UIWindow *window = tabs.view.window ?: ApolloDeviceAppWindow();
    return ApolloDuoModeFromWindow(window, ApolloDuoRailDualDisplays() ? 1 : 0);
}

static int ApolloDuoRailCurrentMode(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    NSNumber *stored = objc_getAssociatedObject(tabs, &kApolloDuoRailModeKey);
    if (stored) return stored.intValue;
    return ApolloDuoRailModeForTabs(tabs);
}

int ApolloDuoCurrentMode(void) {
    return ApolloDuoRailCurrentMode();
}

BOOL ApolloDuoDeviceDetected(void) {
    // Once the cover/inner displays or native Duo canvas prove the capability,
    // keep it through folds and temporarily detached bars. Never cache an early
    // NO, and never inspect UIKit geometry from a SpriteKit background callback.
    static atomic_bool knownDuo = false;
    if (atomic_load_explicit(&knownDuo, memory_order_relaxed)) return YES;
    if (!NSThread.isMainThread ||
        UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    BOOL duo = ApolloDuoRailDualDisplays() ||
        ApolloDuoRailCurrentMode() != ApolloDuoModePhone || ApolloDuoRailHasVisibleSideBar();
    if (duo) atomic_store_explicit(&knownDuo, true, memory_order_relaxed);
    return duo;
}

BOOL ApolloDuoUsesAdaptiveBars(void) {
    if (!IsLiquidGlass() || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class]) return NO;
    NSNumber *known = objc_getAssociatedObject(tabs, &kApolloDuoAdaptiveBarsKey);
    if (!known) {
        // Cache device capability rather than a visible-bar test. A hidden or
        // temporarily detached rail must never enable bottom-bar animations.
        BOOL duo = ApolloDuoRailCurrentMode() != ApolloDuoModePhone || ApolloDuoRailDualDisplays();
        known = @(duo);
        objc_setAssociatedObject(tabs, &kApolloDuoAdaptiveBarsKey, known, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return known.boolValue;
}

BOOL ApolloDuoAllowsTabBarScrollHiding(void) {
    return !ApolloDuoUsesAdaptiveBars() ||
        (!ApolloDuoSplitIsResizing() && ApolloDuoSplitIsUnfoldedPortrait());
}

BOOL ApolloDuoRailHasVisibleSideBar(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return NO;
    UITabBar *bar = tabs.tabBar;
    if (!bar.window || bar.hidden) return NO;
    CGRect frame = [bar convertRect:bar.bounds toView:tabs.view];
    return CGRectGetWidth(frame) < 100.0
        && CGRectGetHeight(frame) > 250.0
        && CGRectGetMaxX(frame) >= CGRectGetWidth(tabs.view.bounds) - 2.0;
}

// Closed-display alphabet indexes remain immediately beside the native rail.
void ApolloDuoRailPinSectionIndex(UITableView *tableView) {
    if (!tableView || !ApolloDuoRailHasVisibleSideBar()
        || ApolloDuoRailCurrentMode() != ApolloDuoModeClosed) return;
    CGFloat wantMaxX = CGRectGetWidth(tableView.bounds) - ApolloDuoRailWidthClosed;
    for (UIView *subview in tableView.subviews) {
        const char *name = class_getName(subview.class);
        if (!name || !strstr(name, "TableViewIndex")) continue;
        CGRect frame = subview.frame;
        if (fabs(CGRectGetMaxX(frame) - wantMaxX) < 0.5) continue;
        frame.origin.x = MAX(0.0, wantMaxX - CGRectGetWidth(frame));
        subview.frame = frame;
    }
}

// UIKit normally propagates the vertical UITabBar's occluded width into the
// selected content controller. During a push on Closed Duo that propagation
// can arrive one layout late, so the first feed/post frame is built beneath
// the rail. Reserve the rail plus the same 15pt content gap explicitly on the
// content view controllers. Keep the navigation controller itself full-width
// so its title and vertical navigation-action pills stay in their native rail.
static CGFloat ApolloDuoClosedContentRightInset(UITabBarController *tabs) {
    UITabBar *bar = tabs.tabBar;
    if (bar.window && !bar.hidden) {
        CGRect frame = [bar convertRect:bar.bounds toView:tabs.view];
        if (CGRectGetWidth(frame) < 100.0 && CGRectGetHeight(frame) > 250.0) {
            return MAX(0.0, CGRectGetWidth(tabs.view.bounds) - CGRectGetMinX(frame) + 15.0);
        }
    }
    // The stock Closed rail is 69pt in the current runtime. Use the declared
    // 72pt rail width plus a 12pt fallback gap until its first frame is live.
    return (CGFloat)ApolloDuoRailWidthClosed + 12.0;
}

static BOOL ApolloDuoRailIsFeedContentController(UIViewController *controller) {
    NSString *name = NSStringFromClass(controller.class);
    return [name isEqualToString:@"Apollo.PostsViewController"]
        || [name isEqualToString:@"Apollo.CommentsViewController"]
        // Account > Comments uses its own Texture controller, including
        // inline media and the attached post preview beneath each comment.
        || [name isEqualToString:@"Apollo.UserCommentsViewController"]
        || [name isEqualToString:@"Apollo.ProfileViewController"];
}

static char kApolloDuoFeedTableKey;

void ApolloDuoRailPrepareFeedContent(UIViewController *controller) {
    if (!ApolloDuoRailIsFeedContentController(controller)) return;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (ApolloDuoRailModeForTabs(tabs) != ApolloDuoModeClosed
        && !ApolloDuoRailHasVisibleSideBar()) return;
    // UIKit supplies the native rail safe area once this view is attached.
    // Do not pre-add that width as additionalSafeAreaInsets: on the first
    // attachment UIKit would add it again and narrow post content twice.
    // The measurement hook below covers Texture's pre-attachment sizing.
    [controller loadViewIfNeeded];
    Ivar ivar = class_getInstanceVariable(controller.class, "tableNode");
    id node = ivar ? object_getIvar(controller, ivar) : nil;
    UIView *table = [node respondsToSelector:@selector(view)]
        ? ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view)) : nil;
    if ([table isKindOfClass:UITableView.class]) {
        objc_setAssociatedObject(table, &kApolloDuoFeedTableKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

CGFloat ApolloDuoRailFeedContentWidth(UITableView *table) {
    if (!NSThread.isMainThread) return 0.0;
    if (![objc_getAssociatedObject(table, &kApolloDuoFeedTableKey) boolValue]) return 0.0;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class]) return 0.0;
    // During a display resize the bar may be detached and the table may
    // still carry its old bounds. Neither is a valid measurement fallback.
    CGFloat transitionWidth = ApolloDuoSplitTransitionContentWidth(table,
        (CGFloat)ApolloDuoRailWidthClosed + 12.0);
    if (transitionWidth > 0.0) return transitionWidth;
    if (ApolloDuoSplitIsUnfoldedPortrait()) return 0.0;
    if (ApolloDuoRailModeForTabs(tabs) != ApolloDuoModeClosed
        && !ApolloDuoRailHasVisibleSideBar()) return 0.0;
    CGFloat width = CGRectGetWidth(tabs.view.bounds) - ApolloDuoClosedContentRightInset(tabs);
    if (table.window) {
        // UIKit keeps the secondary table full-screen beneath the primary
        // column. Texture must measure in the visible safe area on *every*
        // reload (including a sort change), not in that backing surface.
        UIEdgeInsets safe = table.safeAreaInsets;
        width = MIN(width, CGRectGetWidth(table.bounds) - safe.left - safe.right);
    }
    return MIN(CGRectGetWidth(table.bounds), MAX(0.0, width));
}

static BOOL ApolloDuoCoverShouldApplyForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return NO;
    if (tabs.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) return NO;
    return ApolloDuoCoverChromeShouldApply(0, ApolloDuoRailDualDisplays() ? 1 : 0);
}

BOOL ApolloDuoCoverChromeIsActive(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    return ApolloDuoCoverShouldApplyForTabs(tabs);
}

static BOOL ApolloDuoCoverClassLooksLikeComments(Class cls) {
    const char *name = class_getName(cls);
    return name && strstr(name, "CommentsViewController");
}

static UIView *ApolloDuoCoverFindJumpButton(UIViewController *comments) {
    Ivar ivar = class_getInstanceVariable(comments.class, "commentJumpButton");
    id buttonObject = ivar ? object_getIvar(comments, ivar) : nil;
    UIView *button = [buttonObject isKindOfClass:[UIView class]] ? buttonObject : nil;
    if ([button isKindOfClass:[UIView class]]) return button;
    SEL viewSelector = NSSelectorFromString(@"view");
    if ([buttonObject respondsToSelector:viewSelector]) {
        id nodeView = ((id (*)(id, SEL))objc_msgSend)(buttonObject, viewSelector);
        if ([nodeView isKindOfClass:[UIView class]]) return nodeView;
    }

    UIView *root = comments.view;
    if (!root) return nil;
    CGFloat rootW = CGRectGetWidth(root.bounds);
    CGFloat rootH = CGRectGetHeight(root.bounds);
    UIView *best = nil;
    CGFloat bestScore = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 120) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (![view isKindOfClass:[UIControl class]]) continue;
        CGFloat w = CGRectGetWidth(view.bounds);
        CGFloat h = CGRectGetHeight(view.bounds);
        if (w < 36.0 || w > 72.0 || h < 36.0 || h > 72.0) continue;
        if (fabs(w - h) > 8.0) continue;
        CGRect inRoot = [root convertRect:view.bounds fromView:view];
        if (CGRectGetMidX(inRoot) < rootW * 0.55) continue;
        if (CGRectGetMidY(inRoot) < rootH * 0.55) continue;
        CGFloat score = CGRectGetMaxX(inRoot) + CGRectGetMaxY(inRoot);
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }
    return best;
}

void ApolloDuoCoverAdjustJumpButton(UIViewController *comments) {
    if (!comments || !ApolloDuoCoverClassLooksLikeComments(comments.class)) return;
    BOOL coverChrome = ApolloDuoCoverChromeIsActive();
    BOOL trailingRail = ApolloDuoRailHasVisibleSideBar();
    if ((!coverChrome && !trailingRail) || !comments.isViewLoaded) return;

    UIView *button = ApolloDuoCoverFindJumpButton(comments);
    if (![button isKindOfClass:[UIView class]] || !button.superview) return;
    UIView *container = button.superview;
    CGRect frame = button.frame;
    // The button is a child of ASTableView. Its frame is in *content*
    // coordinates, while bounds.origin tracks scrolling. Using height alone
    // clamps the native contentOffset-adjusted Y back to a fixed content Y,
    // which makes the button scroll away with the comments.
    CGFloat limitX = CGRectGetMaxX(container.bounds);
    CGFloat limitY = CGRectGetMaxY(container.bounds);
    if (coverChrome) {
        limitX -= (CGFloat)ApolloDuoCoverPillWidth;
        limitY -= (CGFloat)ApolloDuoCoverPillBottom;
    }
    if (trailingRail) {
        UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
        UIView *sideBar = nil;
        if ([tabs isKindOfClass:[UITabBarController class]]) {
            sideBar = tabs.tabBar;
        }
        if (sideBar.window) {
            CGRect railFrame = [sideBar convertRect:sideBar.bounds toView:container];
            // Match the 15pt gap used by Duo settings rows and profile cards.
            limitX = MIN(limitX, CGRectGetMinX(railFrame) - 15.0);
        }
    }
    BOOL moved = NO;
    if (CGRectGetMaxX(frame) > limitX + 0.5) {
        frame.origin.x -= (CGRectGetMaxX(frame) - limitX);
        moved = YES;
    }
    if (CGRectGetMaxY(frame) > limitY + 0.5) {
        frame.origin.y -= (CGRectGetMaxY(frame) - limitY);
        moved = YES;
    }
    if (frame.origin.x < CGRectGetMinX(container.bounds)) {
        frame.origin.x = CGRectGetMinX(container.bounds);
        moved = YES;
    }
    if (frame.origin.y < CGRectGetMinY(container.bounds)) {
        frame.origin.y = CGRectGetMinY(container.bounds);
        moved = YES;
    }
    if (moved) button.frame = frame;
}

void ApolloDuoRailAlignFeedScrollIndicator(UIScrollView *scrollView) {
    if (!scrollView) return;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    UITabBar *bar = [tabs isKindOfClass:[UITabBarController class]] ? tabs.tabBar : nil;
    BOOL trailingRail = NO;
    if (bar && !bar.hidden && bar.window && scrollView.window) {
        CGRect railFrame = [scrollView.window convertRect:bar.bounds fromView:bar];
        trailingRail = CGRectGetWidth(railFrame) < 100.0
            && CGRectGetHeight(railFrame) > 200.0
            && CGRectGetMidX(railFrame) > CGRectGetWidth(scrollView.window.bounds) * 0.70;
    }

    NSValue *saved = objc_getAssociatedObject(scrollView,
                                               &kApolloDuoRailSavedIndicatorInsetsKey);
    if (!trailingRail) {
        if (saved) {
            scrollView.verticalScrollIndicatorInsets = saved.UIEdgeInsetsValue;
            objc_setAssociatedObject(scrollView, &kApolloDuoRailSavedIndicatorInsetsKey,
                                     nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    UIEdgeInsets insets = scrollView.verticalScrollIndicatorInsets;
    if (!saved) {
        objc_setAssociatedObject(scrollView, &kApolloDuoRailSavedIndicatorInsetsKey,
                                 [NSValue valueWithUIEdgeInsets:insets],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // UIKit automatically adds safeAreaInsets.right to this value. A matching
    // negative explicit inset cancels only that horizontal adjustment while
    // leaving its automatic top and bottom indicator geometry intact.
    CGFloat right = -scrollView.safeAreaInsets.right;
    if (fabs(insets.right - right) > 0.5) {
        insets.right = right;
        scrollView.verticalScrollIndicatorInsets = insets;
    }
}

void ApolloDuoRailSync(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    int mode = ApolloDuoRailModeForTabs(tabs);
    // The visible rail can precede the scene's Duo display signal.
    if (mode == ApolloDuoModePhone && ApolloDuoRailHasVisibleSideBar()) {
        mode = ApolloDuoModeClosed;
    }
    NSNumber *previous = objc_getAssociatedObject(tabs, &kApolloDuoRailModeKey);
    if (!previous || previous.intValue != mode) {
        objc_setAssociatedObject(tabs, &kApolloDuoRailModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (mode != ApolloDuoModePhone &&
        ![objc_getAssociatedObject(tabs, &kApolloDuoAdaptiveBarsKey) boolValue]) {
        objc_setAssociatedObject(tabs, &kApolloDuoAdaptiveBarsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloScheduleDuoBarPolicyUpdate(tabs);
}
