// Owns physical column containment and readable-content insets.
#import "ApolloPaneColumnHostViewController.h"
#import "ApolloPaneSplitViewController.h"
#import "ApolloPaneGeometry.h"
#import "../ApolloCommon.h"
#import "../ApolloThemeRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>

@implementation ApolloPaneColumnHostViewController {
    NSLayoutConstraint *_topConstraint;
    NSLayoutConstraint *_bottomConstraint;
    ApolloPaneGeometryScheduler *_geometryScheduler;
    BOOL _hasResolvedGeometry;
    CGFloat _lastResolvedTop;
    CGFloat _lastResolvedBottom;
    __weak UIViewController *_readableWidthViewController;
    CGFloat _readableWidthBaseLeft;
    CGFloat _readableWidthBaseRight;
    CGFloat _readableWidthAppliedInset;
#if APOLLO_SIM_BUILD
    NSUInteger _simLayoutPassCount;
    NSUInteger _simGeometryRefreshCount;
    NSUInteger _simGeometryWriteCount;
#endif
}

- (instancetype)initWithNavigationController:(UINavigationController *)navigationController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _hostedNavigationController = navigationController;

        // The same tab-bar reservation the pane itself has to opt out of (see
        // the pane's configure method), one level further down.
        //
        // UISplitViewController wraps this host in a navigation controller of
        // its own, and THAT controller applies the identical
        // -[UITabBarController _frameForViewController:] rule to its child: it
        // subtracts the opaque tab bar's height unless the child extends under
        // it. The pane opting in did not help, because this host is a separate
        // controller that never inherited the flag.
        //
        // Measured: the host's view came out (0,0,1376,968) inside a 1032pt
        // wrapper, so the detail column ended at 968 while the list column ended
        // at 1022 — the comment list stopping 54pt above the bottom of the
        // screen with a band of background under it.
        self.edgesForExtendedLayout = UIRectEdgeAll;
        self.extendedLayoutIncludesOpaqueBars = YES;

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(apollo_contentSizeCategoryDidChange:)
                   name:UIContentSizeCategoryDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self apollo_restoreReadableWidthInsets];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // CLEAR, deliberately — this view must never paint.
    //
    // It is laid out at the FULL window width (iPadOS 26 gives the secondary
    // column the whole window and floats the other columns over it), while the
    // navigation controller inside it is inset to the visible column. Giving it
    // a background therefore does not tint "the detail column", it tints the
    // entire window: behind the floating sidebar, in the gap between columns,
    // and above the list column.
    //
    // That is exactly what went wrong. It painted ApolloThemePageBackgroundColor(),
    // which is black under a pure-black theme and so looked correct — until a
    // themed palette made it #0B1F28 and the whole app turned teal behind
    // Apollo's own black screens. Only the controllers actually occupying a
    // column may paint; this one is scaffolding.
    self.view.backgroundColor = UIColor.clearColor;

    UINavigationController *nav = self.hostedNavigationController;
    if (!nav) return;

    [self addChildViewController:nav];
    nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:nav.view];
    // ALL FOUR edges pin to the safe area, vertically as well as horizontally.
    //
    // Leading/trailing is the Texture fix (see the class comment). Top/bottom
    // used to pin to the view so the nav bar could extend under the status bar
    // "as Apollo expects" — that was wrong, and it is what made the app read as
    // three separate windows rather than one.
    //
    // Measured on an iPad Pro 13" landscape, the three navigation bars were:
    //
    //   sidebar   (10, 32, 270, 54)
    //   list      (280, 32, 480, 54)
    //   detail    (760, 86, 616, 54)   ← 54pt lower than both its neighbours
    //
    // UIKit positions the sidebar and the list column inside already-inset
    // column views, so their bars start at the column's own top. The secondary
    // column view spans the full window (0,0,1376,1032), so pinning the nav
    // controller to its top told that controller it began at the very top of the
    // screen and it applied the whole status-bar inset a second time. Pinning to
    // the safe area gives it the same origin UIKit gave the other two, and the
    // three bars line up.
    // Leading/trailing follow the safe area — that is the Texture fix, and it is
    // the only thing the safe area gets to decide here.
    //
    // Top/bottom are driven manually against the LIST column's real frame (see
    // apollo_matchListColumnGeometry). The safe area is the wrong input for
    // them: it produced a detail column running 32→1012 against the list
    // column's 32→1022, and it cannot express the 10pt the navigation bar
    // inserts above itself.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _topConstraint = [nav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                        constant:self.view.safeAreaInsets.top];
    _bottomConstraint = [self.view.bottomAnchor constraintEqualToAnchor:nav.view.bottomAnchor
                                                              constant:self.view.safeAreaInsets.bottom];
    [NSLayoutConstraint activateConstraints:@[
        [nav.view.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [nav.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        _topConstraint,
        _bottomConstraint,
    ]];
    [nav didMoveToParentViewController:self];
}

// UISplitViewController wraps any column view controller that is not already a
// navigation controller in one of its own. This host is a plain UIViewController,
// so the detail column ends up with TWO navigation bars stacked:
//
//   UIKit's wrapper bar   (0, 32, 1376, 54)   full width, empty, invisible
//   Apollo's real bar     (760, 96, 616, 54)  pushed below it
//
// The wrapper bar is never seen, but it still reports itself through the safe
// area — 86pt of top inset — which is what pushed Apollo's bar 54pt below the
// sidebar's and the list column's bars and made the three columns read as three
// separate windows. Its full-width background band was painting across the whole
// app too.
//
// Hiding it costs nothing: the wrapper has no items, no title and no back
// button, because everything the user interacts with lives on the real
// navigation controller inside this host.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationController && !self.navigationController.navigationBarHidden) {
        [self.navigationController setNavigationBarHidden:YES animated:NO];
    }
    [self apollo_scheduleListColumnGeometryRefresh];
}

// Lines the detail column up with the list column exactly, top and bottom.
//
// WHY NOT THE SAFE AREA. Both navigation controllers report a top safe-area
// inset of ZERO, and yet:
//
//   list    view {0,0,480,990}     bar at y=0    (column starts at 32 → bar at 32)
//   detail  view {760,32,616,980}  bar at y=10   (→ bar at 42)
//
// The 10pt is not an inset we can cancel — it is where Apollo's navigation
// controller puts its own bar. UIKit's split view positions the list column's
// navigation controller itself and gets y=0; the same class, parented into this
// host, lays its bar at y=10. So the fix is not to argue with the bar but to
// offset the view by exactly the gap the bar leaves, measured each layout.
//
// The bottom is the same idea from the other side: the safe area put the detail
// column's bottom at 1012 against the list column's 1022, which is the band of
// empty background under the comment list. Matching the list column's maxY
// removes it, and matching is more robust than any constant since it tracks
// whatever inset the platform applies to that column.
//
// Constraint writes must not originate from viewDidLayoutSubviews: even a
// value-checked write there can invalidate the same layout transaction during
// rotation or continuous window resize. Safe-area and transition callbacks
// coalesce into one post-layout sample instead.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self apollo_scheduleListColumnGeometryRefresh];

    ApolloPaneSplitViewController *pane =
        [self.splitViewController isKindOfClass:[ApolloPaneSplitViewController class]]
            ? (ApolloPaneSplitViewController *)self.splitViewController : nil;
    [pane apollo_resolvedDisplayStateMayHaveChanged];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak ApolloPaneColumnHostViewController *weakSelf = self;
    [coordinator animateAlongsideTransition:nil
        completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            [weakSelf apollo_scheduleListColumnGeometryRefresh];
        }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self apollo_scheduleListColumnGeometryRefresh];
}

- (void)apollo_contentSizeCategoryDidChange:(NSNotification *)notification {
    (void)notification;
    [self apollo_scheduleListColumnGeometryRefresh];
}

- (UITableView *)apollo_tableInView:(UIView *)view depth:(NSUInteger)depth {
    if (!view || depth > 10) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *table = [self apollo_tableInView:subview depth:depth + 1];
        if (table) return table;
    }
    return nil;
}

// Settings tables still use an additive safe-area contribution. Comments use
// per-node readable specs, so media headers keep the full detail width and
// asynchronously arriving prose is classified at its factory, not by row zero.
- (BOOL)apollo_topControllerWantsReadableWidth:(UIViewController *)controller {
    ApolloPaneSplitViewController *pane = (id)self.splitViewController;
    if (![pane isKindOfClass:ApolloPaneSplitViewController.class]) return NO;
    UIViewController *root = [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary].viewControllers.firstObject;
    return [NSStringFromClass(root.class) hasSuffix:@"SettingsViewController"] &&
        controller.isViewLoaded && [self apollo_tableInView:controller.view depth:0] != nil;
}

- (void)apollo_restoreReadableWidthInsets {
    UIViewController *controller = _readableWidthViewController;
    if (controller) {
        UIEdgeInsets additional = controller.additionalSafeAreaInsets;
        additional.left -= _readableWidthAppliedInset;
        additional.right -= _readableWidthAppliedInset;
        controller.additionalSafeAreaInsets = additional;
    }
    _readableWidthViewController = nil;
    _readableWidthBaseLeft = 0.0;
    _readableWidthBaseRight = 0.0;
    _readableWidthAppliedInset = 0.0;
}

- (void)apollo_applyReadableWidthIfNeeded {
    UIViewController *top = self.hostedNavigationController.topViewController;
    BOOL wantsReadableWidth = [self apollo_topControllerWantsReadableWidth:top];
    if (_readableWidthViewController != top || !wantsReadableWidth) {
        [self apollo_restoreReadableWidthInsets];
    }
    if (!wantsReadableWidth || !top.isViewLoaded) return;

    if (_readableWidthViewController != top) {
        _readableWidthViewController = top;
        _readableWidthBaseLeft = top.additionalSafeAreaInsets.left;
        _readableWidthBaseRight = top.additionalSafeAreaInsets.right;
    }

    CGFloat width = CGRectGetWidth(top.view.bounds);
    // A controller installed into a visible navigation stack has not always
    // received its first bounds assignment yet. The navigation controller is
    // already constrained to the real detail column, so its width is the exact
    // pre-display fallback we need. Waiting for top.view.bounds to become
    // nonzero would allow one unconstrained frame to reach the screen.
    if (width <= 0.0 && self.hostedNavigationController.isViewLoaded) {
        width = CGRectGetWidth(self.hostedNavigationController.view.bounds);
    }
    if (width <= 0.0) return;

    // 680pt is close to UIKit's familiar readable measure while still leaving
    // room for nested comment indentation. At accessibility text sizes the cap
    // relaxes to 760pt so larger glyphs do not turn every sentence into a tall,
    // narrow column. The nav bar and table/background remain full width; only
    // safe-area-following cell content is inset.
    UIContentSizeCategory category = top.traitCollection.preferredContentSizeCategory;
    CGFloat maximumWidth = UIContentSizeCategoryIsAccessibilityCategory(category) ? 760.0 : 680.0;
    UIEdgeInsets current = top.additionalSafeAreaInsets;
    CGFloat systemLeft = MAX(0.0, top.view.safeAreaInsets.left - current.left);
    CGFloat systemRight = MAX(0.0, top.view.safeAreaInsets.right - current.right);
    // Preserve inset contributions added by Apollo or another feature.
    _readableWidthBaseLeft = current.left - _readableWidthAppliedInset;
    _readableWidthBaseRight = current.right - _readableWidthAppliedInset;
    CGFloat naturalWidth = MAX(0.0, width - systemLeft - systemRight -
                               _readableWidthBaseLeft - _readableWidthBaseRight);
    CGFloat inset = MAX(0.0, floor((naturalWidth - maximumWidth) / 2.0));
    if (fabs(_readableWidthAppliedInset - inset) <= 0.5 &&
        fabs(current.left - (_readableWidthBaseLeft + inset)) <= 0.5 &&
        fabs(current.right - (_readableWidthBaseRight + inset)) <= 0.5) return;

    _readableWidthAppliedInset = inset;
    current.left = _readableWidthBaseLeft + inset;
    current.right = _readableWidthBaseRight + inset;
    top.additionalSafeAreaInsets = current;
    ApolloLog(@"[PaneReadable] %@ width=%.0f max=%.0f inset=%.0f accessibility=%d",
              NSStringFromClass(top.class), naturalWidth, maximumWidth, inset,
              UIContentSizeCategoryIsAccessibilityCategory(category));
}

- (void)apollo_prepareReadableWidthForTopController {
    UIViewController *top = self.hostedNavigationController.topViewController;
    if (!top) {
        [self apollo_restoreReadableWidthInsets];
        return;
    }

    // This destination is about to become visible, so loading it here does not
    // defeat the pane's lazy offscreen-tab policy. It does let us classify its
    // table surface and install additionalSafeAreaInsets before Core Animation
    // commits the navigation transaction's first frame.
    [top loadViewIfNeeded];
#if APOLLO_SIM_BUILD
    ApolloLog(@"[PaneReadablePrepare] %@ topWidth=%.0f navWidth=%.0f table=%d window=%d",
              NSStringFromClass(top.class), CGRectGetWidth(top.view.bounds),
              CGRectGetWidth(self.hostedNavigationController.viewIfLoaded.bounds),
              [self apollo_tableInView:top.view depth:0] != nil,
              top.view.window != nil);
#endif
    [self apollo_applyReadableWidthIfNeeded];
}

#if APOLLO_SIM_BUILD
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _simLayoutPassCount++;
}
#endif

- (void)apollo_scheduleListColumnGeometryRefresh {
    if (!_geometryScheduler) {
        _geometryScheduler = [[ApolloPaneGeometryScheduler alloc] initWithOwner:self update:^(id owner) {
            [owner apollo_matchListColumnGeometry];
        }];
    }
    [_geometryScheduler requestAfterCoordinator:self.splitViewController.transitionCoordinator];
}

- (void)apollo_matchListColumnGeometry {
    UINavigationController *nav = self.hostedNavigationController;
    if (!nav.isViewLoaded || !_topConstraint || !_bottomConstraint) return;
#if APOLLO_SIM_BUILD
    _simGeometryRefreshCount++;
#endif

    CGFloat height = self.view.bounds.size.height;
    if (height <= 0.0) return;

    [self apollo_applyReadableWidthIfNeeded];

    // Fall back to the safe area whenever the list column cannot be measured —
    // collapsed, mid-transition, or not yet loaded.
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    // UIKit's public content guide includes floating top tabs even when the
    // legacy tabBar view is hidden. Use its actual area, never a guessed row
    // height or private tab-bar subview frame.
    UITabBarController *tabs = self.tabBarController;
    if (@available(iOS 26.0, *)) {
        UILayoutGuide *guide = tabs.contentLayoutGuide;
        if (self.splitViewController.isCollapsed && guide.owningView.window) {
            CGRect content = [guide.owningView convertRect:guide.layoutFrame toView:self.view];
            top = MAX(top, CGRectGetMinY(content) - nav.navigationBar.frame.origin.y);
            bottom = MAX(bottom, height - CGRectGetMaxY(content));
        }
    }

    UISplitViewController *split = self.splitViewController;
    UIViewController *list = [split isKindOfClass:[UISplitViewController class]]
        ? [split viewControllerForColumn:UISplitViewControllerColumnPrimary]
        : nil;
    if (list.isViewLoaded && list.view.superview && ApolloPaneSplitShowsTiledPrimary(split)) {
        CGRect listFrame = [list.view.superview convertRect:list.view.frame toView:self.view];
        CGRect splitBoundsInHost = [split.view convertRect:split.view.bounds toView:self.view];
        if (!CGRectIsEmpty(listFrame) && CGRectIntersectsRect(listFrame, splitBoundsInHost)) {
            bottom = height - CGRectGetMaxY(listFrame);

            // Align the two NAVIGATION BARS, not the two view origins.
            //
            // The list column's bar is not always flush with the top of its
            // column, and how far in it sits depends on the mode: with the
            // sidebar showing, column and bar both start at y=32; with the
            // sidebar collapsed to the floating tab bar, the column starts at
            // y=86 and its bar at y=140, 54pt inside. Matching view origins got
            // the sidebar case right and then put our bar 54pt ABOVE the list's
            // in the tab bar case. So take the list bar's real position as the
            // target and back out our own bar's offset within its view.
            UINavigationBar *listBar = [list isKindOfClass:[UINavigationController class]]
                ? ((UINavigationController *)list).navigationBar : nil;
            CGFloat targetBarY = CGRectGetMinY(listFrame);
            if (listBar && !listBar.isHidden && listBar.superview) {
                targetBarY = CGRectGetMinY([listBar.superview convertRect:listBar.frame toView:self.view]);
            }
            top = targetBarY - nav.navigationBar.frame.origin.y;
        }
    }

    BOOL changed = !_hasResolvedGeometry ||
        fabs(_lastResolvedTop - top) > 0.5 ||
        fabs(_lastResolvedBottom - bottom) > 0.5;
    if (!changed) return;

    _hasResolvedGeometry = YES;
    _lastResolvedTop = top;
    _lastResolvedBottom = bottom;
    BOOL wroteConstraint = NO;
    if (fabs(_topConstraint.constant - top) > 0.5) {
        _topConstraint.constant = top;
        wroteConstraint = YES;
    }
    if (fabs(_bottomConstraint.constant - bottom) > 0.5) {
        _bottomConstraint.constant = bottom;
        wroteConstraint = YES;
    }
#if APOLLO_SIM_BUILD
    if (wroteConstraint) _simGeometryWriteCount++;
#else
    (void)wroteConstraint;
#endif
}

#if APOLLO_SIM_BUILD
- (NSString *)apollo_simLayoutPassStateReset:(BOOL)reset {
    NSString *state = [NSString stringWithFormat:
        @"hostPasses=%lu hostRefreshes=%lu hostWrites=%lu top=%.1f bottom=%.1f",
        (unsigned long)_simLayoutPassCount,
        (unsigned long)_simGeometryRefreshCount,
        (unsigned long)_simGeometryWriteCount,
        _topConstraint.constant, _bottomConstraint.constant];
    if (reset) {
        _simLayoutPassCount = 0;
        _simGeometryRefreshCount = 0;
        _simGeometryWriteCount = 0;
    }
    return state;
}
#endif

// The hosted navigation controller owns the chrome; forwarding these keeps the
// host transparent to UIKit rather than having it answer for an empty view.
- (UIViewController *)childViewControllerForStatusBarStyle { return self.hostedNavigationController; }
- (UIViewController *)childViewControllerForStatusBarHidden { return self.hostedNavigationController; }
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden { return self.hostedNavigationController; }

@end

