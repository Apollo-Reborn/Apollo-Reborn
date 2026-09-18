// ApolloFeedSplit.xm
//
// Regular-width two-pane layout for Duo's inner display (and any other
// Regular-width iPhone, e.g. Plus/Max landscape). Compact stays a single
// column.
//
// Open Duo / Regular **primary chrome is the concept mock**: current feed
// on the left, selected post + comments on the right (feed | comments).
// A lone feed stays in the leading half (never full-bleed across the hinge).
// The slim trailing rail is My Subreddits / Home / Popular / All /
// Profile / Settings. **list | feed** is the directory (RedditList left, feed right).
// Tapping a subreddit dismisses the directory from the stack but retains
// the list VC so Subs can restore it. That sub's posts sit leading until
// a topic opens as **feed | comments** (or any reading-detail pane).
// A later left-pane topic tap Mail-replaces the right pane
// (`@[feed, latestDetail]`, animated:NO) — it must not push onto
// `[feed, oldComments]` (top is no longer the feed, so a "tile only if
// top is feed" path leaves the first post painted or blanks the right).
//
// Stock Apollo has no unlockable UISplitViewController path — AutoHideMetaFeeds
// only walks split columns defensively. Wrapping a tab's ApolloNavigationController
// in a split would break the many call sites that treat
// tab.selectedViewController as that nav (settings, floating tabs, swipe-up
// comments, URL routing, video swipe). So we keep the real stack and tile
// inside the existing nav. back / pop / topViewController keep working.
//
// Column frames use layout-margin EXTRA plus the slim Duo rail width
// (ApolloFeedSplitTrailingExtra) so comments/feed text stop left of the
// trailing rail. Children still apply their own safeAreaInsets for the notch.

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
static char kApolloFeedSplitLastApplySizeKey;

// Survives a posts-nav identity change. Associated object on the nav can
// go missing if goToHomeTab rebuilds the stack controller; Subs restore
// must still find the directory.
static UIViewController *sApolloFeedSplitSavedListVC = nil;

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

static void ApolloFeedSplitChromeExtras(UIView *insetView, double *leftOut, double *rightOut) {
    UIEdgeInsets safe = insetView ? insetView.safeAreaInsets : UIEdgeInsetsZero;
    UIEdgeInsets margins = insetView ? insetView.layoutMargins : UIEdgeInsetsZero;
    if (leftOut) {
        *leftOut = ApolloDeviceChromeExtra(safe.left, margins.left);
    }
    if (rightOut) {
        *rightOut = ApolloFeedSplitTrailingExtra(
            ApolloDeviceChromeExtra(safe.right, margins.right),
            ApolloDuoRailIsActive() ? 1 : 0);
    }
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
    UIViewController *list = nav ? objc_getAssociatedObject(nav, &kApolloFeedSplitSavedListKey) : nil;
    if (ApolloFeedSplitIsListController(list)) return list;
    if (ApolloFeedSplitIsListController(sApolloFeedSplitSavedListVC)) {
        return sApolloFeedSplitSavedListVC;
    }
    return nil;
}

static void ApolloFeedSplitSaveList(UINavigationController *nav, UIViewController *list) {
    if (!ApolloFeedSplitIsListController(list)) return;
    sApolloFeedSplitSavedListVC = list;
    if (nav) {
        objc_setAssociatedObject(nav, &kApolloFeedSplitSavedListKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloFeedSplitRememberListOnStack(UINavigationController *nav) {
    if (!nav) return;
    for (UIViewController *controller in nav.viewControllers) {
        if (ApolloFeedSplitIsListController(controller)) {
            ApolloFeedSplitSaveList(nav, controller);
            return;
        }
    }
}

typedef enum {
    ApolloFeedSplitPairNone = 0,
    ApolloFeedSplitPairListFeed,
    ApolloFeedSplitPairFeedComments,
} ApolloFeedSplitPair;

static UIViewController *ApolloFeedSplitFirstFeedOnStack(UINavigationController *nav);
static void ApolloFeedSplitMarkApplyDirty(UINavigationController *nav);

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
        // Only RedditList is a UIKit table. Posts/comments are Texture;
        // writing table.frame / contentInsetAdjustmentNever there paints
        // the same glyphs twice (header + body ghosting).
        if (ApolloFeedSplitIsListController(controller)
            && [table isKindOfClass:[UIView class]] && table.superview == view) {
            table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
        UIEdgeInsets safe = container.safeAreaInsets;
        UIEdgeInsets margins = container.layoutMargins;
        double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
        double extraRight = ApolloFeedSplitTrailingExtra(
            ApolloDeviceChromeExtra(safe.right, margins.right),
            ApolloDuoRailIsActive() ? 1 : 0);
        rect = ApolloFeedSplitClampRectToHalfInsets(rect, width, height, trailing ? 1 : 0,
                                                    extraLeft, extraRight);
    }
    ApolloFeedSplitPinColumn(controller, container, rect);
}

// Shared UINavigationBar stays full-width (from the rail). Shrinking the
// bar onto the comments column stacked its title on the post header
// (ghosted "Weekly Advice Thread"). Shift only the title control into
// the owning pane so titles are not on the hinge.
static void ApolloFeedSplitClearNavBarOwner(UINavigationController *nav) {
    if (!nav) return;
    objc_setAssociatedObject(nav, &kApolloFeedSplitNavBarOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *ApolloFeedSplitNavBarTitleControl(UINavigationBar *bar) {
    if (!bar) return nil;
    for (UIView *sub in bar.subviews) {
        const char *name = class_getName(sub.class);
        if (name && (strstr(name, "TitleControl") || strstr(name, "TitleView"))) {
            return sub;
        }
        for (UIView *inner in sub.subviews) {
            const char *innerName = class_getName(inner.class);
            if (innerName && strstr(innerName, "TitleControl")) return inner;
        }
    }
    return bar.topItem.titleView;
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
        owner = frames.detail;
    }
    (void)rtl;
    if (owner.width < 8.0) {
        ApolloFeedSplitClearNavBarOwner(nav);
        return;
    }
    CGFloat rail = (CGFloat)ApolloDuoRailWidth;
    CGRect barFrame = bar.frame;
    CGFloat navWidth = nav.view.bounds.size.width;
    if (navWidth < 8.0) return;
    barFrame.origin.x = 0.0;
    barFrame.size.width = navWidth - rail;
    if (barFrame.size.width < 8.0) return;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (fabs(bar.frame.origin.x - barFrame.origin.x) > 0.5
        || fabs(bar.frame.size.width - barFrame.size.width) > 0.5) {
        bar.frame = barFrame;
    }

    UIView *from = container && container.superview ? container : nav.view;
    CGRect column = CGRectMake((CGFloat)owner.x, 0.0, (CGFloat)owner.width, 1.0);
    CGRect ownerInNav = [from convertRect:column toView:nav.view];
    CGRect ownerInBar = [nav.view convertRect:ownerInNav toView:bar];
    ownerInBar.origin.y = 0.0;
    ownerInBar.size.height = bar.bounds.size.height;
    objc_setAssociatedObject(nav, &kApolloFeedSplitNavBarOwnerKey,
                             [NSValue valueWithCGRect:ownerInBar],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *title = ApolloFeedSplitNavBarTitleControl(bar);
    if (title && ownerInBar.size.width > 8.0) {
        CGRect titleFrame = title.frame;
        titleFrame.origin.x = ownerInBar.origin.x + (ownerInBar.size.width - titleFrame.size.width) * 0.5;
        if (titleFrame.origin.x < ownerInBar.origin.x) titleFrame.origin.x = ownerInBar.origin.x;
        if (titleFrame.origin.x + titleFrame.size.width > ownerInBar.origin.x + ownerInBar.size.width) {
            titleFrame.size.width = ownerInBar.size.width;
            titleFrame.origin.x = ownerInBar.origin.x;
        }
        if (!CGRectEqualToRect(title.frame, titleFrame)) {
            title.frame = titleFrame;
        }
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
    CGRect ownerInBar = value.CGRectValue;
    UIView *title = ApolloFeedSplitNavBarTitleControl(bar);
    if (!title || ownerInBar.size.width < 8.0) return;
    CGRect titleFrame = title.frame;
    titleFrame.origin.x = ownerInBar.origin.x + (ownerInBar.size.width - titleFrame.size.width) * 0.5;
    if (titleFrame.origin.x < ownerInBar.origin.x) titleFrame.origin.x = ownerInBar.origin.x;
    if (!CGRectEqualToRect(title.frame, titleFrame)) {
        title.frame = titleFrame;
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

static BOOL ApolloFeedSplitIsSnapshotView(UIView *view) {
    if (!view) return NO;
    const char *name = class_getName(view.class);
    return name && (strstr(name, "Snapshot") || strstr(name, "Replicant")
                    || strstr(name, "PortalView"));
}

static void ApolloFeedSplitDedupeHostedView(UIView *container, UIViewController *vc) {
    if (!container || !vc.isViewLoaded) return;
    UIView *layout = ApolloFeedSplitLayoutView(vc, container);
    UIView *view = vc.view;
    if (!layout || !view || layout == view) return;
    if (view.superview == container && layout.superview == container) {
        [view removeFromSuperview];
        if (view.superview != layout) {
            [layout addSubview:view];
            view.frame = layout.bounds;
        }
        ApolloLog(@"[FeedSplit] deduped sibling host %@ / %@",
                  NSStringFromClass(layout.class), NSStringFromClass(view.class));
    }
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
        const char *name = class_getName(sub.class);
        if (name && (strstr(name, "NavigationBar") || strstr(name, "Toolbar")
                     || strstr(name, "Transition") || strstr(name, "DropShadow")
                     || strstr(name, "Dimming") || strstr(name, "Separator"))) {
            continue;
        }
        if (ApolloFeedSplitIsSnapshotView(sub)) {
            ApolloLog(@"[FeedSplit] removing leftover snapshot %@",
                      NSStringFromClass(sub.class));
            [sub removeFromSuperview];
            continue;
        }
        BOOL keep = ApolloFeedSplitViewIsColumnOf(sub, primary, container)
            || ApolloFeedSplitViewIsColumnOf(sub, secondary, container);
        if (keep) continue;
        UIViewController *owner = nil;
        for (UIViewController *vc in candidates) {
            if (ApolloFeedSplitViewIsColumnOf(sub, vc, container)) {
                owner = vc;
                break;
            }
        }
        if (owner && (owner == primary || owner == secondary)) continue;
        // Previous comments/feed hosts stay in the container after a topic
        // replace because they are no longer on the stack (no candidate).
        if (owner || (CGRectGetWidth(sub.frame) >= 80.0 && CGRectGetHeight(sub.frame) >= 80.0)) {
            ApolloLog(@"[FeedSplit] removing leftover column %@ (%@)",
                      NSStringFromClass(sub.class),
                      owner ? NSStringFromClass(owner.class) : @"unowned");
            [sub removeFromSuperview];
        }
    }
    ApolloFeedSplitDedupeHostedView(container, primary);
    ApolloFeedSplitDedupeHostedView(container, secondary);
}

// Overscroll ghost: a leftover comments host (or the same VC mirrored as a
// sibling wrapper/snapshot) sits behind the live trailing scroll view.
// Keep exactly one trailing-column host — the current detail's layout.
static void ApolloFeedSplitKeepSingleTrailingDetail(UINavigationController *nav,
                                                    UIView *container,
                                                    UIViewController *detail) {
    if (!nav || !container || !detail.isViewLoaded) return;
    ApolloFeedSplitDedupeHostedView(container, detail);
    UIView *keepLayout = ApolloFeedSplitLayoutView(detail, container);
    UIView *keepView = detail.view;
    UIView *snapshotHost = keepLayout ?: keepView;
    if (snapshotHost) {
        for (UIView *sub in [snapshotHost.subviews copy]) {
            if (sub == keepView) continue;
            if (ApolloFeedSplitIsSnapshotView(sub)) {
                ApolloLog(@"[FeedSplit] removing nested snapshot %@",
                          NSStringFromClass(sub.class));
                [sub removeFromSuperview];
            }
        }
    }
    double mid = ApolloFeedSplitContainerMidX(container.bounds.size.width);
    for (UIView *sub in [container.subviews copy]) {
        if (sub == keepLayout || sub == keepView) continue;
        if (sub == ApolloFeedSplitSeparator(nav, NO)) continue;
        const char *name = class_getName(sub.class);
        if (name && (strstr(name, "NavigationBar") || strstr(name, "Toolbar")
                     || strstr(name, "DropShadow") || strstr(name, "Dimming")
                     || strstr(name, "Separator"))) {
            continue;
        }
        if (keepView && ([keepView isDescendantOfView:sub] || [sub isDescendantOfView:keepView])) {
            continue;
        }
        CGRect f = sub.frame;
        BOOL sized = CGRectGetWidth(f) >= 80.0 && CGRectGetHeight(f) >= 80.0;
        if (!sized && !sub.hidden && sub.alpha >= 0.05) continue;
        BOOL occupiesTrail = CGRectGetMaxX(f) > mid + 8.0 && CGRectGetMinX(f) + 8.0 >= mid * 0.45;
        BOOL parked = sub.hidden || sub.alpha < 0.05 || CGRectGetMinX(f) > container.bounds.size.width;
        if (ApolloFeedSplitIsSnapshotView(sub) || occupiesTrail || (parked && sized)) {
            ApolloLog(@"[FeedSplit] removing trailing duplicate %@ frame=%@ hidden=%d alpha=%.2f",
                      NSStringFromClass(sub.class), NSStringFromCGRect(f),
                      sub.hidden ? 1 : 0, sub.alpha);
            [sub removeFromSuperview];
        }
    }
    ApolloFeedSplitDedupeHostedView(container, detail);
}

static BOOL ApolloFeedSplitChildSpansMidX(UIView *container) {
    if (!container) return NO;
    CGFloat mid = (CGFloat)ApolloFeedSplitContainerMidX(container.bounds.size.width);
    if (mid < 1.0) return NO;
    CGFloat slop = 48.0;
    for (UIView *sub in container.subviews) {
        CGRect f = sub.frame;
        if (f.size.width < 1.0) continue;
        if (ApolloFeedSplitIsSnapshotView(sub)) continue;
        if (f.size.width < 2.0 || f.size.height < 2.0) continue;
        if (CGRectGetMinX(f) + slop < mid && CGRectGetMaxX(f) > mid + slop
            && f.size.width + 1.0 >= container.bounds.size.width * 0.70) {
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloFeedSplitScrollViewIsActive(UIScrollView *scroll) {
    return scroll && (scroll.tracking || scroll.dragging || scroll.decelerating);
}

static BOOL ApolloFeedSplitControllerIsScrolling(UIViewController *vc) {
    if (!vc.isViewLoaded) return NO;
    if ([vc.view isKindOfClass:[UIScrollView class]]
        && ApolloFeedSplitScrollViewIsActive((UIScrollView *)vc.view)) {
        return YES;
    }
    if ([vc respondsToSelector:@selector(tableView)]) {
        UIScrollView *table = nil;
        @try {
            table = ((UIScrollView * (*)(id, SEL))objc_msgSend)(vc, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UIScrollView class]]
            && ApolloFeedSplitScrollViewIsActive(table)) {
            return YES;
        }
    }
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]
            && ApolloFeedSplitScrollViewIsActive((UIScrollView *)sub)) {
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloFeedSplitNavIsScrolling(UINavigationController *nav) {
    if (!nav) return NO;
    for (UIViewController *vc in nav.viewControllers) {
        if (ApolloFeedSplitControllerIsScrolling(vc)) return YES;
    }
    return ApolloFeedSplitControllerIsScrolling(nav.topViewController);
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
    // Post-open: feed | latest reading-detail. A second topic tap used
    // to leave [feed, oldComments, newComments]; looking only at the
    // last two then returned None and Apply would not swap the right pane.
    if (ApolloFeedSplitIsReadingDetailController(detail)) {
        UIViewController *feed = ApolloFeedSplitIsFeedController(previous)
            ? previous : ApolloFeedSplitFirstFeedOnStack(nav);
        if (feed && feed != detail) {
            if (primaryOut) *primaryOut = feed;
            if (detailOut) *detailOut = detail;
            return ApolloFeedSplitPairFeedComments;
        }
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
    double extraLeft = 0.0;
    double extraRight = 0.0;
    ApolloFeedSplitChromeExtras(insetView, &extraLeft, &extraRight);
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
static void ApolloFeedSplitMarkApplyDirty(UINavigationController *nav);
static UIViewController *ApolloFeedSplitFirstFeedOnStack(UINavigationController *nav);

static UIViewController *ApolloFeedSplitFirstFeedOnStack(UINavigationController *nav) {
    if (!nav) return nil;
    for (UIViewController *controller in nav.viewControllers) {
        if (ApolloFeedSplitIsListController(controller)) continue;
        if (ApolloFeedSplitIsFeedController(controller)) return controller;
    }
    return nil;
}

static UIViewController *ApolloFeedSplitFindListAnywhere(UINavigationController *preferred) {
    UIViewController *list = ApolloFeedSplitSavedList(preferred);
    if (list) return list;
    if (preferred) {
        for (UIViewController *controller in preferred.viewControllers) {
            if (ApolloFeedSplitIsListController(controller)) return controller;
        }
    }
    UIViewController *root = ApolloMainTabBarController();
    if (![root isKindOfClass:[UITabBarController class]]) return nil;
    UITabBarController *tabs = (UITabBarController *)root;
    for (UIViewController *child in tabs.viewControllers) {
        UINavigationController *nav = nil;
        if ([child isKindOfClass:[UINavigationController class]]) {
            nav = (UINavigationController *)child;
        } else if ([child.navigationController isKindOfClass:[UINavigationController class]]) {
            nav = child.navigationController;
        }
        if (!nav) continue;
        for (UIViewController *controller in nav.viewControllers) {
            if (ApolloFeedSplitIsListController(controller)) {
                ApolloFeedSplitSaveList(preferred ?: nav, controller);
                return controller;
            }
        }
    }
    return nil;
}

extern "C" void ApolloFeedSplitShowSubredditPicker(UINavigationController *nav) {
    ApolloDuoRailSetPickingSubreddits(YES);
    if (!nav) {
        ApolloLog(@"[FeedSplit] My Subreddits skipped (no posts nav)");
        return;
    }
    ApolloFeedSplitRememberListOnStack(nav);
    UIViewController *list = ApolloFeedSplitFindListAnywhere(nav);
    UIViewController *feed = ApolloFeedSplitFirstFeedOnStack(nav);
    if (!feed && ApolloFeedSplitIsFeedController(nav.topViewController)) {
        feed = nav.topViewController;
    }
    if (!feed) {
        for (UIViewController *controller in nav.viewControllers) {
            if (ApolloFeedSplitIsFeedController(controller)) {
                feed = controller;
                break;
            }
        }
    }
    NSArray<UIViewController *> *want = nil;
    if (list && feed && list != feed) {
        want = @[ list, feed ];
    } else if (list) {
        want = @[ list ];
    } else if (feed) {
        want = @[ feed ];
    }
    ApolloLog(@"[FeedSplit] My Subreddits restore list=%d feed=%d saved=%d stack=%lu → %lu",
              list ? 1 : 0, feed ? 1 : 0,
              ApolloFeedSplitSavedList(nav) ? 1 : 0,
              (unsigned long)nav.viewControllers.count,
              (unsigned long)(want ? want.count : 0));
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (want && ![nav.viewControllers isEqualToArray:want]) {
        [nav setViewControllers:want animated:NO];
    }
    if (list && !list.isViewLoaded) [list loadViewIfNeeded];
    if (feed && !feed.isViewLoaded) [feed loadViewIfNeeded];
    if (list) ApolloFeedSplitSaveList(nav, list);
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloFeedSplitMarkApplyDirty(nav);
    ApolloFeedSplitForceTiledForSeconds(0.8);
    ApolloFeedSplitApply(nav, NO);
    UIView *container = ApolloFeedSplitContainerView(nav);
    UIViewController *primary = nil;
    UIViewController *secondary = nil;
    ApolloFeedSplitPairOnStack(nav, &primary, &secondary);
    if (!primary) primary = list ?: nav.topViewController;
    if (!secondary) secondary = feed;
    ApolloFeedSplitRemoveForeignColumns(nav, container, primary, secondary);
    ApolloFeedSplitReapplySoon();
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
    ApolloFeedSplitRememberListOnStack(nav);
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

    double extraLeft = 0.0;
    double extraRight = 0.0;
    ApolloFeedSplitChromeExtras(nav.view, &extraLeft, &extraRight);
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
            frames.feed = ApolloFeedSplitClampRectToHalfInsets(frames.feed, cw, ch, rtl ? 1 : 0,
                                                              extraLeft, extraRight);
        }
        if (frames.showsDetail) {
            if (ApolloFeedSplitRectSpansMidX(frames.detail, mid) || mode == ApolloFeedSplitModeTiled) {
                frames.detail = ApolloFeedSplitClampRectToHalfInsets(frames.detail, cw, ch, rtl ? 0 : 1,
                                                                    extraLeft, extraRight);
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
            ApolloFeedSplitKeepSingleTrailingDetail(nav, container, detail);
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
    objc_setAssociatedObject(nav, &kApolloFeedSplitLastApplySizeKey,
                             [NSValue valueWithCGSize:container.bounds.size],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    double extraLeft = 0.0;
    double extraRight = 0.0;
    ApolloFeedSplitChromeExtras(nav.view, &extraLeft, &extraRight);
    double usable = ApolloFeedSplitUsableWidth(size.width, extraLeft, extraRight);
    return ApolloFeedSplitModeForTraits((int)nav.traitCollection.horizontalSizeClass, usable, 1)
        == ApolloFeedSplitModeTiled;
}

static void ApolloFeedSplitMarkApplyDirty(UINavigationController *nav) {
    if (!nav) return;
    objc_setAssociatedObject(nav, &kApolloFeedSplitLastApplySizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(nav, &kApolloFeedSplitSpanCoalesceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedSplitDetachHost(UIView *container, UIViewController *controller) {
    if (!controller.isViewLoaded) return;
    UIView *view = controller.view;
    UIView *layout = container ? ApolloFeedSplitLayoutView(controller, container) : nil;
    if (layout && layout.superview) {
        [layout removeFromSuperview];
    }
    if (view.superview) {
        [view removeFromSuperview];
    }
    if (!container) return;
    for (UIView *sub in [container.subviews copy]) {
        if (sub == view || sub == layout) {
            [sub removeFromSuperview];
            continue;
        }
        if ([view isDescendantOfView:sub] || [sub isDescendantOfView:view]) {
            [sub removeFromSuperview];
        }
    }
}

// Mail-style: right pane is always @[feed, latestDetail]. A second left-pane
// topic tap must not push onto [feed, oldComments] (top is no longer the
// feed, so the old tile-on-feed path skipped and the first post stayed).
static BOOL ApolloFeedSplitReplaceReadingDetail(UINavigationController *nav,
                                                UIViewController *detail) {
    if (!nav || !detail) return NO;
    UIViewController *feed = ApolloFeedSplitFirstFeedOnStack(nav);
    if (!feed || feed == detail) return NO;
    if (!ApolloFeedSplitIsReadingDetailController(detail)) return NO;

    NSArray<UIViewController *> *stack = nav.viewControllers;
    NSMutableArray<UIViewController *> *oldDetails = [NSMutableArray array];
    for (UIViewController *controller in stack) {
        if (controller == feed || controller == detail) continue;
        if (ApolloFeedSplitIsReadingDetailController(controller)) {
            [oldDetails addObject:controller];
        }
    }
    NSArray<UIViewController *> *want = @[ feed, detail ];
    UIView *container = ApolloFeedSplitContainerView(nav);
    if (![stack isEqualToArray:want]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [nav setViewControllers:want animated:NO];
        if (!detail.isViewLoaded) [detail loadViewIfNeeded];
        objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction commit];
        for (UIViewController *oldDetail in oldDetails) {
            ApolloFeedSplitDetachHost(container, oldDetail);
        }
    } else if (!detail.isViewLoaded) {
        [detail loadViewIfNeeded];
    }

    ApolloFeedSplitMarkApplyDirty(nav);
    ApolloFeedSplitForceTiledForSeconds(0.8);
    ApolloFeedSplitApply(nav, NO);
    ApolloFeedSplitRemoveForeignColumns(nav, container, feed, detail);
    ApolloFeedSplitKeepSingleTrailingDetail(nav, container, detail);
    ApolloLog(@"[FeedSplit] replaced reading detail stack=%lu old=%lu new=%@",
              (unsigned long)want.count,
              (unsigned long)oldDetails.count,
              NSStringFromClass(detail.class));
    return YES;
}

static void ApolloFeedSplitCollapseReplacedComments(UINavigationController *nav) {
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;
    UIViewController *feed = ApolloFeedSplitFirstFeedOnStack(nav);
    UIViewController *top = nav.viewControllers.lastObject;
    if (!feed || !top || feed == top) return;
    if (!ApolloFeedSplitIsReadingDetailController(top)) return;
    if (!ApolloFeedSplitWouldTile(nav)) return;
    NSArray<UIViewController *> *stack = nav.viewControllers;
    NSArray<UIViewController *> *want = @[ feed, top ];
    if ([stack isEqualToArray:want]) return;

    NSMutableArray<UIViewController *> *detached = [NSMutableArray array];
    for (UIViewController *controller in stack) {
        if (controller == feed || controller == top) continue;
        if (ApolloFeedSplitIsReadingDetailController(controller)) {
            [detached addObject:controller];
        }
    }
    UIView *container = ApolloFeedSplitContainerView(nav);
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [nav setViewControllers:want animated:NO];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIViewController *controller in detached) {
        ApolloFeedSplitDetachHost(container, controller);
    }
    ApolloFeedSplitMarkApplyDirty(nav);
    ApolloFeedSplitForceTiledForSeconds(0.8);
    ApolloFeedSplitApply(nav, NO);
    ApolloFeedSplitRemoveForeignColumns(nav, container, feed, top);
    ApolloFeedSplitKeepSingleTrailingDetail(nav, container, top);
    ApolloLog(@"[FeedSplit] replaced comments column (stack %lu→%lu)",
              (unsigned long)stack.count, (unsigned long)want.count);
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
    BOOL spans = duoRail && ApolloFeedSplitChildSpansMidX(container);
    BOOL scrolling = duoRail && ApolloFeedSplitNavIsScrolling(nav);

    if (nav.transitionCoordinator) {
        ApolloFeedSplitScheduleApply(nav);
        if (spans) ApolloFeedSplitApply(nav, NO);
        return;
    }

    // Active drag/deceleration: do not re-pin (that hitches the comments
    // pane). Only intervene if a column has gone truly full-bleed.
    if (scrolling && !spans) {
        return;
    }

    NSValue *lastSize = objc_getAssociatedObject(nav, &kApolloFeedSplitLastApplySizeKey);
    BOOL sizeChanged = !lastSize
        || !CGSizeEqualToSize(lastSize.CGSizeValue, container.bounds.size);
    if (!spans && !sizeChanged && duoRail) {
        NSNumber *last = objc_getAssociatedObject(nav, &kApolloFeedSplitSpanCoalesceKey);
        CFTimeInterval now = CACurrentMediaTime();
        if (last && (now - last.doubleValue) < 0.12) {
            return;
        }
        objc_setAssociatedObject(nav, &kApolloFeedSplitSpanCoalesceKey, @(now),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        ApolloFeedSplitMarkApplyDirty(nav);
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

    // Topic / post: tile as feed|detail. If comments are already showing,
    // replace that detail (top is no longer the feed — a second left-pane
    // tap used to %orig-push and leave the first post painted).
    if (duoTile && viewController
        && ApolloFeedSplitIsReadingDetailController(viewController)
        && (ApolloFeedSplitIsFeedController(nav.topViewController)
            || ApolloFeedSplitIsReadingDetailController(nav.topViewController)
            || ApolloFeedSplitFirstFeedOnStack(nav))) {
        if (ApolloFeedSplitReplaceReadingDetail(nav, viewController)) {
            ApolloFeedSplitReapplySoon();
            return;
        }
        %orig(viewController, NO);
        ApolloFeedSplitCollapseReplacedComments(nav);
        ApolloFeedSplitForceTiledForSeconds(0.8);
        ApolloFeedSplitMarkApplyDirty(nav);
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
    if (ApolloDuoRailIsActive()
        && ApolloFeedSplitPairOnStack(nav, NULL, NULL) == ApolloFeedSplitPairFeedComments) {
        ApolloFeedSplitMarkApplyDirty(nav);
        ApolloFeedSplitForceTiledForSeconds(0.8);
        ApolloFeedSplitApply(nav, NO);
        ApolloFeedSplitReapplySoon();
        return;
    }
    ApolloFeedSplitScheduleApply(nav);
}

- (void)showViewController:(UIViewController *)viewController sender:(id)sender {
    UINavigationController *nav = (UINavigationController *)self;
    BOOL duoTile = ApolloDuoRailIsActive() && ApolloFeedSplitWouldTile(nav);
    if (duoTile && viewController
        && ApolloFeedSplitIsReadingDetailController(viewController)
        && ApolloFeedSplitFirstFeedOnStack(nav)) {
        if (ApolloFeedSplitReplaceReadingDetail(nav, viewController)) {
            ApolloFeedSplitReapplySoon();
            return;
        }
    }
    %orig;
}

%end

%hook UINavigationBar

- (void)layoutSubviews {
    %orig;
    UINavigationController *nav = nil;
    if ([self.delegate isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)self.delegate;
    }
    if (nav && ApolloFeedSplitNavIsScrolling(nav)) return;
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
