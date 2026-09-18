// ApolloFeedSplit.xm
//
// Regular-width feed | comments layout for Duo's inner display (and any
// other Regular-width iPhone, e.g. Plus/Max landscape). Compact stays a
// single column.
//
// Stock Apollo has no unlockable UISplitViewController path — AutoHideMetaFeeds
// only walks split columns defensively. Wrapping a tab's ApolloNavigationController
// in a split would break the many call sites that treat
// tab.selectedViewController as that nav (settings, floating tabs, swipe-up
// comments, URL routing, video swipe). So we keep the real stack and tile
// inside the existing nav: feed stays leading, comments stay trailing, back
// / pop / topViewController keep working.
//
// Column frames use layout-margin EXTRA only (ApolloDeviceChromeExtra), not
// the full chrome inset, so children still apply their own safeAreaInsets
// and we do not double-count the notch.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDeviceChromeInsets.h"
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
    Class comments = objc_getClass("_TtC6Apollo22CommentsViewController");
    if (!comments || ![controller isKindOfClass:comments]) return NO;
    return !ApolloSwipeCommentsIsPaneCommentsController(controller);
}

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
    if (!feed.isViewLoaded) return;
    [feed beginAppearanceTransition:alongside animated:NO];
    [feed endAppearanceTransition];
}

static BOOL ApolloFeedSplitHasDetailPair(UINavigationController *nav,
                                         UIViewController **feedOut,
                                         UIViewController **detailOut) {
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.count < 2) return NO;
    UIViewController *detail = stack.lastObject;
    if (!ApolloFeedSplitIsCommentsController(detail)) return NO;
    UIViewController *previous = stack[stack.count - 2];
    if (!ApolloFeedSplitIsFeedController(previous)) return NO;
    if (feedOut) *feedOut = previous;
    if (detailOut) *detailOut = detail;
    return YES;
}

static ApolloFeedSplitMode ApolloFeedSplitCurrentMode(UINavigationController *nav,
                                                      CGSize containerSize,
                                                      UIView *insetView,
                                                      UIViewController **feedOut,
                                                      UIViewController **detailOut) {
    UIViewController *feed = nil;
    UIViewController *detail = nil;
    BOOL hasDetail = ApolloFeedSplitHasDetailPair(nav, &feed, &detail);
    if (!hasDetail) {
        UIViewController *top = nav.topViewController;
        if (ApolloFeedSplitIsFeedController(top)) {
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
    ApolloLog(@"[FeedSplit] mode=%s sizeClass=%ld",
              name, (long)nav.traitCollection.horizontalSizeClass);
}

static void ApolloFeedSplitApply(UINavigationController *nav, BOOL animated) {
    if (!nav.isViewLoaded || ApolloRowMeasureInProgress()) return;
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;

    UIView *container = ApolloFeedSplitContainerView(nav);
    if (!container || CGRectIsEmpty(container.bounds)) return;

    UIViewController *feed = nil;
    UIViewController *detail = nil;
    ApolloFeedSplitMode mode = ApolloFeedSplitCurrentMode(nav, container.bounds.size, nav.view, &feed, &detail);
    ApolloFeedSplitLogModeIfChanged(nav, mode);

    UIEdgeInsets safe = nav.view.safeAreaInsets;
    UIEdgeInsets margins = nav.view.layoutMargins;
    double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
    double extraRight = ApolloDeviceChromeExtra(safe.right, margins.right);
    BOOL rtl = nav.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    ApolloFeedSplitFrames frames = ApolloFeedSplitFramesMake(
        container.bounds.size.width, container.bounds.size.height,
        extraLeft, extraRight, mode, rtl ? 1 : 0);

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
        ApolloFeedSplitSetFrame(feedLayout, CGRectMake(frames.feed.x, frames.feed.y,
                                                       frames.feed.width, frames.feed.height));

        if (mode == ApolloFeedSplitModeTiled && detail) {
            UIView *detailLayout = ApolloFeedSplitLayoutView(detail, container);
            if (detailLayout) {
                if (detailLayout.superview != container) {
                    [container addSubview:detailLayout];
                }
                ApolloFeedSplitSetFrame(detailLayout, CGRectMake(frames.detail.x, frames.detail.y,
                                                                 frames.detail.width, frames.detail.height));
            }
            ApolloFeedSplitSetPrimaryAlongside(feed, YES);
            if (separator) {
                CGFloat gutter = (CGFloat)ApolloFeedSplitGutterWidth;
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

    if (animated) {
        [UIView animateWithDuration:0.25 delay:0.0 options:UIViewAnimationOptionCurveEaseInOut animations:apply completion:nil];
    } else {
        apply();
    }
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
            ApolloFeedSplitApply(nav, YES);
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
    %orig;
    UINavigationController *nav = (UINavigationController *)self;
    ApolloFeedSplitCollapseReplacedComments(nav);
    ApolloFeedSplitScheduleApply(nav);
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = %orig;
    ApolloFeedSplitScheduleApply((UINavigationController *)self);
    return popped;
}

- (NSArray<UIViewController *> *)popToViewController:(UIViewController *)viewController animated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    ApolloFeedSplitScheduleApply((UINavigationController *)self);
    return popped;
}

- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    ApolloFeedSplitScheduleApply((UINavigationController *)self);
    return popped;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    %orig;
    UINavigationController *nav = (UINavigationController *)self;
    if (objc_getAssociatedObject(nav, &kApolloFeedSplitMutatingStackKey)) return;
    ApolloFeedSplitCollapseReplacedComments(nav);
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
    ApolloLog(@"[FeedSplit] hook installed (Regular feed|comments tile; Compact stacks)");
}
