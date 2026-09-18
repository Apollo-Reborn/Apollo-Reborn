// ApolloFeedSplit.xm
//
// Regular-width two-pane layout for Duo's inner display (and any other
// Regular-width iPhone, e.g. Plus/Max landscape). Compact stays a single
// column.
//
// Open Duo / Regular **primary chrome is the concept mock**: current feed
// on the left, selected post + comments on the right (feed | comments).
// A lone feed stays in the leading half (never full-bleed across the hinge).
// The slim rail switches Home / Popular / All / My Subreddits / Profile /
// Settings. **list | feed** is the directory (RedditList left, feed right).
// Tapping a subreddit dismisses the directory from the stack but retains
// the list VC so Subs can restore it. That sub's posts sit leading until
// a topic opens as **feed | comments** (or any reading-detail pane).
//
// Stock Apollo has no unlockable UISplitViewController path — AutoHideMetaFeeds
// only walks split columns defensively. Wrapping a tab's ApolloNavigationController
// in a split would break the many call sites that treat
// tab.selectedViewController as that nav (settings, floating tabs, swipe-up
// comments, URL routing, video swipe). So we keep the real stack and tile
// inside the existing nav. back / pop / topViewController keep working.
//
// Column frames use layout-margin EXTRA plus the slim Duo rail width
// (ApolloFeedSplitLeadingExtra) so list/feed text starts to the right of
// the rail. Children still apply their own safeAreaInsets for the notch.

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceReservedRegions.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"
#import "ApolloFeedSplitLayout.h"
#import "ApolloState.h"

// Logos' internal generator (simulator) only sees a forward class for this
// Swift name unless we declare the UIKit superclass. Device CydiaSubstrate
// builds are looser; match ApolloLiquidGlass.xm so `self` is a real
// UINavigationController * for trait/transition properties and helpers.
@interface _TtC6Apollo26ApolloNavigationController : UINavigationController
@end

static char kApolloFeedSplitPrimaryAlongsideKey;
static char kApolloFeedSplitSeparatorKey;
static char kApolloFeedSplitMutatingStackKey;
static char kApolloFeedSplitApplyingKey;
static char kApolloFeedSplitLastModeKey;
static char kApolloFeedSplitSavedListKey;
static char kApolloFeedSplitSpanCoalesceKey;
static char kApolloFeedSplitNavBarOwnerKey;

static UIView *ApolloFeedSplitSeparator(UINavigationController *nav, BOOL create);
static UIViewController *ApolloFeedSplitSavedList(UINavigationController *nav);

// Short-lived ModeTiled latch after topic open / media dismiss. Size-class
// and DuoRailIsActive can flicker for a few layout passes and otherwise drop
// a live feed|detail pair to Stacked (full-bleed through the hinge).
static NSTimeInterval sApolloFeedSplitForceTiledUntil = 0.0;

extern "C" BOOL ApolloFeedSplitForceTiledActive(void) {
    return CFAbsoluteTimeGetCurrent() < sApolloFeedSplitForceTiledUntil;
}

extern "C" void ApolloFeedSplitForceTiledForSeconds(NSTimeInterval seconds) {
    if (seconds < 0.0) seconds = 0.0;
    NSTimeInterval until = CFAbsoluteTimeGetCurrent() + seconds;
    if (until > sApolloFeedSplitForceTiledUntil) {
        sApolloFeedSplitForceTiledUntil = until;
    }
    ApolloLog(@"[FeedSplit] forceTiled until +%.2fs (active=%d)",
              seconds, ApolloFeedSplitForceTiledActive() ? 1 : 0);
}

static BOOL ApolloFeedSplitShouldForceTiled(void) {
    return ApolloDuoRailIsActive() || ApolloFeedSplitForceTiledActive();
}

static BOOL ApolloFeedSplitIsClass(UIViewController *controller, const char *name) {
    Class cls = name ? objc_getClass(name) : Nil;
    return cls && controller && [controller isKindOfClass:cls];
}

static BOOL ApolloFeedSplitIsFeedController(UIViewController *controller) {
    return ApolloFeedSplitIsClass(controller, "_TtC6Apollo19PostsViewController")
        || ApolloFeedSplitIsClass(controller, "_TtC6Apollo23LitePostsViewController")
        || ApolloFeedSplitIsClass(controller, "_TtC6Apollo32SavedPostsCommentsViewController")
        || ApolloFeedSplitIsClass(controller, "_TtC6Apollo32PostsSearchResultsViewController");
}

static BOOL ApolloFeedSplitIsListController(UIViewController *controller) {
    return ApolloFeedSplitIsClass(controller, "_TtC6Apollo24RedditListViewController");
}

// Comments, or any other non-feed / non-list pushed from a feed (Apollo
// sometimes uses a class that does not contain CommentsViewController).
static BOOL ApolloFeedSplitIsReadingDetailController(UIViewController *controller) {
    if (!controller) return NO;
    if (ApolloSwipeCommentsIsPaneCommentsController(controller)) return NO;
    if (ApolloFeedSplitIsFeedController(controller)) return NO;
    if (ApolloFeedSplitIsListController(controller)) return NO;
    return YES;
}

static UIViewController *ApolloFeedSplitSavedList(UINavigationController *nav) {
    return nav ? objc_getAssociatedObject(nav, &kApolloFeedSplitSavedListKey) : nil;
}

static void ApolloFeedSplitSaveList(UINavigationController *nav, UIViewController *list) {
    if (!nav || !ApolloFeedSplitIsListController(list)) return;
    objc_setAssociatedObject(nav, &kApolloFeedSplitSavedListKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

typedef enum {
    ApolloFeedSplitPairNone = 0,
    ApolloFeedSplitPairListFeed,
    ApolloFeedSplitPairFeedComments,
} ApolloFeedSplitPair;

static UIView *ApolloFeedSplitContainerView(UINavigationController *nav) {
    if (!nav.isViewLoaded) return nil;
    UIView *navView = nav.view;
    for (UIView *subview in navView.subviews) {
        const char *name = class_getName(subview.class);
        if (name && strstr(name, "Transition")) {
            return subview;
        }
    }
    return navView;
}

static UIView *ApolloFeedSplitLayoutView(UIViewController *controller, UIView *container) {
    if (!controller.isViewLoaded || !container) return nil;
    UIView *view = controller.view;
    UIView *parent = view.superview;
    if (parent && parent != container && parent.superview == container) {
        return parent;
    }
    return view;
}

static void ApolloFeedSplitSetFrame(UIView *view, CGRect frame) {
    if (!view) return;
    if (CGRectEqualToRect(view.frame, frame)) return;
    view.autoresizingMask = UIViewAutoresizingNone;
    view.frame = frame;
}

// Column view + the VC's own view must both match frames.feed / detail.
// RedditList otherwise keeps a full-bleed or letterboxed inner frame.
static void ApolloFeedSplitPinColumn(UIViewController *controller,
                                     UIView *container,
                                     ApolloFeedSplitRect rect) {
    if (!controller || !container) return;
    if (!controller.isViewLoaded) [controller loadViewIfNeeded];
    UIView *layout = ApolloFeedSplitLayoutView(controller, container);
    if (!layout) return;
    CGRect frame = CGRectMake(rect.x, rect.y, rect.width, rect.height);
    layout.clipsToBounds = YES;
    ApolloFeedSplitSetFrame(layout, frame);
    UIView *view = controller.view;
    if (view && view != layout) {
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (!CGRectEqualToRect(view.frame, layout.bounds)) {
            view.frame = layout.bounds;
        }
    }
    if (view && [controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView * (*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UIView class]] && table.superview == view) {
            table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            if (ApolloDuoRailIsActive() && [table isKindOfClass:[UIScrollView class]]) {
                // Frame already starts after the rail; do not add the tab
                // controller's safe-area inset again (ghosted/double rows).
                ((UIScrollView *)table).contentInsetAdjustmentBehavior =
                    UIScrollViewContentInsetAdjustmentNever;
            }
            if (!CGRectEqualToRect(table.frame, view.bounds)) {
                table.frame = view.bounds;
            }
        }
    }
}

// Duo rail: clamp a column into the leading or trailing half before setFrame.
static void ApolloFeedSplitPinColumnClamped(UIViewController *controller,
                                            UIView *container,
                                            ApolloFeedSplitRect rect,
                                            BOOL trailing) {
    if (!controller || !container) return;
    CGFloat width = container.bounds.size.width;
    CGFloat height = container.bounds.size.height;
    if (width < 1.0 || height < 1.0) return;
    if (ApolloFeedSplitShouldForceTiled()
        || width + 0.5 >= (CGFloat)ApolloFeedSplitBalancedMinWidth) {
        rect = ApolloFeedSplitClampRectToHalf(rect, width, height, trailing ? 1 : 0);
    }
    ApolloFeedSplitPinColumn(controller, container, rect);
}

// Shared UINavigationBar is full-width by default, so "Home" / sub names
// center on the hinge. Pin the bar to the pane that owns the title:
// leading when the lone feed/list is centered, trailing when the top VC
// is the tiled detail (feed in list|feed, comments in feed|comments).
static void ApolloFeedSplitClearNavBarOwner(UINavigationController *nav) {
    if (!nav) return;
    objc_setAssociatedObject(nav, &kApolloFeedSplitNavBarOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedSplitPinNavigationBar(UINavigationController *nav,
                                            UIView *container,
                                            ApolloFeedSplitMode mode,
                                            ApolloFeedSplitFrames frames,
                                            BOOL rtl) {
    if (!nav.isViewLoaded || !nav.navigationBar) return;
    UINavigationBar *bar = nav.navigationBar;
    if (mode == ApolloFeedSplitModeStacked || !ApolloDuoRailIsActive()) {
        ApolloFeedSplitClearNavBarOwner(nav);
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        return;
    }
    ApolloFeedSplitRect owner = frames.feed;
    if (mode == ApolloFeedSplitModeTiled && frames.showsDetail) {
        // Top VC owns the title: feed in list|feed, comments in feed|comments.
        owner = frames.detail;
    }
    (void)rtl;
    if (owner.width < 8.0) {
        ApolloFeedSplitClearNavBarOwner(nav);
        return;
    }
    CGRect column = CGRectMake((CGFloat)owner.x, 0.0, (CGFloat)owner.width,
                               container ? container.bounds.size.height : nav.view.bounds.size.height);
    UIView *from = container && container.superview ? container : nav.view;
    CGRect inNav = [from convertRect:column toView:nav.view];
    CGRect barFrame = bar.frame;
    barFrame.origin.x = inNav.origin.x;
    barFrame.size.width = inNav.size.width;
    if (barFrame.size.width < 8.0) {
        ApolloFeedSplitClearNavBarOwner(nav);
        return;
    }
    objc_setAssociatedObject(nav, &kApolloFeedSplitNavBarOwnerKey,
                             [NSValue valueWithCGRect:barFrame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    bar.autoresizingMask = UIViewAutoresizingNone;
    if (!CGRectEqualToRect(bar.frame, barFrame)) {
        bar.frame = barFrame;
    }
}

static void ApolloFeedSplitApplyStoredNavBar(UINavigationBar *bar) {
    if (!bar || !ApolloDuoRailIsActive()) return;
    UINavigationController *nav = nil;
    if ([bar.delegate isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)bar.delegate;
    }
    if (!nav) return;
    NSValue *value = objc_getAssociatedObject(nav, &kApolloFeedSplitNavBarOwnerKey);
    if (!value) return;
    CGRect frame = value.CGRectValue;
    bar.autoresizingMask = UIViewAutoresizingNone;
    if (!CGRectEqualToRect(bar.frame, frame)) {
        bar.frame = frame;
    }
}

// After sub-pick / mode changes, orphaned list|feed siblings can remain in the
// transition container and paint the directory over the new leading feed while
// the trailing half stays blank white.
static BOOL ApolloFeedSplitViewIsColumnOf(UIView *sub, UIViewController *vc, UIView *container) {
    if (!sub || !vc.isViewLoaded) return NO;
    UIView *layout = ApolloFeedSplitLayoutView(vc, container);
    return sub == layout || sub == vc.view;
}

static void ApolloFeedSplitRemoveForeignColumns(UINavigationController *nav,
                                                UIView *container,
                                                UIViewController *primary,
                                                UIViewController *secondary) {
    if (!nav || !container) return;
    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];
    for (UIViewController *vc in nav.viewControllers) {
        if (ApolloFeedSplitIsListController(vc) || ApolloFeedSplitIsFeedController(vc)
            || ApolloFeedSplitIsReadingDetailController(vc)) {
            [candidates addObject:vc];
        }
    }
    UIViewController *saved = ApolloFeedSplitSavedList(nav);
    if (saved && ![candidates containsObject:saved]) [candidates addObject:saved];

    for (UIView *sub in [container.subviews copy]) {
        if (sub == ApolloFeedSplitSeparator(nav, NO)) continue;
        UIViewController *owner = nil;
        for (UIViewController *vc in candidates) {
            if (ApolloFeedSplitViewIsColumnOf(sub, vc, container)) {
                owner = vc;
                break;
            }
        }
        if (!owner) continue;
        if (owner == primary || owner == secondary) continue;
        ApolloLog(@"[FeedSplit] removing orphan column %@ (%@)",
                  NSStringFromClass(sub.class), NSStringFromClass(owner.class));
        [sub removeFromSuperview];
    }
}

static BOOL ApolloFeedSplitChildSpansMidX(UIView *container) {
    if (!container) return NO;
    CGFloat mid = (CGFloat)ApolloFeedSplitContainerMidX(container.bounds.size.width);
    if (mid < 1.0) return NO;
    for (UIView *sub in container.subviews) {
        CGRect f = sub.frame;
        if (f.size.width < 1.0) continue;
        if (CGRectGetMinX(f) + 0.5 < mid && CGRectGetMaxX(f) > mid + 0.5) {
            // Ignore hairline separators and the full-width nav chrome wrappers
            // that are not our column content (very short height or <2pt wide).
            if (f.size.width < 2.0 || f.size.height < 2.0) continue;
            // A view that is essentially the full container is a hinge span.
            if (f.size.width + 1.0 >= container.bounds.size.width * 0.85) {
                return YES;
            }
            if (CGRectGetMinX(f) < mid - 20.0 && CGRectGetMaxX(f) > mid + 20.0) {
                return YES;
            }
        }
    }
    return NO;
}

static UIView *ApolloFeedSplitSeparator(UINavigationController *nav, BOOL create) {
    UIView *separator = objc_getAssociatedObject(nav, &kApolloFeedSplitSeparatorKey);
    if (separator || !create) return separator;
    separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.userInteractionEnabled = NO;
    separator.autoresizingMask = UIViewAutoresizingNone;
    separator.backgroundColor = [UIColor separatorColor];
    objc_setAssociatedObject(nav, &kApolloFeedSplitSeparatorKey, separator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return separator;
}

static void ApolloFeedSplitSetPrimaryAlongside(UIViewController *feed, BOOL alongside) {
    if (!feed) return;
    BOOL current = [objc_getAssociatedObject(feed, &kApolloFeedSplitPrimaryAlongsideKey) boolValue];
    if (current == alongside) return;
    if (feed.navigationController.transitionCoordinator) return;
    objc_setAssociatedObject(feed, &kApolloFeedSplitPrimaryAlongsideKey,
                             alongside ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // beginAppearanceTransition on the still-visible feed steals touches
    // on open Duo (scroll and buttons die).
    if (ApolloDuoRailIsActive()) return;
    if (!feed.isViewLoaded) return;
    [feed beginAppearanceTransition:alongside animated:NO];
    [feed endAppearanceTransition];
}

static ApolloFeedSplitPair ApolloFeedSplitPairOnStack(UINavigationController *nav,
                                                      UIViewController **primaryOut,
                                                      UIViewController **detailOut) {
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.count < 2) {
        if (primaryOut) *primaryOut = nil;
        if (detailOut) *detailOut = nil;
        return ApolloFeedSplitPairNone;
    }
    UIViewController *detail = stack.lastObject;
    UIViewController *previous = stack[stack.count - 2];
    // Post-open: feed | reading-detail wins so drilling into a thread does
    // not keep a three-column list|feed|comments layout.
    if (ApolloFeedSplitIsReadingDetailController(detail) && ApolloFeedSplitIsFeedController(previous)) {
        if (primaryOut) *primaryOut = previous;
        if (detailOut) *detailOut = detail;
        return ApolloFeedSplitPairFeedComments;
    }
    if (ApolloFeedSplitIsFeedController(detail)
        && ApolloFeedSplitIsListController(previous)) {
        if (primaryOut) *primaryOut = previous;
        if (detailOut) *detailOut = detail;
        return ApolloFeedSplitPairListFeed;
    }
    if (primaryOut) *primaryOut = nil;
    if (detailOut) *detailOut = nil;
    return ApolloFeedSplitPairNone;
}

static ApolloFeedSplitMode ApolloFeedSplitCurrentMode(UINavigationController *nav,
                                                      CGSize containerSize,
                                                      UIView *insetView,
                                                      UIViewController **feedOut,
                                                      UIViewController **detailOut) {
    UIViewController *feed = nil;
    UIViewController *detail = nil;
    ApolloFeedSplitPair pair = ApolloFeedSplitPairOnStack(nav, &feed, &detail);
    BOOL hasDetail = pair != ApolloFeedSplitPairNone;
    if (!hasDetail) {
        UIViewController *top = nav.topViewController;
        if (ApolloFeedSplitIsFeedController(top) || ApolloFeedSplitIsListController(top)) {
            feed = top;
        }
    }
    UIEdgeInsets safe = insetView.safeAreaInsets;
    UIEdgeInsets margins = insetView.layoutMargins;
    double extraLeft = ApolloFeedSplitLeadingExtra(
        ApolloDeviceChromeExtra(safe.left, margins.left),
        ApolloDuoRailIsActive() ? 1 : 0);
    double extraRight = ApolloDeviceChromeExtra(safe.right, margins.right);
    double usable = ApolloFeedSplitUsableWidth(containerSize.width, extraLeft, extraRight);
    ApolloFeedSplitMode mode = ApolloFeedSplitModeForTraits(
        (int)nav.traitCollection.horizontalSizeClass, usable, hasDetail ? 1 : 0);
    if (mode == ApolloFeedSplitModeCentered && !feed) {
        mode = ApolloFeedSplitModeStacked;
    }
    if (mode == ApolloFeedSplitModeTiled && (!feed || !detail)) {
        mode = ApolloFeedSplitModeStacked;
    }
    // Scroll/layout can blip usable width or size class. On open Duo (or
    // during the post-open / media-dismiss latch) never allow ModeStacked —
    // that full-bleeds the top VC through the hinge.
    BOOL forceDuo = ApolloFeedSplitShouldForceTiled()
        || usable + 0.5 >= (double)ApolloFeedSplitBalancedMinWidth;
    if (forceDuo) {
        if (hasDetail && feed && detail) {
            mode = ApolloFeedSplitModeTiled;
        } else if (feed) {
            // Lone feed OR lone directory list → leading half only.
            mode = ApolloFeedSplitModeCentered;
        }
    }
    if (feedOut) *feedOut = feed;
    if (detailOut) *detailOut = detail;
    return mode;
}

static void ApolloFeedSplitLogModeIfChanged(UINavigationController *nav, ApolloFeedSplitMode mode) {
    NSNumber *previous = objc_getAssociatedObject(nav, &kApolloFeedSplitLastModeKey);
    if (previous && previous.integerValue == (NSInteger)mode) return;
    objc_setAssociatedObject(nav, &kApolloFeedSplitLastModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const char *name = "stacked";
    if (mode == ApolloFeedSplitModeCentered) name = "centered";
    else if (mode == ApolloFeedSplitModeTiled) name = "tiled";
    ApolloFeedSplitPair pair = ApolloFeedSplitPairOnStack(nav, NULL, NULL);
    const char *pairName = "none";
    if (pair == ApolloFeedSplitPairListFeed) pairName = "list-feed";
    else if (pair == ApolloFeedSplitPairFeedComments) pairName = "feed-comments";
    ApolloLog(@"[FeedSplit] mode=%s pair=%s sizeClass=%ld",
              name, pairName, (long)nav.traitCollection.horizontalSizeClass);
}

static void ApolloFeedSplitApply(UINavigationController *nav, BOOL animated);

static UIViewController *ApolloFeedSplitFirstFeedOnStack(UINavigationController *nav) {
    if (!nav) return nil;
    for (UIViewController *controller in nav.viewControllers) {
        if (ApolloFeedSplitIsListController(controller)) continue;
        if (ApolloFeedSplitIsFeedController(controller)) return controller;
    }
    return nil;
}

extern "C" void ApolloFeedSplitShowSubredditPicker(UINavigationController *nav) {
    ApolloDuoRailSetPickingSubreddits(YES);
    if (!nav) {
        ApolloLog(@"[FeedSplit] My Subreddits skipped (no posts nav)");
        return;
    }
    UIViewController *list = nil;
    for (UIViewController *controller in nav.viewControllers) {
        if (ApolloFeedSplitIsListController(controller)) {
            list = controller;
            break;
        }
    }
    if (!list) list = ApolloFeedSplitSavedList(nav);
    UIViewController *feed = ApolloFeedSplitFirstFeedOnStack(nav);
    if (!feed && ApolloFeedSplitIsFeedController(nav.topViewController)) {
        feed = nav.topViewController;
    }
    NSArray<UIViewController *> *want = nil;
    if (list && feed && list != feed) {
        want = @[ list, feed ];
    } else if (list) {
        want = @[ list ];
    } else if (feed) {
        want = @[ feed ];
    }
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (want && ![nav.viewControllers isEqualToArray:want]) {
        [nav setViewControllers:want animated:NO];
    }
    if (list && !list.isViewLoaded) [list loadViewIfNeeded];
    if (feed && !feed.isViewLoaded) [feed loadViewIfNeeded];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Directory must stay leading-half only (never full-bleed across hinge).
    ApolloFeedSplitForceTiledForSeconds(0.8);
    ApolloFeedSplitApply(nav, NO);
    UIView *container = ApolloFeedSplitContainerView(nav);
    UIViewController *primary = nil;
    UIViewController *secondary = nil;
    ApolloFeedSplitPairOnStack(nav, &primary, &secondary);
    if (!primary) primary = nav.topViewController;
    ApolloFeedSplitRemoveForeignColumns(nav, container, primary, secondary);
    ApolloFeedSplitReapplySoon();
    ApolloLog(@"[FeedSplit] My Subreddits list|feed stack=%lu",
              (unsigned long)nav.viewControllers.count);
}

static void ApolloFeedSplitConsiderNav(UIViewController *vc, NSMutableArray *navs) {
    if (!vc || !navs) return;
    UINavigationController *nav = nil;
    Class apolloNav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (apolloNav && [vc isKindOfClass:apolloNav]) {
        nav = (UINavigationController *)vc;
    } else if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if ([vc.navigationController isKindOfClass:[UINavigationController class]]) {
        nav = vc.navigationController;
    }
    if (!nav || [navs containsObject:nav]) return;
    [navs addObject:nav];
}

extern "C" void ApolloFeedSplitReapplyVisible(void) {
    UIViewController *root = ApolloMainTabBarController();
    if (![root isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[FeedSplit] ReapplyVisible skipped (no tab bar)");
        return;
    }
    UITabBarController *tabs = (UITabBarController *)root;
    NSMutableArray *navs = [NSMutableArray array];
    ApolloFeedSplitConsiderNav(tabs.selectedViewController, navs);
    for (UIViewController *child in tabs.viewControllers) {
        ApolloFeedSplitConsiderNav(child, navs);
    }
    if (navs.count == 0) {
        ApolloLog(@"[FeedSplit] ReapplyVisible skipped (no posts nav)");
        return;
    }
    // Prefer the nav that already hosts a feed|detail / list|feed pair so we
    // do not Apply a random Settings/Profile stack and miss the posts tile.
    NSMutableArray *paired = [NSMutableArray array];
    NSMutableArray *duoWide = [NSMutableArray array];
    for (UINavigationController *nav in navs) {
        if (ApolloFeedSplitPairOnStack(nav, NULL, NULL) != ApolloFeedSplitPairNone) {
            [paired addObject:nav];
            continue;
        }
        UIView *container = ApolloFeedSplitContainerView(nav);
        CGFloat width = container ? container.bounds.size.width : nav.view.bounds.size.width;
        if (width + 0.5 >= (CGFloat)ApolloFeedSplitBalancedMinWidth) {
            [duoWide addObject:nav];
        }
    }
    NSArray *targets = paired.count ? paired : (duoWide.count ? duoWide : navs);
    for (UINavigationController *nav in targets) {
        ApolloFeedSplitPair pair = ApolloFeedSplitPairOnStack(nav, NULL, NULL);
        ApolloLog(@"[FeedSplit] ReapplyVisible apply pair=%d force=%d rail=%d stack=%lu",
                  (int)pair,
                  ApolloFeedSplitForceTiledActive() ? 1 : 0,
                  ApolloDuoRailIsActive() ? 1 : 0,
                  (unsigned long)nav.viewControllers.count);
        ApolloFeedSplitApply(nav, NO);
    }
}

extern "C" void ApolloFeedSplitReapplySoon(void) {
    // Latch tiled through the layout passes that follow a topic open / media
    // dismiss; Apollo often resets child frames after our first Apply.
    ApolloFeedSplitForceTiledForSeconds(0.8);
    // Coalesce overlapping schedules (media disappear + dismissalDidEnd, or
    // rapid topic opens) so we do not enqueue dozens of identical Applies.
    static NSTimeInterval sLastSchedule = 0.0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - sLastSchedule < 0.05) {
        ApolloLog(@"[FeedSplit] ReapplySoon coalesced (force latched)");
        return;
    }
    sLastSchedule = now;
    static const double kDelays[] = { 0.0, 0.05, 0.15, 0.35, 0.6 };
    for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
        double delay = kDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloLog(@"[FeedSplit] ReapplySoon t=%.2f force=%d rail=%d",
                      delay,
                      ApolloFeedSplitForceTiledActive() ? 1 : 0,
                      ApolloDuoRailIsActive() ? 1 : 0);
            ApolloFeedSplitReapplyVisible();
        });
    }
}

static void ApolloFeedSplitApply(UINavigationController *nav, BOOL animated) {
    if (!nav.isViewLoaded || ApolloRowMeasureInProgress()) return;
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitApplyingKey)) return;
    objc_setAssociatedObject(nav, &kApolloFeedSplitApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *container = ApolloFeedSplitContainerView(nav);
    if (!container || CGRectIsEmpty(container.bounds)) {
        objc_setAssociatedObject(nav, &kApolloFeedSplitApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    UIViewController *feed = nil;
    UIViewController *detail = nil;
    ApolloFeedSplitMode mode = ApolloFeedSplitCurrentMode(nav, container.bounds.size, nav.view, &feed, &detail);
    ApolloFeedSplitLogModeIfChanged(nav, mode);

    UIEdgeInsets safe = nav.view.safeAreaInsets;
    UIEdgeInsets margins = nav.view.layoutMargins;
    double extraLeft = ApolloFeedSplitLeadingExtra(
        ApolloDeviceChromeExtra(safe.left, margins.left),
        ApolloDuoRailIsActive() ? 1 : 0);
    double extraRight = ApolloDeviceChromeExtra(safe.right, margins.right);
    BOOL rtl = nav.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    ApolloFeedSplitPair pair = ApolloFeedSplitPairOnStack(nav, NULL, NULL);
    double usable = ApolloFeedSplitUsableWidth(container.bounds.size.width, extraLeft, extraRight);
    ApolloFeedSplitTileStyle tileStyle = ApolloFeedSplitTileStyleForPair(
        pair == ApolloFeedSplitPairFeedComments ? 1 : 0, usable);
    ApolloReservedAvoidance avoid;
    memset(&avoid, 0, sizeof(avoid));
    // Collect never calls reservedRegions (Duo first-commit SIGSEGV).
    // hasVerticalGap stays false; chrome extra / layoutMargins own gutters.
    avoid = ApolloDeviceReservedAvoidanceForView(container);
    double hingeX = 0.0;
    double hingeW = 0.0;
    if (avoid.hasVerticalGap && avoid.gapWidth > 0.0) {
        hingeX = avoid.gapX;
        hingeW = avoid.gapWidth;
    }
    // While Duo rail / force latch / Duo-wide canvas: never honor Stacked
    // full-bleed — re-tile a live pair, else pin lone feed/list leading.
    BOOL duoWide = usable + 0.5 >= (double)ApolloFeedSplitBalancedMinWidth;
    BOOL pinLeading = ApolloFeedSplitShouldForceTiled() || duoWide;
    if (mode == ApolloFeedSplitModeStacked && pinLeading) {
        if (feed && detail) {
            mode = ApolloFeedSplitModeTiled;
        } else if (feed) {
            mode = ApolloFeedSplitModeCentered;
        }
        ApolloFeedSplitLogModeIfChanged(nav, mode);
    }
    ApolloFeedSplitFrames frames = ApolloFeedSplitFramesMake(
        container.bounds.size.width, container.bounds.size.height,
        extraLeft, extraRight, mode, rtl ? 1 : 0, tileStyle, hingeX, hingeW,
        pinLeading ? 1 : 0);

    // Final hard clamp: refuse any primary/secondary frame that spans midX.
    if (pinLeading) {
        double mid = ApolloFeedSplitContainerMidX(container.bounds.size.width);
        double ch = container.bounds.size.height;
        double cw = container.bounds.size.width;
        if (ApolloFeedSplitRectSpansMidX(frames.feed, mid) || mode == ApolloFeedSplitModeCentered) {
            frames.feed = ApolloFeedSplitClampRectToHalf(frames.feed, cw, ch, rtl ? 1 : 0);
        }
        if (frames.showsDetail) {
            if (ApolloFeedSplitRectSpansMidX(frames.detail, mid) || mode == ApolloFeedSplitModeTiled) {
                frames.detail = ApolloFeedSplitClampRectToHalf(frames.detail, cw, ch, rtl ? 0 : 1);
            }
        }
    }

    void (^apply)(void) = ^{
        UIView *separator = ApolloFeedSplitSeparator(nav, mode == ApolloFeedSplitModeTiled);
        if (mode == ApolloFeedSplitModeStacked) {
            // Last-resort stacked only when not Duo — still avoid spanning if
            // the canvas is somehow Duo-wide without the rail flag.
            UIViewController *top = nav.topViewController;
            if (pinLeading && top) {
                ApolloFeedSplitRect leading = frames.feed;
                if (leading.width < 1.0) {
                    ApolloFeedSplitRect full;
                    full.x = 0.0; full.y = 0.0;
                    full.width = container.bounds.size.width;
                    full.height = container.bounds.size.height;
                    leading = ApolloFeedSplitClampRectToHalf(
                        full, container.bounds.size.width, container.bounds.size.height,
                        rtl ? 1 : 0);
                }
                ApolloFeedSplitPinColumnClamped(top, container, leading, rtl);
                ApolloFeedSplitRemoveForeignColumns(nav, container, top, nil);
            } else if (top.isViewLoaded) {
                UIView *topLayout = ApolloFeedSplitLayoutView(top, container);
                if (topLayout) {
                    ApolloFeedSplitSetFrame(topLayout, container.bounds);
                    topLayout.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                }
            }
            if (feed && feed != top) {
                UIView *feedLayout = ApolloFeedSplitLayoutView(feed, container);
                if (feedLayout && feedLayout.superview == container) {
                    [feedLayout removeFromSuperview];
                }
                ApolloFeedSplitSetPrimaryAlongside(feed, NO);
            }
            if (separator.superview) [separator removeFromSuperview];
            ApolloFeedSplitPinNavigationBar(nav, container, mode, frames, rtl);
            return;
        }

        if (!feed || !feed.isViewLoaded) return;
        UIView *feedLayout = ApolloFeedSplitLayoutView(feed, container);
        if (!feedLayout) return;

        if (feedLayout.superview != container) {
            [container insertSubview:feedLayout atIndex:0];
        }
        ApolloFeedSplitPinColumnClamped(feed, container, frames.feed, rtl);

        if (mode == ApolloFeedSplitModeTiled && detail) {
            UIView *detailLayout = ApolloFeedSplitLayoutView(detail, container);
            if (detailLayout && detailLayout.superview != container) {
                [container addSubview:detailLayout];
            }
            ApolloFeedSplitPinColumnClamped(detail, container, frames.detail, !rtl);
            ApolloFeedSplitSetPrimaryAlongside(feed, YES);
            ApolloFeedSplitRemoveForeignColumns(nav, container, feed, detail);
            if (separator) {
                CGFloat gutter = rtl
                    ? (CGFloat)(frames.feed.x - (frames.detail.x + frames.detail.width))
                    : (CGFloat)(frames.detail.x - (frames.feed.x + frames.feed.width));
                if (gutter < 1.0) gutter = (CGFloat)ApolloFeedSplitGutterWidth;
                CGFloat mid = rtl
                    ? (CGFloat)(frames.feed.x - gutter / 2.0)
                    : (CGFloat)(frames.feed.x + frames.feed.width + gutter / 2.0);
                CGRect sepFrame = CGRectMake(mid - 0.5, 0.0, 1.0, container.bounds.size.height);
                if (separator.superview != container) [container addSubview:separator];
                ApolloFeedSplitSetFrame(separator, sepFrame);
            }
        } else {
            // Centered lone feed/list: strip orphan directory/detail siblings
            // so the trailing half stays empty (not a stale white feed / list).
            ApolloFeedSplitRemoveForeignColumns(nav, container, feed, nil);
            ApolloFeedSplitSetPrimaryAlongside(feed, feed != nav.topViewController);
            if (separator.superview) [separator removeFromSuperview];
        }
        ApolloFeedSplitPinNavigationBar(nav, container, mode, frames, rtl);
    };

    if (animated && !ApolloDuoRailIsActive()) {
        [UIView animateWithDuration:0.25 delay:0.0 options:UIViewAnimationOptionCurveEaseInOut animations:apply completion:^(BOOL finished) {
            (void)finished;
            objc_setAssociatedObject(nav, &kApolloFeedSplitApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }];
        return;
    }
    apply();
    objc_setAssociatedObject(nav, &kApolloFeedSplitApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedSplitScheduleApply(UINavigationController *nav) {
    id <UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            (void)context;
            ApolloFeedSplitApply(nav, NO);
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            (void)context;
            ApolloFeedSplitApply(nav, NO);
        }];
        return;
    }
    ApolloFeedSplitApply(nav, NO);
}

// When the feed is still on screen, opening another post should replace the
// current comments column (Mail-style) instead of pushing a third full-width
// screen on top of the tile.
static BOOL ApolloFeedSplitWouldTile(UINavigationController *nav) {
    UIView *container = ApolloFeedSplitContainerView(nav);
    CGSize size = container ? container.bounds.size : nav.view.bounds.size;
    if (ApolloFeedSplitShouldForceTiled()
        && size.width + 0.5 >= (double)ApolloFeedSplitMinRegularWidth) {
        return YES;
    }
    UIEdgeInsets safe = nav.view.safeAreaInsets;
    UIEdgeInsets margins = nav.view.layoutMargins;
    double extraLeft = ApolloFeedSplitLeadingExtra(
        ApolloDeviceChromeExtra(safe.left, margins.left),
        ApolloDuoRailIsActive() ? 1 : 0);
    double extraRight = ApolloDeviceChromeExtra(safe.right, margins.right);
    double usable = ApolloFeedSplitUsableWidth(size.width, extraLeft, extraRight);
    return ApolloFeedSplitModeForTraits((int)nav.traitCollection.horizontalSizeClass, usable, 1)
        == ApolloFeedSplitModeTiled;
}

static void ApolloFeedSplitCollapseReplacedComments(UINavigationController *nav) {
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.count < 3) return;
    UIViewController *top = stack.lastObject;
    UIViewController *mid = stack[stack.count - 2];
    UIViewController *under = stack[stack.count - 3];
    if (!ApolloFeedSplitIsReadingDetailController(top)
        || !ApolloFeedSplitIsReadingDetailController(mid)) return;
    if (!ApolloFeedSplitIsFeedController(under)) return;
    if (!ApolloFeedSplitWouldTile(nav)) return;

    NSMutableArray<UIViewController *> *next = [stack mutableCopy];
    [next removeObjectAtIndex:next.count - 2];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [nav setViewControllers:next animated:NO];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[FeedSplit] replaced comments column (stack %lu→%lu)",
              (unsigned long)stack.count, (unsigned long)next.count);
}

// List still visible: selecting another subreddit should replace the feed
// column instead of pushing a third full-width Posts screen.
static void ApolloFeedSplitCollapseReplacedFeeds(UINavigationController *nav) {
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.count < 3) return;
    UIViewController *top = stack.lastObject;
    UIViewController *mid = stack[stack.count - 2];
    UIViewController *under = stack[stack.count - 3];
    if (!ApolloFeedSplitIsFeedController(top) || !ApolloFeedSplitIsFeedController(mid)) return;
    if (!ApolloFeedSplitIsListController(under)) return;
    if (!ApolloFeedSplitWouldTile(nav)) return;

    NSMutableArray<UIViewController *> *next = [stack mutableCopy];
    [next removeObjectAtIndex:next.count - 2];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [nav setViewControllers:next animated:NO];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[FeedSplit] replaced feed column (stack %lu→%lu)",
              (unsigned long)stack.count, (unsigned long)next.count);
}

%hook _TtC6Apollo26ApolloNavigationController

- (void)viewDidLayoutSubviews {
    %orig;
    UINavigationController *nav = (UINavigationController *)self;
    UIView *container = ApolloFeedSplitContainerView(nav);
    BOOL duoRail = ApolloDuoRailIsActive();
    BOOL force = ApolloFeedSplitShouldForceTiled();
    BOOL spans = (duoRail || force) && ApolloFeedSplitChildSpansMidX(container);

    // During a push/pop transition UIKit still lays children full-bleed.
    // Alongside + completion restore; while DuoRail/force is up, Apply every
    // pass — do NOT skip because of transitionCoordinator when rail is active.
    if (nav.transitionCoordinator) {
        ApolloFeedSplitScheduleApply(nav);
        if (duoRail || force || spans) {
            ApolloFeedSplitApply(nav, NO);
        }
        return;
    }

    // Any child spanning midX while DuoRail is active → re-Apply immediately.
    // Coalesce tight layout loops without dropping the correction.
    if (spans) {
        NSNumber *last = objc_getAssociatedObject(nav, &kApolloFeedSplitSpanCoalesceKey);
        CFTimeInterval now = CACurrentMediaTime();
        if (last && (now - last.doubleValue) < 0.016) {
            // Still Apply — coalescing only skips the log spam path by falling
            // through once per frame budget; never skip the clamp itself when
            // the previous Apply could not clear the span.
        }
        objc_setAssociatedObject(nav, &kApolloFeedSplitSpanCoalesceKey, @(now),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloFeedSplitApply(nav, NO);
        return;
    }
    ApolloFeedSplitApply(nav, NO);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedSplitApply((UINavigationController *)self, NO);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    UINavigationController *nav = (UINavigationController *)self;
    if (previous.horizontalSizeClass != nav.traitCollection.horizontalSizeClass) {
        if (nav.transitionCoordinator) {
            ApolloFeedSplitScheduleApply(nav);
        } else {
            ApolloFeedSplitApply(nav, ApolloDuoRailIsActive() ? NO : YES);
        }
    }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    UINavigationController *nav = (UINavigationController *)self;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloFeedSplitApply(nav, NO);
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloFeedSplitApply(nav, NO);
    }];
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UINavigationController *nav = (UINavigationController *)self;
    BOOL duoTile = ApolloDuoRailIsActive() && ApolloFeedSplitWouldTile(nav);

    // Subreddit tap while the directory is on-stack (Subs picking, or list|feed
    // already showing): dismiss the directory, keep the list VC for Subs
    // restore, and pin the selected sub's feed to the leading half. Right pane
    // stays empty until a topic opens (intended mock). Avoids the blank-trailing
    // failure where list stayed leading and the new feed never painted.
    BOOL listOnStack = NO;
    UIViewController *listOnNav = nil;
    for (UIViewController *controller in nav.viewControllers) {
        if (ApolloFeedSplitIsListController(controller)) {
            listOnStack = YES;
            listOnNav = controller;
            break;
        }
    }
    BOOL subPick = duoTile && viewController
        && ApolloFeedSplitIsFeedController(viewController)
        && (ApolloDuoRailIsPickingSubreddits() || listOnStack);
    if (subPick) {
        ApolloFeedSplitSaveList(nav, listOnNav ?: ApolloFeedSplitSavedList(nav));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoRailSetPickingSubreddits(NO);
        // Intended mock: @[subFeed] leading — not list|feed with a blank right.
        [nav setViewControllers:@[ viewController ] animated:NO];
        if (!viewController.isViewLoaded) [viewController loadViewIfNeeded];
        objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction commit];
        ApolloFeedSplitForceTiledForSeconds(0.8);
        ApolloFeedSplitApply(nav, NO);
        // Strip any orphaned RedditList column that UIKit left in the container
        // after setViewControllers — that was painting "directory left / blank right".
        UIView *container = ApolloFeedSplitContainerView(nav);
        ApolloFeedSplitRemoveForeignColumns(nav, container, viewController, nil);
        ApolloFeedSplitReapplySoon();
        ApolloLog(@"[FeedSplit] sub pick → feed leading (directory dismissed, list retained)");
        return;
    }

    // Topic / post: any reading-detail on top of a feed tiles, no slide.
    if (duoTile && viewController
        && ApolloFeedSplitIsReadingDetailController(viewController)
        && ApolloFeedSplitIsFeedController(nav.topViewController)) {
        %orig(viewController, NO);
        ApolloFeedSplitCollapseReplacedComments(nav);
        ApolloFeedSplitForceTiledForSeconds(0.8);
        ApolloFeedSplitApply(nav, NO);
        ApolloLog(@"[FeedSplit] topic open tiled; scheduling ReapplySoon");
        ApolloFeedSplitReapplySoon();
        return;
    }

    %orig;
    ApolloFeedSplitCollapseReplacedComments(nav);
    ApolloFeedSplitCollapseReplacedFeeds(nav);
    if (duoTile) {
        // Home/Popular/All (and any other push): latch + multi-pass so a lone
        // feed cannot remain Stacked full-bleed after UIKit's follow-up layouts.
        if (ApolloFeedSplitPairOnStack(nav, NULL, NULL) == ApolloFeedSplitPairNone
            && (ApolloFeedSplitIsFeedController(nav.topViewController)
                || ApolloFeedSplitIsListController(nav.topViewController))) {
            ApolloFeedSplitForceTiledForSeconds(0.8);
            ApolloFeedSplitApply(nav, NO);
            ApolloFeedSplitReapplySoon();
        } else {
            ApolloFeedSplitApply(nav, NO);
        }
        return;
    }
    ApolloFeedSplitScheduleApply(nav);
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = %orig;
    UINavigationController *nav = (UINavigationController *)self;
    if (!objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) {
        ApolloFeedSplitScheduleApply(nav);
    }
    return popped;
}

- (NSArray<UIViewController *> *)popToViewController:(UIViewController *)viewController animated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    UINavigationController *nav = (UINavigationController *)self;
    if (!objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) {
        ApolloFeedSplitScheduleApply(nav);
    }
    return popped;
}

- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    UINavigationController *nav = (UINavigationController *)self;
    if (!objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) {
        ApolloFeedSplitScheduleApply(nav);
    }
    return popped;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    %orig;
    UINavigationController *nav = (UINavigationController *)self;
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;
    ApolloFeedSplitCollapseReplacedComments(nav);
    ApolloFeedSplitCollapseReplacedFeeds(nav);
    ApolloFeedSplitScheduleApply(nav);
}

%end

%hook UINavigationBar

- (void)layoutSubviews {
    %orig;
    ApolloFeedSplitApplyStoredNavBar((UINavigationBar *)self);
}

%end

%ctor {
    Class nav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!nav) {
        ApolloLog(@"[FeedSplit] ApolloNavigationController missing; size-class layout inactive");
        return;
    }
    %init;
    ApolloLog(@"[FeedSplit] hook installed (Regular feed|comments; list|feed while My Subreddits; Compact stacks)");
}
