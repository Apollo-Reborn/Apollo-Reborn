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
// Settings. **list | feed** is only while My Subreddits is picking (directory
// left, current feed right). Tapping a subreddit dismisses the directory:
// that sub's posts sit in the leading half; the right pane stays empty
// until a post opens as **feed | comments**.
//
// Stock Apollo has no unlockable UISplitViewController path — AutoHideMetaFeeds
// only walks split columns defensively. Wrapping a tab's ApolloNavigationController
// in a split would break the many call sites that treat
// tab.selectedViewController as that nav (settings, floating tabs, swipe-up
// comments, URL routing, video swipe). So we keep the real stack and tile
// inside the existing nav. back / pop / topViewController keep working.
//
// Column frames use layout-margin EXTRA only (ApolloDeviceChromeExtra), not
// the full chrome inset, so children still apply their own safeAreaInsets
// and we do not double-count the notch.

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceReservedRegions.h"
#import "ApolloDuoRail.h"
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

static BOOL ApolloFeedSplitIsCommentsController(UIViewController *controller) {
    if (!controller) return NO;
    if (ApolloSwipeCommentsIsPaneCommentsController(controller)) return NO;
    // Saved posts is a feed whose class name also contains CommentsViewController.
    if (ApolloFeedSplitIsFeedController(controller)) return NO;
    Class comments = objc_getClass("_TtC6Apollo22CommentsViewController");
    if (comments && [controller isKindOfClass:comments]) return YES;
    const char *name = class_getName(controller.class);
    return name && strstr(name, "CommentsViewController") != NULL;
}

static BOOL ApolloFeedSplitIsListController(UIViewController *controller) {
    return ApolloFeedSplitIsClass(controller, "_TtC6Apollo24RedditListViewController");
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
            if (!CGRectEqualToRect(table.frame, view.bounds)) {
                table.frame = view.bounds;
            }
        }
    }
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
    // Post-open: feed | comments wins so drilling into a thread does not
    // keep a three-column list|feed|comments layout.
    if (ApolloFeedSplitIsCommentsController(detail) && ApolloFeedSplitIsFeedController(previous)) {
        if (primaryOut) *primaryOut = previous;
        if (detailOut) *detailOut = detail;
        return ApolloFeedSplitPairFeedComments;
    }
    if (ApolloDuoRailIsPickingSubreddits()
        && ApolloFeedSplitIsFeedController(detail)
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
    double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
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
    // Scroll/layout can blip usable width or size class. On open Duo do not
    // drop a live pair to Stacked (that full-bleeds the top VC).
    if (ApolloDuoRailIsActive() && hasDetail && feed && detail) {
        mode = ApolloFeedSplitModeTiled;
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
    UIViewController *root = nav.viewControllers.firstObject;
    UIViewController *feed = ApolloFeedSplitFirstFeedOnStack(nav);
    NSArray<UIViewController *> *want = nil;
    if (root && feed && root != feed) {
        want = @[ root, feed ];
    } else if (root) {
        want = @[ root ];
    }
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (want && ![nav.viewControllers isEqualToArray:want]) {
        [nav setViewControllers:want animated:NO];
    }
    if (root && !root.isViewLoaded) [root loadViewIfNeeded];
    if (feed && !feed.isViewLoaded) [feed loadViewIfNeeded];
    objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloFeedSplitApply(nav, NO);
    ApolloLog(@"[FeedSplit] My Subreddits list|feed stack=%lu",
              (unsigned long)nav.viewControllers.count);
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
    double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
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
    ApolloFeedSplitFrames frames = ApolloFeedSplitFramesMake(
        container.bounds.size.width, container.bounds.size.height,
        extraLeft, extraRight, mode, rtl ? 1 : 0, tileStyle, hingeX, hingeW,
        ApolloDuoRailIsActive() ? 1 : 0);

    void (^apply)(void) = ^{
        UIView *separator = ApolloFeedSplitSeparator(nav, mode == ApolloFeedSplitModeTiled);
        if (mode == ApolloFeedSplitModeStacked) {
            UIViewController *top = nav.topViewController;
            if (top.isViewLoaded) {
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
            return;
        }

        if (!feed || !feed.isViewLoaded) return;
        UIView *feedLayout = ApolloFeedSplitLayoutView(feed, container);
        if (!feedLayout) return;

        if (feedLayout.superview != container) {
            [container insertSubview:feedLayout atIndex:0];
        }
        ApolloFeedSplitPinColumn(feed, container, frames.feed);

        if (mode == ApolloFeedSplitModeTiled && detail) {
            UIView *detailLayout = ApolloFeedSplitLayoutView(detail, container);
            if (detailLayout && detailLayout.superview != container) {
                [container addSubview:detailLayout];
            }
            ApolloFeedSplitPinColumn(detail, container, frames.detail);
            ApolloFeedSplitSetPrimaryAlongside(feed, YES);
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
            ApolloFeedSplitSetPrimaryAlongside(feed, feed != nav.topViewController);
            if (separator.superview) [separator removeFromSuperview];
        }
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
    if (ApolloDuoRailIsActive()
        && size.width + 0.5 >= (double)ApolloFeedSplitMinRegularWidth) {
        return YES;
    }
    UIEdgeInsets safe = nav.view.safeAreaInsets;
    UIEdgeInsets margins = nav.view.layoutMargins;
    double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
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
    if (!ApolloFeedSplitIsCommentsController(top) || !ApolloFeedSplitIsCommentsController(mid)) return;
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
    if (nav.transitionCoordinator) return;
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

    // Subreddit tap while picking: dismiss the directory. That sub's posts
    // become the sole VC and sit in the leading half (right empty until a
    // post opens). Skip %orig so the stock push does not slide.
    if (duoTile && viewController && ApolloFeedSplitIsFeedController(viewController)
        && ApolloDuoRailIsPickingSubreddits()) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoRailSetPickingSubreddits(NO);
        [nav setViewControllers:@[ viewController ] animated:NO];
        objc_setAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction commit];
        ApolloFeedSplitApply(nav, NO);
        ApolloLog(@"[FeedSplit] dismissed directory; sub feed leading");
        return;
    }

    if (duoTile && ApolloFeedSplitIsCommentsController(viewController)) {
        %orig(viewController, NO);
        ApolloFeedSplitCollapseReplacedComments(nav);
        ApolloFeedSplitApply(nav, NO);
        return;
    }

    %orig;
    ApolloFeedSplitCollapseReplacedComments(nav);
    ApolloFeedSplitCollapseReplacedFeeds(nav);
    if (duoTile) {
        ApolloFeedSplitApply(nav, NO);
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

%ctor {
    Class nav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!nav) {
        ApolloLog(@"[FeedSplit] ApolloNavigationController missing; size-class layout inactive");
        return;
    }
    %init;
    ApolloLog(@"[FeedSplit] hook installed (Regular feed|comments; list|feed while My Subreddits; Compact stacks)");
}
