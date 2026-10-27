// Native sidebar/detail containers for the opened Duo. The tab still owns its
// original ApolloNavigationController: URL routing, tab gestures and account
// switching can keep addressing that object. Only its visible contents change
// at an unfold/fold boundary. UIKit owns all column frames and transitions.
#import "ApolloDuoSplitView.h"
#import "ApolloDuoNavigationGestures.h"
#import "ApolloMediaHinge.h"
#import "ApolloSearchRecents.h"
#import "ApolloSearchVisitRecording.h"
#import "ApolloClasses.h"
#import "ApolloDuoAccount.h"
#import "ApolloDuoSubsChrome.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloDuoSplitPosition.h"
#import "ApolloDuoSplitDivider.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRailLayout.h"
#import "ApolloDuoUIKitCompatibility.h"
#import "ApolloSearchNativeBar.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "ApolloFollowingSection.h"
#import "ApolloGalleryViewController.h"
#import "ApolloSwiftRuntime.h"
#import "settings/CustomAPIViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UITableView *ApolloDuoSplitFindTable(UIView *view);
static void ApolloDuoPostsStopGeometry(UIView *feed);
@class ApolloDuoSplitHost;
static void ApolloDuoPostsCancelActiveInteractiveClose(void);
static void ApolloDuoPostsCancelInteractiveCloseForHost(ApolloDuoSplitHost *host);
static void ApolloDuoToggleFeedLayout(ApolloDuoSplitHost *host);
static void ApolloDuoToggleVisibleFeedLayout(UIViewController *controller, BOOL enabled);

@protocol ApolloDuoLayoutControl <NSObject>
- (void)updateFeedLayoutButton;
@end

static NSHashTable<id<ApolloDuoLayoutControl>> *sDuoLayoutControls;
static BOOL sDuoFeedLayoutChanging;
@class ApolloDuoSplitHost;
// The one host whose list follows a finger, so the interruptions that cancel
// a thread close (a fold, a tab switch, a sheet, resigning) can let it go too.
static __weak ApolloDuoSplitHost *sDuoListDragHost;

static void ApolloDuoRegisterLayoutControl(id<ApolloDuoLayoutControl> control) {
    if (!sDuoLayoutControls) sDuoLayoutControls = [NSHashTable weakObjectsHashTable];
    [sDuoLayoutControls addObject:control];
}

static UIImage *ApolloDuoFeedLayoutImage(void) {
    static UIImage *originalImage, *focusedImage;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        originalImage = [UIImage systemImageNamed:@"rectangle"];
        focusedImage = [UIImage systemImageNamed:@"rectangle.center.inset.filled"];
    });
    return sDuoLandscapeFeedLayout == 2 ? focusedImage : originalImage;
}

static void ApolloDuoRefreshLayoutButton(UIButton *button, UIBarButtonItem *item) {
    BOOL focused = sDuoLandscapeFeedLayout == 2;
    UIImage *image = ApolloDuoFeedLayoutImage();
    if (button.configuration.image != image) {
        UIButtonConfiguration *configuration = [button.configuration copy];
        configuration.image = image;
        button.configuration = configuration;
    }
    if (item.image != image) item.image = image;
    button.accessibilityValue = focused ? @"Focused feed" : @"Original";
    button.accessibilityHint = focused ? @"Switch to Original feed" : @"Switch to Focused feed";
    if (button.enabled == sDuoFeedLayoutChanging) button.enabled = !sDuoFeedLayoutChanging;
    item.accessibilityValue = button.accessibilityValue ?: (focused ? @"Focused feed" : @"Original");
    item.accessibilityHint = button.accessibilityHint ?: (focused ? @"Switch to Original feed" : @"Switch to Focused feed");
    if (item.enabled == sDuoFeedLayoutChanging) item.enabled = !sDuoFeedLayoutChanging;
}

static void ApolloDuoRefreshLayoutControls(void) {
    for (id<ApolloDuoLayoutControl> control in sDuoLayoutControls.allObjects)
        [control updateFeedLayoutButton];
}

// Each account column owns its vertical origin independently. Overview and
// the menu sit below the shared profile header; destinations use the entire
// secondary column without resizing or re-laying out that header.
@interface ApolloDuoAccountColumn : UIViewController
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) NSLayoutConstraint *topConstraint;
@property(nonatomic) CGFloat contentTop;
@property(nonatomic, copy) dispatch_block_t geometryDidChange;
@property(nonatomic) CGRect reportedFrame;
@property(nonatomic) UIEdgeInsets reportedMargins;
@property(nonatomic) BOOL hasReportedFrame;
@end
@implementation ApolloDuoAccountColumn
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self addChildViewController:self.navigation];
    UIView *content = self.navigation.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    self.topConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:self.contentTop];
    [NSLayoutConstraint activateConstraints:@[
        self.topConstraint,
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.navigation didMoveToParentViewController:self];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self reportGeometryChange];
}
- (void)viewLayoutMarginsDidChange {
    [super viewLayoutMarginsDidChange];
    [self reportGeometryChange];
}
- (void)reportGeometryChange {
    // UISplitViewController can settle its column after the host's layout pass
    // when unfolding. Fold margins can settle later still, without changing
    // its frame. Notify for either change so the host's native button follows.
    CGRect frame = [self.view convertRect:self.view.bounds toView:self.splitViewController.view];
    UIEdgeInsets margins = self.view.layoutMargins;
    if (self.hasReportedFrame && CGRectEqualToRect(frame, self.reportedFrame)
        && UIEdgeInsetsEqualToEdgeInsets(margins, self.reportedMargins)) return;
    self.reportedFrame = frame;
    self.reportedMargins = margins;
    self.hasReportedFrame = YES;
    if (self.geometryDidChange) dispatch_async(dispatch_get_main_queue(), self.geometryDidChange);
}
- (void)setContentTop:(CGFloat)contentTop {
    _contentTop = contentTop;
    if (fabs(self.topConstraint.constant - contentTop) > 0.5) self.topConstraint.constant = contentTop;
}
@end

// The Overview caption is Texture content, not a UITableView section header.
// Find its already loaded title node without making offscreen nodes load views.
static UIView *ApolloDuoOverviewTitleView(id node) {
    if (!node) return nil;
    Ivar title = class_getInstanceVariable([node class], "titleTextNode");
    if (title) {
        UIView *view = ApolloDuoOverviewTitleView(object_getIvar(node, title));
        if (view) return view;
    }
    SEL textSelector = NSSelectorFromString(@"attributedText");
    if ([node respondsToSelector:textSelector]) {
        NSAttributedString *text = ((id (*)(id, SEL))objc_msgSend)(node, textSelector);
        SEL loadedSelector = NSSelectorFromString(@"isNodeLoaded");
        if ([text.string caseInsensitiveCompare:@"Overview"] == NSOrderedSame && text.length
            && [node respondsToSelector:loadedSelector]
            && ((BOOL (*)(id, SEL))objc_msgSend)(node, loadedSelector)) {
            return ((id (*)(id, SEL))objc_msgSend)(node, @selector(view));
        }
    }
    SEL children = NSSelectorFromString(@"subnodes");
    if ([node respondsToSelector:children]) {
        for (id child in ((id (*)(id, SEL))objc_msgSend)(node, children)) {
            UIView *view = ApolloDuoOverviewTitleView(child);
            if (view) return view;
        }
    }
    return nil;
}

// UINavigationController forbids a UISplitViewController as a stack entry.
// A plain containment host keeps Apollo's tab navigation identity intact while
// the split controller remains a proper child and owns its own column layout.
// UIKit can coalesce a newly revealed glass view's initial and final
// transforms in one transaction. Supply explicit endpoints so reveal and
// dismiss still travel across the screen on that first visible frame.
@interface ApolloDuoSlideCompletion : NSObject <CAAnimationDelegate>
@property(nonatomic, copy) dispatch_block_t completion;
@property(nonatomic) CFTimeInterval started;
@end
@implementation ApolloDuoSlideCompletion
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
    ApolloLog(@"[DuoSplit] slide stopped finished=%d elapsed=%.3f", finished, CACurrentMediaTime() - self.started);
    if (finished && self.completion) self.completion();
}
@end

static void ApolloDuoSlideView(UIView *view, CGFloat from, CGFloat to, NSTimeInterval duration, dispatch_block_t completion) {
    [view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    view.transform = CGAffineTransformMakeTranslation(to, 0);
    if (duration <= 0) {
        if (completion) completion();
        return;
    }
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform"];
    slide.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(from, 0, 0)];
    slide.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(to, 0, 0)];
    slide.duration = duration;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    // Tie cleanup to this animation, not UIKit's surrounding transaction.
    // A disabled-action navigation transaction can finish before the explicit
    // slide and otherwise hide the drawer at the beginning of dismissal.
    ApolloDuoSlideCompletion *delegate = [ApolloDuoSlideCompletion new];
    delegate.completion = completion;
    delegate.started = CACurrentMediaTime();
    slide.delegate = delegate;
    ApolloLog(@"[DuoSplit] slide from=%.1f to=%.1f duration=%.2f", from, to, duration);
    [view.layer addAnimation:slide forKey:@"ApolloDuoSlide"];
}

// The subreddit drawer settles on a critically damped spring, so it starts
// moving at once and can carry a release velocity instead of restarting from
// rest on an ease-in curve.
static void ApolloDuoSlideDrawer(UIView *view, CGFloat from, CGFloat to, CGFloat velocity,
                                 BOOL animated, dispatch_block_t completion) {
    [view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    view.transform = CGAffineTransformMakeTranslation(to, 0);
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || fabs(to - from) < 0.5) {
        if (completion) completion();
        return;
    }
    double omega = ApolloDuoDrawerSpringOmega();
    CASpringAnimation *slide = [CASpringAnimation animationWithKeyPath:@"transform"];
    slide.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(from, 0, 0)];
    slide.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(to, 0, 0)];
    slide.mass = 1;
    slide.stiffness = omega * omega;
    slide.damping = 2 * omega;
    slide.initialVelocity = ApolloDuoDrawerSpringInitialVelocity(from, to, velocity);
    slide.duration = slide.settlingDuration;
    ApolloDuoSlideCompletion *delegate = [ApolloDuoSlideCompletion new];
    delegate.completion = completion;
    delegate.started = CACurrentMediaTime();
    slide.delegate = delegate;
    ApolloLog(@"[DuoSplit] drawer from=%.1f to=%.1f velocity=%.0f duration=%.2f",
              from, to, velocity, slide.duration);
    [view.layer addAnimation:slide forKey:@"ApolloDuoSlide"];
}

// The subreddit drawer's width in a host that wide.
static CGFloat ApolloDuoListDrawerWidth(CGFloat hostWidth) {
    return MIN(360, hostWidth - 96);
}

// The interactive drawer's pure pieces: where the finger puts the subreddit
// list and when a release shows it. Free of UIKit; tested as shipped
// (tests/run_duo_interactive_drawer_tests.sh). The rest of the slide runs on
// ApolloDuoSlideDrawer's spring with the finger's velocity.
// The drawer parks its width plus a 12pt gap off the leading edge.
static CGFloat ApolloDuoListDragTravel(CGFloat drawerWidth) {
    return MAX(drawerWidth, 0.0) + 12.0;
}
static CGFloat ApolloDuoListDragOffset(CGFloat translation, CGFloat travel) {
    return MIN(MAX(translation, 0.0), MAX(travel, 0.0));
}
static CGFloat ApolloDuoListDragProgress(CGFloat translation, CGFloat travel) {
    return travel > 0.0 ? ApolloDuoListDragOffset(translation, travel) / travel : 0.0;
}
static CGFloat ApolloDuoListDragTranslationX(CGFloat translation, CGFloat travel) {
    return -travel + ApolloDuoListDragOffset(translation, travel);
}
// A drag starts from any drawer that is not shown, including one still
// parking after a hide (it is taken over where it is); a second drag never
// replaces the first.
static BOOL ApolloDuoListDragBegins(BOOL listVisible, BOOL tracking) {
    return !listVisible && !tracking;
}
// How much of the drawer is shown when a drag takes it over: none when it is
// hidden, else what its slide (the presentation transform) has brought in.
// The finger's drag is added to this, so progress follows what it moves.
static CGFloat ApolloDuoListDragBase(CGFloat presentationTx, CGFloat travel, BOOL containerHidden) {
    return containerHidden ? 0.0 : MIN(MAX(travel + presentationTx, 0.0), MAX(travel, 0.0));
}
// A reveal ends shown only by committing; a hide ends hidden only by
// committing and springs back shown otherwise. With no drag in hand, a
// release is neither a Back nor a hide.
static BOOL ApolloDuoListDragEndsVisible(BOOL tracking, BOOL hiding, BOOL commit) {
    return tracking && (hiding ? !commit : commit);
}
// The interactive hide: a leftward drag, measured against the same travel the
// reveal uses (the finger moves that much), committing by the reveal's rule
// mirrored (ApolloDuoBackShouldCommit): a third of the travel, or a leftward
// flick past 5% of it, and never when released rightward faster than 500.
// A list still springing in when the finger takes it shows less than the
// travel: progress is the share of what was shown that has been closed.
static CGFloat ApolloDuoListHideProgress(CGFloat translation, CGFloat travel, CGFloat base) {
    CGFloat shown = MIN(MAX(base, 0.0), MAX(travel, 0.0));
    if (shown <= 0.0) return 1.0;
    return MIN(MAX(-translation, 0.0), shown) / shown;
}
static BOOL ApolloDuoListHideCommits(CGFloat progress, CGFloat leftwardVelocity) {
    return leftwardVelocity > -500.0 && (progress >= 0.35 || (leftwardVelocity >= 500.0 && progress >= 0.05));
}
// Only a shown, idle list, and a drag that heads left and not mostly up or down.
static BOOL ApolloDuoListHideBegins(BOOL listVisible, BOOL tracking, CGFloat dx, CGFloat dy) {
    return listVisible && !tracking && dx < 0.0 && fabs(dy) <= fabs(dx);
}
// The 28pt at the list's trailing edge, where a drag closes it before a row's does.
static BOOL ApolloDuoListHideStripContains(CGFloat x, CGFloat width) {
    return x >= width - 28.0;
}
// What the Reduce Motion fade's completion does. The container's alpha is
// restored whatever happened to the fade (a later slide, a cancel, a fold may
// have superseded it); only the final place and hiding belong to the newest.
typedef struct {
    BOOL restoreAlpha;
    BOOL settle;
} ApolloDuoListFadeEnd;
static ApolloDuoListFadeEnd ApolloDuoListFadeEndFor(BOOL superseded) {
    return (ApolloDuoListFadeEnd){.restoreAlpha = YES, .settle = !superseded};
}
// End of the interactive drawer's pure pieces.

@interface ApolloDuoSplitHost : UIViewController <UISplitViewControllerDelegate, UIGestureRecognizerDelegate, ApolloDuoLayoutControl>
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) UINavigationController *subredditList;
@property(nonatomic, weak) UINavigationController *postsNavigation;
@property(nonatomic, strong) UIView *listContainer;
@property(nonatomic, strong) UIVisualEffectView *listGlass;
@property(nonatomic) BOOL listUsesGlass;
@property(nonatomic) BOOL listStyleApplied;
- (void)updateListAppearance;
- (void)restoreListSurfaceColors;
@property(nonatomic, strong) UINavigationBar *listNavigationBar;
@property(nonatomic, strong) UIControl *listDismiss;
@property(nonatomic, strong) UIButton *listButton;
@property(nonatomic) BOOL listVisible;
@property(nonatomic) BOOL postsShowingDetail;
@property(nonatomic) BOOL postsSplitEnabled;
@property(nonatomic) BOOL postsColumnsPaired;
@property(nonatomic, strong) UIView *postsTransitionSnapshot;
@property(nonatomic, weak) UINavigationController *searchNavigation;
@property(nonatomic) NSUInteger listAnimationGeneration;
// The subreddit list follows the finger (ApolloDuoSplitInteractiveDrawer*):
// shown only to the transform, with listVisible still NO until it commits.
@property(nonatomic) BOOL listDragging;
// The drag closes the shown list (the scrim's or the trailing strip's pan) instead of pulling it in.
@property(nonatomic) BOOL listDragHiding;
@property(nonatomic, strong) UIPanGestureRecognizer *listHideScrimPan;
@property(nonatomic, strong) UIPanGestureRecognizer *listHideEdgePan;
- (BOOL)beginListHide;
@property(nonatomic) CGFloat listDragTravel;
// How much of the drawer was shown when the drag took it over.
@property(nonatomic) CGFloat listDragBase;
- (BOOL)beginListDrag;
- (BOOL)updateListDrag:(CGFloat)translation;
- (CGFloat)listDragProgress:(CGFloat)translation;
- (void)finishListDrag:(BOOL)commit velocity:(CGFloat)velocity;
- (void)listHidePanned:(UIPanGestureRecognizer *)pan;
- (void)cancelListDragNow;
@property(nonatomic, strong) UIButton *splitButton;
@property(nonatomic, strong) UIButton *feedLayoutButton;
@property(nonatomic, strong) UIBarButtonItem *listBarItem;
@property(nonatomic, strong) UIBarButtonItem *splitBarItem;
@property(nonatomic, strong) UIBarButtonItem *feedLayoutBarItem;
@property(nonatomic, weak) UIViewController *feedControlsOwner;
@property(nonatomic) BOOL pendingFeedControlsReveal;
- (void)revealRestoredFeedControls;
@property(nonatomic, copy) void (^togglePostsSplit)(void);
@property(nonatomic, strong) NSMapTable *listBackgrounds;
@property(nonatomic) BOOL updatingListSurfaces;
@property(nonatomic) UIEdgeInsets originalListInsets;
@property(nonatomic) BOOL splitSafeAreaSyncScheduled;
@property(nonatomic) NSInteger splitSafeAreaAttempts;
- (void)scheduleSplitSafeAreaSync;
- (void)syncSplitSafeArea;
- (void)repairSplitSafeAreaNow;
- (void)restoreListBackgrounds;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated velocity:(CGFloat)velocity;
@property(nonatomic, strong) UIView *accountHeader;
@property(nonatomic, strong) UIView *accountHeaderClip;
@property(nonatomic, strong) ApolloDuoAccountColumn *accountPrimary;
@property(nonatomic, strong) ApolloDuoAccountColumn *accountSecondary;
@property(nonatomic, strong) NSNumber *pendingAccountDetail;
@property(nonatomic, strong) NSNumber *accountDisplayMode;
@property(nonatomic) CGFloat overviewTopAdjustment;
@property(nonatomic) BOOL overviewAlignmentPending;
@property(nonatomic, copy) NSArray *overviewAlignmentGeometry;
- (void)scheduleOverviewAlignment;
@property(nonatomic, strong) NSLayoutConstraint *contentTopConstraint;
@property(nonatomic, strong) UIButton *accountsButton;
@property(nonatomic, strong) UIButton *moreButton;
@property(nonatomic, strong) UINavigationBar *sidebarNavigationBar;
@property(nonatomic, strong) UIButton *profileBackButton;
@end
@implementation ApolloDuoSplitHost
- (void)viewDidLoad {
    [super viewDidLoad];
    self.split.delegate = self;
    [self addChildViewController:self.split];
    UIView *content = self.split.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    self.contentTopConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.contentTopConstraint,
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.split didMoveToParentViewController:self];
    if (self.subredditList) {
        // The Posts host: the divider between the feed and a thread moves
        // with a press and drag when the adjustable split is on.
        ApolloDuoSplitDividerInstall(self.view);
        self.listDismiss = [UIControl new];
        self.listDismiss.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.12];
        [self.listDismiss addTarget:self action:@selector(dismissList) forControlEvents:UIControlEventTouchUpInside];
        self.listDismiss.hidden = YES;
        [self.view addSubview:self.listDismiss];
        self.listGlass = [[UIVisualEffectView alloc] initWithEffect:nil];
        self.listGlass.clipsToBounds = YES;
        // Move a plain container so the material and list travel together.
        // UIVisualEffectView manages its own compositor geometry.
        self.listContainer = [UIView new];
        self.listContainer.hidden = YES;
        [self.view addSubview:self.listContainer];
        // A leftward drag on the dimmed feed beside the open list, or in a
        // strip at the list's trailing edge, closes it with the finger. A tap
        // on the scrim still hides at once; a drag cancels that tap.
        self.listHideScrimPan = [self newListHidePan];
        [self.listDismiss addGestureRecognizer:self.listHideScrimPan];
        self.listHideEdgePan = [self newListHidePan];
        [self.listContainer addGestureRecognizer:self.listHideEdgePan];
        self.listGlass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.listContainer addSubview:self.listGlass];
        // The drawer's leading corners sit 12pt inside the display's rounded
        // corners. Follow them concentrically, as system sheets do, instead of
        // a fixed radius the display clips. The container resolves against the
        // window; the material, sharing its bounds, takes the same radius.
        if (@available(iOS 26.0, *)) {
            UICornerConfiguration *corners = [UICornerConfiguration configurationWithUniformRadius:
                [UICornerRadius containerConcentricRadiusWithMinimum:28]];
            self.listContainer.cornerConfiguration = corners;
            self.listGlass.cornerConfiguration = corners;
        } else {
            self.listGlass.layer.cornerRadius = 28;
            self.listGlass.layer.cornerCurve = kCACornerCurveContinuous;
        }
        // A managed bar joins Duo's global vertical navigation rail even
        // inside this narrow drawer. A standalone native bar keeps Apollo's
        // actual items horizontal and derives its height from UIKit.
        self.listNavigationBar = [UINavigationBar new];
        self.listNavigationBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.listNavigationBar.tintColor = ApolloNavigationChromeColor();
        UINavigationBarAppearance *listAppearance = [UINavigationBarAppearance new];
        [listAppearance configureWithTransparentBackground];
        self.listNavigationBar.standardAppearance = listAppearance;
        self.listNavigationBar.scrollEdgeAppearance = listAppearance;
        self.listNavigationBar.compactAppearance = listAppearance;
        [self.listNavigationBar setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        [self.listGlass.contentView addSubview:self.listNavigationBar];
        [self.subredditList setNavigationBarHidden:YES animated:NO];
        [self addChildViewController:self.subredditList];
        UIView *list = self.subredditList.view;
        list.translatesAutoresizingMaskIntoConstraints = NO;
        [self.listGlass.contentView addSubview:list];
        [NSLayoutConstraint activateConstraints:@[
            [self.listNavigationBar.topAnchor constraintEqualToAnchor:self.listGlass.contentView.topAnchor constant:12],
            // UIKit adds 8pt before the native Add platter but places Edit
            // flush with the bar's trailing edge. Both visible platters need
            // the same 20pt inset from the rounded drawer, including Done.
            [self.listNavigationBar.leadingAnchor constraintEqualToAnchor:self.listGlass.contentView.leadingAnchor constant:12],
            [self.listNavigationBar.trailingAnchor constraintEqualToAnchor:self.listGlass.contentView.trailingAnchor constant:-20],
            [list.topAnchor constraintEqualToAnchor:self.listNavigationBar.bottomAnchor constant:8],
            [list.bottomAnchor constraintEqualToAnchor:self.listGlass.contentView.bottomAnchor],
            [list.leadingAnchor constraintEqualToAnchor:self.listGlass.contentView.leadingAnchor],
            [list.trailingAnchor constraintEqualToAnchor:self.listGlass.contentView.trailingAnchor]
        ]];
        [self.subredditList didMoveToParentViewController:self];
        ApolloDuoSubsChromeSetPopupNavigationBar(self.subredditList.viewControllers.firstObject,
                                                self.listNavigationBar);
        const CGFloat controlSize = 48;
        self.listButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration;
        if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
        else configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:@"list.bullet"];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        self.listButton.configuration = configuration;
        self.listButton.accessibilityLabel = @"Subreddit List";
        [self.listButton addTarget:self action:@selector(toggleList) forControlEvents:UIControlEventTouchUpInside];
        self.listButton.frame = CGRectMake(0, 0, controlSize, controlSize);
        self.listBarItem = [[UIBarButtonItem alloc] initWithCustomView:self.listButton];
        self.listBarItem.title = @"Subreddit List";
        self.listBarItem.image = configuration.image;
        self.listBarItem.target = self;
        self.listBarItem.action = @selector(toggleList);
        self.splitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *splitConfiguration = [configuration copy];
        splitConfiguration.image = [UIImage systemImageNamed:@"rectangle.split.2x1"];
        self.splitButton.configuration = splitConfiguration;
        self.splitButton.accessibilityLabel = @"Toggle Feed and Comments Split";
        [self.splitButton addTarget:self action:@selector(toggleSplit) forControlEvents:UIControlEventTouchUpInside];
        self.splitButton.frame = CGRectMake(0, 0, controlSize, controlSize);
        self.splitBarItem = [[UIBarButtonItem alloc] initWithCustomView:self.splitButton];
        self.splitBarItem.title = @"Toggle Feed and Comments Split";
        self.splitBarItem.target = self;
        self.splitBarItem.action = @selector(toggleSplit);
        [self updateSplitButton];
        self.feedLayoutButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *layoutConfiguration = [configuration copy];
        self.feedLayoutButton.configuration = layoutConfiguration;
        self.feedLayoutButton.accessibilityLabel = @"Feed Layout";
        [self.feedLayoutButton addTarget:self action:@selector(toggleFeedLayout) forControlEvents:UIControlEventTouchUpInside];
        [self updateFeedLayoutButton];
        self.feedLayoutButton.frame = CGRectMake(0, 0, controlSize, controlSize);
        self.feedLayoutBarItem = [[UIBarButtonItem alloc] initWithCustomView:self.feedLayoutButton];
        self.feedLayoutBarItem.title = @"Feed Layout";
        self.feedLayoutBarItem.image = self.feedLayoutButton.configuration.image;
        self.feedLayoutBarItem.target = self;
        self.feedLayoutBarItem.action = @selector(toggleFeedLayout);
        if (@available(iOS 26.0, *)) {
            // Match each persistent control across native navigation changes.
            // The shared accessibility ID below identifies the whole family,
            // whereas UIKit needs a distinct transition identity for each role.
            self.listBarItem.identifier = @"ApolloReborn.duo-list";
            self.splitBarItem.identifier = @"ApolloReborn.duo-split";
            self.feedLayoutBarItem.identifier = @"ApolloReborn.duo-feed-layout";
        }
        for (UIBarButtonItem *item in @[self.listBarItem, self.splitBarItem, self.feedLayoutBarItem]) {
            // UIKit applies compact sizing directly to UIButton custom views
            // and gives these bar items a 48pt minimum width. Match that with
            // a square host so the glass background remains circular.
            UIView *button = item.customView;
            button.alpha = self.pendingFeedControlsReveal ? 0 : 1;
            UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, controlSize, controlSize)];
            button.translatesAutoresizingMaskIntoConstraints = NO;
            item.customView = container;
            [container addSubview:button];
            [NSLayoutConstraint activateConstraints:@[
                [container.widthAnchor constraintEqualToConstant:controlSize],
                [container.heightAnchor constraintEqualToConstant:controlSize],
                [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
                [button.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
                [button.topAnchor constraintEqualToAnchor:container.topAnchor],
                [button.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
            ]];
            if (@available(iOS 26.0, *)) item.hidesSharedBackground = YES;
            if (@available(iOS 27.1, *)) item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        }
        self.originalListInsets = self.subredditList.topViewController.additionalSafeAreaInsets;
        [self.subredditList setNavigationBarHidden:YES animated:NO];
        [self updateListAppearance];
    }
    if (self.accountHeader) {
        self.accountHeaderClip = [UIView new];
        self.accountHeaderClip.clipsToBounds = YES;
        [self.accountHeaderClip addSubview:self.accountHeader];
        [self.view addSubview:self.accountHeaderClip];
        if (self.accountsButton) [self.view addSubview:self.accountsButton];
        [self.view addSubview:self.moreButton];
        [self.view addSubview:self.sidebarNavigationBar];
        if (self.profileBackButton) [self.view addSubview:self.profileBackButton];
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    ApolloDuoPostsCancelInteractiveCloseForHost(self);
    self.pendingFeedControlsReveal = NO;
    if (self.subredditList) {
        for (UIButton *button in @[self.listButton, self.splitButton, self.feedLayoutButton]) {
            button.alpha = 1;
            [button.layer removeAnimationForKey:@"ApolloDuoControlsReveal"];
        }
    }
    if (self.subredditList) [self setListVisible:NO animated:NO];
    [self.postsTransitionSnapshot removeFromSuperview];
    self.postsTransitionSnapshot = nil;
    ApolloDuoPostsStopGeometry(self.searchNavigation.viewIfLoaded);
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    ApolloDuoPostsCancelInteractiveCloseForHost(self);
    ApolloDuoPostsStopGeometry(self.searchNavigation.viewIfLoaded);
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}
- (void)updateListAppearance {
    if (!self.subredditList || !self.listGlass) return;
    BOOL changed = !self.listStyleApplied || self.listUsesGlass != sDuoSubredditPanelGlassEnabled;
    BOOL refreshRows = self.listStyleApplied && changed;
    self.listUsesGlass = sDuoSubredditPanelGlassEnabled;
    if (changed) {
        // Keep the same controller, panel geometry, and native Add/Edit items.
        // Standard restores Apollo's own surfaces instead of clearing them for
        // the material; it does not change the app-wide Liquid Glass setting.
        [self restoreListSurfaceColors];
        UIVisualEffect *effect = nil;
        if (self.listUsesGlass) {
            if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        }
        self.listGlass.effect = effect;
        self.listStyleApplied = YES;
    }
    NSString *panelTitle = self.listUsesGlass ? @"" : @"Subreddits";
    if (![self.listNavigationBar.topItem.title isEqualToString:panelTitle])
        self.listNavigationBar.topItem.title = panelTitle;
    self.listGlass.backgroundColor = self.listUsesGlass ? UIColor.clearColor
        : (ApolloThemeSubredditListBackgroundColor() ?: UIColor.systemBackgroundColor);
    // Re-vend only on an explicit style change, never on scroll/layout.
    if (refreshRows) [ApolloDuoSplitFindTable(self.subredditList.view) reloadData];
    // A drawer being pulled in is prepared as a shown one: material cleared first.
    if (self.listUsesGlass && (self.listVisible || self.listDragging))
        ApolloDuoSplitPrepareOverlaySurface(self.subredditList.view);
}
- (void)restoreListSurfaceColors {
    self.updatingListSurfaces = YES;
    for (UIView *view in self.listBackgrounds) {
        id color = [self.listBackgrounds objectForKey:view];
        view.backgroundColor = color == NSNull.null ? nil : color;
    }
    self.updatingListSurfaces = NO;
    self.listBackgrounds = nil;
}
- (void)endListEditing {
    UIViewController *root = self.subredditList.viewControllers.firstObject;
    if (root.isEditing) [root setEditing:NO animated:NO];
}
- (void)restoreListBackgrounds {
    [self endListEditing];
    ApolloDuoSubsChromeSetPopupNavigationBar(self.subredditList.viewControllers.firstObject, nil);
    [self restoreListSurfaceColors];
    self.subredditList.viewControllers.firstObject.additionalSafeAreaInsets = self.originalListInsets;
    [self.subredditList setNavigationBarHidden:NO animated:NO];
}
- (void)updateSplitButton {
    UIImage *symbol = [UIImage systemImageNamed:@"rectangle.split.2x1"];
    if (!self.postsSplitEnabled) {
        // One template image lets the glass button resolve the slash and the
        // symbol together, including appearance and accessibility changes.
        // A separate CGColor layer captures the pre-window system-blue tint.
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:symbol.size];
        symbol = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[symbol imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal]
                drawAtPoint:CGPointZero];
            [UIColor.blackColor setStroke];
            UIBezierPath *slash = [UIBezierPath bezierPath];
            [slash moveToPoint:CGPointMake(1, symbol.size.height - 1)];
            [slash addLineToPoint:CGPointMake(symbol.size.width - 1, 1)];
            slash.lineWidth = 1.5;
            slash.lineCapStyle = kCGLineCapRound;
            [slash stroke];
        }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIButtonConfiguration *configuration = [self.splitButton.configuration copy];
    configuration.image = symbol;
    // The slashed state is a rendered template rather than an SF Symbol.
    // Give both states the navigation foreground so glass does not dim the
    // available toggle merely because its image representation changed.
    configuration.baseForegroundColor = ApolloNavigationChromeColor();
    self.splitButton.configuration = configuration;
    self.splitBarItem.image = symbol;
    self.splitButton.accessibilityValue = self.postsSplitEnabled ? @"On" : @"Off";
}
- (void)toggleSplit {
    if (self.togglePostsSplit) self.togglePostsSplit();
}
- (void)updateFeedLayoutButton {
    ApolloDuoRegisterLayoutControl(self);
    ApolloDuoRefreshLayoutButton(self.feedLayoutButton, self.feedLayoutBarItem);
    [self applyFeedLayoutAvailability];
}
// Focused only applies to full-width content; paired columns are both narrow.
// Dim the control in place instead of removing it, so the bar does not reflow
// (and the control does not vanish and return) as threads open and close.
- (void)applyFeedLayoutAvailability {
    BOOL enabled = !sDuoFeedLayoutChanging && !self.postsColumnsPaired;
    if (self.feedLayoutButton.enabled != enabled) self.feedLayoutButton.enabled = enabled;
    if (self.feedLayoutBarItem.enabled != enabled) self.feedLayoutBarItem.enabled = enabled;
}
- (void)toggleFeedLayout { ApolloDuoToggleFeedLayout(self); }
- (void)revealRestoredFeedControls {
    if (!self.pendingFeedControlsReveal) return;
    // Buttons start transparent before native item registration. Reveal after
    // the full split update (including idle tabs) has finished, so setup work
    // cannot consume the animation before the new navigation bar is visible.
    [self.view layoutIfNeeded];
    [self.feedControlsOwner.navigationController.navigationBar layoutIfNeeded];
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIButton *button in @[self.listButton, self.splitButton, self.feedLayoutButton]) {
        if (!button.hidden && button.window) [buttons addObject:button];
        else if (button.hidden) button.alpha = 1;
    }
    if (!buttons.count) return;
    self.pendingFeedControlsReveal = NO;
    BOOL visible = self.navigationController.topViewController == self
        && self.navigationController.tabBarController.selectedViewController == self.navigationController;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    NSTimeInterval duration = reduceMotion ? 0.18 : 0.28;
    for (UIView *button in buttons) {
        button.alpha = 1;
        if (!visible) continue;
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.toValue = @1;
        fade.duration = duration;
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        scale.fromValue = @0.92;
        scale.toValue = @1;
        scale.duration = duration;
        CAAnimationGroup *reveal = [CAAnimationGroup animation];
        reveal.animations = reduceMotion ? @[fade] : @[fade, scale];
        reveal.duration = duration;
        reveal.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        // Explicit endpoints survive the nonanimated containment transaction.
        // Model alpha/transform stay final, so interruption or folding cannot
        // leave a retained control faded out or scaled down.
        [button.layer addAnimation:reveal forKey:@"ApolloDuoControlsReveal"];
    }
    ApolloLog(@"[DuoSplit] revealing %lu restored feed controls", (unsigned long)buttons.count);
}
- (UIPanGestureRecognizer *)newListHidePan {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(listHidePanned:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    pan.name = @"ApolloReborn.Duo.ListHide";
    return pan;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture != self.listHideScrimPan && gesture != self.listHideEdgePan) return YES;
    if (!self.listVisible || self.listDragging) return NO;
    if (gesture == self.listHideScrimPan) return YES;
    return ApolloDuoListHideStripContains([touch locationInView:self.listContainer].x, CGRectGetWidth(self.listContainer.bounds));
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.listHideScrimPan && gesture != self.listHideEdgePan) return YES;
    // The motion since touch-down, or the velocity: a slow drag still begins.
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gesture;
    CGPoint motion = [pan translationInView:nil], velocity = [pan velocityInView:nil];
    return ApolloDuoListHideBegins(self.listVisible, self.listDragging, motion.x, motion.y)
        || ApolloDuoListHideBegins(self.listVisible, self.listDragging, velocity.x, velocity.y);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Vertical scrolling never waits for the hide; once it begins it stops that scrolling.
    return (gesture == self.listHideScrimPan || gesture == self.listHideEdgePan)
        && [other.view isKindOfClass:UIScrollView.class] && other == ((UIScrollView *)other.view).panGestureRecognizer;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // Inside the trailing strip the close takes priority over a row's own
    // leftward drag (unsubscribe): that waits for this to fail.
    BOOL scrollPan = [other.view isKindOfClass:UIScrollView.class] && other == ((UIScrollView *)other.view).panGestureRecognizer;
    return gesture == self.listHideEdgePan && [other isKindOfClass:UIPanGestureRecognizer.class] && !scrollPan
        && ![other.name hasPrefix:@"ApolloReborn.Duo."];
}
- (void)listHidePanned:(UIPanGestureRecognizer *)pan {
    // Measured in the window: a tracked drag moves views under the finger.
    CGFloat translation = [pan translationInView:nil].x;
    BOOL ours = self.listDragging && self.listDragHiding;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            if (![self beginListHide]) {
                pan.enabled = NO;
                pan.enabled = YES;
                return;
            }
            // Once it begins it is the hide: stop the list's scrolling.
            UIPanGestureRecognizer *scrollPan = ApolloDuoSplitFindTable(self.subredditList.view).panGestureRecognizer;
            scrollPan.enabled = NO;
            scrollPan.enabled = YES;
            return;
        }
        case UIGestureRecognizerStateChanged:
            // A fold, a sheet, a resize or a takeover let the drag go: this pan is over.
            if (!ours || ![self updateListDrag:translation]) {
                pan.enabled = NO;
                pan.enabled = YES;
            }
            return;
        case UIGestureRecognizerStateEnded: {
            if (!ours) return;
            CGFloat velocity = [pan velocityInView:nil].x;
            BOOL commit = ApolloDuoListHideCommits(ApolloDuoListHideProgress(translation, self.listDragTravel, self.listDragBase), -velocity);
            ApolloLog(@"[DuoSwipe] subreddit list: %@ after the finger closed it; velocity=%.0f",
                      commit ? @"hidden" : @"sprang back", velocity);
            [self finishListDrag:commit velocity:velocity];
            return;
        }
        default:
            // Cancelled by the system: back to shown on the spring.
            if (ours) [self finishListDrag:NO velocity:0];
            return;
    }
}
- (void)toggleList { [self setListVisible:!self.listVisible animated:YES]; }
- (void)dismissList {
    ApolloLog(@"[DuoSwipe] scrim tap: hide the list");
    [self setListVisible:NO animated:YES];
}
// Material must be cleared after UIKit installs its initial light-mode table
// background, before exposing the drawer.
- (void)prepareListReveal {
    [self.subredditList.view layoutIfNeeded];
    UITableView *table = ApolloDuoSplitFindTable(self.subredditList.view);
    // Reset before the first reveal frame, after the drawer's safe-area
    // layout, so reopening always starts with the feed shortcuts.
    [table setContentOffset:CGPointMake(-table.adjustedContentInset.left,
                                       -table.adjustedContentInset.top) animated:NO];
    [table layoutIfNeeded];
    [self updateListAppearance];
}
// Settles the drawer from `start` to its shown or parked place on the
// drawer's spring, carrying `velocity` (a released finger's, or 0), and fades
// the dismiss layer with it. The drawer is hidden for good only if it ends parked.
- (void)settleListVisible:(BOOL)visible from:(CGFloat)start velocity:(CGFloat)velocity animated:(BOOL)animated {
    self.listDismiss.hidden = NO;
    // The spring's tail is visually settled; let taps reach the feed then.
    self.listDismiss.userInteractionEnabled = visible;
    self.listContainer.hidden = NO;
    self.listContainer.userInteractionEnabled = YES;
    // A Reduce Motion fade may have been fading the container out.
    [self.listContainer.layer removeAnimationForKey:@"opacity"];
    self.listContainer.alpha = 1;
    NSUInteger generation = ++self.listAnimationGeneration;
    NSTimeInterval duration = animated && !UIAccessibilityIsReduceMotionEnabled() ? 0.25 : 0;
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.listDismiss.alpha = visible ? 1 : 0; } completion:nil];
    __weak typeof(self) weakSelf = self;
    ApolloDuoSlideDrawer(self.listContainer, start, visible ? 0 : -self.listGlass.bounds.size.width - 12,
                         velocity, animated, ^{
        if (weakSelf.listAnimationGeneration != generation) return;
        weakSelf.listContainer.hidden = !weakSelf.listVisible;
        weakSelf.listDismiss.hidden = !weakSelf.listVisible;
    });
}
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated {
    [self setListVisible:visible animated:animated velocity:0];
}
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated velocity:(CGFloat)velocity {
    if (!self.subredditList) return;
    if (!visible) [self endListEditing];
    // A drag in hand ends here: the slide below starts from where it is.
    BOOL dragging = self.listDragging;
    self.listDragging = NO;
    self.listDragHiding = NO;
    if (dragging) sDuoListDragHost = nil;
    if (self.listVisible == visible && !dragging) return;
    [self.view layoutIfNeeded];
    BOOL wasHidden = self.listContainer.hidden;
    CGFloat start = wasHidden ? -self.listGlass.bounds.size.width - 12
        : (self.listContainer.layer.presentationLayer ?: self.listContainer.layer).transform.m41;
    self.listVisible = visible;
    [self.view setNeedsLayout];
    if (visible && !dragging) [self prepareListReveal];
    [self settleListVisible:visible from:start velocity:velocity animated:animated];
}
// Pulls the hidden drawer in with the finger: transforms and alpha only from
// here on. The drawer is prepared once, as a reveal would, before it moves.
- (BOOL)beginListDrag {
    if (!self.subredditList || !self.view.window
        || !ApolloDuoListDragBegins(self.listVisible, self.listDragging)) return NO;
    [self.view layoutIfNeeded];
    CGFloat width = self.listGlass.bounds.size.width;
    if (width <= 0.0) return NO;
    // A hide still parking the drawer is taken over from its presentation.
    BOOL hidden = self.listContainer.hidden;
    CGFloat travel = ApolloDuoListDragTravel(width);
    CGFloat presentationTx = (self.listContainer.layer.presentationLayer ?: self.listContainer.layer).transform.m41;
    // Set first: the appearance prep treats a dragged drawer as a shown one.
    self.listDragging = YES;
    if (hidden) [self prepareListReveal];
    self.listDragTravel = travel;
    self.listDragBase = ApolloDuoListDragBase(presentationTx, travel, hidden);
    sDuoListDragHost = self;
    // A hide that finished earlier must not hide this drag when its turn comes.
    ++self.listAnimationGeneration;
    [self.listContainer.layer removeAnimationForKey:@"ApolloDuoSlide"];
    [self.listContainer.layer removeAnimationForKey:@"opacity"];
    self.listContainer.alpha = 1;
    self.listContainer.transform = CGAffineTransformMakeTranslation(ApolloDuoListDragTranslationX(self.listDragBase, travel), 0);
    // The scrim's fade from the last settle must not run against the finger.
    [self.listDismiss.layer removeAnimationForKey:@"opacity"];
    self.listDismiss.alpha = ApolloDuoListDragProgress(self.listDragBase, travel);
    // The finger that pulls the list in is on the feed; a second one is not
    // for a drawer that is not open yet.
    self.listDismiss.userInteractionEnabled = NO;
    self.listContainer.userInteractionEnabled = NO;
    self.listDismiss.hidden = NO;
    self.listContainer.hidden = NO;
    ApolloLog(@"[DuoSplit] interactive drawer began; shown=%.0f of %.0f", self.listDragBase, travel);
    return YES;
}
// Closes the shown list with the finger: transforms and alpha only, from
// where its slide has got to. listVisible stays YES (so no Back or forward
// swipe starts under it) until a commit.
- (BOOL)beginListHide {
    CGFloat width = self.listGlass.bounds.size.width;
    if (!self.subredditList || !self.view.window || width <= 0.0 || self.listContainer.hidden
        || !self.listVisible || self.listDragging) return NO;
    CGFloat travel = ApolloDuoListDragTravel(width);
    CGFloat presentationTx = (self.listContainer.layer.presentationLayer ?: self.listContainer.layer).transform.m41;
    self.listDragging = YES;
    self.listDragHiding = YES;
    self.listDragTravel = travel;
    self.listDragBase = ApolloDuoListDragBase(presentationTx, travel, NO);
    sDuoListDragHost = self;
    ++self.listAnimationGeneration;
    [self.listContainer.layer removeAnimationForKey:@"ApolloDuoSlide"];
    [self.listContainer.layer removeAnimationForKey:@"opacity"];
    self.listContainer.alpha = 1;
    self.listContainer.transform = CGAffineTransformMakeTranslation(ApolloDuoListDragTranslationX(self.listDragBase, travel), 0);
    // The scrim's fade from the last settle must not run against the finger.
    [self.listDismiss.layer removeAnimationForKey:@"opacity"];
    self.listDismiss.alpha = ApolloDuoListDragProgress(self.listDragBase, travel);
    ApolloLog(@"[DuoSwipe] subreddit list: the finger began closing it; shown=%.0f of %.0f", self.listDragBase, travel);
    return YES;
}
- (CGFloat)listDragProgress:(CGFloat)translation {
    // The same measure with or without a drag in hand, so one swipe commits
    // at the same distance whether the list followed the finger or not.
    // Before the drawer's first layout its glass is 0 wide: measure against
    // the width layout gives it, not against the 12pt gap alone.
    CGFloat width = self.listGlass.bounds.size.width;
    if (width <= 0.0) width = ApolloDuoListDrawerWidth(self.view.bounds.size.width);
    CGFloat travel = self.listDragging ? self.listDragTravel : ApolloDuoListDragTravel(width);
    return ApolloDuoListDragProgress((self.listDragging ? self.listDragBase : 0.0) + translation, travel);
}
- (BOOL)updateListDrag:(CGFloat)translation {
    if (!self.listDragging) return NO;
    if (!self.view.window) {
        [self cancelListDragNow];
        return NO;
    }
    CGFloat shown = self.listDragBase + translation;
    self.listContainer.transform = CGAffineTransformMakeTranslation(ApolloDuoListDragTranslationX(shown, self.listDragTravel), 0);
    self.listDismiss.alpha = ApolloDuoListDragProgress(shown, self.listDragTravel);
    return YES;
}
// Commits the rest of the slide, or slides the drawer back out, on the
// drawer's spring from where the finger left it and at the finger's speed.
// Reduce Motion tracked the finger, then fades instead of sliding.
- (void)finishListDrag:(BOOL)commit velocity:(CGFloat)velocity {
    if (!self.listDragging) return;
    BOOL visible = ApolloDuoListDragEndsVisible(self.listDragging, self.listDragHiding, commit);
    CGFloat start = self.listContainer.transform.tx;
    if (!visible) [self endListEditing];
    self.listDragging = NO;
    self.listDragHiding = NO;
    sDuoListDragHost = nil;
    self.listVisible = visible;
    [self.view setNeedsLayout];
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        [self settleListVisible:visible from:start velocity:velocity animated:YES];
        return;
    }
    // No slide: a shown list snaps to its place; a hidden one fades out
    // where the finger left it. A fading scrim lets taps reach the feed, as
    // the spring's tail does.
    self.listDismiss.userInteractionEnabled = visible;
    self.listContainer.userInteractionEnabled = YES;
    NSUInteger generation = ++self.listAnimationGeneration;
    if (visible) self.listContainer.transform = CGAffineTransformIdentity;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.15 animations:^{
        weakSelf.listDismiss.alpha = visible ? 1 : 0;
        if (!visible) weakSelf.listContainer.alpha = 0;
    } completion:^(__unused BOOL finished) {
        ApolloDuoSplitHost *host = weakSelf;
        if (!host) return;
        ApolloDuoListFadeEnd end = ApolloDuoListFadeEndFor(host.listAnimationGeneration != generation);
        if (end.restoreAlpha) host.listContainer.alpha = 1;
        if (!end.settle) return;
        host.listContainer.transform = CGAffineTransformMakeTranslation(visible ? 0 : -host.listGlass.bounds.size.width - 12, 0);
        host.listContainer.hidden = !host.listVisible;
        host.listDismiss.hidden = !host.listVisible;
    }];
}
// An interruption: the drawer is parked, hidden and consistent at once.
- (void)cancelListDragNow {
    if (!self.listDragging) return;
    BOOL hiding = self.listDragHiding;
    self.listDragging = NO;
    self.listDragHiding = NO;
    sDuoListDragHost = nil;
    ++self.listAnimationGeneration;
    [self.listContainer.layer removeAnimationForKey:@"ApolloDuoSlide"];
    [self.listContainer.layer removeAnimationForKey:@"opacity"];
    self.listContainer.alpha = 1;
    if (hiding) {
        // A hide the finger was closing goes back to fully shown, scrim and all.
        self.listContainer.transform = CGAffineTransformIdentity;
        self.listContainer.hidden = NO;
        [self.listDismiss.layer removeAnimationForKey:@"opacity"];
        self.listDismiss.alpha = 1;
        self.listDismiss.hidden = NO;
        self.listDismiss.userInteractionEnabled = YES;
        self.listContainer.userInteractionEnabled = YES;
        ApolloLog(@"[DuoSplit] interactive list hide removed; the list stays shown");
        return;
    }
    self.listContainer.transform = CGAffineTransformMakeTranslation(-self.listGlass.bounds.size.width - 12, 0);
    self.listContainer.hidden = YES;
    [self.listDismiss.layer removeAnimationForKey:@"opacity"];
    self.listDismiss.alpha = 0;
    self.listDismiss.hidden = YES;
    self.listDismiss.userInteractionEnabled = YES;
    self.listContainer.userInteractionEnabled = YES;
    ApolloLog(@"[DuoSplit] interactive drawer removed");
}
- (void)splitViewController:(UISplitViewController *)splitViewController willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    if (!self.accountHeader) return;
    // The host is outside UIKit's column hierarchy, so a column-only change
    // need not lay it out. Use the announced mode (displayMode still reports
    // the old value here) to move the header mask and sidebar control with it.
    self.accountDisplayMode = @(displayMode);
    void (^layout)(void) = ^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    };
    id<UIViewControllerTransitionCoordinator> coordinator = splitViewController.transitionCoordinator;
    if (![coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        layout();
    } completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        self.accountDisplayMode = @(splitViewController.displayMode);
        layout();
    }]) layout();
}
- (void)scheduleOverviewAlignment {
    if (!self.accountHeader || self.overviewAlignmentPending) return;
    self.overviewAlignmentPending = YES;
    __weak ApolloDuoSplitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoSplitHost *host = weakSelf;
        host.overviewAlignmentPending = NO;
        if (!host.viewIfLoaded.window || host.pendingAccountDetail.boolValue
            || host.accountSecondary.navigation.viewControllers.count != 1) return;
        UITableView *shortcuts = ApolloDuoSplitFindTable(host.accountPrimary.navigation.topViewController.viewIfLoaded);
        UITableView *overview = ApolloDuoSplitFindTable(host.accountSecondary.navigation.topViewController.viewIfLoaded);
        if (!shortcuts.window || !overview.window || !ApolloDuoAccountIsOverviewTable(overview)
            || shortcuts.numberOfSections == 0 || [shortcuts numberOfRowsInSection:0] == 0) return;
        SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
        if (![overview respondsToSelector:nodeSelector] || overview.numberOfSections == 0) return;
        NSArray *geometry = @[[NSValue valueWithCGSize:shortcuts.bounds.size],
                              [NSValue valueWithCGSize:overview.bounds.size],
                              [NSValue valueWithCGSize:shortcuts.contentSize],
                              [NSValue valueWithCGSize:overview.contentSize],
                              [NSValue valueWithUIEdgeInsets:shortcuts.adjustedContentInset],
                              [NSValue valueWithUIEdgeInsets:overview.adjustedContentInset],
                              @(sShowDetailedProfiles), @(sProfileHeaderImmersive)];
        if ([host.overviewAlignmentGeometry isEqual:geometry]) return;
        UIView *heading = nil;
        NSInteger count = MIN([overview numberOfRowsInSection:0], 50);
        for (NSInteger row = 0; row < count; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
            if (ApolloDuoAccountHidesProfileRow(overview, path)) continue;
            id node = ((id (*)(id, SEL, id))objc_msgSend)(overview, nodeSelector, path);
            heading = ApolloDuoOverviewTitleView(node);
            // Only the first exposed row is the dashboard heading. Never
            // align a caption/title belonging to a later activity item.
            break;
        }
        if (!heading.window || ![heading isDescendantOfView:overview]) return;
        CGRect shortcut = [shortcuts rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIView *leftNavigation = host.accountPrimary.navigation.view;
        UIView *rightNavigation = host.accountSecondary.navigation.view;
        CGFloat leftOrigin = CGRectGetMinY([host.view convertRect:leftNavigation.bounds fromView:leftNavigation]);
        CGFloat rightOrigin = CGRectGetMinY([host.view convertRect:rightNavigation.bounds fromView:rightNavigation]);
        CGFloat left = CGRectGetMinY([host.view convertRect:shortcut fromView:shortcuts])
            + shortcuts.contentOffset.y + shortcuts.adjustedContentInset.top - leftOrigin;
        CGFloat right = CGRectGetMinY([host.view convertRect:heading.bounds fromView:heading])
            + overview.contentOffset.y + overview.adjustedContentInset.top - rightOrigin;
        // Remove each table's scrolling and current column origin before
        // comparing. The correction therefore cannot follow or undo a scroll.
        CGFloat adjustment = left - right;
        if (!isfinite(adjustment) || fabs(adjustment) > 150) return;
        host.overviewAlignmentGeometry = geometry;
        if (fabs(adjustment - host.overviewTopAdjustment) < 0.5) return;
        host.overviewTopAdjustment = adjustment;
        [host.view setNeedsLayout];
        ApolloLog(@"[DuoSplit] Overview top alignment left=%.1f right=%.1f adjustment=%.1f", left, right, adjustment);
    });
}
// The split fills this host, so its safe area must equal the host's. After a
// Closed portrait -> Open landscape -> portrait sequence UIKit can leave the
// split (and every page inside it) holding the landscape rail's {0,0,34,84}
// insets while the host and its bottom tab bar already report the portrait
// ones. Pages then reserve an 84pt trailing strip: posts are pushed left and
// the navigation pill lands under the status region. Bounded: at most a few
// attempts per stale episode, never a feedback loop.
- (void)scheduleSplitSafeAreaSync {
    if (self.splitSafeAreaSyncScheduled) return;
    self.splitSafeAreaSyncScheduled = YES;
    __weak ApolloDuoSplitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoSplitHost *host = weakSelf;
        if (!host) return;
        host.splitSafeAreaSyncScheduled = NO;
        [host syncSplitSafeArea];
    });
}
static BOOL ApolloDuoSafeAreaInsetsMatch(UIEdgeInsets a, UIEdgeInsets b) {
    return fabs(a.top - b.top) < 0.5 && fabs(a.left - b.left) < 0.5
        && fabs(a.bottom - b.bottom) < 0.5 && fabs(a.right - b.right) < 0.5;
}
- (void)syncSplitSafeArea {
    [self syncSplitSafeAreaWaiting:YES];
}
// A rotation or fold has just finished laying out: the host is settled, so a
// remaining mismatch is real and is repaired at once (no visible wrong frame).
- (void)repairSplitSafeAreaNow {
    [self syncSplitSafeAreaWaiting:NO];
}
- (void)syncSplitSafeAreaWaiting:(BOOL)waiting {
    UIView *hostView = self.viewIfLoaded;
    UIView *splitView = self.split.viewIfLoaded;
    if (!hostView.window || !splitView.window || (waiting && ApolloDuoSplitIsResizing())) return;
    // Only a split that fills the host inherits the host's safe area verbatim.
    if (fabs(splitView.frame.origin.x) > 1.0 || fabs(splitView.frame.origin.y) > 1.0
        || fabs(CGRectGetWidth(splitView.frame) - CGRectGetWidth(hostView.bounds)) > 1.0
        || fabs(CGRectGetHeight(splitView.frame) - CGRectGetHeight(hostView.bounds)) > 1.0) return;
    UIEdgeInsets want = hostView.safeAreaInsets;
    UIEdgeInsets have = splitView.safeAreaInsets;
    if (ApolloDuoSafeAreaInsetsMatch(want, have)) {
        self.splitSafeAreaAttempts = 0;
        return;
    }
    if (self.splitSafeAreaAttempts >= 3) return;
    self.splitSafeAreaAttempts++;
    // Host and split legitimately disagree for a moment during a rotation or
    // fold. Only intervene when the mismatch survives a full re-check.
    if (waiting && self.splitSafeAreaAttempts == 1) {
        __weak ApolloDuoSplitHost *weakFirst = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakFirst scheduleSplitSafeAreaSync]; });
        return;
    }
    ApolloLog(@"[DuoSplit] split safe area stale (attempt %ld): host=%@ split=%@",
              (long)self.splitSafeAreaAttempts, NSStringFromUIEdgeInsets(want), NSStringFromUIEdgeInsets(have));
    // Nothing writable recomputes the stale value: neither the split's nor the
    // host's additionalSafeAreaInsets moves it. Re-attaching the split's view
    // makes UIKit derive its safe area from the host afresh. Same frame, same
    // controller: scroll positions and navigation state are untouched.
    UIView *content = splitView;
    [UIView performWithoutAnimation:^{
        [content removeFromSuperview];
        [self.view insertSubview:content atIndex:0];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        self.contentTopConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                                      constant:self.contentTopConstraint.constant];
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            self.contentTopConstraint,
            [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
        [self.view layoutIfNeeded];
    }];
    ApolloLog(@"[DuoSplit] split safe area after remount: host=%@ split=%@",
              NSStringFromUIEdgeInsets(hostView.safeAreaInsets), NSStringFromUIEdgeInsets(splitView.safeAreaInsets));
    // Re-verify once UIKit has settled the transition.
    __weak ApolloDuoSplitHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf scheduleSplitSafeAreaSync]; });
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self scheduleSplitSafeAreaSync];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self scheduleSplitSafeAreaSync];
    if (self.subredditList) {
        CGFloat width = ApolloDuoListDrawerWidth(self.view.bounds.size.width);
        BOOL portrait = self.view.bounds.size.width <= self.view.bounds.size.height;
        CGFloat bottom = CGRectGetMaxY(self.view.bounds) - 12;
        if (portrait) {
            // The floating bottom tab bar overlays this full-height host.
            // Reserve its native layout frame, not the animated glass platter,
            // so the drawer stays clear without resizing as the bar minimizes.
            bottom -= self.view.safeAreaInsets.bottom;
            UITabBar *tabBar = self.tabBarController.tabBar;
            if (tabBar.window && tabBar.window == self.view.window) {
                CGRect barFrame = [tabBar convertRect:tabBar.bounds toView:self.view];
                if (!CGRectIsEmpty(barFrame) && CGRectGetWidth(barFrame) > CGRectGetHeight(barFrame)
                    && CGRectGetMidY(barFrame) > CGRectGetMidY(self.view.bounds)) {
                    bottom = MIN(bottom, CGRectGetMinY(barFrame) - 12);
                }
            }
        }
        CGFloat height = MAX(0, bottom - 12);
        self.listDismiss.frame = self.view.bounds;
        // Bounds/center stay independent of the presentation transform.
        self.listContainer.bounds = CGRectMake(0, 0, width, height);
        self.listContainer.center = CGPointMake(12 + width / 2, 12 + height / 2);
        self.listGlass.frame = self.listContainer.bounds;
        // The drawer covers/intercepts its underlying controls. Keep the
        // navigation items installed so opening it never reflows the bar.
        self.listButton.hidden = NO;
        self.splitButton.hidden = portrait;
        // UIKit lays out the real controls in the title row, above the search
        // field. They follow their content column and the bar's safe area.
        UINavigationController *navigation = self.postsNavigation;
        if (self.postsShowingDetail && !self.postsColumnsPaired) {
            UIViewController *secondary = [self.split viewControllerForColumn:UISplitViewControllerColumnSecondary];
            if ([secondary isKindOfClass:UINavigationController.class]) navigation = (id)secondary;
        }
        UIViewController *owner = navigation.topViewController;
        BOOL supportsLayout = [owner isKindOfClass:NSClassFromString(@"Apollo.PostsViewController")]
            || [owner isKindOfClass:NSClassFromString(@"Apollo.CommentsViewController")];
        // Carry the same control into full-width comments, just like List and
        // Split. Replacing it with the thread's standalone item makes its
        // glass and glyph disappear/reappear during the native push and Back.
        self.feedLayoutButton.hidden = portrait || !supportsLayout;
        [self applyFeedLayoutAvailability];
        if (self.feedControlsOwner != owner) {
            ApolloNativeFeedSearchSetDuoControls(self.feedControlsOwner, nil, nil, nil);
            self.feedControlsOwner = owner;
        }
        ApolloNativeFeedSearchSetDuoControls(owner,
            self.listButton.hidden ? nil : self.listBarItem,
            self.splitButton.hidden ? nil : self.splitBarItem,
            self.feedLayoutButton.hidden ? nil : self.feedLayoutBarItem);
    }
    if (!self.accountHeader) return;
    UISplitViewControllerDisplayMode displayMode = self.accountDisplayMode
        ? (UISplitViewControllerDisplayMode)self.accountDisplayMode.integerValue : self.split.displayMode;
    CGFloat headerHeight = ApolloDuoAccountHeaderHeight(self.accountHeader, self.view.bounds.size.width);
    UINavigationController *detail = self.accountSecondary.navigation;
    BOOL hasDetail = self.pendingAccountDetail ? self.pendingAccountDetail.boolValue : detail.viewControllers.count > 1;
    self.accountPrimary.contentTop = headerHeight;
    self.accountSecondary.contentTop = hasDetail ? 0
        : MAX(0, headerHeight + self.overviewTopAdjustment);
    if (!hasDetail) [self scheduleOverviewAlignment];
    UIView *primaryView = self.accountPrimary.viewIfLoaded;
    CGRect primaryFrame = [primaryView convertRect:primaryView.bounds toView:self.view];
    CGFloat sidebarRight = primaryView.superview && CGRectGetWidth(primaryFrame) > 0
        ? CGRectGetMaxX(primaryFrame) : self.split.primaryColumnWidth;
    CGFloat headerWidth = hasDetail ? sidebarRight : self.view.bounds.size.width;
    if (hasDetail && displayMode == UISplitViewControllerDisplayModeSecondaryOnly) headerWidth = 0;
    self.accountHeaderClip.frame = CGRectMake(0, 0, headerWidth, headerHeight);
    self.accountHeader.frame = CGRectMake(0, 0, self.view.bounds.size.width, headerHeight);
    // Follow the native primary column's trailing margin: it grows around an
    // active fold and returns to 20pt when flat. The native bar-item renderer
    // also supplies the same symbol size and vibrancy as Settings and Inbox.
    CGFloat sidebarTrailingMargin = MAX(20, primaryView.layoutMargins.right);
    CGFloat sidebarRightEdge = displayMode == UISplitViewControllerDisplayModeSecondaryOnly
        ? (self.profileBackButton ? 132 : 72) : MAX(72, sidebarRight - sidebarTrailingMargin);
    self.sidebarNavigationBar.frame = CGRectMake(sidebarRightEdge - 88,
        MAX(24, self.view.safeAreaInsets.top), 88, 58);
    self.profileBackButton.frame = CGRectMake(24, MAX(24, self.view.safeAreaInsets.top), 48, 48);
    // A full-width gallery owns the leading bar area; its Back returns here.
    BOOL galleryCovers = displayMode == UISplitViewControllerDisplayModeSecondaryOnly
        && [detail.topViewController isKindOfClass:ApolloGalleryViewController.class];
    if (self.sidebarNavigationBar.hidden != galleryCovers) self.sidebarNavigationBar.hidden = galleryCovers;
    if (self.profileBackButton.hidden != galleryCovers) self.profileBackButton.hidden = galleryCovers;
    self.moreButton.hidden = hasDetail;
    self.accountsButton.hidden = hasDetail;
    // Match the native rail's 48pt platter and 24pt physical edge inset.
    // The safe-area inset includes the rail and is not its visible center.
    CGFloat railX = self.view.bounds.size.width - 72;
    CGFloat statusBottom = CGRectGetMaxY(self.view.window.windowScene.statusBarManager.statusBarFrame);
    CGFloat railTop = MAX(124, statusBottom + 16);
    self.moreButton.frame = CGRectMake(railX, railTop, 48, 48);
    self.accountsButton.frame = CGRectMake(railX, railTop + 60, 48, 48);
}
@end

@class ApolloDuoPostsCloseHandoff;
@class ApolloDuoPostsClosedThread;
@interface ApolloDuoSplitState : NSObject
@property(nonatomic, weak) UINavigationController *outer;
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic, strong) UINavigationController *primary;
@property(nonatomic, strong) UINavigationController *secondary;
@property(nonatomic, strong) UINavigationController *feed;
@property(nonatomic, copy) NSArray *feedActions;
// The feed page whose actions feedActions were taken from: the stack can hold
// several feeds (split links push them), and only the visible one is hidden.
@property(nonatomic, weak) UINavigationItem *feedActionsItem;
// A pushed feed whose Back is hidden while paired: the rail's Back already
// closes the thread first, so a second Back in the feed pane is redundant.
@property(nonatomic, weak) UINavigationItem *feedBackHiddenItem;
@property(nonatomic, strong) NSArray<UIViewController *> *lastSettings;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *sidebarTitle;
// Pages preceding a visited profile stay in their original tab's Back stack.
@property(nonatomic, copy) NSArray<UIViewController *> *profilePrefix;
@property(nonatomic, strong) UIViewController *tabRoot;
@property(nonatomic, copy) NSString *tabKind;
@property(nonatomic) BOOL selectingAccountShortcut;
@property(nonatomic) BOOL changing;
@property(nonatomic) BOOL postsTogglingSplit;
// A Posts thread close following the finger, set from the drag's start until
// it hands over to the close, springs back or is interrupted. The column
// sync and the split update leave the state alone while it is set.
@property(nonatomic, strong) ApolloDuoPostsCloseHandoff *interactiveClose;
// The thread the last close took from beside the feed, which a forward swipe
// brings back (ApolloDuoSplitRestoreClosedThread) until something forgets it.
@property(nonatomic, strong) ApolloDuoPostsClosedThread *closedThread;
// UIKit's own tap on the column separator, kept off while the adjustable
// split owns the divider (ApolloDuoPostsSyncSeparatorTap).
@property(nonatomic, weak) UIGestureRecognizer *separatorTap;
@property(nonatomic) BOOL separatorTapDisabled;
@property(nonatomic) BOOL navigationBarWasHidden;
@property(nonatomic) BOOL needsDefault;
@property(nonatomic) BOOL halfWidthSidebar;
@property(nonatomic, weak) id<UIViewControllerTransitionCoordinator> pendingNavigationTransition;
@property(nonatomic, weak) UIViewController *searchBackPage;
@property(nonatomic, strong) UIBarButtonItem *searchBackItem;
@property(nonatomic) BOOL searchBackSupplementedNative;
@property(nonatomic) BOOL sidebarHiddenForGallery;
@end
@implementation ApolloDuoSplitState @end
static void ApolloDuoPostsCancelInteractiveClose(ApolloDuoSplitState *state, BOOL animated, CGFloat velocity);

@interface ApolloDuoSplitReference : NSObject
@property(nonatomic, weak) ApolloDuoSplitState *state;
@end
@implementation ApolloDuoSplitReference @end

static char kDuoSplitState, kDuoSplitReference;
static char kDuoSplitHingeInteraction, kDuoSplitHingeStatus;
static BOOL sDuoSplitUpdateScheduled;
static BOOL sDuoSplitUpdating;
static NSHashTable<ApolloDuoSplitState *> *sDuoSplitDeferredPresentations;
static __weak UITabBarController *sDuoSplitKnownTabs;
static __weak UITabBarController *sDuoSplitResizingTabs;
static CGSize sDuoSplitTargetSize;
static __weak id<UIViewControllerTransitionCoordinator> sDuoSplitSizeCoordinator;

// Repair every Duo split host in this tab controller after its size change.
static void ApolloDuoSplitRepairSafeAreas(UITabBarController *tabs) {
    for (UIViewController *tab in tabs.viewControllers) {
        for (UIViewController *child in tab.childViewControllers) {
            if ([child isKindOfClass:ApolloDuoSplitHost.class]) [(ApolloDuoSplitHost *)child repairSplitSafeAreaNow];
        }
    }
}
BOOL ApolloDuoSplitIsResizing(void) {
    return sDuoSplitResizingTabs != nil;
}

// Nested: a column sync runs inside a thread open's or close's column update.
static NSUInteger sDuoSplitMovingColumns;
BOOL ApolloDuoSplitIsMovingColumns(void) {
    return sDuoSplitMovingColumns > 0;
}

BOOL ApolloDuoSplitIsUnfolded(void) {
    if (!ApolloDeviceIsDuo()) return NO;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone
        || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return NO;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone) return NO;
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    return MIN(size.width, size.height) >= 600.0;
}

BOOL ApolloDuoSplitIsUnfoldedPortrait(void) {
    if (!ApolloDuoSplitIsUnfolded()) return NO;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    return size.height > size.width;
}

// The adjustable split applies to the unfolded Posts split only; anywhere
// else, or with the setting off, the feed keeps half the canvas.
static BOOL ApolloDuoPostsAdjustableSplit(void) {
    return sDuoAdjustableSplit && ApolloDuoSplitIsUnfolded();
}

// Where the fold's division begins on `canvas`, or 0 without one inside it.
// Mid-resize the region may still describe the old canvas: 0 until the next
// update.
static CGFloat ApolloDuoPostsFoldX(ApolloDuoSplitState *state, CGSize canvas) {
    if (sDuoSplitResizingTabs) return 0.0;
    CGRect fold = ApolloDuoActiveVerticalDivision(state.host.view);
    BOOL inside = !CGRectIsNull(fold) && CGRectGetMinX(fold) > 0.0 && CGRectGetMinX(fold) < canvas.width;
    return inside ? CGRectGetMinX(fold) : 0.0;
}

// The thread's least width beside the rail: UIKit's minimum secondary column
// width for the split, which it holds against the thread less the rail.
static const CGFloat kApolloDuoPostsMinimumThread = 240.0;

// The thread width, beside the rail, that the right limit leaves: what the
// post's five action buttons need (measured on the Duo: they keep their 53 pt
// pitch and the last is clipped by the rail below 260). More than the minimum
// above, which only keeps UIKit tiling.
static const CGFloat kApolloDuoPostsWideStopThread = 260.0;

// The trailing safe area UIKit holds the thread's minimum width against: the
// rail on the Duo, read live.
static CGFloat ApolloDuoPostsTrailingInset(ApolloDuoSplitState *state) {
    return MAX(state.secondary.viewIfLoaded.safeAreaInsets.right, state.feed.viewIfLoaded.safeAreaInsets.right);
}

// The remembered divider position: the stored share, else the retired stop
// (read-only; DuoSplitFeedShare is the only key written).
static ApolloDuoSplitStored ApolloDuoPostsStoredPosition(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id share = [defaults objectForKey:UDKeyDuoSplitFeedShare];
    BOOL has = [share isKindOfClass:NSNumber.class];
    return (ApolloDuoSplitStored){ has, has ? [share doubleValue] : 0.0,
                                   [defaults integerForKey:UDKeyDuoSplitStop] };
}

// The divider x the Posts landscape split should use now on `canvas`: the
// remembered position with the setting on, else half the canvas. Half with
// the setting on ends the feed at the fold; mid-resize the region may still
// describe the old canvas, so Half takes mid-canvas until the next update.
// The position is re-clamped to the limits on this canvas, which already
// leave the thread more than UIKit needs to tile it beside the rail; one that
// would still leave it too narrow (the inset changed since) gives way to Half
// rather than break the split.
static CGFloat ApolloDuoPostsWantedDivider(ApolloDuoSplitState *state, CGSize canvas) {
    BOOL adjustable = ApolloDuoPostsAdjustableSplit();
    CGFloat foldX = adjustable ? ApolloDuoPostsFoldX(state, canvas) : 0.0;
    return ApolloDuoPostsFittedPrimaryWidth(adjustable, ApolloDuoPostsStoredPosition(), canvas.width, foldX,
                                            ApolloDuoPostsTrailingInset(state), kApolloDuoPostsWideStopThread,
                                            kApolloDuoPostsMinimumThread);
}

// Apollo's native navigation delegate tests a 70pt edge band in its view.
// UIKit extends the secondary view under the sidebar and the trailing rail;
// translate only that delegate's location query into the visible pane's band.
static __thread void *sDuoSplitGesture;
static __thread void *sDuoSplitGestureView;
static __thread CGFloat sDuoSplitGestureOffset;

// Apollo's pan handler (sub_10015e204, behind screenEdgePanned: and
// navigationBarPanned:) completes a held release at half its view's width.
// A split pane's view extends under the sidebar or the feed column, so scale
// only that release's translation: half is then measured on the visible pane.
static __thread void *sDuoSplitReleaseGesture;
static __thread void *sDuoSplitReleaseView;
static __thread CGFloat sDuoSplitReleaseScale = 1.0;

static NSString *ApolloDuoSplitKind(UIViewController *root) {
    NSString *name = NSStringFromClass(root.class);
    if ([name isEqualToString:@"Apollo.RedditListViewController"]) return @"subreddits";
    if ([name isEqualToString:@"Apollo.SettingsViewController"]) return @"settings";
    if ([name isEqualToString:@"Apollo.InboxListViewController"]) return @"inbox";
    if ([name isEqualToString:@"Apollo.ProfileViewController"]) return @"account";
    if ([name isEqualToString:@"Apollo.SearchViewController"]) return @"search";
    return nil;
}

static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, BOOL create) {
    ApolloDuoSplitReference *reference = objc_getAssociatedObject(nav, &kDuoSplitReference);
    if (reference.state) return reference.state;
    ApolloDuoSplitState *state = objc_getAssociatedObject(nav, &kDuoSplitState);
    if (!state && create && [nav.parentViewController isKindOfClass:UITabBarController.class]) {
        NSString *kind = ApolloDuoSplitKind(nav.viewControllers.firstObject);
        ApolloLog(@"[DuoSplit] tab root=%@ supported=%d", NSStringFromClass(nav.viewControllers.firstObject.class), kind != nil);
        if (kind) {
            state = [ApolloDuoSplitState new];
            state.outer = nav;
            state.root = nav.viewControllers.firstObject;
            state.kind = kind;
            objc_setAssociatedObject(nav, &kDuoSplitState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return state;
}

// Node measurement can run while UIKit is moving the page between navigation
// controllers, before the new safe area exists. Use the destination column's
// width for that one transition, including offscreen rows measured by Texture.
CGFloat ApolloDuoSplitTransitionContentWidth(UIView *view, CGFloat trailingInset) {
    if (!sDuoSplitResizingTabs) return 0.0;
    UIViewController *owner = nil;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            owner = (id)responder;
            break;
        }
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(owner.navigationController, NO);
    CGFloat width = sDuoSplitTargetSize.width;
    if (state.feed && state.split && MIN(sDuoSplitTargetSize.width, sDuoSplitTargetSize.height) >= 600) {
        if (owner.navigationController == state.primary) return MIN(360, width - 96);
        BOOL paired = state.host.postsSplitEnabled && sDuoSplitTargetSize.width > sDuoSplitTargetSize.height && (state.secondary.viewControllers.count > 1 || state.feed.viewControllers.count > 1);
        if (paired) {
            CGFloat divider = ApolloDuoPostsWantedDivider(state, sDuoSplitTargetSize);
            width = owner.navigationController == state.feed ? divider : width - divider;
        }
        BOOL feedColumn = paired && owner.navigationController == state.feed;
        return MAX(0, width - (!feedColumn && sDuoSplitTargetSize.width > sDuoSplitTargetSize.height ? trailingInset : 0));
    }
    if (state.split && width >= 800.0 && width > sDuoSplitTargetSize.height) {
        UISplitViewController *split = state.split;
        CGFloat primary = MIN(split.maximumPrimaryColumnWidth,
                              MAX(split.minimumPrimaryColumnWidth,
                                  width * split.preferredPrimaryColumnWidthFraction));
        // Ordinary tab roots live in the sidebar. Account's native profile
        // supplies Overview in the secondary pane beneath its shared header.
        if (owner == state.root && ![state.kind isEqualToString:@"account"]) return primary;
        width -= primary;
    }
    // The unfolded portrait layout uses a bottom tab bar. A narrow cover or
    // side window, and the unfolded landscape layout, use the trailing rail.
    BOOL trailingRail = sDuoSplitTargetSize.width > sDuoSplitTargetSize.height
        || sDuoSplitTargetSize.width < 600.0;
    return MAX(0.0, width - (trailingRail ? trailingInset : 0.0));
}

static void ApolloDuoSplitLink(UINavigationController *nav, ApolloDuoSplitState *state) {
    ApolloDuoSplitReference *reference = [ApolloDuoSplitReference new];
    reference.state = state;
    objc_setAssociatedObject(nav, &kDuoSplitReference, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UINavigationController *ApolloDuoSplitDetailNavigation(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    // A Back addressed to a visible pane belongs to that pane. Only the outer
    // shell / drawer forwards Back to whichever content is currently showing.
    if (nav == state.feed || nav == state.secondary) return nav;
    return state.split && !state.changing ? (state.feed && !state.host.postsShowingDetail ? state.feed : state.secondary) : nav;
}

BOOL ApolloDuoSplitAllowsNavigationSwipe(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (state.changing) return NO;
    if (!state.split) return YES;
    return !state.host.listVisible && (nav == state.feed || nav == state.secondary);
}

// Whether a native pop in `nav` uncovers a real page of that same pane. With
// no split (folded, portrait) every pop does. In the split only a visible pane
// qualifies: the feed with no thread beside it (Apollo's own pans stay off
// the feed while a thread shows, see gestureRecognizerShouldBegin: below), or
// the detail pane. A thread right above the Posts backstop does not: closing
// it is a column change, and a native pop would show the backstop. Neither do
// an empty detail's plain placeholder or Account's Overview beneath the
// shared header, which only the split's own Back lays out.
BOOL ApolloDuoSplitPopRevealsContent(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    NSArray<UIViewController *> *pages = nav.viewControllers;
    if (pages.count < 2) return NO;
    if (!state.split) return YES;
    if (state.changing) return NO;
    if (nav == state.feed) return !state.host.postsShowingDetail;
    if (nav != state.secondary) return NO;
    if (state.feed) return pages.count > 2;
    UIViewController *below = pages[pages.count - 2];
    BOOL placeholder = below.class == UIViewController.class;
    BOOL overview = [state.kind isEqualToString:@"account"] && below == state.root;
    return !placeholder && !overview;
}

// An unfolded split lays `nav` out: a pane, its outer host, a sidebar or the
// drawer list. Folded or in portrait there is none.
BOOL ApolloDuoSplitIsActive(UINavigationController *nav) {
    return ApolloDuoSplitStateForNavigation(nav, NO).split != nil;
}

// Back in `nav` closes the Posts thread column: the thread pane right above
// its backstop, which this file's popViewControllerAnimated: hook closes.
BOOL ApolloDuoSplitBackClosesThread(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && state.feed && !state.changing && nav == state.secondary
        && nav.viewControllers.count == 2;
}

// A native pop has still left the Posts thread pane on its backstop. Apollo's
// tab-bar pan and goBack call its Swift pop directly, so they never reach this
// file's popViewControllerAnimated: hook and its column close.
static BOOL ApolloDuoPostsPopReachedBackstop(ApolloDuoSplitState *state, UINavigationController *nav,
                                             UIViewController *shown) {
    return state.split && state.feed && !state.changing && nav == state.secondary
        && state.host.postsShowingDetail && nav.viewControllers.count == 1
        && shown == nav.viewControllers.firstObject;
}

BOOL ApolloDuoSplitCanRevealPostsListWithSwipe(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && !state.changing && state.feed == nav
        && !state.host.listVisible && nav.viewControllers.count == 1;
}

UIViewController *ApolloDuoSplitRootController(UINavigationController *nav) {
    return ApolloDuoSplitStateForNavigation(nav, NO).root;
}

CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView) {
    UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    // Settings refreshes offscreen pages too. Their retained view hierarchy
    // still supplies the split geometry even while detached from the window.
    if (!state.split || (nav != state.secondary && nav != state.feed)) return CGRectNull;
    // Modern UIKit can extend the secondary surface beneath the sidebar. Its
    // safe-area guide, rather than its full bounds, is the visible column.
    UIView *view = nav.view;
    UIEdgeInsets insets = view.safeAreaInsets;
    // Center across the whole detail pane, including its trailing navigation
    // strip. Only the leading sidebar is excluded from this alignment band.
    insets.right = 0.0;
    CGRect content = UIEdgeInsetsInsetRect(view.bounds, insets);
    return [coordinateView convertRect:content fromView:view];
}

// Media covering the screen from a column's navigation view covers the whole
// split instead: the tab's own navigation view, which holds every column and
// is the view it would have covered on the cover display. Nil leaves it alone.
static UIView *ApolloDuoSplitMediaSurface(ApolloDuoSplitState *state, UINavigationController *nav) {
    if (!state.split || (nav != state.feed && nav != state.secondary && nav != state.primary)) return nil;
    return state.outer.viewIfLoaded;
}

// How much wider a pane's navigation view is than the visible pane, or 1
// when it is not, or either width is missing.
static CGFloat ApolloDuoSplitNativePanReleaseScale(CGFloat viewWidth, CGFloat paneWidth) {
    if (!(viewWidth > 0.0) || !(paneWidth > 0.0) || paneWidth >= viewWidth) return 1.0;
    return viewWidth / paneWidth;
}

// The scale for the translation Apollo reads on releasing one of its own
// navigation pans (edge Back, edge Forward, navigation bar) in a visible pane,
// else 1. Dragging stays unscaled, so the page keeps tracking the finger.
// The pane is the one the Duo pane Back measures: it excludes the sidebar or
// feed column and keeps the trailing rail.
static CGFloat ApolloDuoSplitNativePanReleaseScaleForNavigation(UINavigationController *nav, UIPanGestureRecognizer *gesture) {
    if (!gesture || (gesture.state != UIGestureRecognizerStateEnded && gesture.state != UIGestureRecognizerStateCancelled)) return 1.0;
    static const char *const names[] = {"leftScreenEdgePanGestureRecognizer", "rightScreenEdgePanGestureRecognizer",
                                        "navigationBarPanGestureRecognizer"};
    BOOL apolloPan = NO;
    for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        Ivar ivar = class_getInstanceVariable(nav.class, names[index]);
        if (ivar && object_getIvar(nav, ivar) == gesture) apolloPan = YES;
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!apolloPan || !state.split || state.changing || ApolloDuoSplitIsResizing()
        || (nav != state.secondary && nav != state.feed)) return 1.0;
    CGRect pane = ApolloDuoSplitContentFrame(nav, nav.view);
    return ApolloDuoSplitNativePanReleaseScale(CGRectGetWidth(nav.view.bounds), CGRectIsNull(pane) ? 0.0 : CGRectGetWidth(pane));
}

// Runs Apollo's pan handler with its release translation scaled for `nav`.
// Apollo then takes its own finish or cancel branch, with its own bookkeeping.
// The previous window is restored afterwards, so a nested release is safe.
static void ApolloDuoSplitNativePanReleaseRun(UINavigationController *nav, UIPanGestureRecognizer *gesture, void (^handler)(void)) {
    CGFloat scale = ApolloDuoSplitNativePanReleaseScaleForNavigation(nav, gesture);
    if (scale == 1.0) {
        handler();
        return;
    }
    void *previousGesture = sDuoSplitReleaseGesture;
    void *previousView = sDuoSplitReleaseView;
    CGFloat previousScale = sDuoSplitReleaseScale;
    sDuoSplitReleaseGesture = (__bridge void *)gesture;
    sDuoSplitReleaseView = (__bridge void *)nav.view;
    sDuoSplitReleaseScale = scale;
    handler();
    sDuoSplitReleaseGesture = previousGesture;
    sDuoSplitReleaseView = previousView;
    sDuoSplitReleaseScale = previousScale;
}

// The translation `gesture` reports in `view`: scaled only for the pan and
// view of the release that is running.
static CGPoint ApolloDuoSplitReleaseTranslation(UIPanGestureRecognizer *gesture, UIView *view, CGPoint translation) {
    if ((__bridge void *)gesture == sDuoSplitReleaseGesture && (__bridge void *)view == sDuoSplitReleaseView) {
        translation.x *= sDuoSplitReleaseScale;
    }
    return translation;
}

BOOL ApolloDuoSplitIsAccountFeedController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || ![state.kind isEqualToString:@"account"]
        || ![state.secondary.viewControllers containsObject:controller]) return NO;
    // A real comment thread has depth and linked-comment highlight colors.
    // The profile and shortcut lists instead render independent feed cards.
    return ![NSStringFromClass(controller.class) isEqualToString:@"Apollo.CommentsViewController"];
}

BOOL ApolloDuoSplitIsOwnAccountController(UIViewController *controller) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !controller) return NO;
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *navigation = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
        UIViewController *root = state.split ? (state.tabRoot ?: state.root) : navigation.viewControllers.firstObject;
        if (root == controller && [ApolloDuoSplitKind(root) isEqualToString:@"account"]) return YES;
    }
    return NO;
}

static NSUInteger ApolloDuoFeedStackKeptCount(UINavigationController *feed);

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    // Portrait moves the comments stack onto this navigation controller.
    // Suppression belongs to the visible feed page (the Posts root, or a feed
    // a split link pushed), not every page temporarily sharing that controller
    // during a rotation or fold transition.
    if (!state.feed || !state.host.postsColumnsPaired) return NO;
    NSUInteger feedPages = ApolloDuoFeedStackKeptCount(state.feed);
    return feedPages && controller == state.feed.viewControllers[feedPages - 1];
}

static ApolloDuoSplitHost *ApolloDuoSubredditOverlayHost(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *controller = (id)responder;
        UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
        return state.feed && state.split && !state.changing && nav == state.primary ? state.host : nil;
    }
    return nil;
}

BOOL ApolloDuoSplitIsSubredditOverlayView(UIView *view) {
    return ApolloDuoSubredditOverlayHost(view) != nil;
}

BOOL ApolloDuoSplitIsGlassSubredditOverlayView(UIView *view) {
    return ApolloDuoSubredditOverlayHost(view).listUsesGlass;
}

// Only native list surfaces belong to the drawer material. Walking every
// descendant also erased the red removal badges and restored their old colors
// after folding. In particular, never traverse into controls or effect views.
static BOOL ApolloDuoListOwnsSurface(UIView *view, ApolloDuoSplitHost *host) {
    if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class]
        || [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UIVisualEffectView.class]) return NO;
    UIView *list = host.subredditList.view;
    for (UIView *ancestor = view.superview; ancestor && ancestor != list; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UIControl.class] || [ancestor isKindOfClass:UIVisualEffectView.class]) return NO;
    }
    if (view == list || view == host.subredditList.viewControllers.firstObject.view
        || [view isKindOfClass:UITableView.class] || [view isKindOfClass:UITableViewCell.class]
        || [view isKindOfClass:UITableViewHeaderFooterView.class]) return YES;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"TableViewWrapper"] || [name containsString:@"TableViewCellContentView"]
        || [name containsString:@"SectionBackground"] || [name containsString:@"TableViewHeaderFooterContentView"]
        || [name isEqualToString:@"Apollo.RecreatedTableSectionHeaderView"]) return YES;
    UIView *parent = view.superview;
    if ([parent isKindOfClass:UITableView.class]) return ((UITableView *)parent).backgroundView == view;
    if ([parent isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *cell = (id)parent;
        return cell.backgroundView == view || cell.selectedBackgroundView == view;
    }
    if ([parent isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (id)parent;
        return header.backgroundView == view || header.contentView == view;
    }
    return NO;
}

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color) {
    if (!NSThread.isMainThread) return color;
    ApolloDuoSplitHost *host = ApolloDuoSubredditOverlayHost(view);
    if (!host || !host.listUsesGlass || host.updatingListSurfaces || !ApolloDuoListOwnsSurface(view, host)) return color;
    if (!host.listBackgrounds) host.listBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
    // Theme updates and reused cells may change while the drawer is hidden.
    // Preserve the latest requested native color, not the first light-mode one.
    [host.listBackgrounds setObject:color ?: (id)NSNull.null forKey:view];
    return UIColor.clearColor;
}

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface) {
    ApolloDuoSplitHost *host = ApolloDuoSubredditOverlayHost(surface);
    if (!host || !host.listUsesGlass || host.updatingListSurfaces) return;
    if (!host.listBackgrounds) host.listBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
    host.updatingListSurfaces = YES;
    NSMutableArray *views = [NSMutableArray arrayWithObject:surface];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UIVisualEffectView.class]) continue;
        [views addObjectsFromArray:view.subviews];
        if (!ApolloDuoListOwnsSurface(view, host)) continue;
        if (![host.listBackgrounds objectForKey:view]) {
            [host.listBackgrounds setObject:view.backgroundColor ?: (id)NSNull.null forKey:view];
        }
        view.backgroundColor = UIColor.clearColor;
    }
    host.updatingListSurfaces = NO;
}

BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return state.split && state.root == controller && ![state.kind isEqualToString:@"account"];
}

// A Posts-tab reselect closes an open drawer before any scroll or pop, so the
// tab toggles the list like its List button. The feed behind it is untouched.
BOOL ApolloDuoSplitDismissPostsList(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || !state.feed || state.changing || !state.host.listVisible) return NO;
    ApolloLog(@"[DuoSplit] Posts tab reselect: hide the list");
    [state.host setListVisible:NO animated:!UIAccessibilityIsReduceMotionEnabled()];
    return YES;
}

// A Posts-tab reselect at the feed root reveals the drawer. Other tabs and the
// cover display keep their native behavior.
BOOL ApolloDuoSplitRevealPostsList(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || !state.feed || state.changing) return NO;
    [state.host setListVisible:YES animated:!UIAccessibilityIsReduceMotionEnabled()];
    return YES;
}

BOOL ApolloDuoSplitShowSidebar(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split) return NO;
    if (state.feed) [state.host setListVisible:!state.host.listVisible animated:YES];
    else [state.split showColumn:UISplitViewControllerColumnPrimary];
    return YES;
}

// A subreddit opened from Search fills the width, and the search column acts
// like the Posts list: a Back swipe at the subreddit's root brings it back,
// with Search's query, results and scroll intact; a tap on the subreddit, a
// left swipe on the column, or the next result hides it again. UIKit owns the
// column through hide/showColumn, as the Account sidebar toggle does. The
// preferred mode stays OneBesideSecondary, so anything UIKit re-applies (or a
// book-posture change) only shows the column, never strands it hidden.
static void ApolloDuoSearchSetColumnVisible(ApolloDuoSplitState *state, BOOL visible, BOOL animated) {
    UISplitViewController *split = state.split;
    void (^apply)(void) = ^{
        if (visible) [split showColumn:UISplitViewControllerColumnPrimary];
        else [split hideColumn:UISplitViewControllerColumnPrimary];
    };
    if (animated && state.host.viewIfLoaded.window && !UIAccessibilityIsReduceMotionEnabled()) {
        apply();
        return;
    }
    [UIView performWithoutAnimation:^{
        apply();
        [state.host.view layoutIfNeeded];
    }];
}

BOOL ApolloDuoSplitCanRevealSearchColumnWithSwipe(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && !state.changing && [state.kind isEqualToString:@"search"]
        && state.secondary == nav && nav.viewControllers.count == 1
        && state.split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly;
}

BOOL ApolloDuoSplitRevealSearchColumn(UINavigationController *nav) {
    if (!ApolloDuoSplitCanRevealSearchColumnWithSwipe(nav)) return NO;
    ApolloDuoSearchSetColumnVisible(ApolloDuoSplitStateForNavigation(nav, NO), YES, YES);
    return YES;
}

static BOOL ApolloDuoSearchColumnBesideSubreddit(ApolloDuoSplitState *state) {
    return state.split && !state.changing && [state.kind isEqualToString:@"search"]
        && state.split.displayMode != UISplitViewControllerDisplayModeSecondaryOnly
        && ApolloClassPostsViewController
        && [state.secondary.viewControllers.firstObject isKindOfClass:ApolloClassPostsViewController];
}

BOOL ApolloDuoSplitCanHideSidebarWithSwipe(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || state.changing || nav != state.primary) return NO;
    return state.feed ? state.host.listVisible : ApolloDuoSearchColumnBesideSubreddit(state);
}

BOOL ApolloDuoSplitIsPostsListNavigation(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && state.feed && nav == state.primary;
}

BOOL ApolloDuoSplitCanHideSearchColumnWithTap(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return nav == state.secondary && ApolloDuoSearchColumnBesideSubreddit(state);
}

BOOL ApolloDuoSplitHideSidebar(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (state.feed && ApolloDuoSplitCanHideSidebarWithSwipe(nav)) {
        [state.host setListVisible:NO animated:!UIAccessibilityIsReduceMotionEnabled()];
        return YES;
    }
    if (!ApolloDuoSplitCanHideSidebarWithSwipe(nav) && !ApolloDuoSplitCanHideSearchColumnWithTap(nav)) return NO;
    ApolloDuoSearchSetColumnVisible(state, NO, YES);
    return YES;
}

// Never infer Duo merely from a landscape iPhone. Its native trailing tab bar
// or established Duo mode must be present, and two useful columns must fit.
static BOOL ApolloDuoSplitShouldOpen(UITabBarController *tabs) {
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    if (ApolloDuoRailHasVisibleSideBar() || ApolloDuoCurrentMode() == ApolloDuoModeOpen) {
        sDuoSplitKnownTabs = tabs;
    }
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone
        && size.width >= 800.0 && size.width > size.height
        && tabs == sDuoSplitKnownTabs;
}

// Book posture comes from the division reserved region, not window size (a
// side window can match a cover display's aspect) and not the hinge reading,
// per Apple's Duo layout guidance (https://developer.apple.com/forums/thread/847644).
static BOOL ApolloDuoSplitWantsHalfWidth(UITabBarController *tabs) {
    return !CGRectIsNull(ApolloDuoActiveVerticalDivision(tabs.view));
}

// The hinge interaction only prompts a re-check of that region. Resolve the
// iOS 27.1 API dynamically so 26 SDK device builds and older iPhones work.

static void ApolloDuoSplitObserveHinge(UITabBarController *tabs) {
    if (objc_getAssociatedObject(tabs, &kDuoSplitHingeInteraction)) return;
    if (@available(iOS 27.1, *)) {
        Class cls = NSClassFromString(@"UIHingeInteraction");
        if (!cls) return;
        __weak UITabBarController *weakTabs = tabs;
        void (^handler)(id, id) = ^(__unused id interaction, id update) {
            UITabBarController *owner = weakTabs;
            if (!owner) return;
            id hinge = ((id (*)(id, SEL))objc_msgSend)(update, NSSelectorFromString(@"hinge"));
            NSInteger status = hinge ? ((NSInteger (*)(id, SEL))objc_msgSend)(hinge, NSSelectorFromString(@"status")) : 0;
            NSInteger previous = [objc_getAssociatedObject(owner, &kDuoSplitHingeStatus) integerValue];
            if (previous == status) return;
            objc_setAssociatedObject(owner, &kDuoSplitHingeStatus, @(status), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[DuoSplit] hinge status %ld -> %ld; re-checking the division region", (long)previous, (long)status);
            // The columns may move under a thread close following the finger.
            ApolloDuoPostsCancelActiveInteractiveClose();
            // Defer containment work out of UIKit's interaction delivery. The
            // normal update also prepares the tabs that are not selected.
            ApolloDuoSplitScheduleUpdate();
            // The division region may publish a beat after the hinge reading;
            // check once more instead of depending on the hinge update rate.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ApolloDuoSplitScheduleUpdate(); });
        };
        id<UIInteraction> interaction = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithUpdateHandler:"), handler);
        objc_setAssociatedObject(tabs, &kDuoSplitHingeInteraction, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tabs.view addInteraction:interaction];
    }
}

static void ApolloDuoSplitApplySidebarWidth(ApolloDuoSplitState *state, BOOL halfWidth) {
    UISplitViewController *split = state.split;
    if (!split) return;
    state.halfWidthSidebar = halfWidth;
    // Lift the ordinary sidebar cap in book posture: half of a 951pt inner
    // display is 475.5pt, and retaining the 420pt cap misses the hinge.
    CGSize canvas = sDuoSplitResizingTabs ? sDuoSplitTargetSize : state.host.view.bounds.size;
    BOOL postsLandscape = state.feed && canvas.width > canvas.height;
    CGFloat half = canvas.width * 0.5;
    BOOL adjustable = postsLandscape && ApolloDuoPostsAdjustableSplit();
    CGFloat postsWidth = postsLandscape ? ApolloDuoPostsWantedDivider(state, canvas) : half;
    // UIKit may keep an earlier sidebar width across column replacement.
    // Bound both ends for Posts so its actual divider stays at the midpoint,
    // or at the remembered position with the adjustable split on.
    CGFloat maximum = postsLandscape ? postsWidth : (state.feed || halfWidth ? CGFLOAT_MAX : 420.0);
    // Settings' widest native row is "Touch ID & Passcode" + its value +
    // disclosure: a third of the flat inner display (~317pt) cut "Off" to "O".
    // Give that sidebar enough room for the value at the default text size.
    CGFloat sidebarMinimum = [state.kind isEqualToString:@"settings"] ? 340.0 : 240.0;
    CGFloat minimum = postsLandscape ? postsWidth : sidebarMinimum;
    if (split.maximumPrimaryColumnWidth != maximum) split.maximumPrimaryColumnWidth = maximum;
    if (split.minimumPrimaryColumnWidth != minimum) split.minimumPrimaryColumnWidth = minimum;
    CGFloat fraction = halfWidth || state.feed ? 0.5 : 1.0 / 3.0;
    if (adjustable && canvas.width > 0.0) fraction = postsWidth / canvas.width;
    if (halfWidth && !state.feed && canvas.width > 0.0) {
        // End the sidebar at the fold itself rather than an assumed midpoint.
        CGRect fold = ApolloDuoActiveVerticalDivision(state.host.view);
        if (!CGRectIsNull(fold)) fraction = MIN(0.7, MAX(0.3, CGRectGetMinX(fold) / canvas.width));
    }
    if (split.preferredPrimaryColumnWidthFraction != fraction) split.preferredPrimaryColumnWidthFraction = fraction;
    if (@available(iOS 26.0, *)) {
        // UIKit's default secondary minimum (532pt on this inner display)
        // otherwise caps the primary at 419pt even with a 50% preference.
        // Posts: the wanted divider always leaves the thread this much beside the rail.
        CGFloat secondaryMinimum = state.feed || halfWidth ? kApolloDuoPostsMinimumThread : UISplitViewControllerAutomaticDimension;
        if (split.minimumSecondaryColumnWidth != secondaryMinimum) split.minimumSecondaryColumnWidth = secondaryMinimum;
    }
    if (halfWidth && !state.feed) {
        split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        [split showColumn:UISplitViewControllerColumnPrimary];
    }
}

BOOL ApolloDuoRequiresSubredditEnhancements(void) {
    return ApolloDuoCurrentMode() != ApolloDuoModePhone || ApolloDuoSplitIsUnfolded();
}

static BOOL ApolloDuoPostsHasLandscapeColumns(ApolloDuoSplitState *state) {
    CGSize size = sDuoSplitResizingTabs ? sDuoSplitTargetSize : state.host.view.bounds.size;
    return size.width > size.height;
}

static BOOL ApolloDuoPostsUsesSplit(ApolloDuoSplitState *state) {
    return state.host.postsSplitEnabled && ApolloDuoPostsHasLandscapeColumns(state);
}


// Gallery View is a grid over its source listing, so it is a feed page too.
// As a thread page it sat in the comments pane with the feed column covering
// part of it; on the feed stack it uses the full width like any other feed.
static BOOL ApolloDuoIsFeedPage(UIViewController *page) {
    return (ApolloClassPostsViewController && [page isKindOfClass:ApolloClassPostsViewController])
        || [page isKindOfClass:ApolloGalleryViewController.class];
}

// Feed pages (subreddits and multireddits, whether opened from a split link or
// pushed while the split was off) belong on the feed stack; only the pages
// above the last of them are thread pages for the right pane.
static char kDuoFeedLinkPage;
static NSUInteger ApolloDuoFeedStackKeptCount(UINavigationController *feed) {
    NSArray *pages = feed.viewControllers;
    NSUInteger kept = MIN(pages.count, (NSUInteger)1);
    for (NSUInteger index = 1; index < pages.count; index++) {
        UIViewController *page = pages[index];
        if ([objc_getAssociatedObject(page, &kDuoFeedLinkPage) boolValue] || ApolloDuoIsFeedPage(page)) kept = index + 1;
    }
    return kept;
}

// The closed thread's memory: its pure pieces. A close of the thread column
// (the button, a Back, the drag) remembers the thread for a forward swipe, as
// Apollo keeps a page popped on a regular iPhone. Apollo forgets that page
// when a new one is pushed or memory runs low; the split forgets the thread on
// the same occasions, and whenever it could no longer come back where it was.
typedef NS_ENUM(NSInteger, ApolloDuoClosedThreadEvent) {
    ApolloDuoClosedThreadEventCheck,          // nothing happened; the facts alone decide
    ApolloDuoClosedThreadEventThreadOpened,   // another thread is opening beside the feed
    ApolloDuoClosedThreadEventFeedOpened,     // a feed is opening: a list row, a feed link, Search, a reroot
    ApolloDuoClosedThreadEventMemoryWarning,  // the feed's didReceiveMemoryWarning, Apollo's forward wipe
    ApolloDuoClosedThreadEventForeground,     // the app is back after `away` seconds in the background
};
typedef struct {
    BOOL split;           // the feed pairs a thread beside it (unfolded, landscape, split on)
    BOOL threadOpen;      // a thread shows beside the feed
    BOOL feedPageOnTop;   // the feed page it was closed from is still the feed's top page
    BOOL feedUnchanged;   // and it still shows the same feed (Apollo reuses it in place)
    BOOL pagesOnStack;    // one of its pages is on a navigation stack again
    NSTimeInterval away;  // Foreground only: the time in the background
} ApolloDuoClosedThreadFacts;

// Apollo keeps its own forward page through any time in the background. A
// thread the reader closed beside the feed is not on screen to remind them,
// so it lasts only a short trip to another app.
static const NSTimeInterval kApolloDuoClosedThreadBackgroundLimit = 60.0;

// Why the remembered thread is forgotten now, or nil to keep it.
static NSString *ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEvent event, ApolloDuoClosedThreadFacts facts) {
    if (event == ApolloDuoClosedThreadEventThreadOpened) return @"another thread opened";
    if (event == ApolloDuoClosedThreadEventFeedOpened) return @"a feed opened";
    if (event == ApolloDuoClosedThreadEventMemoryWarning) return @"memory warning";
    if (event == ApolloDuoClosedThreadEventForeground && facts.away > kApolloDuoClosedThreadBackgroundLimit)
        return @"a long stay in the background";
    if (!facts.split) return @"the split ended";
    if (facts.threadOpen) return @"a thread is beside the feed";
    if (!facts.feedPageOnTop) return @"the feed changed";
    if (!facts.feedUnchanged) return @"the feed page shows another feed";
    if (facts.pagesOnStack) return @"its pages are on a stack again";
    return nil;
}

// What a close remembers: the thread pane's pages above its backstop, the
// thread and anything pushed over it. Nothing when only the backstop is left.
static NSArray *ApolloDuoClosedThreadPages(NSArray *paneStack) {
    return paneStack.count > 1 ? [paneStack subarrayWithRange:NSMakeRange(1, paneStack.count - 1)] : @[];
}

// A thread a Back closed beside the feed, held for the forward swipe: its
// pages strongly (no stack holds them any more), its feed page weakly, and
// the snapshot of its pane as it closed, which the forward swipe slides in
// (nil when the close had none to take). The snapshot lives here alone: a
// forgotten or restored thread lets it go.
@interface ApolloDuoPostsClosedThread : NSObject
@property(nonatomic, copy) NSArray<UIViewController *> *pages;
@property(nonatomic, weak) UIViewController *feedPage;
@property(nonatomic, copy) NSString *feedIdentity;
@property(nonatomic, strong) UIView *snapshot;
@property(nonatomic) CGRect pane;
@property(nonatomic) CGSize canvas;
@property(nonatomic) CGFloat divider;
@end
@implementation ApolloDuoPostsClosedThread @end

// What a feed page shows. Apollo switches a PostsViewController's feed in
// place (the title jump bar, the subreddit list reusing the visible feed), so
// the page alone does not say. It writes the PostsType case and the title
// synchronously on every such switch (see ApolloSubredditHeaders.xm).
extern NSInteger ApolloPostsTypeTagFromViewController(UIViewController *viewController);
static NSString *ApolloDuoPostsFeedIdentity(UIViewController *page) {
    if (!page) return nil;
    return [NSString stringWithFormat:@"%@|%ld|%@|%@", NSStringFromClass(page.class),
            (long)ApolloPostsTypeTagFromViewController(page), page.navigationItem.title ?: page.title ?: @"",
            ApolloNamedSubredditForPostsController(page) ?: @""];
}

// The state holding a closed thread, for the app-wide events (the background).
static __weak ApolloDuoSplitState *sDuoPostsClosedThreadState;
static CFAbsoluteTime sDuoPostsBackgroundedAt;

static void ApolloDuoPostsForgetClosedThread(ApolloDuoSplitState *state, NSString *reason) {
    if (!state.closedThread) return;
    ApolloLog(@"[DuoSplit] forgot the closed thread (%lu page(s)): %@",
              (unsigned long)state.closedThread.pages.count, reason);
    state.closedThread = nil;
    if (sDuoPostsClosedThreadState == state) sDuoPostsClosedThreadState = nil;
}

static void ApolloDuoPostsReviewClosedThread(ApolloDuoSplitState *state, ApolloDuoClosedThreadEvent event,
                                             NSTimeInterval away) {
    ApolloDuoPostsClosedThread *closed = state.closedThread;
    if (!closed) return;
    // On a stack's pages, not merely parented: a page a non-animated
    // setViewControllers: just removed can keep its parent a moment longer.
    BOOL onStack = NO;
    for (UIViewController *page in closed.pages)
        onStack = onStack || [page.navigationController.viewControllers containsObject:page];
    ApolloDuoClosedThreadFacts facts = {
        .split = state.split && state.feed && ApolloDuoPostsUsesSplit(state),
        .threadOpen = state.secondary.viewControllers.count > 1,
        .feedPageOnTop = closed.feedPage && closed.feedPage == state.feed.topViewController,
        .feedUnchanged = [ApolloDuoPostsFeedIdentity(closed.feedPage) isEqualToString:closed.feedIdentity],
        .pagesOnStack = onStack,
        .away = away,
    };
    NSString *reason = ApolloDuoClosedThreadForgetReason(event, facts);
    if (reason) ApolloDuoPostsForgetClosedThread(state, reason);
}

// Where the split's configured primary column ends: the divider a thread
// pane sits beside, for the column widths in force whether or not a thread
// shows (ApolloDuoSplitApplySidebarWidth). Posts landscape pins both bounds
// to the wanted divider, so this follows the remembered stop.
static CGFloat ApolloDuoPostsSplitDivider(ApolloDuoSplitState *state) {
    UISplitViewController *split = state.split;
    CGFloat width = CGRectGetWidth(state.host.view.bounds);
    return MIN(split.maximumPrimaryColumnWidth,
               MAX(split.minimumPrimaryColumnWidth, width * split.preferredPrimaryColumnWidthFraction));
}

static void ApolloDuoPostsRememberClosedThread(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages,
                                               UIView *snapshot, CGRect pane) {
    UIViewController *feedPage = state.feed.topViewController;
    if (!pages.count || !feedPage) return;
    ApolloDuoSplitState *previous = sDuoPostsClosedThreadState;
    if (previous && previous != state) ApolloDuoPostsForgetClosedThread(previous, @"a thread closed in another split");
    ApolloDuoPostsClosedThread *closed = [ApolloDuoPostsClosedThread new];
    closed.pages = pages;
    closed.feedPage = feedPage;
    closed.feedIdentity = ApolloDuoPostsFeedIdentity(feedPage);
    closed.snapshot = snapshot;
    closed.pane = pane;
    closed.canvas = state.host.view.bounds.size;
    closed.divider = ApolloDuoPostsSplitDivider(state);
    state.closedThread = closed;
    sDuoPostsClosedThreadState = state;
    ApolloLog(@"[DuoSplit] remembered the closed thread (%lu page(s)) for a forward swipe; snapshot=%d",
              (unsigned long)pages.count, snapshot != nil);
}

static void ApolloDuoPostsSyncColumnsWithAnimation(ApolloDuoSplitState *state, BOOL animateDisplayMode) {
    if (!state.split || !state.feed) ApolloDuoPostsForgetClosedThread(state, @"the split ended");
    if (!state.feed || !state.split || state.changing || state.interactiveClose) return;
    // A rotation to portrait, the split turned off or a thread put beside the
    // feed by any path ends what a forward swipe could bring back.
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventCheck, 0.0);
    // Moving a navigation between columns takes it out of the window and back.
    sDuoSplitMovingColumns++;
    if (sDuoSplitResizingTabs || !ApolloDuoPostsHasLandscapeColumns(state)) {
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    }
    ApolloDuoSplitApplySidebarWidth(state, state.halfWidthSidebar);
    if (!state.primary.navigationBarHidden) [state.primary setNavigationBarHidden:YES animated:NO];
    UIViewController *listRoot = state.primary.viewControllers.firstObject;
    UIEdgeInsets currentInsets = listRoot.additionalSafeAreaInsets;
    CGFloat inheritedRight = listRoot.view.safeAreaInsets.right - currentInsets.right;
    UIEdgeInsets desiredInsets = state.host.originalListInsets;
    desiredInsets.right = -inheritedRight;
    if (!UIEdgeInsetsEqualToEdgeInsets(currentInsets, desiredInsets)) listRoot.additionalSafeAreaInsets = desiredInsets;
    [state.host updateListAppearance];
    // Full-width comments stay on Apollo's native feed navigation stack.
    // Only a real split (or its width-toggle preparation) needs two stacks.
    // Never migrate a page while Apollo's native push/pop owns its transition.
    BOOL separateComments = ApolloDuoPostsHasLandscapeColumns(state)
        && (state.host.postsSplitEnabled || state.postsTogglingSplit);
    NSUInteger feedKept = ApolloDuoFeedStackKeptCount(state.feed);
    if (separateComments && state.feed.viewControllers.count > feedKept && !state.feed.transitionCoordinator) {
        NSArray *pushed = [state.feed.viewControllers subarrayWithRange:NSMakeRange(feedKept, state.feed.viewControllers.count - feedKept)];
        state.changing = YES;
        [state.feed setViewControllers:[state.feed.viewControllers subarrayWithRange:NSMakeRange(0, feedKept)] animated:NO];
        [state.secondary setViewControllers:[@[state.secondary.viewControllers.firstObject] arrayByAddingObjectsFromArray:pushed] animated:NO];
        state.changing = NO;
    }
    // Keep the live comments column throughout a split width animation, then
    // restore native full-screen push/Back ownership once it has finished.
    if (!separateComments && state.secondary.viewControllers.count > 1
        && !state.secondary.transitionCoordinator) {
        NSArray *destinations = [state.secondary.viewControllers subarrayWithRange:NSMakeRange(1, state.secondary.viewControllers.count - 1)];
        state.changing = YES;
        [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject] animated:NO];
        [state.feed setViewControllers:[[state.feed.viewControllers subarrayWithRange:NSMakeRange(0, feedKept)]
                                           arrayByAddingObjectsFromArray:destinations] animated:NO];
        state.changing = NO;
    }
    [state.host.viewIfLoaded setNeedsLayout];
    BOOL detail = state.secondary.viewControllers.count > 1;
    BOOL paired = detail && ApolloDuoPostsUsesSplit(state);
    UISplitViewController *split = state.split;
    // A hidden primary can lose its parent while UIKit still retains it as
    // the configured column. Check column ownership, not visibility, so a
    // queued sync cannot interrupt show/hide by recommitting the display mode.
    BOOL columnsMatch = [split viewControllerForColumn:UISplitViewControllerColumnPrimary] == (detail ? state.feed : nil)
        && [split viewControllerForColumn:UISplitViewControllerColumnSecondary] == (detail ? state.secondary : state.feed);
    BOOL unchanged = state.host.postsShowingDetail == detail && state.host.postsColumnsPaired == paired && columnsMatch;
    if (unchanged) {
        sDuoSplitMovingColumns--;
        return;
    }
    state.changing = YES;
    state.host.postsShowingDetail = detail;
    state.host.postsColumnsPaired = paired;
    // The stack was just merged in portrait, so its top item can now belong
    // to comments. Restore the cached trophy/feed actions only to the Posts
    // root; assigning them to the top item replaces the thread's own actions.
    // The last feed page, not the top one: the merged stack can end in comments.
    NSUInteger feedPages = ApolloDuoFeedStackKeptCount(state.feed);
    UINavigationItem *feedItem = feedPages ? state.feed.viewControllers[feedPages - 1].navigationItem : nil;
    UINavigationItem *backItem = paired && feedPages > 1 ? feedItem : nil;
    if (state.feedBackHiddenItem != backItem) {
        state.feedBackHiddenItem.hidesBackButton = NO;
        backItem.hidesBackButton = YES;
        state.feedBackHiddenItem = backItem;
    }
    if (paired && state.feedActions && state.feedActionsItem != feedItem) {
        // A different feed page is showing now; give the previous one back
        // its actions before hiding this one's.
        state.feedActionsItem.rightBarButtonItems = state.feedActions;
        state.feedActions = nil;
    }
    if (paired) {
        if (!state.feedActions) {
            // Cache Apollo's actions only. Host controls are owned by the
            // current presentation and must not return after it is folded.
            NSMutableArray *actions = [NSMutableArray array];
            for (UIBarButtonItem *item in feedItem.rightBarButtonItems) {
                if ([item.accessibilityIdentifier isEqualToString:@"ApolloDuoFeedControl"]) continue;
                if (@available(iOS 27.0, *)) {
                    if (item == feedItem.searchBarPlacementBarButtonItem) continue;
                }
                [actions addObject:item];
            }
            state.feedActions = actions;
            state.feedActionsItem = feedItem;
        }
        feedItem.rightBarButtonItems = @[];
    } else if (state.feedActions) {
        (state.feedActionsItem ?: feedItem).rightBarButtonItems = state.feedActions;
        state.feedActions = nil;
        state.feedActionsItem = nil;
    }
    UISplitViewControllerColumn feedColumn = detail ? UISplitViewControllerColumnPrimary : UISplitViewControllerColumnSecondary;
    if (feedPages && [split viewControllerForColumn:feedColumn] != state.feed)
        ApolloNativeFeedSearchWillMoveBetweenColumns(state.feed.viewControllers[feedPages - 1]);
    if (detail) {
        BOOL retainedColumns = [split viewControllerForColumn:UISplitViewControllerColumnPrimary] == state.feed
            && [split viewControllerForColumn:UISplitViewControllerColumnSecondary] == state.secondary;
        if (!retainedColumns) {
            [split setViewController:nil forColumn:UISplitViewControllerColumnSecondary];
            [split setViewController:state.feed forColumn:UISplitViewControllerColumnPrimary];
            [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
        }
        // A width toggle retains both controllers. Let UIKit's show/hide
        // transition move the divider and cover/reveal the primary column.
        // Assigning the endpoint display mode first hides it immediately;
        // reattaching the same columns also destroys the native transition.
        if (!animateDisplayMode || !retainedColumns)
            split.preferredDisplayMode = paired ? UISplitViewControllerDisplayModeOneBesideSecondary : UISplitViewControllerDisplayModeSecondaryOnly;
        if (paired) [split showColumn:UISplitViewControllerColumnPrimary];
        else [split hideColumn:UISplitViewControllerColumnPrimary];
    } else {
        [split setViewController:nil forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.feed forColumn:UISplitViewControllerColumnSecondary];
        split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        [split hideColumn:UISplitViewControllerColumnPrimary];
    }
    [state.host.view setNeedsLayout];
    state.changing = NO;
    sDuoSplitMovingColumns--;
}

static void ApolloDuoPostsSyncColumns(ApolloDuoSplitState *state) {
    ApolloDuoPostsSyncColumnsWithAnimation(state, NO);
}

static CGRect ApolloDuoPostsDetailPane(ApolloDuoSplitState *state) {
    UIView *surface = state.host.view;
    UIView *detail = state.secondary.view;
    // The secondary navigation surface may extend underneath the primary.
    // Its leading safe area identifies the actual comments pane, including
    // its navigation chrome and trailing rail.
    CGRect pane = UIEdgeInsetsInsetRect(detail.bounds,
        UIEdgeInsetsMake(0, detail.safeAreaInsets.left, 0, 0));
    return CGRectIntersection(surface.bounds, [surface convertRect:pane fromView:detail]);
}

@interface ApolloDuoPostsGeometry : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) UIView *parent;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint position;
@property(nonatomic) CGRect surfaceFrame;
@end
@implementation ApolloDuoPostsGeometry @end

static void ApolloDuoPostsStopGeometry(UIView *feed) {
    if (!feed) return;
    [feed.layer removeAnimationForKey:@"ApolloDuoPostsGeometry"];
    for (UIView *child in feed.subviews) ApolloDuoPostsStopGeometry(child);
}

static NSArray<ApolloDuoPostsGeometry *> *ApolloDuoPostsCaptureGeometry(UIView *feed, UIView *surface) {
    NSMutableArray *geometry = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:feed];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        if (view.hidden || view.alpha < 0.01) continue;
        CALayer *layer = view.layer.presentationLayer ?: view.layer;
        ApolloDuoPostsGeometry *item = [ApolloDuoPostsGeometry new];
        item.view = view;
        item.parent = view.superview;
        item.bounds = layer.bounds;
        item.position = layer.position;
        item.surfaceFrame = [view.superview.layer convertRect:layer.frame toLayer:surface.layer];
        [geometry addObject:item];
        // The effect's compositor owns its internal backdrop geometry. Move
        // its public surface, just as UIKit does during a window resize.
        if (![view isKindOfClass:UIVisualEffectView.class]) [views addObjectsFromArray:view.subviews];
    }
    return geometry;
}

// A centered bar title (and trailing items) would travel half the screen as
// its column widens. Fade those in at their destination instead.
static BOOL ApolloDuoGeometryRecentersBarItem(ApolloDuoPostsGeometry *item, UIView *view, UIView *feed, UIView *surface) {
    BOOL inBar = NO;
    for (UIView *ancestor = view.superview; ancestor && ancestor != feed; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UINavigationBar.class]) { inBar = YES; break; }
    }
    if (!inBar || !view.superview) return NO;
    CGRect now = [view.superview.layer convertRect:view.layer.frame toLayer:surface.layer];
    return fabs(CGRectGetMidX(now) - CGRectGetMidX(item.surfaceFrame)) > 24.0
        && fabs(CGRectGetWidth(now) - CGRectGetWidth(item.surfaceFrame)) < 8.0;
}

// A view inside a feed row that draws its own contents (text, a flair, an
// image). Its bitmap is drawn for the final layout, so animating its bounds
// squashes or stretches the text, and moving it past text that reflowed
// draws it over that text.
static BOOL ApolloDuoReplayDrawsRowContents(UIView *view, UIView *feed) {
    if (!view.layer.contents) return NO;
    for (UIView *ancestor = view.superview; ancestor && ancestor != feed; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UITableViewCell.class]) return YES;
    }
    return NO;
}

// Set while a restore's hand-off replays the feed: its crossfade pictures of
// the old bar items go under the dragged page's overlay, not over the thread
// arriving under that page.
static __weak UIView *sDuoReplayCrossfadeCeiling;

// `fadeRecenteredBarItems`: bar items that recenter crossfade in place
// instead of moving with their column (the feed's column moves).
// `rowContentsFinal`: the rows' own contents take their final layout at once
// inside their rows, which keep moving and resizing (the Posts thread close).
static void ApolloDuoAnimateRetainedGeometry(NSArray<ApolloDuoPostsGeometry *> *geometry,
                                             UIView *feed, UIView *surface, NSTimeInterval duration,
                                             BOOL fadeRecenteredBarItems, BOOL rowContentsFinal) {
    NSUInteger count = 0;
    NSMutableArray<UIView *> *faded = [NSMutableArray array];
    for (ApolloDuoPostsGeometry *item in geometry) {
        UIView *view = item.view;
        if (!view || (view != feed && ![view isDescendantOfView:feed])) continue;
        CALayer *layer = view.layer;
        BOOL insideFaded = NO;
        for (UIView *ancestor in faded) if ([view isDescendantOfView:ancestor]) insideFaded = YES;
        if (insideFaded) continue;
        if (rowContentsFinal && ApolloDuoReplayDrawsRowContents(view, feed)) continue;
        if (fadeRecenteredBarItems && view != feed && ApolloDuoGeometryRecentersBarItem(item, view, feed, surface)) {
            // Crossfade: the old rendering leaves from where it was while the
            // item fades in at its destination, so the bar is never empty.
            UIView *old = [view snapshotViewAfterScreenUpdates:NO];
            if (old) {
                old.frame = item.surfaceFrame;
                old.userInteractionEnabled = NO;
                UIView *ceiling = sDuoReplayCrossfadeCeiling;
                if (ceiling.superview == surface) [surface insertSubview:old belowSubview:ceiling];
                else [surface addSubview:old];
                [UIView animateWithDuration:duration * 0.6 delay:0 options:UIViewAnimationOptionCurveEaseOut
                                 animations:^{ old.alpha = 0; }
                                 completion:^(__unused BOOL finished) { [old removeFromSuperview]; }];
            }
            CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            fade.values = @[@0, @0, @(layer.opacity)];
            fade.keyTimes = @[@0, @0.2, @1];
            fade.duration = duration;
            [layer addAnimation:fade forKey:@"ApolloDuoPostsGeometry"];
            [faded addObject:view];
            count++;
            continue;
        }
        CGPoint position = item.position;
        if (view == feed || item.parent != view.superview) {
            // A container can keep its direct wrapper while its ancestors
            // move between column coordinate spaces, so convert the root
            // unconditionally. A reparented descendant stays where it is.
            if (!view.superview || view != feed) continue;
            CGRect frame = [view.superview.layer convertRect:item.surfaceFrame fromLayer:surface.layer];
            position = CGPointMake(CGRectGetMinX(frame) + CGRectGetWidth(frame) * layer.anchorPoint.x,
                                   CGRectGetMinY(frame) + CGRectGetHeight(frame) * layer.anchorPoint.y);
        }
        NSMutableArray<CAAnimation *> *animations = [NSMutableArray array];
        if (!CGRectEqualToRect(item.bounds, layer.bounds)) {
            CABasicAnimation *bounds = [CABasicAnimation animationWithKeyPath:@"bounds"];
            bounds.fromValue = [NSValue valueWithCGRect:item.bounds];
            bounds.toValue = [NSValue valueWithCGRect:layer.bounds];
            bounds.duration = duration;
            [animations addObject:bounds];
        }
        if (!CGPointEqualToPoint(position, layer.position)) {
            CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
            move.fromValue = [NSValue valueWithCGPoint:position];
            move.toValue = [NSValue valueWithCGPoint:layer.position];
            move.duration = duration;
            [animations addObject:move];
        }
        if (!animations.count) continue;
        CAAnimationGroup *resize = [CAAnimationGroup animation];
        resize.animations = animations;
        resize.duration = duration;
        resize.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [layer addAnimation:resize forKey:@"ApolloDuoPostsGeometry"];
        count++;
    }
    ApolloLog(@"[DuoSplit] animating %lu retained surfaces", (unsigned long)count);
}

static void ApolloDuoPostsAnimateGeometry(NSArray<ApolloDuoPostsGeometry *> *geometry,
                                         UIView *feed, UIView *surface, NSTimeInterval duration) {
    ApolloDuoAnimateRetainedGeometry(geometry, feed, surface, duration, YES, NO);
}

// A thread closing beside the feed: the rows glide to their new size and
// place while their text is drawn in its final layout throughout, never
// squashed, stretched, or moved across text that reflowed. Only the close:
// its rows get shorter, so that layout always fits inside the growing row.
// Recentered bar items crossfade, as in every feed column move.
static void ApolloDuoPostsAnimateColumnGeometry(NSArray<ApolloDuoPostsGeometry *> *geometry,
                                               UIView *feed, UIView *surface, NSTimeInterval duration) {
    ApolloDuoAnimateRetainedGeometry(geometry, feed, surface, duration, YES, YES);
}

@interface ApolloDuoLayoutTransition : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UIView *surface;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) NSIndexPath *anchor;
@property(nonatomic) CGFloat anchorOffset;
@property(nonatomic) CGSize size;
@property(nonatomic, copy) NSArray<ApolloDuoPostsGeometry *> *geometry;
@property(nonatomic, strong) UIView *cover;
@end
@implementation ApolloDuoLayoutTransition @end

// One preference affects both the feed and the thread beside it. Capture every
// visible native Posts/Comments table before invalidating any of their nodes.
static void ApolloDuoToggleVisibleFeedLayout(UIViewController *controller, BOOL enabled) {
    UIWindow *window = controller.viewIfLoaded.window;
    if (!window || !enabled || sDuoFeedLayoutChanging || ApolloDuoSplitIsResizing()
        || !ApolloDuoSplitIsUnfolded() || ApolloDuoSplitIsUnfoldedPortrait()) return;
    [window layoutIfNeeded];
    BOOL animate = !UIAccessibilityIsReduceMotionEnabled();
    NSMutableArray<ApolloDuoLayoutTransition *> *transitions = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:window];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        if (view.hidden || view.alpha < 0.01) continue;
        if (![view isKindOfClass:UITableView.class]) {
            [views addObjectsFromArray:view.subviews];
            continue;
        }
        UIViewController *page = nil;
        for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
            if ([responder isKindOfClass:UIViewController.class]) { page = (id)responder; break; }
        }
        NSString *name = NSStringFromClass(page.class);
        if ((![name isEqualToString:@"Apollo.PostsViewController"] && ![name isEqualToString:@"Apollo.CommentsViewController"])
            || page.navigationController.topViewController != page
            || !CGRectIntersectsRect(window.bounds, [view convertRect:view.bounds toView:window])) continue;
        ApolloDuoLayoutTransition *transition = [ApolloDuoLayoutTransition new];
        transition.controller = page;
        transition.surface = page.view;
        transition.table = (id)view;
        transition.size = page.view.bounds.size;
        transition.anchor = [[transition.table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)] firstObject];
        transition.anchorOffset = transition.anchor
            ? CGRectGetMinY([transition.table rectForRowAtIndexPath:transition.anchor]) - transition.table.contentOffset.y : 0;
        transition.geometry = animate ? ApolloDuoPostsCaptureGeometry(page.view, page.view) : nil;
        // Cover only the queued measurement, then animate retained live views.
        transition.cover = animate ? [view snapshotViewAfterScreenUpdates:NO] : nil;
        if (transition.cover) {
            transition.cover.frame = [view convertRect:view.bounds toView:page.view];
            transition.cover.userInteractionEnabled = NO;
            [page.view addSubview:transition.cover];
        }
        ApolloDuoPostsStopGeometry(page.view);
        [transitions addObject:transition];
    }
    if (!transitions.count) return;
    sDuoFeedLayoutChanging = YES;
    sDuoLandscapeFeedLayout = sDuoLandscapeFeedLayout == 2 ? 0 : 2;
    [NSUserDefaults.standardUserDefaults setInteger:sDuoLandscapeFeedLayout forKey:UDKeyDuoLandscapeFeedLayout];
    ApolloDuoRefreshLayoutControls();
    [NSNotificationCenter.defaultCenter postNotificationName:@"ApolloDuoFeedLayoutDidChange" object:nil];
    // Media invalidation queues first. Finish Texture's transaction before
    // reading final frames, preserving each pane's own visible row anchor.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (ApolloDuoLayoutTransition *transition in transitions) {
            UIViewController *page = transition.controller;
            UIView *surface = transition.surface;
            UITableView *table = transition.table;
            if (page.viewIfLoaded != surface || surface.window != window
                || page.navigationController.topViewController != page) {
                [transition.cover removeFromSuperview];
                continue;
            }
            [UIView performWithoutAnimation:^{
                [surface layoutIfNeeded];
                [table layoutIfNeeded];
                SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
                if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
                [table layoutIfNeeded];
                NSIndexPath *anchor = transition.anchor;
                if (anchor && anchor.section < table.numberOfSections
                    && anchor.row < [table numberOfRowsInSection:anchor.section]) {
                    CGFloat minimum = -table.adjustedContentInset.top;
                    CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
                    CGFloat offset = CGRectGetMinY([table rectForRowAtIndexPath:anchor]) - transition.anchorOffset;
                    [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(maximum, MAX(minimum, offset))) animated:NO];
                    [table layoutIfNeeded];
                }
            }];
            [transition.cover removeFromSuperview];
            if (animate && CGSizeEqualToSize(transition.size, surface.bounds.size)
                && ApolloDuoSplitIsUnfolded() && !ApolloDuoSplitIsUnfoldedPortrait())
                ApolloDuoPostsAnimateGeometry(transition.geometry, surface, surface, 0.32);
        }
        sDuoFeedLayoutChanging = NO;
        ApolloDuoRefreshLayoutControls();
    });
}

static void ApolloDuoToggleFeedLayout(ApolloDuoSplitHost *host) {
    ApolloDuoToggleVisibleFeedLayout(host.feedControlsOwner, host.feedLayoutButton.enabled);
}

// Threads outside Posts need their own control. Inside Posts, the host carries
// its retained layout item between the feed and comments with List and Split.
static NSString *const kApolloDuoCommentsLayoutID = @"ApolloDuoCommentsLayoutControl";
static char kApolloDuoCommentsLayoutKey, kApolloDuoCommentsLayoutPendingKey;
@interface ApolloDuoCommentsLayoutControl : NSObject <ApolloDuoLayoutControl>
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UIBarButtonItem *item;
- (void)update;
- (void)toggle;
@end
static NSMapTable<UINavigationItem *, ApolloDuoCommentsLayoutControl *> *sDuoCommentsLayoutOwners;

static BOOL ApolloDuoCommentsShowsLayoutControl(UIViewController *controller) {
    if (!ApolloDuoSplitIsUnfolded() || ApolloDuoSplitIsUnfoldedPortrait()) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return !state.feed;
}

// NavigationActions calls this before normalizing native items, so an async
// Apollo action refresh cannot remove the independent layout control.
NSArray<UIBarButtonItem *> *ApolloDuoCommentsLayoutItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    ApolloDuoCommentsLayoutControl *control = [sDuoCommentsLayoutOwners objectForKey:item];
    if (!control) return items;
    NSMutableArray *result = [NSMutableArray array];
    if (ApolloDuoCommentsShowsLayoutControl(control.controller)) [result addObject:control.item];
    for (UIBarButtonItem *candidate in items)
        if (![candidate.accessibilityIdentifier isEqualToString:kApolloDuoCommentsLayoutID]) [result addObject:candidate];
    return result;
}

@implementation ApolloDuoCommentsLayoutControl
- (void)updateFeedLayoutButton { ApolloDuoRefreshLayoutButton(nil, self.item); }
- (void)toggle {
    if (ApolloDuoCommentsShowsLayoutControl(self.controller))
        ApolloDuoToggleVisibleFeedLayout(self.controller, self.item.enabled);
}
- (void)update {
    [self updateFeedLayoutButton];
    UINavigationItem *navigationItem = self.controller.navigationItem;
    NSArray *items = ApolloDuoCommentsLayoutItems(navigationItem, navigationItem.rightBarButtonItems);
    if (![(navigationItem.rightBarButtonItems ?: @[]) isEqualToArray:items])
        [navigationItem setRightBarButtonItems:items animated:NO];
}
@end

static void ApolloDuoCommentsUpdateLayoutControl(UIViewController *controller) {
    ApolloDuoCommentsLayoutControl *control = objc_getAssociatedObject(controller, &kApolloDuoCommentsLayoutKey);
    if (!control && !ApolloDuoCommentsShowsLayoutControl(controller)) return;
    if (!control) {
        control = [ApolloDuoCommentsLayoutControl new];
        control.controller = controller;
        // A native image item lets UIKit own glyph visibility, accessibility,
        // sizing and glass. No configured UIButton or custom wrapper is needed.
        control.item = [[UIBarButtonItem alloc] initWithImage:ApolloDuoFeedLayoutImage()
            style:UIBarButtonItemStylePlain target:control action:@selector(toggle)];
        control.item.title = @"Feed Layout";
        control.item.accessibilityLabel = @"Feed Layout";
        control.item.accessibilityIdentifier = kApolloDuoCommentsLayoutID;
        control.item.tintColor = ApolloNavigationChromeColor();
        if (@available(iOS 26.0, *)) {
            control.item.hidesSharedBackground = NO;
            control.item.sharesBackground = NO;
        }
        if (@available(iOS 27.1, *)) control.item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        objc_setAssociatedObject(controller, &kApolloDuoCommentsLayoutKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sDuoCommentsLayoutOwners) sDuoCommentsLayoutOwners = [NSMapTable weakToWeakObjectsMapTable];
        [sDuoCommentsLayoutOwners setObject:control forKey:controller.navigationItem];
        ApolloDuoRegisterLayoutControl(control);
    }
    [control update];
}

static void ApolloDuoCommentsScheduleLayoutControl(UIViewController *controller) {
    ApolloDuoCommentsLayoutControl *control = objc_getAssociatedObject(controller, &kApolloDuoCommentsLayoutKey);
    if (objc_getAssociatedObject(controller, &kApolloDuoCommentsLayoutPendingKey)
        || (!control && !ApolloDuoCommentsShowsLayoutControl(controller))) return;
    objc_setAssociatedObject(controller, &kApolloDuoCommentsLayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *page = weakController;
        if (!page) return;
        objc_setAssociatedObject(page, &kApolloDuoCommentsLayoutPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoCommentsUpdateLayoutControl(page);
    });
}

// A split toggle changes only the width of an already open comments page.
// Both native column controllers stay attached; UIKit owns their divider,
// clipping, safe areas, and the disappearance/reappearance of the feed.
static void ApolloDuoPostsToggleSplit(ApolloDuoSplitState *state) {
    if (!state.feed || state.changing || state.postsTogglingSplit
        || state.feed.transitionCoordinator || state.secondary.transitionCoordinator) return;
    ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    UIView *surface = state.host.view;
    [surface layoutIfNeeded];
    BOOL hasComments = state.secondary.viewControllers.count > 1 || state.feed.viewControllers.count > 1;
    BOOL animate = surface.window && ApolloDuoPostsHasLandscapeColumns(state)
        && hasComments && !UIAccessibilityIsReduceMotionEnabled();
    os_log_debug(ApolloFixLog(), "[ApolloFix] [DuoSplit] toggle enabled=%d animated=%d reduceMotion=%d",
        !state.host.postsSplitEnabled, animate, UIAccessibilityIsReduceMotionEnabled());
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    [state.host.postsTransitionSnapshot removeFromSuperview];
    state.host.postsTransitionSnapshot = nil;
    [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    state.postsTogglingSplit = YES;
    void (^commitTables)(void) = ^{
        [surface layoutIfNeeded];
        for (UINavigationController *navigation in @[state.feed, state.secondary]) {
            // The secondary keeps full-screen bounds while UIKit moves its
            // leading safe area. Invalidate the retained native page as well
            // as the host, so the table inherits the new column before Texture
            // measures it instead of waiting for the next scroll callback.
            UIView *pageView = navigation.topViewController.viewIfLoaded;
            [navigation.view setNeedsLayout];
            [pageView setNeedsLayout];
            [navigation.view layoutIfNeeded];
            [pageView layoutIfNeeded];
            UITableView *table = ApolloDuoSplitFindTable(pageView);
            ApolloDuoRailPrepareTableForTransition(table);
            ApolloDuoMediaPrepareTableForTransition(table);
            SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
            if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
            [table layoutIfNeeded];
        }
    };
    if (!state.host.postsSplitEnabled && state.feed.viewControllers.count > 1) {
        // Move the SAME comments page to a full-width secondary first. Its
        // appearance and geometry stay fixed; UIKit can then animate the
        // retained columns to 50/50 without a pop/re-push or an empty surface.
        [UIView performWithoutAnimation:^{
            ApolloDuoPostsSyncColumns(state);
            commitTables();
        }];
    }
    state.host.postsSplitEnabled = !state.host.postsSplitEnabled;
    [NSUserDefaults.standardUserDefaults setBool:!state.host.postsSplitEnabled forKey:@"ApolloDuoPostsSplitDisabled"];
    [state.host updateSplitButton];
    void (^updateColumns)(void) = ^{
        ApolloDuoPostsSyncColumnsWithAnimation(state, animate);
        commitTables();
    };
    void (^finish)(void) = ^{
        state.postsTogglingSplit = NO;
        // Hiding the primary has completed. Rejoin the stacks at the same
        // full-width geometry so subsequent Back uses Apollo's own animator.
        if (state.feed && state.split) {
            [UIView performWithoutAnimation:^{
                ApolloDuoPostsSyncColumns(state);
                commitTables();
            }];
        }
        ApolloDuoSplitScheduleUpdate();
    };
    if (animate) {
        [UIView animateWithDuration:0.32 delay:0
                           options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                        animations:updateColumns completion:^(__unused BOOL finished) {
            finish();
        }];
    } else {
        [UIView performWithoutAnimation:updateColumns];
        finish();
    }
}

// Read the model identity without loading the new controller's view. Feed
// selections seed link immediately; URL-created controllers seed linkID.
static NSString *ApolloDuoCommentsPostID(UIViewController *page) {
    if (![NSStringFromClass(page.class) isEqualToString:@"Apollo.CommentsViewController"]) return nil;
    id link = ApolloReadObjectIvar(page, "link");
    id value = [link respondsToSelector:@selector(fullName)]
        ? ((id (*)(id, SEL))objc_msgSend)(link, @selector(fullName)) : nil;
    NSString *identifier = [value isKindOfClass:NSString.class] ? value : nil;
    if (!identifier.length) identifier = ApolloReadSwiftStringIvar(page, "linkID");
    if ([identifier hasPrefix:@"t3_"]) identifier = [identifier substringFromIndex:3];
    return identifier.length ? identifier.lowercaseString : nil;
}

// The feed rewraps when a thread opens or closes beside it, so rows above the
// reader's place change height and the page drifts up or down. Keep the row
// at the middle of the visible feed at the same height on screen instead.
@interface ApolloDuoFeedAnchor : NSObject
@property(nonatomic, strong) NSIndexPath *path;
@property(nonatomic) CGFloat fraction;
@property(nonatomic) CGFloat screenY;
@property(nonatomic) BOOL atTop;
@end
@implementation ApolloDuoFeedAnchor @end

static ApolloDuoFeedAnchor *ApolloDuoCaptureFeedAnchor(UITableView *table) {
    if (!table.window || table.dragging || table.decelerating) return nil;
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat visible = table.bounds.size.height - inset.top - inset.bottom;
    CGFloat middle = table.contentOffset.y + inset.top + visible / 2;
    for (NSIndexPath *path in table.indexPathsForVisibleRows) {
        CGRect rect = [table rectForRowAtIndexPath:path];
        if (middle < CGRectGetMinY(rect) || middle >= CGRectGetMaxY(rect) || rect.size.height <= 0) continue;
        ApolloDuoFeedAnchor *anchor = [ApolloDuoFeedAnchor new];
        anchor.path = path;
        anchor.fraction = (middle - CGRectGetMinY(rect)) / rect.size.height;
        anchor.screenY = middle - table.contentOffset.y;
        anchor.atTop = ApolloDuoFeedRestsAtTop(table.contentOffset.y, -inset.top);
        return anchor;
    }
    return nil;
}

static void ApolloDuoRestoreFeedAnchor(UITableView *table, ApolloDuoFeedAnchor *anchor) {
    NSIndexPath *path = anchor.path;
    if (!path || !table.window || path.section >= table.numberOfSections
        || path.row >= [table numberOfRowsInSection:path.section]) return;
    CGRect rect = [table rectForRowAtIndexPath:path];
    CGFloat minimum = -table.adjustedContentInset.top;
    CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
    CGFloat offset = anchor.atTop ? minimum
        : ApolloDuoAnchoredOffset(CGRectGetMinY(rect), rect.size.height, anchor.fraction,
                                  anchor.screenY, minimum, maximum);
    if (fabs(offset - table.contentOffset.y) < 0.5) return;
    ApolloLog(@"[DuoSplit] feed anchor: row %ld.%ld offset %.1f -> %.1f", (long)path.section, (long)path.row,
              table.contentOffset.y, offset);
    [table setContentOffset:CGPointMake(table.contentOffset.x, offset) animated:NO];
}

// The interactive thread close's pure pieces: where the drag puts the thread
// and the gap it uncovers, the spring that finishes it, and the phases that
// keep the split's own column updates away while it runs. Host-tested in
// tests/duo_interactive_close_tests.m.
typedef NS_ENUM(NSInteger, ApolloDuoPostsClosePhase) {
    ApolloDuoPostsClosePhaseIdle,       // no drag: the split syncs and updates as usual
    ApolloDuoPostsClosePhaseTracking,   // the thread's snapshot follows the finger
    ApolloDuoPostsClosePhaseReturning,  // released short: springing back over the live thread
};
typedef NS_ENUM(NSInteger, ApolloDuoPostsCloseEvent) {
    ApolloDuoPostsCloseEventBegin,
    ApolloDuoPostsCloseEventCommit,      // released past the threshold: the close takes over
    ApolloDuoPostsCloseEventSpringBack,  // released short of it
    ApolloDuoPostsCloseEventReturned,    // the spring back finished
    ApolloDuoPostsCloseEventInterrupt,   // fold, resize, hinge, tab, presentation, disappear, resign, push
};

static ApolloDuoPostsClosePhase ApolloDuoPostsClosePhaseAfter(ApolloDuoPostsClosePhase phase, ApolloDuoPostsCloseEvent event) {
    switch (event) {
        case ApolloDuoPostsCloseEventBegin:
            return phase == ApolloDuoPostsClosePhaseIdle ? ApolloDuoPostsClosePhaseTracking : phase;
        case ApolloDuoPostsCloseEventCommit:
            return phase == ApolloDuoPostsClosePhaseTracking ? ApolloDuoPostsClosePhaseIdle : phase;
        case ApolloDuoPostsCloseEventSpringBack:
            return phase == ApolloDuoPostsClosePhaseTracking ? ApolloDuoPostsClosePhaseReturning : phase;
        case ApolloDuoPostsCloseEventReturned:
            return phase == ApolloDuoPostsClosePhaseReturning ? ApolloDuoPostsClosePhaseIdle : phase;
        case ApolloDuoPostsCloseEventInterrupt:
            return ApolloDuoPostsClosePhaseIdle;
    }
    return phase;
}

// The button close's duration; the interactive commit finishes within it.
static const NSTimeInterval kApolloDuoPostsCloseDuration = 0.32;
// A shorter remainder replays nothing (CA reads a zero duration as 0.25 s).
static const NSTimeInterval kApolloDuoPostsCloseMinimumReplay = 0.05;
// Apollo's Back shadow opacity (ApolloInterruptibleNavTransition.xm).
static const CGFloat kApolloDuoPostsCloseShadowOpacity = 0.3;
// The smear column ends this far inside the feed's trailing edge: clear of
// the split divider and the scroll indicator, and outside the content margin
// that right-aligned thumbnails and vote/more controls keep.
static const CGFloat kApolloDuoPostsSmearInset = 8.0;
// One stretched point between two 1pt caps.
static const CGFloat kApolloDuoPostsSmearWidth = 3.0;
// A critically damped spring with a 0.3 s response (no bounce), UIKit's
// interactive Back feel. Stiffness is its square, damping twice it.
static const CGFloat kApolloDuoPostsSpringOmega = 2.0 * M_PI / 0.3;

static CGFloat ApolloDuoPostsCloseOffset(CGFloat translation, CGFloat travel) {
    return MIN(MAX(0.0, translation), MAX(0.0, travel));
}

static CGFloat ApolloDuoPostsCloseProgress(CGFloat offset, CGFloat width) {
    return width > 0.0 ? MIN(1.0, MAX(0.0, offset / width)) : 0.0;
}

static CGFloat ApolloDuoPostsCloseShadowOpacity(CGFloat progress) {
    return kApolloDuoPostsCloseShadowOpacity * (1.0 - MIN(1.0, MAX(0.0, progress)));
}

// What the thread has uncovered: [pane.minX, 0, dx, H].
static CGRect ApolloDuoPostsCloseExtensionFrame(CGRect pane, CGFloat offset) {
    return CGRectMake(CGRectGetMinX(pane), CGRectGetMinY(pane), MAX(0.0, offset), CGRectGetHeight(pane));
}

// The extension is laid out once at the full travel and scaled from its
// leading edge, so the drag changes a transform, never a frame. At rest it
// stays invertible and under a point wide, beneath the thread's snapshot.
static CGFloat ApolloDuoPostsCloseExtensionScale(CGFloat offset, CGFloat travel) {
    if (travel <= 0.0) return 1.0;
    return MIN(1.0, MAX(0.001, offset / travel));
}

static CGRect ApolloDuoPostsCloseSmearColumn(CGFloat trailingEdge, CGRect pane) {
    return CGRectMake(trailingEdge - kApolloDuoPostsSmearInset - kApolloDuoPostsSmearWidth, CGRectGetMinY(pane),
                      kApolloDuoPostsSmearWidth, CGRectGetHeight(pane));
}

// Only the bar band above the feed's content is smeared, so the glass bar
// carries on over the gap. Below it a row can reach the column (the open
// post's highlight, its more button, a separator) and would be stretched
// into a band or a line across the gap; the rows' own color fills it.
static CGRect ApolloDuoPostsCloseSmearBand(CGRect column, CGFloat contentTop) {
    CGFloat height = MIN(CGRectGetHeight(column), contentTop - CGRectGetMinY(column));
    if (height <= 0.0) return CGRectNull;
    column.size.height = height;
    return column;
}

// CASpringAnimation's initialVelocity is per unit of the from-to distance,
// positive toward `to`. Springing back toward the pane it is capped at the
// critical rate, so the thread never overshoots over the feed. Off the pane
// an overshoot only leaves the screen, so a fast flick keeps its speed.
static CGFloat ApolloDuoPostsSpringVelocity(CGFloat from, CGFloat to, CGFloat velocity) {
    CGFloat distance = to - from;
    if (fabs(distance) < 1.0) return 0.0;
    CGFloat spring = velocity / distance;
    return to < from ? MIN(kApolloDuoPostsSpringOmega, spring) : spring;
}

static NSTimeInterval ApolloDuoPostsCloseRemaining(NSTimeInterval elapsed) {
    NSTimeInterval remaining = kApolloDuoPostsCloseDuration - MAX(0.0, elapsed);
    return remaining >= kApolloDuoPostsCloseMinimumReplay ? remaining : 0.0;
}

// A surface that spanned the feed column at capture: the page and its
// containers, and the table, the bar, its material and scroll edge effect,
// full-bleed rows. The replay starts these at the full width, so nothing
// behind them (the page's black, content above the bar's blur) shows while
// they would otherwise still be growing.
static BOOL ApolloDuoPostsSpansColumn(CGRect surfaceFrame, CGRect column) {
    return !CGRectIsEmpty(surfaceFrame) && !CGRectIsEmpty(column)
        && fabs(CGRectGetMinX(surfaceFrame) - CGRectGetMinX(column)) < 1.0
        && fabs(CGRectGetMaxX(surfaceFrame) - CGRectGetMaxX(column)) < 1.0;
}

// Where a row that only came on screen as the feed widened starts its replay:
// below its place by as much as the nearest retained row above it moved up,
// so it comes in behind that row; with none above, with the nearest below.
// Frames are in the table's content, before and after the re-layout.
static CGFloat ApolloDuoPostsEnteringRowShift(const CGRect *before, const CGRect *after, NSUInteger count,
                                             CGRect entering) {
    NSInteger above = -1, below = -1;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat top = CGRectGetMinY(after[i]);
        if (top <= CGRectGetMinY(entering)) {
            if (above < 0 || top > CGRectGetMinY(after[above])) above = (NSInteger)i;
        } else if (below < 0 || top < CGRectGetMinY(after[below])) {
            below = (NSInteger)i;
        }
    }
    if (above >= 0) return CGRectGetMaxY(before[above]) - CGRectGetMaxY(after[above]);
    if (below >= 0) return CGRectGetMinY(before[below]) - CGRectGetMinY(after[below]);
    return 0.0;
}

// The forward swipe's restore is the close mirrored, on one offset: the
// page's distance right of the thread pane's place. The close starts at 0 and
// commits off the pane at `travel`; the restore starts at `travel`, fully off
// screen at the feed pane's trailing edge, and commits at 0.
static CGFloat ApolloDuoPostsDragOffset(BOOL restoring, CGFloat translation, CGFloat travel) {
    return ApolloDuoPostsCloseOffset(restoring ? travel + translation : translation, travel);
}

static CGFloat ApolloDuoPostsDragTarget(BOOL restoring, BOOL commit, CGFloat travel) {
    return restoring == commit ? 0.0 : travel;
}

// The restore's progress for ApolloDuoForwardShouldCommit: the drag over the
// thread pane it fills, signed like the translation (negative leftward).
static CGFloat ApolloDuoPostsRestoreProgress(CGFloat translation, CGFloat width) {
    return width > 0.0 ? translation / width : 0.0;
}

// The snapshot a close left serves only the canvas and the divider it was
// taken with: a size, hinge or posture change since moved the pane, and the
// restore is then discrete.
static BOOL ApolloDuoClosedThreadSnapshotFits(BOOL snapshot, CGSize canvas, CGSize now, CGFloat divider, CGFloat nowDivider) {
    return snapshot && fabs(canvas.width - now.width) < 1.0 && fabs(canvas.height - now.height) < 1.0
        && fabs(divider - nowDivider) < 1.0;
}

// Widen a captured layer by `expansion` with its leading edge fixed.
static void ApolloDuoPostsInflateGeometry(CGRect *bounds, CGPoint *position, CGRect *surfaceFrame,
                                          CGFloat anchorX, CGFloat expansion) {
    bounds->size.width += expansion;
    position->x += expansion * anchorX;
    surfaceFrame->size.width += expansion;
}

// What an interactive close hands to ApolloDuoPostsCloseDetail when a drag
// already owns the departing thread. It is also the drag's own record while
// the finger is down (ApolloDuoSplitState.interactiveClose), for the forward
// swipe's restore too (`restoring`), which hands it to ApolloDuoPostsOpenDetail.
@interface ApolloDuoPostsCloseHandoff : NSObject
// Holds everything below and is the host's postsTransitionSnapshot, so every
// stale-transition cleanup removes the drag with it. Clear, it takes every
// new touch: a second finger can't reach the feed or the live thread.
@property (nonatomic, strong) UIView *overlay;
// The thread pane's snapshot inside a view carrying Apollo's Back shadow.
@property (nonatomic, strong) UIView *snapshot;
// What the thread uncovers: the feed's trailing edge, stretched, or a flat fill.
@property (nonatomic, strong) UIView *extension;
// The feed as it was, laid over the live feed while the close re-lays it out.
@property (nonatomic, strong) UIView *cover;
@property (nonatomic, weak) UINavigationController *navigation;
@property (nonatomic) ApolloDuoPostsClosePhase phase;
@property (nonatomic) CGRect pane;
@property (nonatomic) CGFloat travel;
@property (nonatomic) CGFloat velocity;
@property (nonatomic) CFTimeInterval slideStarted;
// The forward swipe brings a closed thread back: the page slides in from the
// screen's edge and commits onto the pane.
@property (nonatomic) BOOL restoring;
// The close's drag, for the memory: the pane as it was when the drag began.
@property (nonatomic, strong) UIView *restoreSnapshot;
// The slide's spring as handed to Core Animation, so the restore's live
// thread can run the very same one under it.
@property (nonatomic) CGFloat slideFrom;
@property (nonatomic) CGFloat slideSpring;
// The divider pressed and dragged (ApolloDuoSplitDivider*): the same drag
// with the divider as its offset, either way. The press drives it with no
// pane navigation; the thread pane's own pan drives it with one.
@property (nonatomic) BOOL dividing;
// What a divider dragged left uncovers at the thread's trailing edge, laid
// out once at the feed's whole width and scaled from that edge.
@property (nonatomic, strong) UIView *fill;
@end

@implementation ApolloDuoPostsCloseHandoff
@end

// Removes a drag's overlay once nothing in it is still finishing.
static void ApolloDuoPostsRemoveEmptyOverlay(ApolloDuoSplitHost *host, UIView *overlay) {
    if (!overlay || overlay.subviews.count) return;
    [overlay removeFromSuperview];
    if (host.postsTransitionSnapshot == overlay) host.postsTransitionSnapshot = nil;
}

static void ApolloDuoPostsRemoveOverlay(ApolloDuoSplitHost *host, UIView *overlay) {
    [overlay.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    ApolloDuoPostsRemoveEmptyOverlay(host, overlay);
}

// `omega` is the spring's natural frequency; a `cap` above 0 ends it that
// early (a critically damped tail is under 1% of the distance by then).
static CASpringAnimation *ApolloDuoPostsSpringWith(NSString *keyPath, id from, id to, CGFloat velocity,
                                                   CGFloat omega, NSTimeInterval cap) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:keyPath];
    spring.mass = 1.0;
    spring.stiffness = omega * omega;
    spring.damping = 2.0 * omega;
    spring.initialVelocity = velocity;
    spring.fromValue = from;
    spring.toValue = to;
    spring.duration = cap > 0 ? MIN(cap, spring.settlingDuration) : spring.settlingDuration;
    return spring;
}

static CASpringAnimation *ApolloDuoPostsSpring(NSString *keyPath, id from, id to, CGFloat velocity) {
    return ApolloDuoPostsSpringWith(keyPath, from, to, velocity, kApolloDuoPostsSpringOmega, 0.0);
}

// Springs the dragged thread to `offset` (0, back over the pane, or the full
// travel, off it) from wherever the finger left it, with the finger's
// velocity, and the uncovered gap and the shadow with it. Explicit Core
// Animation, so the render server keeps it moving through a main-thread stall.
// The completion runs however the springs end (finished or removed), so the
// drag's flag can never outlive its views.
static void ApolloDuoPostsSpringDragWith(ApolloDuoPostsCloseHandoff *drag, CGFloat offset, CGFloat velocity,
                                         CGFloat omega, NSTimeInterval cap, dispatch_block_t completion) {
    UIView *page = drag.snapshot, *extension = drag.extension;
    CGFloat from = page.transform.tx;
    CGFloat spring = ApolloDuoPostsSpringVelocity(from, offset, velocity);
    // A restore has no gap to widen.
    CGFloat fromScale = extension ? extension.transform.a : 1.0;
    CGFloat toScale = ApolloDuoPostsCloseExtensionScale(offset, drag.travel);
    float fromOpacity = page.layer.shadowOpacity;
    // A restore lands with its shadow gone: the live thread under it has
    // none, so the page's removal leaves nothing to pop.
    float toOpacity = drag.restoring && offset <= 0.0 ? 0.0f
        : ApolloDuoPostsCloseShadowOpacity(ApolloDuoPostsCloseProgress(offset, CGRectGetWidth(drag.pane)));
    // A divider dragged left: its trailing fill, toward the feed's width.
    UIView *fill = drag.fill;
    CGFloat fromFill = fill ? fill.transform.a : 1.0;
    CGFloat toFill = ApolloDuoPostsCloseExtensionScale(-offset, CGRectGetMinX(drag.pane));
    page.transform = CGAffineTransformMakeTranslation(offset, 0);
    extension.transform = CGAffineTransformMakeScale(toScale, 1);
    fill.transform = CGAffineTransformMakeScale(toFill, 1);
    page.layer.shadowOpacity = toOpacity;
    CASpringAnimation *slide = ApolloDuoPostsSpringWith(@"transform",
        [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(from, 0, 0)],
        [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(offset, 0, 0)], spring, omega, cap);
    drag.slideFrom = from;
    drag.slideSpring = spring;
    [CATransaction begin];
    [CATransaction setCompletionBlock:completion];
    [page.layer addAnimation:slide forKey:@"ApolloDuoSlide"];
    [page.layer addAnimation:ApolloDuoPostsSpringWith(@"shadowOpacity", @(fromOpacity), @(toOpacity), spring, omega, cap)
                      forKey:@"ApolloDuoShadow"];
    [extension.layer addAnimation:ApolloDuoPostsSpringWith(@"transform",
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(fromScale, 1, 1)],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(toScale, 1, 1)], spring, omega, cap) forKey:@"ApolloDuoSlide"];
    [fill.layer addAnimation:ApolloDuoPostsSpringWith(@"transform",
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(fromFill, 1, 1)],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(toFill, 1, 1)], spring, omega, cap) forKey:@"ApolloDuoSlide"];
    [CATransaction commit];
}

static void ApolloDuoPostsSpringDrag(ApolloDuoPostsCloseHandoff *drag, CGFloat offset, CGFloat velocity,
                                     dispatch_block_t completion) {
    ApolloDuoPostsSpringDragWith(drag, offset, velocity, kApolloDuoPostsSpringOmega, 0.0, completion);
}

// The rest of a committed drag's slide: a close's off the pane, widening the
// gap with it; a restore's onto the pane, where it stays over the live thread
// until that one has arrived under it.
static void ApolloDuoPostsSlideHandoff(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *handoff) {
    UIView *page = handoff.snapshot, *overlay = handoff.overlay;
    if (!page) return;
    handoff.slideStarted = CACurrentMediaTime();
    __weak ApolloDuoSplitHost *weakHost = state.host;
    ApolloDuoPostsSpringDrag(handoff, ApolloDuoPostsDragTarget(handoff.restoring, YES, handoff.travel), handoff.velocity, ^{
        [page removeFromSuperview];
        ApolloDuoPostsRemoveEmptyOverlay(weakHost, overlay);
        ApolloDuoSplitScheduleUpdate();
    });
}

// Rows that only came on screen as the feed widened were never captured, so
// the replay would leave them at their final place from its first frame,
// with their text drawn a frame late. Draw them now and slide them in behind
// the retained row above them, on the replay's curve.
static void ApolloDuoPostsReplayEnteringRows(NSArray<ApolloDuoPostsGeometry *> *geometry, UITableView *table,
                                             NSTimeInterval duration) {
    if (!table || duration <= 0) return;
    NSMapTable<UIView *, ApolloDuoPostsGeometry *> *captured = [NSMapTable weakToStrongObjectsMapTable];
    for (ApolloDuoPostsGeometry *item in geometry) if (item.view) [captured setObject:item forKey:item.view];
    NSMutableData *before = [NSMutableData data], *after = [NSMutableData data];
    NSMutableArray<UITableViewCell *> *entering = [NSMutableArray array];
    for (UITableViewCell *cell in table.visibleCells) {
        ApolloDuoPostsGeometry *item = [captured objectForKey:cell];
        if (!item) {
            [entering addObject:cell];
            continue;
        }
        if (item.parent != cell.superview) continue;
        CGPoint anchor = cell.layer.anchorPoint;
        CGRect was = CGRectMake(item.position.x - item.bounds.size.width * anchor.x,
                                item.position.y - item.bounds.size.height * anchor.y,
                                item.bounds.size.width, item.bounds.size.height);
        CGRect now = cell.frame;
        [before appendBytes:&was length:sizeof was];
        [after appendBytes:&now length:sizeof now];
    }
    NSUInteger count = before.length / sizeof(CGRect);
    if (!entering.count || !count) return;
    SEL nodeSelector = @selector(nodeForRowAtIndexPath:);
    SEL displaySelector = @selector(recursivelyEnsureDisplaySynchronously:);
    NSUInteger slid = 0;
    for (UITableViewCell *cell in entering) {
        CGFloat shift = ApolloDuoPostsEnteringRowShift((const CGRect *)before.bytes, (const CGRect *)after.bytes,
                                                       count, cell.frame);
        if (fabs(shift) < 0.5) continue;
        NSIndexPath *path = [table indexPathForCell:cell];
        id node = path && [table respondsToSelector:nodeSelector]
            ? ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, path) : nil;
        if ([node respondsToSelector:displaySelector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(node, displaySelector, YES);
        CALayer *layer = cell.layer;
        CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
        move.fromValue = [NSValue valueWithCGPoint:CGPointMake(layer.position.x, layer.position.y + shift)];
        move.toValue = [NSValue valueWithCGPoint:layer.position];
        move.duration = duration;
        move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [layer addAnimation:move forKey:@"ApolloDuoPostsGeometry"];
        slid++;
    }
    ApolloLog(@"[DuoSplit] %lu of %lu rows that came on screen as the feed widened slid in",
              (unsigned long)slid, (unsigned long)entering.count);
}

// The feed re-laid out at full width under the drag's cover: finish its
// widening, then let the cover and the gap go. The replay starts every
// surface that spanned the feed column inflated to the cover's width (the
// cover and the widened gap span the surface), so no strip opens beyond the
// half-width rows while they grow in the slide's remaining time, and the
// bar's material and scroll edge effect cover the whole bar from the start;
// the root never lags the thread.
static void ApolloDuoPostsHandoffFeed(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *handoff,
                                      NSArray<ApolloDuoPostsGeometry *> *geometry, UIView *surface) {
    UIView *feed = state.feed.view, *page = state.feed.topViewController.viewIfLoaded;
    NSTimeInterval remaining = ApolloDuoPostsCloseRemaining(CACurrentMediaTime() - handoff.slideStarted);
    ApolloDuoPostsGeometry *root = nil;
    for (ApolloDuoPostsGeometry *item in geometry) if (item.view == feed) root = item;
    BOOL replay = remaining > 0 && root && page;
    if (replay) {
        CGRect column = root.surfaceFrame;
        CGFloat expansion = CGRectGetMaxX(surface.bounds) - CGRectGetMaxX(column);
        for (ApolloDuoPostsGeometry *item in geometry) {
            UIView *view = item.view;
            // The containers from the feed's navigation view down to its
            // page, and everything else that spanned the column.
            BOOL container = view == page || [page isDescendantOfView:view];
            if (expansion <= 0 || !view || (view != feed && ![view isDescendantOfView:feed])
                || !(container || ApolloDuoPostsSpansColumn(item.surfaceFrame, column))) continue;
            CGRect bounds = item.bounds, frame = item.surfaceFrame;
            CGPoint position = item.position;
            ApolloDuoPostsInflateGeometry(&bounds, &position, &frame, view.layer.anchorPoint.x, expansion);
            item.bounds = bounds;
            item.position = position;
            item.surfaceFrame = frame;
        }
        ApolloDuoPostsAnimateColumnGeometry(geometry, feed, surface, remaining);
        ApolloDuoPostsReplayEnteringRows(geometry, ApolloDuoSplitFindTable(page), remaining);
    }
    UIView *cover = handoff.cover, *extension = handoff.extension, *overlay = handoff.overlay;
    __weak ApolloDuoSplitHost *weakHost = state.host;
    ApolloLog(@"[DuoSplit] interactive close hand-off: %@ remaining=%.3f",
              replay ? @"replay" : @"cross-fade", remaining);
    [UIView animateWithDuration:replay ? 0.1 : 0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        cover.alpha = 0;
        extension.alpha = 0;
    } completion:^(__unused BOOL finished) {
        [cover removeFromSuperview];
        [extension removeFromSuperview];
        ApolloDuoPostsRemoveEmptyOverlay(weakHost, overlay);
    }];
}

// Reduce Motion, or no window: the drag's overlay fades over the settled
// columns (or goes at once) instead of sliding and replaying.
static void ApolloDuoPostsFadeHandoff(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *handoff, NSTimeInterval duration) {
    UIView *overlay = handoff.overlay;
    __weak ApolloDuoSplitHost *weakHost = state.host;
    [UIView animateWithDuration:duration animations:^{ overlay.alpha = 0; } completion:^(__unused BOOL finished) {
        ApolloDuoPostsRemoveOverlay(weakHost, overlay);
        ApolloDuoSplitScheduleUpdate();
    }];
}

// Opening or closing a thread beside the feed resizes the feed's table,
// re-measures its rows and moves its offset in one go. UIKit showed its
// scroll indicator for that, sized from rows Texture was still measuring:
// tall at first, then tiny as the real heights arrived. Hide the feed's and
// the incoming thread's indicators through the move and the time UIKit keeps
// a flashed one up; a drag that starts sooner gets them back at once.
static const NSTimeInterval kApolloDuoPostsIndicatorHold = 1.0;
@interface ApolloDuoIndicatorHold : NSObject
@property(nonatomic, weak) UIScrollView *scroll;
@property(nonatomic) BOOL shows;
@property(nonatomic) NSUInteger generation;
@end
static char kApolloDuoIndicatorHoldKey;
@implementation ApolloDuoIndicatorHold
- (void)scrolled:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) [self end];
}
- (void)end {
    UIScrollView *scroll = self.scroll;
    [scroll.panGestureRecognizer removeTarget:self action:@selector(scrolled:)];
    if (objc_getAssociatedObject(scroll, &kApolloDuoIndicatorHoldKey) != self) return;
    scroll.showsVerticalScrollIndicator = self.shows;
    objc_setAssociatedObject(scroll, &kApolloDuoIndicatorHoldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

static void ApolloDuoPostsHoldIndicator(UIScrollView *scroll) {
    if (!scroll) return;
    ApolloDuoIndicatorHold *hold = objc_getAssociatedObject(scroll, &kApolloDuoIndicatorHoldKey);
    if (!hold) {
        hold = [ApolloDuoIndicatorHold new];
        hold.scroll = scroll;
        hold.shows = scroll.showsVerticalScrollIndicator;
        objc_setAssociatedObject(scroll, &kApolloDuoIndicatorHoldKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scroll.panGestureRecognizer addTarget:hold action:@selector(scrolled:)];
        scroll.showsVerticalScrollIndicator = NO;
    }
    NSUInteger generation = ++hold.generation;
    __weak ApolloDuoIndicatorHold *weakHold = hold;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloDuoPostsIndicatorHold * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloDuoIndicatorHold *live = weakHold;
        if (live.generation == generation) [live end];
    });
}

// Close the thread column. `handoff` is nil for the discrete paths (button,
// pop hook, didShow safety net), which take their own snapshot and slide it
// out from the pane's left edge. With a handoff (a committed drag) the close
// adopts the drag's overlay as its transition snapshot, keeps its slide
// going from wherever the finger left it, and finishes the feed under the
// drag's cover.
static void ApolloDuoPostsCloseDetail(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *handoff, BOOL animated) {
    // Any other close ends a drag first, without animation.
    if (state.interactiveClose && state.interactiveClose != handoff)
        ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    UIView *surface = state.host.view;
    BOOL animate = animated && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    if (!animate) {
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    }
    UIViewController *backstop = state.secondary.viewControllers.firstObject;
    NSArray<UIViewController *> *closedPages = ApolloDuoClosedThreadPages(state.secondary.viewControllers);
    // A handed-in overlay is the live drag's; it becomes the transition snapshot.
    if (handoff.overlay) {
        state.host.postsTransitionSnapshot = handoff.overlay;
    } else {
        [state.host.postsTransitionSnapshot removeFromSuperview];
        state.host.postsTransitionSnapshot = nil;
    }
    [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];

    [surface layoutIfNeeded];
    NSArray<ApolloDuoPostsGeometry *> *feedGeometry = animate
        ? ApolloDuoPostsCaptureGeometry(state.feed.view, surface) : nil;
    CGRect pane = ApolloDuoPostsDetailPane(state);
    BOOL paneShown = surface.window && !CGRectIsNull(pane) && !CGRectIsEmpty(pane);
    UIView *snapshot = handoff.snapshot;
    if (!handoff && animate && paneShown)
        snapshot = [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    // What a forward swipe slides back in: the pane as it looks now (as the
    // drag began, for a drag, whose own views cover the pane by now).
    UIView *closedSnapshot = handoff ? handoff.restoreSnapshot
        : paneShown ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
    CGRect closedPane = handoff ? handoff.pane : pane;
    if (snapshot && !handoff) {
        snapshot.frame = pane;
        snapshot.userInteractionEnabled = NO;
        [surface insertSubview:snapshot belowSubview:state.host.listDismiss];
        state.host.postsTransitionSnapshot = snapshot;
    }
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    ApolloDuoFeedAnchor *feedAnchor = ApolloDuoCaptureFeedAnchor(
        ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded));
    ApolloDuoPostsHoldIndicator(ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded));
    void (^updateColumns)(void) = ^{
        // The thread's page leaves its column, and a forward swipe may put it
        // back: note its revealed palette while it is still live.
        ApolloNativeFeedSearchWillMoveBetweenColumns(closedPages.lastObject);
        // UIKit installs the moved column's views as it lays them out.
        sDuoSplitMovingColumns++;
        state.changing = YES;
        [state.secondary setViewControllers:@[backstop] animated:NO];
        state.changing = NO;
        // Off the pane now: what a forward swipe brings back.
        ApolloDuoPostsRememberClosedThread(state, closedPages, closedSnapshot, closedPane);
        ApolloDuoPostsSyncColumns(state);
        [surface layoutIfNeeded];
        sDuoSplitMovingColumns--;
        ApolloNativeFeedSearchFinishColumnMove(state.feed.topViewController);
        // Texture schedules its row geometry separately from UIKit's column
        // layout. Commit the existing measurement before taking endpoints so
        // cell/media widths participate in the same resize as their live nav.
        UITableView *table = ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded);
        ApolloDuoMediaPrepareTableForTransition(table);
        SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
        if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
        [table layoutIfNeeded];
        // Anchor before the geometry replay reads its endpoints, so rows
        // glide to where the reader's place stays put instead of jumping.
        if (feedAnchor) {
            ApolloDuoRestoreFeedAnchor(table, feedAnchor);
            [table layoutIfNeeded];
        }
    };
    if (!animate) {
        [UIView performWithoutAnimation:updateColumns];
        // Reduce Motion: a short fade over the closed column, no replay.
        if (handoff) ApolloDuoPostsFadeHandoff(state, handoff, animated && surface.window ? 0.15 : 0.0);
        return;
    }
    // Finish containment with UIKit animation disabled. Running this inside
    // a UIView animation also animates UIKit's column wrappers, which moves
    // the whole feed a second time on top of its explicit geometry replay.
    // Model geometry remains UIKit-owned; only presentation endpoints below
    // animate from the captured full-width/half-width live view hierarchy.
    [UIView performWithoutAnimation:updateColumns];
    __weak ApolloDuoSplitHost *weakHost = state.host;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ ApolloDuoSplitScheduleUpdate(); }];
    if (handoff) {
        // The drag's release normally started the slide already, before
        // the re-layout above; otherwise start it from where the finger left it.
        if (![snapshot.layer animationForKey:@"ApolloDuoSlide"]) ApolloDuoPostsSlideHandoff(state, handoff);
        ApolloDuoPostsHandoffFeed(state, handoff, feedGeometry, surface);
    } else {
        ApolloDuoPostsAnimateColumnGeometry(feedGeometry, state.feed.view, surface, 0.32);
        ApolloDuoPostsReplayEnteringRows(feedGeometry, ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded), 0.32);
        if (snapshot) {
            CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
            ApolloDuoSlideView(snapshot, 0, travel, 0.32, ^{
                [snapshot removeFromSuperview];
                if (weakHost.postsTransitionSnapshot == snapshot) weakHost.postsTransitionSnapshot = nil;
                ApolloDuoSplitScheduleUpdate();
            });
        }
    }
    [CATransaction commit];
}

// Creating/removing the comments column is a containment transition. Animate
// that layout together with the page: the retained live feed must resize as
// comments enter/leave, not jump to its final width before a snapshot slides.
// Once both columns exist, Apollo's native navigation animator owns pushes.
// Closing (page == nil) is shared with the interactive gestures through
// ApolloDuoPostsCloseDetail. Opening takes the thread's pages: one for a new
// thread, or a closed thread with the pages pushed over it, brought back.
static void ApolloDuoPostsOpenDetail(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages, BOOL animated,
                                     ApolloDuoPostsCloseHandoff *handoff);
static void ApolloDuoPostsSetDetail(ApolloDuoSplitState *state, UIViewController *page, BOOL animated) {
    if (!page) {
        ApolloDuoPostsCloseDetail(state, nil, animated);
        return;
    }
    ApolloDuoPostsOpenDetail(state, @[page], animated, nil);
}

// `handoff` is a committed forward swipe's: its page, already springing onto
// the pane, stays over the live thread, which runs the same spring under it
// instead of the open's slide, and the feed narrows in the slide's remaining time.
static void ApolloDuoPostsOpenDetail(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages, BOOL animated,
                                     ApolloDuoPostsCloseHandoff *handoff) {
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventThreadOpened, 0.0);
    if (state.interactiveClose && state.interactiveClose != handoff) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    UIView *surface = state.host.view;
    BOOL animate = animated && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    if (!animate) {
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    }
    UIViewController *backstop = state.secondary.viewControllers.firstObject;
    // A handed-in overlay is the live drag's; it becomes the transition snapshot.
    if (handoff.overlay) {
        state.host.postsTransitionSnapshot = handoff.overlay;
    } else {
        [state.host.postsTransitionSnapshot removeFromSuperview];
        state.host.postsTransitionSnapshot = nil;
    }
    [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    NSArray<UIViewController *> *stack = [@[backstop] arrayByAddingObjectsFromArray:pages];
    if (state.host.postsShowingDetail) {
        [surface layoutIfNeeded];
        [state.secondary setViewControllers:stack animated:animate];
        return;
    }

    [surface layoutIfNeeded];
    NSArray<ApolloDuoPostsGeometry *> *feedGeometry = animate
        ? ApolloDuoPostsCaptureGeometry(state.feed.view, surface) : nil;
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    ApolloDuoFeedAnchor *feedAnchor = ApolloDuoCaptureFeedAnchor(
        ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded));
    ApolloDuoPostsHoldIndicator(ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded));
    void (^updateColumns)(void) = ^{
        // UIKit installs the moved column's views as it lays them out.
        sDuoSplitMovingColumns++;
        state.changing = YES;
        [state.secondary setViewControllers:stack animated:NO];
        state.changing = NO;
        ApolloDuoPostsSyncColumns(state);
        [surface layoutIfNeeded];
        sDuoSplitMovingColumns--;
        ApolloNativeFeedSearchFinishColumnMove(state.feed.topViewController);
        // A thread brought back has its palette repaired as the feed has
        // (a page opened fresh was never noted, and is left alone).
        ApolloNativeFeedSearchFinishColumnMove(pages.lastObject);
        // Texture schedules its row geometry separately from UIKit's column
        // layout. Commit the existing measurement before taking endpoints so
        // cell/media widths participate in the same resize as their live nav.
        UITableView *table = ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded);
        ApolloDuoMediaPrepareTableForTransition(table);
        SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
        if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
        [table layoutIfNeeded];
        // Anchor before the geometry replay reads its endpoints, so rows
        // glide to where the reader's place stays put instead of jumping.
        if (feedAnchor) {
            ApolloDuoRestoreFeedAnchor(table, feedAnchor);
            [table layoutIfNeeded];
        }
        ApolloDuoPostsHoldIndicator(ApolloDuoSplitFindTable(pages.lastObject.viewIfLoaded));
    };
    if (!animate) {
        [UIView performWithoutAnimation:updateColumns];
        // Reduce Motion: a short fade of the dragged page over the thread now in place.
        if (handoff) ApolloDuoPostsFadeHandoff(state, handoff, animated && surface.window ? 0.15 : 0.0);
        return;
    }
    // Finish containment with UIKit animation disabled (see the close path).
    [UIView performWithoutAnimation:updateColumns];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ ApolloDuoSplitScheduleUpdate(); }];
    // The rows get taller as the feed narrows: final-layout text would hang
    // below a row still growing, over the next one. Replay it as before.
    NSTimeInterval duration = handoff ? ApolloDuoPostsCloseRemaining(CACurrentMediaTime() - handoff.slideStarted) : 0.32;
    sDuoReplayCrossfadeCeiling = handoff.overlay;
    if (duration > 0) ApolloDuoPostsAnimateGeometry(feedGeometry, state.feed.view, surface, duration);
    sDuoReplayCrossfadeCeiling = nil;
    if (handoff) {
        // The live thread arrives on the dragged page's own spring, started
        // at the same moment, so the page covers it exactly until it lands.
        CALayer *layer = state.secondary.view.layer;
        CASpringAnimation *slide = ApolloDuoPostsSpring(@"transform",
            [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(handoff.slideFrom, 0, 0)],
            [NSValue valueWithCATransform3D:CATransform3DIdentity], handoff.slideSpring);
        slide.beginTime = [layer convertTime:handoff.slideStarted fromLayer:nil];
        [layer addAnimation:slide forKey:@"ApolloDuoSlide"];
        ApolloLog(@"[DuoSplit] interactive restore hand-off: replay=%.3f", duration);
    } else {
        // Use the live navigation surface so async comment/media updates
        // remain visible throughout the first push.
        CGRect incomingPane = ApolloDuoPostsDetailPane(state);
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(incomingPane);
        if (!CGRectIsNull(incomingPane) && travel > 0)
            ApolloDuoSlideView(state.secondary.view, travel, 0, 0.32, nil);
    }
    [CATransaction commit];
}

// The forward swipe on the full-width Posts feed brings back the thread the
// last close took from beside it, through the normal open: the same pages
// (reading position, reply text and all), not a fresh load. A stale memory
// that no event caught is forgotten here, the first time a swipe asks.
// The restore that follows the finger is no drag in the way of its own thread.
BOOL ApolloDuoSplitCanRestoreClosedThread(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.closedThread || state.feed != nav || !state.split || state.changing || state.postsTogglingSplit) return NO;
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventCheck, 0.0);
    ApolloDuoPostsCloseHandoff *drag = state.interactiveClose;
    BOOL ownDrag = drag.restoring && drag.phase == ApolloDuoPostsClosePhaseTracking && drag.navigation == nav;
    return state.closedThread && (!drag || ownDrag) && !state.host.listVisible && !state.host.postsShowingDetail
        && state.secondary.viewControllers.count == 1;
}

static BOOL ApolloDuoPostsRestoreClosedThread(ApolloDuoSplitState *state, UINavigationController *nav,
                                              ApolloDuoPostsCloseHandoff *handoff) {
    if (!ApolloDuoSplitCanRestoreClosedThread(nav)) return NO;
    NSArray<UIViewController *> *pages = state.closedThread.pages;
    state.closedThread = nil;
    if (sDuoPostsClosedThreadState == state) sDuoPostsClosedThreadState = nil;
    ApolloLog(@"[DuoSplit] restored the closed thread (%lu page(s)) beside the feed", (unsigned long)pages.count);
    ApolloDuoPostsOpenDetail(state, pages, YES, handoff);
    ApolloDuoPostsSyncColumns(state);
    return YES;
}

BOOL ApolloDuoSplitRestoreClosedThread(UINavigationController *nav) {
    return ApolloDuoPostsRestoreClosedThread(ApolloDuoSplitStateForNavigation(nav, NO), nav, nil);
}

// The Posts thread close that follows the finger (research 3.B). While the
// finger is down only views made for the drag move: the thread pane's
// snapshot slides by the drag and the gap it uncovers is filled from the
// feed's trailing edge. The live thread stays in place, covered and
// untouched, so a cancel costs no layout and no appearance callbacks. A
// commit hands the rest of the slide to Core Animation, covers the feed and
// runs the shared close (ApolloDuoPostsCloseDetail) under those covers.
static __weak ApolloDuoSplitState *sDuoPostsInteractiveClose;

static void ApolloDuoPostsCloseAdvance(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *drag,
                                       ApolloDuoPostsCloseEvent event) {
    drag.phase = ApolloDuoPostsClosePhaseAfter(drag.phase, event);
    if (drag.phase != ApolloDuoPostsClosePhaseIdle) {
        state.interactiveClose = drag;
        sDuoPostsInteractiveClose = state;
    } else if (state.interactiveClose == drag) {
        state.interactiveClose = nil;
        if (sDuoPostsInteractiveClose == state) sDuoPostsInteractiveClose = nil;
    }
}

// The drag `nav` began, while it still follows the finger.
static ApolloDuoPostsCloseHandoff *ApolloDuoPostsTrackingClose(ApolloDuoSplitState *state, UINavigationController *nav) {
    ApolloDuoPostsCloseHandoff *drag = state.interactiveClose;
    return drag.phase == ApolloDuoPostsClosePhaseTracking && !drag.dividing && drag.navigation == nav ? drag : nil;
}

// Releases short of the threshold spring back over the live thread (a fade
// with Reduce Motion); interruptions remove the drag at once. Neither lays
// anything out or touches the live thread.
static void ApolloDuoPostsCancelInteractiveClose(ApolloDuoSplitState *state, BOOL animated, CGFloat velocity) {
    ApolloDuoPostsCloseHandoff *drag = state.interactiveClose;
    if (!drag) return;
    ApolloDuoSplitHost *host = state.host;
    NSString *kind = drag.dividing ? @"divider drag" : drag.restoring ? @"thread restore" : @"thread close";
    // The divider's drag never springs back here: its release snaps (ApolloDuoSplitDividerFinish).
    if (!animated || drag.dividing || drag.phase != ApolloDuoPostsClosePhaseTracking || !drag.overlay.window) {
        ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventInterrupt);
        ApolloDuoPostsRemoveOverlay(host, drag.overlay);
        ApolloLog(@"[DuoSplit] interactive %@ removed", kind);
        // The grabber and the press go with it.
        if (drag.dividing) ApolloDuoSplitDividerLetGo(host.viewIfLoaded);
        ApolloDuoSplitScheduleUpdate();
        return;
    }
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventSpringBack);
    __weak ApolloDuoSplitState *weakState = state;
    __weak ApolloDuoSplitHost *weakHost = host;
    dispatch_block_t returned = ^{
        ApolloDuoSplitState *live = weakState;
        if (live.interactiveClose == drag) ApolloDuoPostsCloseAdvance(live, drag, ApolloDuoPostsCloseEventReturned);
        ApolloDuoPostsRemoveOverlay(weakHost, drag.overlay);
        ApolloDuoSplitScheduleUpdate();
    };
    ApolloLog(@"[DuoSplit] interactive %@ springs back", kind);
    if (UIAccessibilityIsReduceMotionEnabled()) {
        UIView *overlay = drag.overlay;
        [UIView animateWithDuration:0.15 animations:^{ overlay.alpha = 0; }
                         completion:^(__unused BOOL finished) { returned(); }];
    } else {
        ApolloDuoPostsSpringDrag(drag, ApolloDuoPostsDragTarget(drag.restoring, NO, drag.travel), velocity, returned);
    }
}

static void ApolloDuoPostsCancelActiveInteractiveClose(void) {
    ApolloDuoSplitState *state = sDuoPostsInteractiveClose;
    if (state) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    // The same interruptions let a list pulled in with the finger go.
    [sDuoListDragHost cancelListDragNow];
}

static void ApolloDuoPostsCancelInteractiveCloseForHost(ApolloDuoSplitHost *host) {
    ApolloDuoSplitState *state = sDuoPostsInteractiveClose;
    if (state && state.host == host) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    [host cancelListDragNow];
}

// Apollo's own Back shadow on the departing page (ApolloInterruptibleNavTransition.xm),
// on a plain view around the snapshot so the snapshot's own layer stays as UIKit made it.
static UIView *ApolloDuoPostsShadowedPage(UIView *snapshot, CGRect pane, UITraitCollection *traits) {
    UIView *page = [[UIView alloc] initWithFrame:pane];
    page.userInteractionEnabled = NO;
    page.clipsToBounds = NO;
    snapshot.frame = page.bounds;
    snapshot.userInteractionEnabled = NO;
    [page addSubview:snapshot];
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    CALayer *layer = page.layer;
    layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:dark ? 0.05 : 0.25].CGColor;
    layer.shadowOffset = CGSizeMake(-5.0, 0.0);
    layer.shadowRadius = 4.0;
    layer.shadowOpacity = ApolloDuoPostsCloseShadowOpacity(0.0);
    layer.shadowPath = [UIBezierPath bezierPathWithRect:page.bounds].CGPath;
    return page;
}

// The color behind the feed's rows at its trailing edge: the deepest opaque
// layer under a point just inside that edge, on the row nearest the middle
// that is not the open post's (selected or highlighted). Layers, not views,
// so layer-backed Texture backgrounds count. nil when nothing there is opaque.
static UIColor *ApolloDuoPostsRowColor(UITableView *table, CGFloat x) {
    CGFloat middle = CGRectGetMidY(table.bounds);
    UITableViewCell *sample = nil;
    for (UITableViewCell *cell in table.visibleCells) {
        if (cell.selected || cell.highlighted || cell.hidden || CGRectGetHeight(cell.frame) < 4.0) continue;
        if (!sample || fabs(CGRectGetMidY(cell.frame) - middle) < fabs(CGRectGetMidY(sample.frame) - middle)) sample = cell;
    }
    if (!sample) return nil;
    CALayer *layer = sample.layer;
    CGPoint point = [table.layer convertPoint:CGPointMake(x, CGRectGetMidY(sample.frame)) toLayer:layer];
    CGColorRef color = NULL;
    while (layer) {
        if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0.99) color = layer.backgroundColor;
        CALayer *next = nil;
        for (CALayer *sublayer in layer.sublayers.reverseObjectEnumerator) {
            if (sublayer.hidden || sublayer.opacity < 0.99) continue;
            CGPoint inner = [layer convertPoint:point toLayer:sublayer];
            if (!CGRectContainsPoint(sublayer.bounds, inner)) continue;
            next = sublayer;
            point = inner;
            break;
        }
        layer = next;
    }
    return color ? [UIColor colorWithCGColor:color] : nil;
}

// The gap the thread uncovers continues the feed: its rows' own color, and
// across the bar band above them the feed's trailing edge, one point
// stretched, so the glass bar carries on and text never distorts. Rows are
// never stretched: whatever reaches that column (the open post's highlight,
// a more button) would become a band or a line across the gap. Where the
// band cannot be captured, the flat color fills it too.
// Laid out once at the full travel; the drag scales it from its leading edge.
static UIView *ApolloDuoPostsCloseExtension(ApolloDuoSplitState *state, UIView *surface, CGRect pane, CGFloat travel) {
    UIView *extension = [UIView new];
    UIView *feed = state.feed.view, *page = state.feed.topViewController.viewIfLoaded;
    UITableView *table = ApolloDuoSplitFindTable(page);
    CGFloat edge = MIN(CGRectGetMinX(pane), CGRectGetMaxX([surface convertRect:feed.bounds fromView:feed]));
    UIColor *rows = table ? ApolloDuoPostsRowColor(table, [table convertPoint:CGPointMake(edge - 2.0, 0) fromView:surface].x) : nil;
    UIColor *tableColor = CGColorGetAlpha(table.backgroundColor.CGColor) > 0.99 ? table.backgroundColor : nil;
    extension.backgroundColor = rows ?: tableColor ?: ApolloThemePageBackgroundColor()
        ?: UIColor.systemGroupedBackgroundColor;
    if (page) {
        CGFloat contentTop = [surface convertPoint:CGPointMake(0, page.safeAreaInsets.top) fromView:page].y;
        CGRect band = ApolloDuoPostsCloseSmearBand(ApolloDuoPostsCloseSmearColumn(edge, pane), contentTop);
        UIView *smear = !CGRectIsNull(band) && CGRectGetMinX(band) >= CGRectGetMinX(surface.bounds)
            ? [surface resizableSnapshotViewFromRect:band afterScreenUpdates:NO withCapInsets:UIEdgeInsetsMake(0, 1, 0, 1)] : nil;
        if (smear) {
            smear.frame = CGRectMake(0, 0, travel, CGRectGetHeight(band));
            smear.userInteractionEnabled = NO;
            [extension addSubview:smear];
        }
    }
    extension.userInteractionEnabled = NO;
    extension.layer.anchorPoint = CGPointMake(0.0, 0.5);
    extension.frame = ApolloDuoPostsCloseExtensionFrame(pane, travel);
    extension.transform = CGAffineTransformMakeScale(ApolloDuoPostsCloseExtensionScale(0.0, travel), 1);
    return extension;
}

// The thread pane's drag views over the live columns: its snapshot with
// Apollo's Back shadow, the gap it uncovers and the clear overlay holding
// them, which takes every new touch. nil when the pane can't be captured.
static ApolloDuoPostsCloseHandoff *ApolloDuoPostsNewPaneDrag(ApolloDuoSplitState *state) {
    ApolloDuoSplitHost *host = state.host;
    UIView *surface = host.view;
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    [surface layoutIfNeeded];
    CGRect pane = ApolloDuoPostsDetailPane(state);
    if (CGRectIsNull(pane) || CGRectIsEmpty(pane)) return nil;
    // The same capture the close uses: the thread with its bar and chrome,
    // not the tab rail, which stays on top.
    UIView *snapshot = [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if (!snapshot) return nil;
    ApolloDuoPostsCloseHandoff *drag = [ApolloDuoPostsCloseHandoff new];
    drag.pane = pane;
    // A second capture of the same moment for the closed thread's memory:
    // the first one slides off with the drag.
    drag.restoreSnapshot = [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    drag.travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
    drag.extension = ApolloDuoPostsCloseExtension(state, surface, pane, drag.travel);
    drag.snapshot = ApolloDuoPostsShadowedPage(snapshot, pane, surface.traitCollection);
    drag.overlay = [[UIView alloc] initWithFrame:surface.bounds];
    drag.overlay.backgroundColor = UIColor.clearColor;
    drag.overlay.accessibilityElementsHidden = YES;
    [drag.overlay addSubview:drag.extension];
    [drag.overlay addSubview:drag.snapshot];
    [host.postsTransitionSnapshot removeFromSuperview];
    [surface insertSubview:drag.overlay belowSubview:host.listDismiss];
    host.postsTransitionSnapshot = drag.overlay;
    return drag;
}

BOOL ApolloDuoSplitInteractiveCloseBegin(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoSplitHost *host = state.host;
    UIView *surface = host.view;
    // A drag still springing back is let go; the new one snapshots afresh.
    ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    // The thread right above the backstop, beside the feed, and nothing else
    // moving the panes: an open still sliding in, a toggle, a native pop or
    // a resize leaves this Back to the discrete close on release.
    BOOL closable = state.split && state.feed && !state.changing && !state.postsTogglingSplit
        && host.postsColumnsPaired && !host.listVisible && state.secondary.viewControllers.count == 2
        && nav == state.secondary && surface.window && !sDuoSplitResizingTabs
        && !state.feed.transitionCoordinator && !state.secondary.transitionCoordinator
        && !host.postsTransitionSnapshot.window && ![state.secondary.view.layer animationForKey:@"ApolloDuoSlide"];
    if (!closable) return NO;
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsNewPaneDrag(state);
    if (!drag) return NO;
    drag.navigation = nav;
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventBegin);
    ApolloLog(@"[DuoSplit] interactive thread close began; smear=%d", drag.extension.subviews.count > 0);
    return YES;
}

// Either direction's drag, while the finger moves.
static BOOL ApolloDuoPostsUpdateDrag(UINavigationController *nav, CGFloat translation, BOOL restoring) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsTrackingClose(state, nav);
    if (!drag || drag.restoring != restoring) return NO;
    if (!drag.overlay.window) {
        ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
        return NO;
    }
    // Transforms only: no layout and no Texture work while the finger moves.
    CGFloat offset = ApolloDuoPostsDragOffset(restoring, translation, drag.travel);
    drag.snapshot.transform = CGAffineTransformMakeTranslation(offset, 0);
    drag.extension.transform = CGAffineTransformMakeScale(ApolloDuoPostsCloseExtensionScale(offset, drag.travel), 1);
    drag.snapshot.layer.shadowOpacity = ApolloDuoPostsCloseShadowOpacity(
        ApolloDuoPostsCloseProgress(offset, CGRectGetWidth(drag.pane)));
    return YES;
}

BOOL ApolloDuoSplitInteractiveCloseUpdate(UINavigationController *nav, CGFloat translation) {
    return ApolloDuoPostsUpdateDrag(nav, translation, NO);
}

// A drag let go past its threshold becomes the close: the render server takes
// the rest of the slide, a picture of the feed covers its re-layout, and the
// shared close (ApolloDuoPostsCloseDetail) runs under both.
static void ApolloDuoPostsCommitInteractiveClose(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *drag, CGFloat velocity) {
    UIView *surface = state.host.view;
    // Cleared first: the close below syncs the columns, which the flag holds off.
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventCommit);
    drag.velocity = velocity;
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        // The render server owns the rest of the slide before the main thread
        // stalls in the close's re-layout and Texture re-measure.
        ApolloDuoPostsSlideHandoff(state, drag);
        [CATransaction flush];
    }
    CGRect feedRect = CGRectMake(0, 0, CGRectGetMinX(drag.pane), CGRectGetHeight(surface.bounds));
    UIView *cover = CGRectGetWidth(feedRect) > 0
        ? [surface resizableSnapshotViewFromRect:feedRect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
    if (cover) {
        cover.frame = feedRect;
        cover.userInteractionEnabled = NO;
        [drag.overlay insertSubview:cover belowSubview:drag.snapshot];
        drag.cover = cover;
    }
    [CATransaction flush];
    // From here it is the close's transition: touches reach the full-width
    // feed under it, as during the button close's slide.
    drag.overlay.userInteractionEnabled = NO;
    ApolloDuoPostsCloseDetail(state, drag, YES);
}

void ApolloDuoSplitInteractiveCloseFinish(UINavigationController *nav, BOOL commit, CGFloat velocity) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsTrackingClose(state, nav);
    if (!drag || drag.restoring) return;
    BOOL closes = state.split && state.feed && !state.changing && !state.postsTogglingSplit
        && state.secondary.viewControllers.count == 2 && drag.overlay.window;
    if (!commit || !closes) {
        // A commit the split no longer allows was overtaken: remove it at once.
        ApolloDuoPostsCancelInteractiveClose(state, !commit, velocity);
        return;
    }
    ApolloLog(@"[DuoSplit] interactive thread close committed; velocity=%.0f", velocity);
    ApolloDuoPostsCommitInteractiveClose(state, drag, velocity);
}

void ApolloDuoSplitInteractiveCloseCancel(UINavigationController *nav, BOOL animated) {
    // The pane's navigation is gone: whatever drag is active still goes, so
    // its full-screen touch shield can never stay up.
    if (!nav) {
        ApolloDuoPostsCancelActiveInteractiveClose();
        return;
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (state.interactiveClose.navigation == nav) ApolloDuoPostsCancelInteractiveClose(state, animated, 0.0);
}

// The Posts divider pressed and dragged (ApolloDuoSplitDivider.m) is the
// thread close's drag with the divider as its offset, either way. While the
// finger is down only pictures move, never the columns: a column width
// re-lays out both panes and re-measures every Texture row, too much for
// every frame of a drag (worst with the feed at a quarter of the screen).
// The thread pane's snapshot follows the divider over the live feed, as in
// the close. Rightward the close's gap continues the feed; leftward the
// thread covers the feed and its trailing edge widens in its own color. The
// columns are laid out once, on release: a landing re-pins them where the
// divider was let go (ApolloDuoSplitApplyPostsStop) under the pictures
// springing to it, a close past the right limit commits the drag as the
// close's own, and full screen
// runs the split toggle. The close's interruptions (a fold, a resize, the
// hinge, a tab switch, a sheet, disappearing, resigning) remove it the same
// way, and so does any other close.

// UIKit's own tap on the column separator (iOS 26's column resize tap,
// _handleResizeColumnToPreferredSizeTapGestureRecognizer:) is what acts on a
// tap at the divider; no Duo gesture handles a tap there. With the
// adjustable split on a tap on the divider does nothing: that tap stays off
// until the setting is turned off again.
static NSString *const kApolloDuoSeparatorTapName = @"com.apple.UIKit.UISplitViewController.ColumnResizeTapGestureRecognizer";

// The separator is the split's own view, not the columns' pages: search only
// around them.
static UIGestureRecognizer *ApolloDuoPostsFindSeparatorTap(ApolloDuoSplitState *state) {
    UIView *root = state.split.viewIfLoaded;
    UIView *feed = state.feed.viewIfLoaded, *thread = state.secondary.viewIfLoaded, *list = state.primary.viewIfLoaded;
    NSArray<UIView *> *level = root ? @[root] : @[];
    for (NSUInteger depth = 0; depth < 5 && level.count; depth++) {
        NSMutableArray<UIView *> *next = [NSMutableArray array];
        for (UIView *view in level) {
            for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
                if ([gesture.name isEqualToString:kApolloDuoSeparatorTapName]) return gesture;
            }
            for (UIView *subview in view.subviews) {
                if (subview != feed && subview != thread && subview != list) [next addObject:subview];
            }
        }
        level = next;
    }
    return nil;
}

static void ApolloDuoPostsSyncSeparatorTap(ApolloDuoSplitState *state, BOOL adjustable) {
    if (!adjustable && !state.separatorTapDisabled) return;
    UIGestureRecognizer *tap = state.separatorTap;
    if (!tap.view) {
        tap = ApolloDuoPostsFindSeparatorTap(state);
        state.separatorTap = tap;
    }
    if (!adjustable) {
        tap.enabled = YES;
        state.separatorTapDisabled = NO;
        return;
    }
    if (!tap.enabled) return;
    tap.enabled = NO;
    state.separatorTapDisabled = YES;
    ApolloLog(@"[DuoSplit] adjustable split: UIKit's separator tap is off");
}

static ApolloDuoSplitState *ApolloDuoPostsStateForHostView(UIView *view) {
    ApolloDuoSplitHost *host = [view.nextResponder isKindOfClass:ApolloDuoSplitHost.class] ? (id)view.nextResponder : nil;
    ApolloDuoSplitState *state = host.postsNavigation ? ApolloDuoSplitStateForNavigation(host.postsNavigation, NO) : nil;
    return state.host == host && state.feed ? state : nil;
}

static void ApolloDuoPostsFinishSettle(ApolloDuoSplitState *state);

// A thread open beside the feed in the landscape Posts split, and nothing
// else moving the panes: a column change, a toggle, the drawer, a resize, a push.
static BOOL ApolloDuoPostsDividerMovable(ApolloDuoSplitState *state) {
    ApolloDuoSplitHost *host = state.host;
    return state.split && state.feed && !state.changing && !state.postsTogglingSplit
        && host.postsColumnsPaired && !host.listVisible && !host.listDragging
        && state.secondary.viewControllers.count > 1 && host.viewIfLoaded.window && !sDuoSplitResizingTabs
        && ApolloDuoPostsHasLandscapeColumns(state)
        && !state.feed.transitionCoordinator && !state.secondary.transitionCoordinator;
}

CGFloat ApolloDuoSplitDividerPosition(UIView *view, BOOL *adjustable) {
    ApolloDuoSplitState *state = ApolloDuoPostsStateForHostView(view);
    BOOL on = state && ApolloDuoPostsAdjustableSplit();
    if (adjustable) *adjustable = on;
    // Off, the divider is UIKit's as before; only a separator tap turned off
    // while on still needs giving back.
    if (!on && !state.separatorTapDisabled) return -1.0;
    if (!state || !ApolloDuoPostsDividerMovable(state)) return -1.0;
    ApolloDuoPostsSyncSeparatorTap(state, on);
    // A divider settle still running ends at once, so a press on the divider
    // is never refused for it.
    ApolloDuoPostsFinishSettle(state);
    // A close or a restore still finishing holds the panes.
    if (state.interactiveClose || state.host.postsTransitionSnapshot.window) return -1.0;
    CGRect pane = ApolloDuoPostsDetailPane(state);
    if (CGRectIsNull(pane) || CGRectIsEmpty(pane)) return -1.0;
    // A thread UIKit laid out under the feed (its pane starting at the screen's
    // edge, not at the feed's) has no divider to hold.
    CGFloat divider = CGRectGetMinX(pane);
    return fabs(divider - ApolloDuoPostsSplitDivider(state)) > 2.0 ? -1.0 : divider;
}

BOOL ApolloDuoSplitDividerBegin(UIView *view) {
    ApolloDuoSplitState *state = ApolloDuoPostsStateForHostView(view);
    if (!state) return NO;
    UIView *surface = state.host.view;
    // A divider settle still running ends at once: the new drag begins from
    // where the divider really is, never ignored.
    ApolloDuoPostsFinishSettle(state);
    // Another drag, or a close or restore still finishing, holds the panes.
    if (!ApolloDuoPostsAdjustableSplit() || !ApolloDuoPostsDividerMovable(state) || state.interactiveClose
        || state.host.postsTransitionSnapshot.window
        || [state.secondary.view.layer animationForKey:@"ApolloDuoSlide"]) return NO;
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsNewPaneDrag(state);
    if (!drag) return NO;
    drag.dividing = YES;
    CGRect pane = drag.pane;
    // Leftward the thread outgrows its picture: its trailing edge widens in
    // its rows' own color, as far as the feed is wide.
    CGFloat growth = CGRectGetMinX(pane);
    UITableView *table = ApolloDuoSplitFindTable(state.secondary.topViewController.viewIfLoaded);
    CGFloat edge = CGRectGetMaxX(pane) - state.secondary.view.safeAreaInsets.right - 2.0;
    UIColor *rows = table ? ApolloDuoPostsRowColor(table, [table convertPoint:CGPointMake(edge, 0) fromView:surface].x) : nil;
    UIColor *tableColor = CGColorGetAlpha(table.backgroundColor.CGColor) > 0.99 ? table.backgroundColor : nil;
    UIView *fill = [UIView new];
    fill.backgroundColor = rows ?: tableColor ?: ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    fill.userInteractionEnabled = NO;
    fill.layer.anchorPoint = CGPointMake(1.0, 0.5);
    fill.frame = CGRectMake(CGRectGetMaxX(pane) - growth, CGRectGetMinY(pane), growth, CGRectGetHeight(pane));
    fill.transform = CGAffineTransformMakeScale(ApolloDuoPostsCloseExtensionScale(0.0, growth), 1);
    [drag.overlay insertSubview:fill belowSubview:drag.snapshot];
    drag.fill = fill;
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventBegin);
    ApolloLog(@"[DuoSplit] divider drag began at %.0f of %.0f", CGRectGetMinX(pane), CGRectGetWidth(surface.bounds));
    return YES;
}

static ApolloDuoPostsCloseHandoff *ApolloDuoPostsDividerDrag(ApolloDuoSplitState *state) {
    ApolloDuoPostsCloseHandoff *drag = state.interactiveClose;
    return drag.dividing && drag.phase == ApolloDuoPostsClosePhaseTracking ? drag : nil;
}

// The divider `offset` from the thread pane's place. Transforms only: no
// layout and no Texture work while the finger moves.
static void ApolloDuoPostsPlaceDivider(ApolloDuoPostsCloseHandoff *drag, CGFloat offset) {
    drag.snapshot.transform = CGAffineTransformMakeTranslation(offset, 0);
    drag.extension.transform = CGAffineTransformMakeScale(ApolloDuoPostsCloseExtensionScale(offset, drag.travel), 1);
    drag.fill.transform = CGAffineTransformMakeScale(ApolloDuoPostsCloseExtensionScale(-offset, CGRectGetMinX(drag.pane)), 1);
    drag.snapshot.layer.shadowOpacity = ApolloDuoPostsCloseShadowOpacity(
        ApolloDuoPostsCloseProgress(offset, CGRectGetWidth(drag.pane)));
}

// The setting turned off, the thread closed or the columns changed under the
// finger: the drag goes at once.
static BOOL ApolloDuoPostsDividerHolds(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *drag) {
    if (drag.overlay.window && ApolloDuoPostsAdjustableSplit() && ApolloDuoPostsDividerMovable(state)) return YES;
    ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    return NO;
}

BOOL ApolloDuoSplitDividerUpdate(UIView *view, CGFloat dividerX) {
    ApolloDuoSplitState *state = ApolloDuoPostsStateForHostView(view);
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsDividerDrag(state);
    if (!drag || !ApolloDuoPostsDividerHolds(state, drag)) return NO;
    ApolloDuoPostsPlaceDivider(drag, dividerX - CGRectGetMinX(drag.pane));
    return YES;
}

// Set while a landing lays the columns out (ApolloDuoSplitApplyPostsStop).
static BOOL sDuoPostsApplyUnanimated;

// A landing's spring: critically damped like the close's, but quicker, and
// ended at a known time, so the reveal never waits out a tail.
static const CGFloat kApolloDuoPostsLandingOmega = 2.0 * M_PI / 0.2;
static const NSTimeInterval kApolloDuoPostsLandingDuration = 0.26;
// A landing this near where the pictures already are has nothing to spring.
static const CGFloat kApolloDuoPostsLandingTravel = 8.0;

// The settle in flight, if any: its overlay and the cut that ends it. A new
// drag on the divider ends it at once (ApolloDuoPostsFinishSettle) instead of
// being ignored until the pictures are gone.
static __weak UIView *sDuoPostsSettleOverlay;
static dispatch_block_t sDuoPostsSettleCut;

// The pictures go in one frame: no fade and no effect, the columns having
// been laid out and committed under them at the landing width. Idempotent.
static void ApolloDuoPostsFinishSettle(ApolloDuoSplitState *state) {
    UIView *overlay = sDuoPostsSettleOverlay;
    dispatch_block_t cut = sDuoPostsSettleCut;
    if (!overlay || !cut || state.host.postsTransitionSnapshot != overlay) return;
    ApolloLog(@"[DuoSplit] a new divider drag ended the settle in flight");
    cut();
}

// A landing or full screen: the render server owns what the pictures do from
// here, flushed before the expensive part (`relayout`, the column change,
// which stalls the main thread for a Texture re-measure), as the close's
// commit does. Where the pictures have a way to go they spring there and are
// cut once they land; where they are already in place (a plain landing) they
// are cut as soon as the columns under them are committed. Touches go
// through, Reduce Motion or not.
static void ApolloDuoPostsSettleDivider(ApolloDuoSplitState *state, ApolloDuoPostsCloseHandoff *drag, CGFloat offset,
                                        CGFloat velocity, dispatch_block_t relayout) {
    __weak ApolloDuoSplitHost *weakHost = state.host;
    UIView *overlay = drag.overlay;
    overlay.userInteractionEnabled = NO;
    __block BOOL cutDone = NO;
    dispatch_block_t cut = ^{
        if (cutDone) return;
        cutDone = YES;
        if (sDuoPostsSettleOverlay == overlay) {
            sDuoPostsSettleOverlay = nil;
            sDuoPostsSettleCut = nil;
        }
        ApolloDuoPostsRemoveOverlay(weakHost, overlay);
        ApolloDuoSplitScheduleUpdate();
    };
    sDuoPostsSettleOverlay = overlay;
    sDuoPostsSettleCut = cut;
    CGFloat shown = drag.snapshot.transform.tx;
    if (UIAccessibilityIsReduceMotionEnabled() || !overlay.window || fabs(offset - shown) < kApolloDuoPostsLandingTravel) {
        if (overlay.window && !UIAccessibilityIsReduceMotionEnabled()) [CATransaction flush];
        if (relayout) relayout();
        // Committed first, so the cut shows the new columns and nothing between.
        [CATransaction flush];
        dispatch_async(dispatch_get_main_queue(), cut);
        return;
    }
    ApolloDuoPostsSpringDragWith(drag, offset, velocity, kApolloDuoPostsLandingOmega, kApolloDuoPostsLandingDuration, cut);
    [CATransaction flush];
    if (relayout) relayout();
}

void ApolloDuoSplitDividerFinish(UIView *view, CGFloat dividerX, CGFloat velocityX) {
    ApolloDuoSplitState *state = ApolloDuoPostsStateForHostView(view);
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsDividerDrag(state);
    if (!drag || !ApolloDuoPostsDividerHolds(state, drag)) return;
    ApolloDuoSplitHost *host = state.host;
    CGSize canvas = host.view.bounds.size;
    CGFloat divider = CGRectGetMinX(drag.pane);
    ApolloDuoPostsPlaceDivider(drag, dividerX - divider);
    ApolloDuoSplitRelease release = ApolloDuoSplitReleaseFor(dividerX, velocityX, canvas.width,
                                                             ApolloDuoPostsFoldX(state, canvas),
                                                             ApolloDuoPostsTrailingInset(state),
                                                             kApolloDuoPostsWideStopThread);
    // Closing the thread and full screen leave the remembered position as it was.
    if (release.closesThread) {
        ApolloLog(@"[DuoSplit] divider let go at %.0f, %.0f pt/s: close the thread", dividerX, velocityX);
        // Past the right limit it is the close's drag: the same slide off the pane.
        [drag.fill removeFromSuperview];
        drag.fill = nil;
        ApolloDuoPostsCommitInteractiveClose(state, drag, velocityX);
        return;
    }
    if (release.fullScreen) {
        // Cleared first: the toggle syncs the columns, which the flag holds off.
        ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventInterrupt);
        // The toggle clears the host's transition picture; the drag's
        // pictures cover its column change instead.
        UIView *overlay = drag.overlay;
        BOOL wasSplit = host.postsSplitEnabled;
        ApolloLog(@"[DuoSplit] divider let go at %.0f, %.0f pt/s: full screen", dividerX, velocityX);
        ApolloDuoPostsSettleDivider(state, drag, wasSplit ? -divider : 0.0, velocityX, ^{
            host.postsTransitionSnapshot = nil;
            ApolloDuoPostsToggleSplit(state);
            if (overlay.window && !host.postsTransitionSnapshot) host.postsTransitionSnapshot = overlay;
            if (wasSplit && host.postsSplitEnabled) ApolloLog(@"[DuoSplit] full screen refused, the pictures stay at the position");
        });
        return;
    }
    // A landing. Cleared first, so the position applies (it waits for no drag).
    // Half is stored as 0, so it follows the fold.
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventInterrupt);
    [NSUserDefaults.standardUserDefaults setDouble:release.share forKey:UDKeyDuoSplitFeedShare];
    // Where the columns will be, known before they are laid out.
    CGFloat target = ApolloDuoPostsWantedDivider(state, canvas);
    ApolloLog(@"[DuoSplit] divider let go at %.0f, %.0f pt/s: landed at %.0f (share %.3f)", dividerX, velocityX,
              target, release.share);
    ApolloDuoPostsSettleDivider(state, drag, target - divider, velocityX, ^{
        sDuoPostsApplyUnanimated = YES;
        ApolloDuoSplitApplyPostsStop(state.feed);
        sDuoPostsApplyUnanimated = NO;
    });
}

void ApolloDuoSplitDividerCancel(UIView *view) {
    ApolloDuoSplitState *state = ApolloDuoPostsStateForHostView(view);
    if (state.interactiveClose.dividing) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
}

// The same drag from the post itself: the thread pane's pan (the pane Back
// rightward, the forward swipe leftward) with Adjustable Split on. The pan's
// translation moves the divider from where it began, so the thread follows
// the finger either way; the release is the divider's own (a landing, the
// close or full screen), never the Back's threshold.
BOOL ApolloDuoSplitThreadDividerDrags(UINavigationController *nav) {
    return ApolloDuoPostsAdjustableSplit() && ApolloDuoSplitBackClosesThread(nav);
}

BOOL ApolloDuoSplitThreadDividerBegin(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.feed || nav != state.secondary) return NO;
    // A close still springing back is let go, as the close's own Begin does;
    // a divider drag already held (the press) keeps hold.
    if (state.interactiveClose && !ApolloDuoPostsDividerDrag(state)) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    if (!ApolloDuoSplitDividerBegin(state.host.view)) return NO;
    // The pan's own drag: the routine split update's sweep keeps it, as it
    // keeps a close that has a pane navigation.
    ApolloDuoPostsDividerDrag(state).navigation = nav;
    return YES;
}

// The divider `translation` from where the drag began, kept on the canvas.
static BOOL ApolloDuoPostsThreadDividerX(UINavigationController *nav, CGFloat translation, UIView **host,
                                         CGFloat *dividerX) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoPostsCloseHandoff *drag = state.feed && nav == state.secondary ? ApolloDuoPostsDividerDrag(state) : nil;
    if (!drag) return NO;
    *host = state.host.view;
    *dividerX = MIN(MAX(0.0, CGRectGetMinX(drag.pane) + translation), CGRectGetWidth(state.host.view.bounds));
    return YES;
}

BOOL ApolloDuoSplitThreadDividerUpdate(UINavigationController *nav, CGFloat translation) {
    UIView *host = nil;
    CGFloat dividerX = 0.0;
    return ApolloDuoPostsThreadDividerX(nav, translation, &host, &dividerX) && ApolloDuoSplitDividerUpdate(host, dividerX);
}

void ApolloDuoSplitThreadDividerFinish(UINavigationController *nav, CGFloat translation, CGFloat velocity) {
    UIView *host = nil;
    CGFloat dividerX = 0.0;
    if (ApolloDuoPostsThreadDividerX(nav, translation, &host, &dividerX)) ApolloDuoSplitDividerFinish(host, dividerX, velocity);
}

void ApolloDuoSplitThreadDividerCancel(UINavigationController *nav) {
    // The pane's navigation is gone: whatever drag is active still goes.
    if (!nav) {
        ApolloDuoPostsCancelActiveInteractiveClose();
        return;
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (state.interactiveClose.dividing) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
}

// The forward swipe's restore, the close's driver run the other way. The
// snapshot the close left waits fully off screen at the feed pane's trailing
// edge and comes in with the finger over the live full-width feed, which is
// not laid out or re-measured until the commit. The commit springs the page
// onto the pane and runs the existing restore (ApolloDuoPostsOpenDetail with
// the remembered pages) under it; a spring back leaves the thread remembered.
BOOL ApolloDuoSplitInteractiveRestoreBegin(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoSplitHost *host = state.host;
    UIView *surface = host.view;
    // Nothing else should be dragging here (the route refuses beside any other
    // drag, and the overlay takes second fingers); let a stray one go at once.
    ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    ApolloDuoPostsClosedThread *closed = state.closedThread;
    BOOL restorable = ApolloDuoSplitCanRestoreClosedThread(nav) && surface.window && !sDuoSplitResizingTabs
        && ApolloDuoClosedThreadSnapshotFits(closed.snapshot != nil, closed.canvas, surface.bounds.size,
                                             closed.divider, ApolloDuoPostsSplitDivider(state))
        && !CGRectIsNull(closed.pane) && !CGRectIsEmpty(closed.pane)
        && !nav.transitionCoordinator && !state.secondary.transitionCoordinator
        && !host.postsTransitionSnapshot.window && ![state.secondary.view.layer animationForKey:@"ApolloDuoSlide"];
    if (!restorable) return NO;
    ApolloDuoPostsCloseHandoff *drag = [ApolloDuoPostsCloseHandoff new];
    drag.restoring = YES;
    drag.navigation = nav;
    drag.pane = closed.pane;
    drag.travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(closed.pane);
    drag.snapshot = ApolloDuoPostsShadowedPage(closed.snapshot, closed.pane, surface.traitCollection);
    drag.snapshot.transform = CGAffineTransformMakeTranslation(drag.travel, 0);
    drag.snapshot.layer.shadowOpacity = ApolloDuoPostsCloseShadowOpacity(ApolloDuoPostsCloseProgress(drag.travel, CGRectGetWidth(closed.pane)));
    drag.overlay = [[UIView alloc] initWithFrame:surface.bounds];
    drag.overlay.backgroundColor = UIColor.clearColor;
    drag.overlay.accessibilityElementsHidden = YES;
    [drag.overlay addSubview:drag.snapshot];
    [host.postsTransitionSnapshot removeFromSuperview];
    [surface insertSubview:drag.overlay belowSubview:host.listDismiss];
    host.postsTransitionSnapshot = drag.overlay;
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventBegin);
    ApolloLog(@"[DuoSplit] interactive thread restore began");
    return YES;
}

BOOL ApolloDuoSplitInteractiveRestoreUpdate(UINavigationController *nav, CGFloat translation) {
    return ApolloDuoPostsUpdateDrag(nav, translation, YES);
}

CGFloat ApolloDuoSplitInteractiveRestoreProgress(UINavigationController *nav, CGFloat translation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsTrackingClose(state, nav);
    return ApolloDuoPostsRestoreProgress(translation, drag.restoring ? CGRectGetWidth(drag.pane) : 0.0);
}

void ApolloDuoSplitInteractiveRestoreFinish(UINavigationController *nav, BOOL commit, CGFloat velocity) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoPostsCloseHandoff *drag = ApolloDuoPostsTrackingClose(state, nav);
    if (!drag.restoring) return;
    BOOL restores = commit && drag.overlay.window && ApolloDuoSplitCanRestoreClosedThread(nav);
    if (!restores) {
        // A commit the split no longer allows was overtaken: remove it at once.
        ApolloDuoPostsCancelInteractiveClose(state, !commit, velocity);
        return;
    }
    // Cleared first: the restore below syncs the columns, which the flag holds off.
    ApolloDuoPostsCloseAdvance(state, drag, ApolloDuoPostsCloseEventCommit);
    drag.velocity = velocity;
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        // The render server owns the rest of the slide before the main thread
        // stalls in the restore's re-layout and Texture re-measure.
        ApolloDuoPostsSlideHandoff(state, drag);
        [CATransaction flush];
    } else {
        // No slide: the page takes the thread's place before it fades, so the
        // fade crosses two identical pictures, not an offset one.
        drag.snapshot.transform = CGAffineTransformIdentity;
        drag.snapshot.layer.shadowOpacity = 0.0f;
    }
    drag.overlay.userInteractionEnabled = NO;
    ApolloLog(@"[DuoSplit] interactive thread restore committed; velocity=%.0f", velocity);
    if (!ApolloDuoPostsRestoreClosedThread(state, nav, drag)) ApolloDuoPostsRemoveOverlay(state.host, drag.overlay);
}

void ApolloDuoSplitInteractiveRestoreCancel(UINavigationController *nav, BOOL animated) {
    if (!nav) {
        ApolloDuoPostsCancelActiveInteractiveClose();
        return;
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoPostsCloseHandoff *drag = state.interactiveClose;
    if (drag.restoring && drag.navigation == nav) ApolloDuoPostsCancelInteractiveClose(state, animated, 0.0);
}

// The subreddit list pulled in with the finger from the Posts feed root, by
// the same pane Back. Begin prepares the hidden drawer; NO when it can't, and
// the Back then acts on release. Update moves it by the drag's translation and
// returns NO once the drag was let go. Progress is the share of the drawer
// shown. Finish commits it shown or slides it back on the drawer's spring with
// the release velocity; Cancel removes the drag at once (with a nil
// navigation, whichever drag is active).
static ApolloDuoSplitHost *ApolloDuoDrawerHost(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && state.feed == nav && !state.changing ? state.host : nil;
}

BOOL ApolloDuoSplitInteractiveDrawerBegin(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloDuoSplitHost *host = ApolloDuoDrawerHost(nav);
    // Nothing else moving the panes: a thread close following a finger, an
    // open still sliding in, a toggle, a native pop or a resize.
    if (!host || state.interactiveClose || state.postsTogglingSplit || sDuoSplitResizingTabs
        || nav.transitionCoordinator || host.postsTransitionSnapshot.window) return NO;
    return [host beginListDrag];
}

BOOL ApolloDuoSplitInteractiveDrawerUpdate(UINavigationController *nav, CGFloat translation) {
    ApolloDuoSplitHost *host = ApolloDuoDrawerHost(nav);
    if (!host.listDragging || host.listDragHiding) return NO;
    if (sDuoSplitResizingTabs) {
        [host cancelListDragNow];
        return NO;
    }
    return [host updateListDrag:translation];
}

CGFloat ApolloDuoSplitInteractiveDrawerProgress(UINavigationController *nav, CGFloat translation) {
    return [ApolloDuoDrawerHost(nav) listDragProgress:translation];
}

void ApolloDuoSplitInteractiveDrawerFinish(UINavigationController *nav, BOOL commit, CGFloat velocity) {
    ApolloDuoSplitHost *host = ApolloDuoDrawerHost(nav);
    if (!host.listDragging || host.listDragHiding) return;
    [host finishListDrag:commit velocity:velocity];
}

void ApolloDuoSplitInteractiveDrawerCancel(UINavigationController *nav, BOOL animated) {
    if (!nav) {
        [sDuoListDragHost cancelListDragNow];
        return;
    }
    // A split being rebuilt (state.changing) still lets its drag go.
    ApolloDuoSplitHost *host = ApolloDuoSplitStateForNavigation(nav, NO).host;
    if (!host.listDragging || host.listDragHiding) return;
    if (animated) [host finishListDrag:NO velocity:0];
    else [host cancelListDragNow];
}

static UITableView *ApolloDuoSplitFindTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (id)view;
    for (UIView *child in view.subviews) {
        UITableView *table = ApolloDuoSplitFindTable(child);
        if (table) return table;
    }
    return nil;
}

static BOOL ApolloDuoSplitViewHasLabel(UIView *view, NSSet<NSString *> *labels) {
    if ([view isKindOfClass:UILabel.class] && [labels containsObject:((UILabel *)view).text]) return YES;
    if (view.accessibilityLabel && [labels containsObject:view.accessibilityLabel]) return YES;
    for (UIView *child in view.subviews) {
        if (ApolloDuoSplitViewHasLabel(child, labels)) return YES;
    }
    return NO;
}

static BOOL ApolloDuoSplitSelectRow(UIViewController *root, NSSet<NSString *> *labels) {
    [root loadViewIfNeeded];
    UITableView *table = ApolloDuoSplitFindTable(root.view);
    if (!table || ![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    [table layoutIfNeeded];
    for (NSInteger section = 0; section < MIN(table.numberOfSections, 40); section++) {
        for (NSInteger row = 0; row < MIN([table numberOfRowsInSection:section], 40); row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            UIView *content = [table cellForRowAtIndexPath:path];
            BOOL matches = NO;
            if ([table respondsToSelector:NSSelectorFromString(@"nodeForRowAtIndexPath:")]) {
                id node = ((id (*)(id, SEL, id))objc_msgSend)(table, NSSelectorFromString(@"nodeForRowAtIndexPath:"), path);
                // Texture's offscreen shortcut nodes expose their label on
                // the node; their backing views have no accessibility label.
                if ([node respondsToSelector:@selector(accessibilityLabel)]) {
                    matches = [labels containsObject:[node accessibilityLabel] ?: @""];
                }
                if (!content && [node respondsToSelector:@selector(view)]) content = [node view];
            } else if (!content) {
                content = [table.dataSource tableView:table cellForRowAtIndexPath:path];
            }
            if (matches || (content && ApolloDuoSplitViewHasLabel(content, labels))) {
                [table.delegate tableView:table didSelectRowAtIndexPath:path];
                return YES;
            }
        }
    }
    return NO;
}

extern void ApolloHiddenContentPresentFromProfile(UIViewController *profile);
extern void ApolloRecentlyReadPresentFromViewController(UIViewController *fromViewController);
void ApolloDuoAccountOpenShortcut(UIViewController *profile, NSString *title) {
    if (!profile || !title.length) return;
    // Recently Read is a tweak row sharing Friends' native row.
    if ([title isEqualToString:@"Recently Read"]) {
        ApolloRecentlyReadPresentFromViewController(profile);
        return;
    }
    // Hidden & Deleted is a tweak-owned row nested beside Saved; every other
    // shortcut is the native row with this label, selected through Apollo.
    if ([title isEqualToString:@"Hidden & Deleted"]) {
        ApolloHiddenContentPresentFromProfile(profile);
        return;
    }
    // Match the native Texture node's own label. The visible anchor cell also
    // hosts the portrait grid, so a cell-text search would find the grid's
    // copy of every title on the first shortcut row.
    UITableView *table = ApolloDuoSplitFindTable(profile.view);
    SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if ([table respondsToSelector:nodeSelector]
        && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        NSInteger count = [table.dataSource tableView:table numberOfRowsInSection:0];
        for (NSInteger row = 0; row < MIN(count, 60); row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, path);
            if (![node respondsToSelector:@selector(accessibilityLabel)]) continue;
            if (![[node accessibilityLabel] isEqualToString:title]) continue;
            [table.delegate tableView:table didSelectRowAtIndexPath:path];
            return;
        }
    }
    if (!ApolloDuoSplitSelectRow(profile, [NSSet setWithObject:title])) {
        ApolloLog(@"[DuoAccount] no native row for shortcut %@", title);
    }
}

// The Account tab profile, when its view exists (portrait or closed layout).
static void ApolloDuoAccountRefreshPortraitGrid(UITabBarController *tabs) {
    for (UIViewController *tab in tabs.viewControllers) {
        if (![tab isKindOfClass:UINavigationController.class]) continue;
        UIViewController *root = ((UINavigationController *)tab).viewControllers.firstObject;
        if (!root.isViewLoaded || !ApolloDuoSplitIsOwnAccountController(root)) continue;
        UITableView *table = ApolloDuoSplitFindTable(root.view);
        if (table) ApolloDuoAccountGridRefresh(table);
    }
}

static UIViewController *ApolloDuoSplitForwardPage(UINavigationController *nav) {
    // Read-only native Swift storage, as used by ForwardSwipeExpiry. Let
    // Apollo's native push bookkeeping consume it; never mutate the array.
    Ivar ivar = class_getInstanceVariable(nav.class, "poppedViewControllers");
    if (!ivar) return nil;
    uintptr_t word = 0;
    memcpy(&word, (const uint8_t *)(__bridge const void *)nav + ivar_getOffset(ivar), sizeof(word));
    if (!word || (word & 0xC000000000000007ull)) return nil;
    id storage = (__bridge id)(void *)word;
    if (![storage respondsToSelector:@selector(firstObject)]) return nil;
    id page = [storage firstObject];
    return [page isKindOfClass:UIViewController.class] ? page : nil;
}

BOOL ApolloDuoSplitHasForwardPage(UINavigationController *nav) {
    return ApolloDuoSplitForwardPage(nav) != nil;
}

static BOOL ApolloDuoSplitOpenStartupFeed(ApolloDuoSplitState *state) {
    // Native General stores ["subreddit", name], ["multireddit", user, name],
    // or a one-element built-in-feed choice (verified in Apollo's setter).
    NSArray *choice = [NSUserDefaults.standardUserDefaults arrayForKey:@"DefaultRedditToLoad"];
    NSString *kind = [choice.firstObject isKindOfClass:NSString.class] ? [choice.firstObject lowercaseString] : @"home";
    NSString *path = @"/";
    if ([kind isEqualToString:@"subreddit"] && choice.count >= 2 && [choice[1] isKindOfClass:NSString.class]) {
        path = [@"/r/" stringByAppendingString:choice[1]];
    } else if ([kind isEqualToString:@"multireddit"] && choice.count >= 3 &&
               [choice[1] isKindOfClass:NSString.class] && [choice[2] isKindOfClass:NSString.class]) {
        path = [NSString stringWithFormat:@"/user/%@/m/%@", choice[1], choice[2]];
    } else if ([kind containsString:@"popular"]) {
        path = @"/r/popular";
    } else if ([kind isEqualToString:@"all"]) {
        path = @"/r/all";
    }
    // Home, Popular and All are native feed rows, not subreddits. Routing
    // /r/all as a URL opened a separate lowercase "all" subreddit page, and a
    // paired split placed it in the comments column beside the native feed.
    // The enhanced list presents these rows in a separate shortcut control, so
    // searching visible row labels misses them. Use the same visible-index
    // mapping as the shortcut's tap handler.
    NSNumber *feedIndex = [path isEqualToString:@"/"] ? @0
        : [path isEqualToString:@"/r/popular"] ? @1
        : [path isEqualToString:@"/r/all"] ? @2 : nil;
    if (feedIndex) {
        UITableView *table = ApolloDuoSplitFindTable(state.root.view);
        NSUInteger row = [ApolloFeedShortcutVisibleIndexes() indexOfObject:feedIndex];
        if (row != NSNotFound) {
            // Leave the default pending until the list has loaded its rows.
            if (table.numberOfSections == 0 || row >= (NSUInteger)[table numberOfRowsInSection:0] ||
                ![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
            [table.delegate tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
            return (state.feed ?: state.secondary).viewControllers.firstObject.class != UIViewController.class;
        }
        // Home is always listed. A hidden Popular/All shortcut has no row, so
        // its URL is the only way to open that feed.
        if ([feedIndex isEqualToNumber:@0]) return NO;
    }
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://www.reddit.com"];
    url.path = path;
    return ApolloRouteURLThroughApp(url.URL);
}

static void ApolloDuoSplitOpenDefault(ApolloDuoSplitState *state) {
    if (!state.needsDefault || state.changing || !state.split || state.outer.presentedViewController) return;
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"settings"]) {
        NSArray *saved = state.lastSettings;
        if (saved.count && ![saved.firstObject parentViewController]) {
            [state.secondary setViewControllers:saved animated:NO];
        } else {
            [state.secondary setViewControllers:@[[[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]] animated:NO];
        }
    } else if ([state.kind isEqualToString:@"subreddits"]) {
        state.needsDefault = !ApolloDuoSplitOpenStartupFeed(state);
    } else if ([state.kind isEqualToString:@"account"]) {
        // The native profile is already installed as the initial Overview.
    } else if (![state.kind isEqualToString:@"search"]) {
        NSSet *labels = [state.kind isEqualToString:@"inbox"]
            ? [NSSet setWithObjects:@"Inbox (All)", @"Inbox", nil] : [NSSet setWithObject:@"Posts"];
        // A profile may still be fetching its menu. Leave the default pending
        // until its table reloads; do not invent a Posts controller or row index.
        state.needsDefault = !ApolloDuoSplitSelectRow(state.root, labels);
    }
}

extern void ApolloHiddenContentPresentFromProfile(UIViewController *profile);

static void ApolloDuoAccountSetPages(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages) {
    UIView *surface = state.host.view;
    if ([state.secondary.viewControllers isEqualToArray:pages]) return;
    // Size the destination column before Apollo's navigation controller takes
    // its transition snapshots. Only the secondary stack slides; the shared
    // header and shortcuts keep their existing geometry.
    state.host.pendingAccountDetail = @(pages.count > 1);
    [UIView performWithoutAnimation:^{
        [surface setNeedsLayout];
        [surface layoutIfNeeded];
    }];
    // UINavigationController selects a pop when the destination is already in
    // the stack and a push for a new shortcut. Keep Apollo's animator/delegate.
    BOOL animated = surface.window && !UIAccessibilityIsReduceMotionEnabled();
    [state.secondary setViewControllers:pages animated:animated];
    state.host.pendingAccountDetail = nil;
    [state.secondary setNavigationBarHidden:pages.count == 1 animated:animated];

}

// Gallery View is a full-width grid. In a sidebar split (a profile, Saved, or
// a Search result) the detail column extends beneath the sidebar, so the grid's
// leading tiles sat behind it. Hide the sidebar while a gallery is the visible
// detail page, then return it only if the gallery was what hid it: 1 hides,
// -1 restores, 0 leaves the user's own sidebar choice alone.
static NSInteger ApolloDuoGallerySidebarAction(BOOL galleryOnTop, BOOL sidebarVisible, BOOL hiddenForGallery) {
    if (galleryOnTop) return sidebarVisible ? 1 : 0;
    return hiddenForGallery ? -1 : 0;
}

static void ApolloDuoSplitSyncGallerySidebar(ApolloDuoSplitState *state) {
    // Posts keeps galleries on its feed stack, which already spans the width.
    // An interactive Back can still be cancelled; its didShow settles it.
    if (!state.split || state.feed || state.changing || state.secondary.transitionCoordinator.isInteractive) return;
    UISplitViewController *split = state.split;
    BOOL gallery = [state.secondary.topViewController isKindOfClass:ApolloGalleryViewController.class];
    NSInteger action = ApolloDuoGallerySidebarAction(gallery,
        split.displayMode != UISplitViewControllerDisplayModeSecondaryOnly, state.sidebarHiddenForGallery);
    if (!action) return;
    // The same column calls as the sidebar button, so UIKit animates the
    // divider and the header/controls follow its display-mode callback.
    state.sidebarHiddenForGallery = action > 0;
    if (action > 0) [split hideColumn:UISplitViewControllerColumnPrimary];
    else [split showColumn:UISplitViewControllerColumnPrimary];
    [state.host.viewIfLoaded setNeedsLayout];
    ApolloLog(@"[DuoSplit] %@ sidebar %@ for Gallery View", state.kind, action > 0 ? @"hidden" : @"restored");
}

static void ApolloDuoAccountSelect(ApolloDuoSplitState *state, NSString *title) {
    if (!state.split || state.changing) return;
    if ([title isEqualToString:@"Overview"]) {
        ApolloDuoAccountSetPages(state, @[state.root]);
        return;
    }
    state.selectingAccountShortcut = YES;
    if ([title isEqualToString:@"Hidden & Deleted"]) ApolloHiddenContentPresentFromProfile(state.root);
    else if ([title isEqualToString:@"Recently Read"]) ApolloRecentlyReadPresentFromViewController(state.root);
    else ApolloDuoSplitSelectRow(state.root, [NSSet setWithObject:title]);
    state.selectingAccountShortcut = NO;
    [state.host.view setNeedsLayout];
}

static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail);
static void ApolloDuoResumeVideosAfterMove(NSArray<UIViewController *> *controllers);
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward);

static void ApolloDuoSearchRestoreBackItem(ApolloDuoSplitState *state) {
    UIViewController *page = state.searchBackPage;
    if (page && state.searchBackItem) {
        NSMutableArray *items = [page.navigationItem.leftBarButtonItems mutableCopy];
        [items removeObjectIdenticalTo:state.searchBackItem];
        page.navigationItem.leftBarButtonItems = items.count ? items : nil;
        page.navigationItem.leftItemsSupplementBackButton = state.searchBackSupplementedNative;
    }
    state.searchBackPage = nil;
    state.searchBackItem = nil;
}

static void ApolloDuoSearchReturnToSearch(ApolloDuoSplitState *state) {
    if (!state.split || state.changing || ![state.kind isEqualToString:@"search"]) return;
    UINavigationController *outer = state.outer;
    UIViewController *search = state.root;
    UIView *surface = outer.view;
    UIView *detail = state.secondary.view;
    // The secondary controller can extend beneath the sidebar. Capture only
    // its visible pane, retaining its navigation chrome and trailing rail.
    // Top/bottom safe areas describe those controls, not obscured content.
    CGRect pane = UIEdgeInsetsInsetRect(detail.bounds,
        UIEdgeInsetsMake(0, detail.safeAreaInsets.left, 0, 0));
    pane = CGRectIntersection(surface.bounds, [surface convertRect:pane fromView:detail]);
    BOOL animate = surface.window && !UIAccessibilityIsReduceMotionEnabled()
        && !CGRectIsNull(pane) && !CGRectIsEmpty(pane);
    UIView *snapshot = animate
        ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;

    // Commit the real native Back beneath the captured outgoing page. A pop
    // after reparenting cannot animate the old split hierarchy; it otherwise
    // reveals Search immediately and loses the visible subreddit transition.
    // The retained Search controller keeps its query, results and scroll.
    [UIView performWithoutAnimation:^{
        ApolloDuoSplitClose(state, YES);
        [outer popToViewController:search animated:NO];
        [surface layoutIfNeeded];
        if (snapshot) {
            snapshot.frame = pane;
            snapshot.userInteractionEnabled = NO;
            [surface addSubview:snapshot];
        }
    }];
    if (snapshot) {
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
        ApolloDuoSlideView(snapshot, 0, travel, 0.32, ^{ [snapshot removeFromSuperview]; });
    }
    ApolloDuoSplitScheduleUpdate();
}

static void ApolloDuoSearchUpdateBackItem(ApolloDuoSplitState *state) {
    UIViewController *page = state.secondary.viewControllers.firstObject;
    BOOL needsBack = state.split && [state.kind isEqualToString:@"search"]
        && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"];
    if (!needsBack || state.searchBackPage != page) ApolloDuoSearchRestoreBackItem(state);
    if (!needsBack || state.searchBackItem) return;

    // Search remains in the primary column, so this subreddit is a secondary
    // root with no generated Back item. Supply a native leading navigation
    // action; UIKit places it above the other actions in Duo's side rail.
    __weak ApolloDuoSplitState *weakState = state;
    UIAction *action = [UIAction actionWithTitle:@"Back to Search"
                                         image:[UIImage systemImageNamed:@"chevron.left"]
                                    identifier:nil handler:^(__unused UIAction *sender) {
        ApolloDuoSearchReturnToSearch(weakState);
    }];
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithPrimaryAction:action];
    back.accessibilityLabel = @"Back to Search";
    back.tintColor = ApolloNavigationChromeColor();
    if (@available(iOS 26.0, *)) {
        back.identifier = @"ApolloReborn.duo-search.back";
        back.sharesBackground = NO;
    }
    if (@available(iOS 27.1, *)) back.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
    state.searchBackPage = page;
    state.searchBackItem = back;
    state.searchBackSupplementedNative = page.navigationItem.leftItemsSupplementBackButton;
    page.navigationItem.leftItemsSupplementBackButton = NO;
    page.navigationItem.leftBarButtonItems = [@[back] arrayByAddingObjectsFromArray:page.navigationItem.leftBarButtonItems ?: @[]];
}

static void ApolloDuoAccountPrepareHost(ApolloDuoSplitState *state, ApolloDuoSplitHost *host) {
    UIViewController *profile = state.root;
    BOOL ownAccount = ApolloDuoSplitIsOwnAccountController(profile);
    host.accountHeader = ApolloDuoAccountProfileHeader(profile);
    UINavigationBar *sidebarBar = [[UINavigationBar alloc] init];
    // Only hosts the sidebar button over the banner; ApolloProgressiveBlur
    // skips it so no frosted square appears behind the button.
    sidebarBar.accessibilityIdentifier = @"ApolloReborn.duo-sidebar-bar";
    UINavigationBarAppearance *sidebarAppearance = [UINavigationBarAppearance new];
    [sidebarAppearance configureWithTransparentBackground];
    sidebarBar.standardAppearance = sidebarAppearance;
    sidebarBar.scrollEdgeAppearance = sidebarAppearance;
    sidebarBar.compactAppearance = sidebarAppearance;
    sidebarBar.tintColor = ApolloNavigationChromeColor();
    UINavigationItem *sidebarItem = [[UINavigationItem alloc] initWithTitle:@""];
    // Use the same native bar-item renderer and sidebar symbol as the other
    // primary columns. UIKit clears displayModeButtonItem's image when its
    // managed column bars are hidden, so this item owns only the toggle action.
    __weak ApolloDuoSplitHost *weakHost = host;
    UIAction *toggleSidebar = [UIAction actionWithTitle:@"Toggle Sidebar"
        image:[UIImage systemImageNamed:@"sidebar.left"] identifier:nil
        handler:^(__unused UIAction *action) {
            UISplitViewController *split = weakHost.split;
            if (split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly)
                [split showColumn:UISplitViewControllerColumnPrimary];
            else
                [split hideColumn:UISplitViewControllerColumnPrimary];
        }];
    UIBarButtonItem *sidebar = [[UIBarButtonItem alloc] initWithPrimaryAction:toggleSidebar];
    if (@available(iOS 27.1, *)) sidebar.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
    sidebarItem.rightBarButtonItem = sidebar;
    [sidebarBar setItems:@[sidebarItem] animated:NO];
    host.sidebarNavigationBar = sidebarBar;
    host.split.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;
    UIButtonConfiguration *sidebarConfiguration;
    if (@available(iOS 26.0, *)) sidebarConfiguration = [UIButtonConfiguration glassButtonConfiguration];
    else sidebarConfiguration = [UIButtonConfiguration tintedButtonConfiguration];
    sidebarConfiguration.baseForegroundColor = UIColor.labelColor;
    sidebarConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    if (state.profilePrefix.count) {
        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *backConfiguration = [sidebarConfiguration copy];
        backConfiguration.image = [UIImage systemImageNamed:@"chevron.left"];
        back.configuration = backConfiguration;
        back.accessibilityLabel = @"Back";
        __weak ApolloDuoSplitState *weakProfileState = state;
        [back addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            ApolloDuoSplitState *current = weakProfileState;
            if (!current || current.changing) return;
            ApolloDuoSplitNavigateProfile(current, nil, NO);
        }] forControlEvents:UIControlEventTouchUpInside];
        host.profileBackButton = back;
    }
    __weak ApolloDuoSplitState *weakState = state;
    UIButtonConfiguration *configuration;
    if (ownAccount) {
        UIButton *accounts = [UIButton buttonWithType:UIButtonTypeSystem];
        if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
        else configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.baseForegroundColor = UIColor.labelColor;
        configuration.image = [UIImage systemImageNamed:@"person.2" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular]];
        configuration.contentInsets = NSDirectionalEdgeInsetsZero;
        accounts.accessibilityLabel = @"Accounts";
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        accounts.configuration = configuration;
        [accounts addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            UIViewController *root = weakState.root;
            SEL selector = @selector(accountsBarButtonItemTappedWithSender:);
            if ([root respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(root, selector, nil);
        }] forControlEvents:UIControlEventTouchUpInside];
        accounts.tintColor = UIColor.labelColor;
        host.accountsButton = accounts;
    }
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
    else configuration = [UIButtonConfiguration tintedButtonConfiguration];
    Ivar moreIvar = class_getInstanceVariable([profile class], "moreOptionsBarButtonItem");
    UIBarButtonItem *nativeMore = moreIvar ? object_getIvar(profile, moreIvar) : nil;
    configuration.image = nativeMore.image ?: [UIImage systemImageNamed:@"ellipsis"];
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    more.configuration = configuration;
    more.accessibilityLabel = @"More Options";
    if (ownAccount) {
        UIAction *trophies = [UIAction actionWithTitle:@"Trophies" image:[UIImage systemImageNamed:@"trophy"] identifier:nil handler:^(__unused UIAction *action) {
            ApolloDuoAccountSelect(weakState, @"Trophies");
        }];
        UIMenu *nativeMenu = ApolloProfileMoreMenuForController(profile);
        more.menu = [UIMenu menuWithTitle:@"" children:[(nativeMenu.children ?: @[]) arrayByAddingObject:trophies]];
        more.showsMenuAsPrimaryAction = YES;
    } else {
        // Visited profiles use Apollo's own actions for that user. The native
        // menu hook anchors its presentation to this button in the dashboard.
        __weak UIButton *weakMore = more;
        [more addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            UIViewController *root = weakState.root;
            SEL selector = @selector(moreOptionsBarButtonItemTappedWithSender:);
            if ([root respondsToSelector:selector])
                ((void (*)(id, SEL, id))objc_msgSend)(root, selector, weakMore);
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    host.moreButton = more;
    more.tintColor = ApolloNavigationChromeColor();
}

static void ApolloDuoSplitOpen(ApolloDuoSplitState *state) {
    UINavigationController *outer = state.outer;
    id<UIViewControllerTransitionCoordinator> transition = outer.transitionCoordinator;
    if (state.split || state.changing) {
        [sDuoSplitDeferredPresentations removeObject:state];
        return;
    }
    if (outer.presentedViewController) {
        // An over-fullscreen modal such as Pixel Pals can stay open through
        // unfolding without another appearance callback on its presenter.
        // Keep reparenting out of that presentation, but remember to install
        // the columns when dismissal releases the native navigation stack.
        if (!sDuoSplitDeferredPresentations) sDuoSplitDeferredPresentations = [NSHashTable weakObjectsHashTable];
        if (![sDuoSplitDeferredPresentations containsObject:state])
            ApolloLog(@"[DuoSplit] deferring %@ columns until modal dismissal", state.kind);
        [sDuoSplitDeferredPresentations addObject:state];
        return;
    }
    if (transition && transition != sDuoSplitSizeCoordinator) {
        // A native push/pop may still own the stack when unfolding begins.
        // Retry at its completion; a layout pass during that transition is
        // too early, and the idle tab may never produce another one.
        if (state.pendingNavigationTransition != transition) {
            state.pendingNavigationTransition = transition;
            __weak ApolloDuoSplitState *weakState = state;
            [transition animateAlongsideTransition:nil
                                       completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                weakState.pendingNavigationTransition = nil;
                ApolloDuoSplitScheduleUpdate();
            }];
        }
        return;
    }
    state.changing = YES;
    if ([state.kind isEqualToString:@"subreddits"] && outer.viewControllers.count == 1) {
        UIViewController *forward = ApolloDuoSplitForwardPage(outer);
        if (forward) {
            // goForward calls Apollo's Swift push helper directly with
            // animated:YES. performWithoutAnimation does not change that
            // navigation operation, nor does it reach our ObjC push hook.
            // Reparenting its pages immediately leaves the pending transition
            // owning the outer stack: its completion removes our split host
            // and the tab ends up with no controllers at all.
            // Consume the same forward entry through a genuinely nonanimated
            // push, then build the columns on the next main-queue turn, after
            // native didShow/history bookkeeping has finished.
            [outer pushViewController:forward animated:NO];
            if (outer.topViewController == forward) {
                state.changing = NO;
                ApolloLog(@"[DuoSplit] restored forward page before installing columns");
                ApolloDuoSplitScheduleUpdate();
                return;
            }
        }
    }
    // Retain the deferred marker through the early navigation/forward-page
    // retries above. Consume it only when we can actually install the host.
    BOOL revealFeedControls = [sDuoSplitDeferredPresentations containsObject:state]
        && outer.tabBarController.selectedViewController == outer && outer.viewIfLoaded.window;
    [sDuoSplitDeferredPresentations removeObject:state];
    NSArray *stack = [outer.viewControllers copy];
    // Pages moving into the columns (not a bare root at launch) carry their
    // playing videos through the move.
    if (stack.count > 1) ApolloDuoResumeVideosAfterMove(stack);
    NSUInteger rootIndex = 0;
    // Only landscape has a profile dashboard. Portrait keeps visited profiles
    // on the Posts navigation stack; promoting one to Account here would make
    // the next update collapse it, then reopen Posts and repeat indefinitely.
    if (ApolloDuoSplitShouldOpen((id)outer.tabBarController)) {
        for (NSUInteger index = 1; index < stack.count; index++) {
            if ([ApolloDuoSplitKind(stack[index]) isEqualToString:@"account"]) rootIndex = index;
        }
    }
    if (rootIndex) {
        state.tabRoot = state.root;
        state.tabKind = state.kind;
        state.profilePrefix = [stack subarrayWithRange:NSMakeRange(0, rootIndex)];
        state.root = stack[rootIndex];
        state.kind = @"account";
    }
    NSArray *detail = stack.count > rootIndex + 1
        ? [stack subarrayWithRange:NSMakeRange(rootIndex + 1, stack.count - rootIndex - 1)] : @[];
    state.navigationBarWasHidden = outer.navigationBarHidden;
    state.sidebarTitle = state.root.navigationItem.title;
    UISplitViewController *split = [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    // An unfold starts while the outer controller still has the cover
    // display's compact traits. Pin the split itself before attaching either
    // column: a parent override applied afterward is too late and UIKit starts
    // a compact-column merge during viewWillTransitionToSize:.
    // Apple advises observing size classes rather than overriding them
    // (https://developer.apple.com/forums/thread/847644). This pin is limited
    // to our own split on Duo and goes away with it; the tab container keeps
    // UIKit's traits (logged as "[DuoRail] native horizontalSizeClass").
    if (@available(iOS 17.0, *)) {
        split.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassRegular;
    }
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredPrimaryColumnWidthFraction = 1.0 / 3.0;
    split.minimumPrimaryColumnWidth = 240.0;
    split.maximumPrimaryColumnWidth = 420.0;
    split.primaryEdge = UISplitViewControllerPrimaryEdgeLeading;
    split.presentsWithGesture = YES;
    // Release native ownership before reparenting. No view/frame stealing,
    // layout-loop repinning, or replacement of the tab's navigation object.
    ApolloDuoSplitHost *host = [ApolloDuoSplitHost new];
    // Dark/opaque themes make the native tab bar nontranslucent. A plain
    // controller's default layout then subtracts the vertical rail's entire
    // height as though it were a bottom bar, collapsing this host to zero.
    // Match Apollo's native pages and let the split's safe areas own the inset.
    host.extendedLayoutIncludesOpaqueBars = YES;
    host.split = split;
    state.host = host;
    BOOL account = [state.kind isEqualToString:@"account"];
    if (account) ApolloDuoAccountPrepareHost(state, host);
    BOOL posts = [state.kind isEqualToString:@"subreddits"];
    [outer setViewControllers:@[host] animated:NO];
    state.split = split;
    state.root.extendedLayoutIncludesOpaqueBars = YES;
    ApolloDuoAccountShortcuts *shortcuts = account ? [ApolloDuoAccountShortcuts new] : nil;
    shortcuts.profileTable = account ? ApolloDuoSplitFindTable(state.root.view) : nil;
    state.primary = [[outer.class alloc] initWithRootViewController:shortcuts ?: state.root];
    state.secondary = [[outer.class alloc] init];
    if ([state.kind isEqualToString:@"search"]) host.searchNavigation = state.primary;
    ApolloDuoSplitLink(state.primary, state);
    ApolloDuoSplitLink(state.secondary, state);
    if (account) {
        [state.primary setNavigationBarHidden:YES animated:NO];
        [state.secondary setViewControllers:[@[state.root] arrayByAddingObjectsFromArray:detail] animated:NO];
        [state.secondary setNavigationBarHidden:detail.count == 0 animated:NO];
        __weak ApolloDuoSplitState *weakState = state;
        shortcuts.selectShortcut = ^(NSString *title) { ApolloDuoAccountSelect(weakState, title); };
        ApolloDuoAccountConfigureOverviewTable(ApolloDuoSplitFindTable(state.root.view), YES);
    } else if (detail.count) [state.secondary setViewControllers:detail animated:NO];
    else {
        UIViewController *placeholder = [UIViewController new];
        placeholder.view.backgroundColor = UIColor.systemBackgroundColor;
        [state.secondary setViewControllers:@[placeholder] animated:NO];
    }
    if (posts) {
        state.feed = [[outer.class alloc] init];
        ApolloDuoSplitLink(state.feed, state);
        // Leading subreddit/feed pages stay on the left; only what follows
        // them (posts, comments) belongs in the thread pane.
        NSUInteger feedCount = detail.count ? 1 : 0;
        while (feedCount < detail.count && ApolloDuoIsFeedPage(detail[feedCount])) feedCount++;
        NSArray *feedPages = feedCount ? [detail subarrayWithRange:NSMakeRange(0, feedCount)] : @[[UIViewController new]];
        [state.secondary setViewControllers:@[] animated:NO];
        [state.feed setViewControllers:feedPages animated:NO];
        UIViewController *backstop = [UIViewController new];
        backstop.title = @"Feed";
        NSArray *comments = detail.count > feedCount
            ? [detail subarrayWithRange:NSMakeRange(feedCount, detail.count - feedCount)] : @[];
        [state.secondary setViewControllers:[@[backstop] arrayByAddingObjectsFromArray:comments] animated:NO];
        // The host may already have loaded while the outer stack was changed.
        // Recreate it with the overlay configured before viewDidLoad.
        ApolloDuoSplitHost *postsHost = [ApolloDuoSplitHost new];
        postsHost.extendedLayoutIncludesOpaqueBars = YES;
        postsHost.split = split;
        postsHost.subredditList = state.primary;
        postsHost.postsNavigation = state.feed;
        postsHost.pendingFeedControlsReveal = revealFeedControls;
        postsHost.postsSplitEnabled = ![NSUserDefaults.standardUserDefaults boolForKey:@"ApolloDuoPostsSplitDisabled"];
        split.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;
        split.presentsWithGesture = NO;
        __weak ApolloDuoSplitState *weakPostsState = state;
        postsHost.togglePostsSplit = ^{
            ApolloDuoSplitState *live = weakPostsState;
            ApolloDuoPostsToggleSplit(live);
        };
        if (split.parentViewController) {
            [split willMoveToParentViewController:nil];
            [split.view removeFromSuperview];
            [split removeFromParentViewController];
        }
        state.host = postsHost;
        host = postsHost;
        [outer setViewControllers:@[host] animated:NO];
        state.changing = NO;
        ApolloDuoPostsSyncColumns(state);
        state.changing = YES;
    } else if (account) {
        host.accountPrimary = [ApolloDuoAccountColumn new];
        host.accountPrimary.extendedLayoutIncludesOpaqueBars = YES;
        host.accountPrimary.navigation = state.primary;
        __weak ApolloDuoSplitHost *weakAccountHost = host;
        host.accountPrimary.geometryDidChange = ^{
            ApolloDuoSplitHost *liveHost = weakAccountHost;
            [liveHost.view setNeedsLayout];
            [liveHost.accountHeader setNeedsLayout];
        };
        host.accountSecondary = [ApolloDuoAccountColumn new];
        host.accountSecondary.extendedLayoutIncludesOpaqueBars = YES;
        host.accountSecondary.navigation = state.secondary;
        CGFloat height = ApolloDuoAccountHeaderHeight(host.accountHeader, outer.view.bounds.size.width);
        host.accountPrimary.contentTop = height;
        host.accountSecondary.contentTop = detail.count ? 0 : height;
        [split setViewController:host.accountPrimary forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:host.accountSecondary forColumn:UISplitViewControllerColumnSecondary];
        // UISplitViewController wraps non-navigation columns in its own
        // navigation controllers. Their bars would duplicate the native page
        // bar (and consume the entire vertical rail under opaque themes).
        [(UINavigationController *)host.accountPrimary.parentViewController setNavigationBarHidden:YES animated:NO];
        [(UINavigationController *)host.accountSecondary.parentViewController setNavigationBarHidden:YES animated:NO];
    } else {
        [split setViewController:state.primary forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
    }
    ApolloDuoSplitApplySidebarWidth(state, ApolloDuoSplitWantsHalfWidth((id)outer.tabBarController));
    [outer setNavigationBarHidden:YES animated:NO];
    // The compatibility phone can retain a compact horizontal size class on
    // its wide inner display. The width/rail gate above is authoritative.
    // Cleared in ApolloDuoSplitClose. If that log shows UIKit publishing
    // regular when unfolded, both pins can become trait observation instead.
    [outer setOverrideTraitCollection:[UITraitCollection traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassRegular]
              forChildViewController:host];
    state.needsDefault = detail.count == 0;
    state.changing = NO;
    ApolloDuoSearchUpdateBackItem(state);
    ApolloLog(@"[DuoSplit] opened native %@ sidebar/detail", state.kind);
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloDuoSplitOpenDefault(state); });
}

// Folding or unfolding re-hosts the open pages. UIKit reports that as the
// thread disappearing and reappearing, and Apollo pauses its video exactly as
// when the reader leaves the post. Resume what was playing before the move.
//
// Apollo has two player paths (AGENTS.md, "ASVideoNode Player Access"):
// shareable v.redd.it video keeps a nil ASVideoNode.player and plays through
// playerLayer.player; GIF/Giphy/Streamable play through the node's own player.
// Resolve the layer's player first, as the native mute handler does.
static AVPlayer *ApolloDuoVideoNodePlayer(id node) {
    CALayer *layer = [node respondsToSelector:@selector(playerLayer)]
        ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(playerLayer)) : nil;
    AVPlayer *player = [layer isKindOfClass:AVPlayerLayer.class] ? ((AVPlayerLayer *)layer).player : nil;
    if (!player && [node respondsToSelector:@selector(player)])
        player = ((id (*)(id, SEL))objc_msgSend)(node, @selector(player));
    return [player isKindOfClass:AVPlayer.class] ? player : nil;
}

@interface ApolloDuoPlayingVideo : NSObject
@property(nonatomic, weak) id node;
@property(nonatomic, weak) AVPlayer *player;
@property(nonatomic, weak) AVPlayerItem *item;
@end
@implementation ApolloDuoPlayingVideo @end

static void ApolloDuoResumeVideosAfterMove(NSArray<UIViewController *> *controllers) {
    Class videoClass = objc_getClass("ASVideoNode");
    if (!videoClass || !controllers.count) return;
    NSMutableArray<ApolloDuoPlayingVideo *> *playing = [NSMutableArray array];
    for (UIViewController *controller in controllers) {
        UIView *root = controller.viewIfLoaded;
        if (!root.window) continue;
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:root];
        for (NSUInteger index = 0; index < views.count && index < 4000; index++) {
            UIView *view = views[index];
            [views addObjectsFromArray:view.subviews];
            id node = [view respondsToSelector:@selector(asyncdisplaykit_node)]
                ? ((id (*)(id, SEL))objc_msgSend)(view, @selector(asyncdisplaykit_node)) : nil;
            if (![node isKindOfClass:videoClass]) continue;
            AVPlayer *player = ApolloDuoVideoNodePlayer(node);
            if (!(player.rate > 0) || !player.currentItem) continue;
            ApolloDuoPlayingVideo *video = [ApolloDuoPlayingVideo new];
            video.node = node;
            video.player = player;
            video.item = player.currentItem;
            [playing addObject:video];
        }
    }
    if (!playing.count) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSUInteger resumed = 0;
        for (ApolloDuoPlayingVideo *video in playing) {
            id node = video.node;
            AVPlayer *player = video.player;
            // Only the same player, still on the same content, still on screen
            // and paused: a node that was reused or scrolled away, or a player
            // that moved on, belongs to something else now.
            if (!node || !player || ApolloDuoVideoNodePlayer(node) != player
                || player.currentItem != video.item || player.rate > 0) continue;
            UIView *view = ((id (*)(id, SEL))objc_msgSend)(node, @selector(view));
            if (!view.window || view.hidden || view.alpha <= 0.01) continue;
            // The shareable path's node has no player of its own: play the
            // layer's player directly. The direct path goes through the node so
            // ASVideoNode's own playback state stays in step.
            id direct = [node respondsToSelector:@selector(player)]
                ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(player)) : nil;
            if (direct == player) ((void (*)(id, SEL))objc_msgSend)(node, @selector(play));
            else [player play];
            resumed++;
        }
        if (resumed) ApolloLog(@"[DuoSplit] resumed %lu video(s) paused by the fold rebuild", (unsigned long)resumed);
    });
}

static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail) {
    [sDuoSplitDeferredPresentations removeObject:state];
    // Even a close that bails (mid column change, or no split left) lets the
    // closed thread's pages go.
    ApolloDuoPostsForgetClosedThread(state, @"the split closed");
    if (!state.split || state.changing) return;
    ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    state.changing = YES;
    NSMutableArray<UIViewController *> *moving = [NSMutableArray array];
    for (UINavigationController *nav in @[state.primary ?: (id)NSNull.null, state.feed ?: (id)NSNull.null,
                                          state.secondary ?: (id)NSNull.null]) {
        if ([nav isKindOfClass:UINavigationController.class]) [moving addObjectsFromArray:nav.viewControllers];
    }
    ApolloDuoResumeVideosAfterMove(moving);
    ApolloDuoPostsStopGeometry(state.host.searchNavigation.viewIfLoaded);
    ApolloDuoSearchRestoreBackItem(state);
    NSArray *detail = [state.secondary.viewControllers copy];
    if (state.feed) {
        ApolloNativeFeedSearchSetDuoControls(state.host.feedControlsOwner, nil, nil, nil);
        state.host.feedControlsOwner = nil;
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
        [state.host.postsTransitionSnapshot removeFromSuperview];
        state.host.postsTransitionSnapshot = nil;
        [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
        [state.host restoreListBackgrounds];
        // Stop suppressing the feed before its item setter runs, then discard
        // this presentation's snapshot so reopening cannot reuse stale items.
        state.host.postsColumnsPaired = NO;
        if (state.feedActions) {
            (state.feedActionsItem ?: state.feed.viewControllers.firstObject.navigationItem).rightBarButtonItems = state.feedActions;
        }
        state.feedActions = nil;
        state.feedActionsItem = nil;
        state.feedBackHiddenItem.hidesBackButton = NO;
        state.feedBackHiddenItem = nil;
        NSArray *comments = detail.count > 1 ? [detail subarrayWithRange:NSMakeRange(1, detail.count - 1)] : @[];
        detail = [state.feed.viewControllers arrayByAddingObjectsFromArray:comments];
        [state.feed setViewControllers:@[] animated:NO];
    }
    if ([state.kind isEqualToString:@"account"]) {
        NSMutableArray *pages = [detail mutableCopy];
        [pages removeObjectIdenticalTo:state.root];
        detail = pages;
        ApolloDuoAccountRestoreProfile(state.root);
        ApolloDuoAccountConfigureOverviewTable(ApolloDuoSplitFindTable(state.root.view), NO);
    }
    if (detail.count && [detail.firstObject class] == UIViewController.class) detail = @[];
    if ([state.kind isEqualToString:@"settings"] && detail.count) state.lastSettings = detail;
    [state.primary setViewControllers:@[] animated:NO];
    [state.secondary setViewControllers:@[] animated:NO];
    [state.outer setOverrideTraitCollection:nil forChildViewController:state.host];
    // Settings and Inbox have automatically selected detail pages. Account
    // starts at Overview, so any remaining detail was opened by the user and
    // must stay on top when the split collapses to the cover display.
    BOOL overviewOnCover = !preserveDetail && !state.profilePrefix.count && !ApolloDuoSplitIsUnfolded()
        && ([state.kind isEqualToString:@"settings"] || [state.kind isEqualToString:@"inbox"]);
    NSArray *restored = overviewOnCover ? @[state.root] : [@[state.root] arrayByAddingObjectsFromArray:detail];
    if (state.profilePrefix.count) restored = [state.profilePrefix arrayByAddingObjectsFromArray:restored];
    [state.outer setViewControllers:restored animated:NO];
    [state.outer setNavigationBarHidden:state.navigationBarWasHidden animated:NO];
    // Account switches update the native profile title while the split is open.
    // Restoring its entry-time title would repoint the cover header at the old user.
    if (![state.kind isEqualToString:@"account"]) state.root.navigationItem.title = state.sidebarTitle;
    if (state.profilePrefix.count) {
        state.root = state.tabRoot;
        state.kind = state.tabKind;
        state.tabRoot = nil;
        state.tabKind = nil;
        state.profilePrefix = nil;
    }
    state.split = nil;
    state.host = nil;
    state.primary = nil;
    state.secondary = nil;
    state.feed = nil;
    state.sidebarHiddenForGallery = NO;
    state.needsDefault = NO;
    state.changing = NO;
    ApolloLog(@"[DuoSplit] restored single-column %@ stack", state.kind);
}

// Reparent the live pages under one visual transition. A snapshot covers the
// intermediate single-column stack, so UIKit cannot flash that layout first.
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward) {
    if (!state.split || state.changing) return;
    UINavigationController *outer = state.outer;
    UIView *oldView = state.host.view;
    UIView *snapshot = [oldView snapshotViewAfterScreenUpdates:NO];
    CGRect frame = [oldView convertRect:oldView.bounds toView:outer.view];
    NSArray *prefix = state.profilePrefix;
    [UIView performWithoutAnimation:^{
        ApolloDuoSplitClose(state, YES);
        NSArray *stack = forward ? [outer.viewControllers arrayByAddingObject:profile] : prefix;
        [outer setViewControllers:stack animated:NO];
        ApolloDuoSplitOpen(state);
        [outer.view layoutIfNeeded];
    }];
    UIView *destination = state.host.view;
    if (!snapshot || !destination || UIAccessibilityIsReduceMotionEnabled()) return;
    snapshot.frame = frame;
    snapshot.userInteractionEnabled = NO;
    [outer.view addSubview:snapshot];
    CGFloat direction = forward ? 1 : -1;
    CGFloat width = CGRectGetWidth(frame);
    destination.transform = CGAffineTransformMakeTranslation(direction * width, 0);
    [outer.view bringSubviewToFront:destination];
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        destination.transform = CGAffineTransformIdentity;
        snapshot.transform = CGAffineTransformMakeTranslation(-direction * width, 0);
    } completion:^(__unused BOOL finished) {
        [snapshot removeFromSuperview];
        destination.transform = CGAffineTransformIdentity;
    }];
}

BOOL ApolloDuoSplitCanReturnFromVisitedProfile(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    return state.split && !state.changing && state.profilePrefix.count
        && [state.kind isEqualToString:@"account"]
        && [state.tabKind isEqualToString:@"subreddits"]
        && state.secondary.viewControllers.count == 1
        && state.secondary.topViewController == state.root;
}

BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *navigation) {
    if (!ApolloDuoSplitCanReturnFromVisitedProfile(navigation)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    // An unfolded visited profile is the dashboard's detail root. Its native
    // Back pages are retained outside that one-page navigation stack, so use
    // the same transition as the profile's Back button. The Account tab has
    // no Posts prefix and must retain its own profile at the top.
    ApolloDuoSplitNavigateProfile(state, nil, NO);
    return YES;
}

// The thread pane of the selected tab's Posts split when the post can be
// dragged from the rail (the same case as the pane's own drag), else nil.
static UINavigationController *ApolloDuoSplitRailDragThread(UITabBarController *tabs) {
    UIViewController *selected = tabs.selectedViewController;
    if (![selected isKindOfClass:UINavigationController.class]) return nil;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation((id)selected, NO);
    return state.feed && ApolloDuoSplitThreadDividerDrags(state.secondary) ? state.secondary : nil;
}

// The visible rail is not the UITabBar (which has no subviews on iOS 26):
// UIKit hosts the floating bar's platters in a _UITabContainerView of the
// tab controller's view, and a touch on a rail button hits those, never the
// bar. The post drag's pan lives on that container, which holds the rail and
// nothing else, so a touch anywhere else never reaches it.
static UIView *ApolloDuoSplitRailContainer(UITabBarController *tabs) {
    static __weak UIView *found;
    if (found.window && [found isDescendantOfView:tabs.view]) return found;
    Class container = NSClassFromString(@"_UITabContainerView");
    if (!container) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:tabs.view];
    for (NSUInteger visited = 0; queue.count && visited < 4000; visited++) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:container]) {
            found = view;
            return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void ApolloDuoSplitInstallRailDrag(UITabBarController *tabs) {
    UIView *rail = ApolloDuoSplitRailContainer(tabs);
    if (!rail) return;
    __weak UITabBarController *weakTabs = tabs;
    ApolloDuoInstallRailDrag(rail, ^UINavigationController *{
        UITabBarController *live = weakTabs;
        return live ? ApolloDuoSplitRailDragThread(live) : nil;
    });
}

static void ApolloDuoSplitUpdate(void) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (sDuoSplitUpdating || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdating = YES;
    ApolloDuoSplitObserveHinge(tabs);
    ApolloDuoSplitInstallRailDrag(tabs);
    BOOL open = ApolloDuoSplitShouldOpen(tabs);
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *nav = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, open || child == tabs.selectedViewController);
        if (!state) continue;
        // A thread close following the finger owns its columns until it ends;
        // the interruptions that do need an update cancel it before this runs.
        // One whose views have left the window, or whose pane navigation
        // is gone while it still tracks, is over: let it go. The divider's
        // drag is held by its press, or by the thread pane's pan, which has
        // a pane navigation as the close's has.
        ApolloDuoPostsCloseHandoff *drag = state.interactiveClose;
        BOOL held = drag.dividing ? (ApolloDuoSplitDividerHolding(state.host.viewIfLoaded) || drag.navigation)
            : drag.navigation || drag.phase != ApolloDuoPostsClosePhaseTracking;
        if (drag.overlay.window && held) continue;
        ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
        BOOL postsOpen = [state.kind isEqualToString:@"subreddits"] && ApolloDuoSplitIsUnfolded();
        if (!open && !postsOpen) ApolloDuoSplitClose(state, NO);
        else {
            // Native Swift pushes can bypass the ObjC push hook. On rotation
            // into landscape, a profile may also still be on the portrait feed
            // stack. Normalize either path before installing its dashboard.
            if (open) {
                NSArray *pages = [(state.feed.viewControllers ?: @[])
                    arrayByAddingObjectsFromArray:state.secondary.viewControllers ?: @[]];
                for (UIViewController *page in pages) {
                    if (page != state.root && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
                        ApolloDuoSplitClose(state, YES);
                        break;
                    }
                }
            }
            // Search stays full-width until a result is opened. Once it has
            // a detail page, retain the query/results in the sidebar.
            if ([state.kind isEqualToString:@"search"] && !state.split && nav.viewControllers.count < 2) continue;
            ApolloDuoSplitOpen(state);
            BOOL halfWidth = ApolloDuoSplitWantsHalfWidth(tabs);
            if (state.split && state.halfWidthSidebar != halfWidth) {
                // UIKit animates the same column containers; content and
                // navigation chrome move with the divider in both directions.
                [UIView animateWithDuration:0.25 animations:^{
                    ApolloDuoSplitApplySidebarWidth(state, halfWidth);
                    [state.split.view layoutIfNeeded];
                }];
            }
            ApolloDuoSplitOpenDefault(state);
            ApolloDuoPostsSyncColumns(state);
            ApolloDuoSplitSyncGallerySidebar(state);
            ApolloDuoSearchUpdateBackItem(state);
            if ([state.kind isEqualToString:@"account"] && state.split) {
                BOOL overview = state.secondary.topViewController == state.root;
                if (!state.secondary.transitionCoordinator && state.secondary.navigationBarHidden != overview) {
                    [state.secondary setNavigationBarHidden:overview animated:NO];
                }
                if (state.host.moreButton.hidden == overview) [state.host.view setNeedsLayout];
            }
            if ([state.primary.viewControllers.firstObject isKindOfClass:ApolloDuoAccountShortcuts.class]) {
                [(ApolloDuoAccountShortcuts *)state.primary.viewControllers.firstObject refreshProfileMenu];
            }
        }
    }
    sDuoSplitUpdating = NO;
    if ([tabs.selectedViewController isKindOfClass:UINavigationController.class]) {
        ApolloDuoSplitHost *host = ApolloDuoSplitStateForNavigation((id)tabs.selectedViewController, NO).host;
        if (host.pendingFeedControlsReveal) {
            __weak ApolloDuoSplitHost *weakHost = host;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakHost revealRestoredFeedControls]; });
        }
    }
}

void ApolloDuoSplitScheduleUpdate(void) {
    if (sDuoSplitUpdateScheduled) return;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sDuoSplitUpdateScheduled = NO;
        ApolloDuoSplitUpdate();
    });
}

// Re-pin the Posts columns after the setting or the position changed: at once
// with no thread beside the feed, with the columns' animation when one is.
static void ApolloDuoSplitApplyPostsStopToState(ApolloDuoSplitState *state) {
    // The setting turned off under a divider drag: the drag goes at once, and
    // the columns take half the canvas below. UIKit's separator tap follows
    // the setting (ApolloDuoPostsSyncSeparatorTap).
    if (state.interactiveClose.dividing) ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    ApolloDuoPostsSyncSeparatorTap(state, state.feed && ApolloDuoPostsAdjustableSplit());
    if (!state.split || !state.feed || state.changing || state.interactiveClose) return;
    BOOL threadShown = ApolloDuoPostsUsesSplit(state) && state.secondary.viewControllers.count > 1
        && state.split.viewIfLoaded.window && !sDuoSplitResizingTabs;
    if (!threadShown) {
        ApolloDuoSplitApplySidebarWidth(state, state.halfWidthSidebar);
        return;
    }
    void (^apply)(void) = ^{
        ApolloDuoSplitApplySidebarWidth(state, state.halfWidthSidebar);
        [state.split.view layoutIfNeeded];
    };
    // A divider landing lays the columns out at once under its pictures: an
    // animated width would still be moving after they have been revealed.
    if (sDuoPostsApplyUnanimated) apply();
    else [UIView animateWithDuration:0.25 animations:apply];
}

void ApolloDuoSplitApplyPostsStop(UINavigationController *anyPostsNavigation) {
    if (anyPostsNavigation) {
        ApolloDuoSplitApplyPostsStopToState(ApolloDuoSplitStateForNavigation(anyPostsNavigation, NO));
        return;
    }
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        ApolloDuoSplitApplyPostsStopToState(ApolloDuoSplitStateForNavigation((id)child, NO));
    }
}

static BOOL ApolloDuoSplitHasDeferredPresentationInWindow(UIWindow *window) {
    if (!window) return NO;
    for (ApolloDuoSplitState *state in sDuoSplitDeferredPresentations.allObjects) {
        if (state.outer.viewIfLoaded.window == window) return YES;
    }
    return NO;
}

%hook UIViewController
// A sheet or alert over a thread close following the finger lets it go.
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    ApolloDuoPostsCancelActiveInteractiveClose();
    %orig(controller, animated, completion);
}
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    UIWindow *window = ((UIViewController *)self).viewIfLoaded.window
        ?: ((UIViewController *)self).presentingViewController.viewIfLoaded.window;
    if (!ApolloDuoSplitHasDeferredPresentationInWindow(window)) {
        %orig(animated, completion);
        return;
    }
    void (^duoCompletion)(void) = ^{
        if (completion) completion();
        // Dismissal may not relayout the tab controller behind an overlay.
        // Refresh its cached mode before the existing coalesced update reads
        // the now-current canvas and restores the host's List/Layout/Split UI.
        ApolloLog(@"[DuoSplit] retrying deferred columns after modal dismissal");
        ApolloDuoRailSync();
        ApolloDuoSplitScheduleUpdate();
    };
    %orig(animated, duoCompletion);
}
%end

// Feed links opened from either pane of the landscape feed/comments split
// (a subreddit name on a feed row, in the post header or in a comment).
// Posts, comment permalinks, subreddit pages (wiki/sidebar/rules) and profiles
// keep their existing routes; only subreddit/multireddit feeds come here:
// - the subreddit already shown on the left (e.g. the post header): no-op;
// - any other feed: show it full width like a subreddit-list selection, but
//   pushed on the feed stack so Back returns to the previous feed and thread.
static char kDuoFeedLinkReturnDetail;
static BOOL sDuoSplitPushingFeedLink;

@interface ApolloDuoFeedLinkReturn : NSObject
@property(nonatomic, copy) NSArray<UIViewController *> *detail;
@property(nonatomic, weak) UIViewController *openedFeed;
@end
@implementation ApolloDuoFeedLinkReturn
@end

static BOOL ApolloDuoPostsRouteFeedLink(ApolloDuoSplitState *state, UINavigationController *nav,
                                       UIViewController *page, BOOL animated) {
    // Drawer selections arrive through the primary/outer stacks and keep their
    // root-replacing path.
    if ((nav != state.secondary && nav != state.feed) || !state.split || !ApolloDuoPostsUsesSplit(state)
        || !ApolloDuoIsFeedPage(page)) return NO;
    // Without a thread to cover, Gallery View is an ordinary full-width push.
    BOOL gallery = [page isKindOfClass:ApolloGalleryViewController.class];
    if (gallery && state.secondary.viewControllers.count < 2) return NO;
    UIViewController *visibleFeed = state.feed.topViewController;
    NSString *target = ApolloNamedSubredditForPostsController(page);
    NSString *current = ApolloNamedSubredditForPostsController(visibleFeed);
    if (target.length && current.length && [target caseInsensitiveCompare:current] == NSOrderedSame) {
        ApolloLog(@"[DuoSplit] feed link to the subreddit already on the left; ignored");
        return YES;
    }
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventFeedOpened, 0.0);
    NSArray *detail = state.secondary.viewControllers.count > 1
        ? [state.secondary.viewControllers subarrayWithRange:NSMakeRange(1, state.secondary.viewControllers.count - 1)] : @[];
    BOOL animate = animated && !UIAccessibilityIsReduceMotionEnabled();
    state.needsDefault = NO;
    UIView *surface = state.host.view;
    // One coordinated animation: snapshot both panes, settle the final
    // layout underneath (thread closed, feed pushed) without animation, then
    // slide the thread out to the right and fade the old feed out while the
    // new feed fades in at full width. Running a native push alongside the
    // column animation instead flung retained surfaces across the screen.
    UIView *feedSnapshot = nil, *threadSnapshot = nil;
    if (animate && surface.window) {
        [surface layoutIfNeeded];
        CGRect pane = ApolloDuoPostsDetailPane(state);
        if (!CGRectIsNull(pane) && !CGRectIsEmpty(pane)) {
            CGRect feedRect = CGRectMake(0, 0, CGRectGetMinX(pane), CGRectGetHeight(surface.bounds));
            feedSnapshot = [surface resizableSnapshotViewFromRect:feedRect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
            feedSnapshot.frame = feedRect;
            threadSnapshot = [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
            threadSnapshot.frame = pane;
        }
    }
    // Close the thread first: an unpaired feed keeps its own bar actions,
    // which the split would otherwise discard while the page is pushed.
    UIViewController *backstop = state.secondary.viewControllers.firstObject;
    [state.secondary setViewControllers:backstop ? @[backstop] : @[] animated:NO];
    ApolloDuoPostsSyncColumns(state);
    objc_setAssociatedObject(page, &kDuoFeedLinkPage, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sDuoSplitPushingFeedLink = YES;
    [state.feed pushViewController:page animated:NO];
    sDuoSplitPushingFeedLink = NO;
    [surface layoutIfNeeded];
    if (feedSnapshot && threadSnapshot) {
        for (UIView *snapshot in @[feedSnapshot, threadSnapshot]) {
            snapshot.userInteractionEnabled = NO;
            [surface addSubview:snapshot];
        }
        UIView *incoming = state.feed.view;
        incoming.alpha = 0.0;
        incoming.transform = CGAffineTransformMakeTranslation(48.0, 0.0);
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(threadSnapshot.frame);
        [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:1.0 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            threadSnapshot.transform = CGAffineTransformMakeTranslation(travel, 0.0);
            feedSnapshot.transform = CGAffineTransformMakeTranslation(-48.0, 0.0);
            feedSnapshot.alpha = 0.0;
            incoming.alpha = 1.0;
            incoming.transform = CGAffineTransformIdentity;
        } completion:^(__unused BOOL finished) {
            [feedSnapshot removeFromSuperview];
            [threadSnapshot removeFromSuperview];
            incoming.alpha = 1.0;
            incoming.transform = CGAffineTransformIdentity;
        }];
    }
    if (detail.count && visibleFeed && [state.feed.viewControllers containsObject:page]) {
        // Recorded after the push, so re-shows during it never count as Back.
        ApolloDuoFeedLinkReturn *ret = [ApolloDuoFeedLinkReturn new];
        ret.detail = detail;
        ret.openedFeed = page;
        objc_setAssociatedObject(visibleFeed, &kDuoFeedLinkReturnDetail, ret, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [state.host setListVisible:NO animated:animate];
    ApolloLog(@"[DuoSplit] feed link %@ opened full width; Back restores %lu thread page(s)",
              gallery ? @"(gallery)" : target ?: @"(multireddit/feed)", (unsigned long)detail.count);
    return YES;
}

// Back to a feed that a link left: restore its retained thread in the current
// presentation, including when rotation or folding removed the paired columns.
static void ApolloDuoPostsRestoreFeedLinkDetail(ApolloDuoSplitState *state,
                                               UINavigationController *navigation,
                                               UIViewController *controller) {
    ApolloDuoFeedLinkReturn *ret = objc_getAssociatedObject(controller, &kDuoFeedLinkReturnDetail);
    NSArray *detail = ret.detail;
    // Only a real Back: the feed the link opened has left the stack.
    if (!detail.count || !navigation || controller != navigation.topViewController || state.changing
        || (state.feed && navigation != state.feed)
        || (ret.openedFeed && [navigation.viewControllers containsObject:ret.openedFeed])) return;
    if (!state.feed || !ApolloDuoPostsUsesSplit(state)) {
        // Native didShow has completed the pop. Keep these exact controllers
        // (and their reading positions) on the single stack until columns return.
        state.changing = YES;
        [navigation setViewControllers:[navigation.viewControllers arrayByAddingObjectsFromArray:detail] animated:NO];
        state.changing = NO;
    } else if (!state.secondary.viewControllers.firstObject) {
        // A column transition has not supplied its backstop yet. Retain the
        // record rather than consuming history that cannot be installed.
        return;
    } else if (detail.count == 1) {
        ApolloDuoPostsSetDetail(state, detail.firstObject, YES);
    } else {
        UIViewController *backstop = state.secondary.viewControllers.firstObject;
        [state.secondary setViewControllers:[@[backstop] arrayByAddingObjectsFromArray:detail] animated:NO];
        ApolloDuoPostsSyncColumns(state);
    }
    objc_setAssociatedObject(controller, &kDuoFeedLinkReturnDetail, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!state.feed || !ApolloDuoPostsUsesSplit(state)) ApolloDuoPostsSyncColumns(state);
    ApolloLog(@"[DuoSplit] Back from a feed link; restored %lu thread page(s)", (unsigned long)detail.count);
}

// Back from a feed a link opened: return to the previous feed with its thread
// in one animation (the mirror of the forward one) instead of a native pop
// followed by the thread sliding back in. Returns the popped page, or nil to
// leave the pop to UIKit (Apollo's own interactive Back, or a thread is open).
static UIViewController *ApolloDuoPostsPopFeedLink(ApolloDuoSplitState *state, BOOL animated) {
    NSArray<UIViewController *> *pages = state.feed.viewControllers;
    if (!state.split || state.changing || pages.count < 2 || !ApolloDuoPostsUsesSplit(state)
        || state.secondary.viewControllers.count > 1) return nil;
    if (ApolloDuoNativeBackInFlight(state.feed)) return nil;
    UIViewController *top = pages.lastObject, *previous = pages[pages.count - 2];
    ApolloDuoFeedLinkReturn *ret = objc_getAssociatedObject(previous, &kDuoFeedLinkReturnDetail);
    if (![objc_getAssociatedObject(top, &kDuoFeedLinkPage) boolValue] || !ret.detail.count) return nil;
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventFeedOpened, 0.0);

    UIView *surface = state.host.view;
    BOOL animate = animated && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    UIView *snapshot = nil;
    if (animate) {
        [surface layoutIfNeeded];
        snapshot = [surface snapshotViewAfterScreenUpdates:NO];
        snapshot.frame = surface.bounds;
        snapshot.userInteractionEnabled = NO;
    }
    // Settle the final split underneath: previous feed on the left, its
    // thread on the right.
    objc_setAssociatedObject(previous, &kDuoFeedLinkReturnDetail, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state.feed setViewControllers:[pages subarrayWithRange:NSMakeRange(0, pages.count - 1)] animated:NO];
    UIViewController *backstop = state.secondary.viewControllers.firstObject;
    [state.secondary setViewControllers:[(backstop ? @[backstop] : @[]) arrayByAddingObjectsFromArray:ret.detail] animated:NO];
    ApolloDuoPostsSyncColumns(state);
    [surface layoutIfNeeded];
    ApolloLog(@"[DuoSplit] Back from a feed link; restored %lu thread page(s)%@",
              (unsigned long)ret.detail.count, animate ? @" (animated)" : @"");
    if (!snapshot) return top;

    [surface addSubview:snapshot];
    UIView *feedView = state.feed.view, *threadView = state.secondary.view;
    CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX([threadView convertRect:threadView.bounds toView:surface]);
    feedView.alpha = 0.0;
    feedView.transform = CGAffineTransformMakeTranslation(-48.0, 0.0);
    threadView.transform = CGAffineTransformMakeTranslation(MAX(0.0, travel), 0.0);
    [surface bringSubviewToFront:snapshot];
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:1.0 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        snapshot.alpha = 0.0;
        snapshot.transform = CGAffineTransformMakeTranslation(48.0, 0.0);
        feedView.alpha = 1.0;
        feedView.transform = CGAffineTransformIdentity;
        threadView.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        [snapshot removeFromSuperview];
        feedView.alpha = 1.0;
        feedView.transform = CGAffineTransformIdentity;
        threadView.transform = CGAffineTransformIdentity;
    }];
    return top;
}

// Apollo opens a Reddit link in whichever tab is showing. On Duo Settings is
// a split, so a subreddit or post opened from Safari there landed in the
// Settings detail column and stayed. Open it from the Posts tab instead.
static BOOL ApolloDuoSplitRouteSettingsRedditContent(ApolloDuoSplitState *state, UIViewController *page, BOOL animated) {
    if (state.split && !state.changing && [state.kind isEqualToString:@"settings"]
        && ([page isKindOfClass:ApolloClassPostsViewController]
            || [page isKindOfClass:ApolloClassCommentsViewController])) {
        UITabBarController *tabs = state.outer.tabBarController;
        if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
        } else {
            tabs.selectedViewController = tabs.viewControllers.firstObject;
        }
        UINavigationController *posts = (id)tabs.selectedViewController;
        if ([posts isKindOfClass:UINavigationController.class] && posts != state.outer) {
            ApolloLog(@"[DuoSplit] %@ opened from Settings; showing it in Posts", NSStringFromClass(page.class));
            [posts pushViewController:page animated:animated];
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloDuoSplitRoutePush(UINavigationController *nav, UIViewController *page, BOOL animated) {
    if (sDuoSplitPushingFeedLink) return NO;
    // UIKit pushes column containers while adapting a split. Those are native
    // containment operations, not sidebar selections. Redirecting the secondary
    // navigation controller into its own stack raises a UIKit assertion.
    if ([page isKindOfClass:UINavigationController.class] ||
        [page isKindOfClass:UISplitViewController.class]) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, YES);
    if (ApolloDuoSplitRouteSettingsRedditContent(state, page, animated)) return YES;
    if (state.split && !state.changing && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
        if (ApolloDuoSplitShouldOpen((id)state.outer.tabBarController)) {
            ApolloDuoSplitNavigateProfile(state, page, YES);
            return YES;
        }
        // The portrait drawer is an overlay, not a profile sidebar. Push onto
        // the retained feed so native Back returns to the previous page.
        if (state.feed && (nav == state.primary || nav == state.outer)) {
            [state.feed pushViewController:page animated:animated];
            [state.host setListVisible:NO animated:animated];
            return YES;
        }
    }
    if (state.feed && !state.changing) {
        // A push lands in the columns a drag is holding: let the drag go first.
        ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
        if (ApolloDuoPostsRouteFeedLink(state, nav, page, animated)) return YES;
        if (state.host.postsColumnsPaired && (nav == state.feed || nav == state.outer)) {
            NSString *incomingPost = ApolloDuoCommentsPostID(page);
            NSString *visiblePost = ApolloDuoCommentsPostID(state.secondary.topViewController);
            // A comment permalink is a deliberate jump within a post, not a
            // feed re-selection. Keep those native navigations available.
            if (incomingPost.length && [incomingPost isEqualToString:visiblePost]
                && !ApolloReadSwiftStringIvar(page, "commentID").length) {
                ApolloLog(@"[DuoSplit] current post reselected; keeping comments and scroll position");
                return YES;
            }
        }
        state.needsDefault = NO;
        if (nav == state.primary || (nav == state.outer && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"])) {
            // Apollo may wait for subreddit data before pushing. The drawer
            // has already dismissed by then, so its visibility is not an
            // animation gate; preserve the originating navigation request.
            BOOL animate = animated && !UIAccessibilityIsReduceMotionEnabled();
            ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventFeedOpened, 0.0);
            [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject] animated:NO];
            ApolloDuoPostsSyncColumns(state);
            [state.host.view layoutIfNeeded];
            // Let Apollo's navigation controller/delegate perform its normal
            // forward transition. Replacing the root with animation avoids
            // accumulating old subreddit pages in the comments Back stack.
            [state.feed setViewControllers:@[page] animated:animate];
            ApolloLog(@"[DuoSplit] subreddit forward transition animated=%d", animate);
            [state.host setListVisible:NO animated:YES];
        } else if (nav == state.feed || nav == state.outer) {
            if (!ApolloDuoPostsUsesSplit(state) || ApolloDuoIsFeedPage(page)) {
                // A single page needs no column replacement or custom slide.
                // Apollo's native animator keeps the outgoing Focused feed
                // visible underneath the arriving thread (and on Back). A
                // feed page (Gallery View over an unpaired feed) is pushed
                // the same way, full width, never into the comments pane.
                if (nav == state.feed) return NO;
                [state.feed pushViewController:page animated:animated];
                return YES;
            }
            ApolloDuoPostsSetDetail(state, page, animated);
        } else return NO;
        ApolloDuoPostsSyncColumns(state);
        return YES;
    }
    // A feed pushed mid column change bypasses the routes above; it still
    // replaces what a closed thread was closed from.
    if (state.feed && ApolloClassPostsViewController && [page isKindOfClass:ApolloClassPostsViewController])
        ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventFeedOpened, 0.0);
    BOOL searchSubreddit = [state.kind isEqualToString:@"search"] && ApolloClassPostsViewController
        && [page isKindOfClass:ApolloClassPostsViewController];
    // A subreddit from Search fills the width; the column hides behind it.
    // Whatever was showing (full-width Search, or the column beside the
    // previous subreddit) leaves to the left as the subreddit arrives, like a
    // native forward push. Capture it before the columns change.
    BOOL searchOpens = [state.kind isEqualToString:@"search"] && nav == state.outer && !state.split
        && ApolloDuoSplitShouldOpen((id)nav.tabBarController);
    UIView *searchOutgoing = nil;
    if (searchSubreddit && !state.changing && !UIAccessibilityIsReduceMotionEnabled()
        && (searchOpens || (state.split && nav == state.primary))) {
        UIView *visible = state.split ? state.host.viewIfLoaded : state.outer.viewIfLoaded;
        if (visible.window) searchOutgoing = [visible snapshotViewAfterScreenUpdates:NO];
    }
    if (searchOpens) ApolloDuoSplitOpen(state);
    if (state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && nav == state.secondary && !state.selectingAccountShortcut) {
        // Content links are pushes, not menu replacements. Commit the stack
        // and full-height geometry together before fading in the destination.
        ApolloDuoAccountSetPages(state, [state.secondary.viewControllers arrayByAddingObject:page]);
        return YES;
    }
    if (!state.split || state.changing || (nav != state.primary && nav != state.outer && !state.selectingAccountShortcut)) return NO;
    if ([state.kind isEqualToString:@"settings"] && page.class != UIViewController.class
        && page.class == state.secondary.viewControllers.firstObject.class) {
        // Each native Settings root row constructs its own destination class.
        // Re-selecting the row returns to its retained first page. Keeping
        // that controller preserves its scroll position and live controls;
        // an already visible first page needs no navigation at all.
        // Only root/sidebar pushes reach this branch; detail-page navigation
        // remains Apollo's normal push path.
        if (state.secondary.viewControllers.count > 1) {
            [state.secondary popToRootViewControllerAnimated:animated && !UIAccessibilityIsReduceMotionEnabled()];
        }
        ApolloLog(@"[DuoSplit] current Settings destination reselected; keeping root page");
        return YES;
    }
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"account"]) {
        ApolloDuoAccountSetPages(state, @[state.root, page]);
    } else {
        // A new Search detail may still be loading when UIKit performs the
        // root replacement. Animate its entire live navigation pane, including
        // chrome, rather than a blank page whose content appears afterward.
        // This mirrors the explicit rightward Back across the split boundary.
        [state.secondary setViewControllers:@[page] animated:NO];
        if (searchSubreddit) {
            ApolloDuoSearchUpdateBackItem(state);
            // The host may just have been installed as the outer navigation
            // root. Layout the outer container first so UIKit attaches and
            // sizes its child, then hide the column before reading the pane.
            UIView *surface = state.host.view;
            [UIView performWithoutAnimation:^{
                [state.outer.view layoutIfNeeded];
                [surface layoutIfNeeded];
                ApolloDuoSearchSetColumnVisible(state, NO, NO);
                [state.secondary.view layoutIfNeeded];
            }];
            CGRect pane = ApolloDuoPostsDetailPane(state);
            BOOL animate = state.outer.view.window && !UIAccessibilityIsReduceMotionEnabled()
                && !CGRectIsNull(pane) && !CGRectIsEmpty(pane);
            CGFloat travel = animate ? CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane) : 0;
            if (searchOutgoing && travel > 0) {
                // Both travel the same distance on the same curve, so the
                // outgoing page abuts the arriving subreddit without a gap.
                // A UIView completion removes it even when interrupted.
                searchOutgoing.frame = surface.bounds;
                searchOutgoing.userInteractionEnabled = NO;
                [surface addSubview:searchOutgoing];
                [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                    searchOutgoing.transform = CGAffineTransformMakeTranslation(-travel, 0);
                } completion:^(__unused BOOL finished) {
                    [searchOutgoing removeFromSuperview];
                }];
            }
            if (travel > 0) ApolloDuoSlideView(state.secondary.view, travel, 0, 0.32, nil);
        }
    }
    ApolloDuoSearchUpdateBackItem(state);
    if ([state.kind isEqualToString:@"subreddits"]) {
        // A sidebar selection no longer pushes the list off screen, so its
        // usual viewWillAppear deselection never runs. End the tap feedback
        // after UIKit finishes selecting the row; otherwise Home/subreddits
        // retain a solid highlight until the list disappears or is reused.
        __weak UIViewController *weakRoot = state.root;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *root = weakRoot;
            if (!root || root.isEditing) return;
            UITableView *table = ApolloDuoSplitFindTable(root.viewIfLoaded);
            for (NSIndexPath *path in table.indexPathsForSelectedRows) {
                [table deselectRowAtIndexPath:path animated:YES];
            }
        });
    }
    // The detail column is already present. showColumn:Secondary is not a
    // harmless reveal while an offscreen tab is adapting: UIKit changes its
    // preferredDisplayMode to SecondaryOnly, so Account/Inbox lose their
    // sidebar when the tab next appears. Keep the user's display mode intact.
    ApolloLog(@"[DuoSplit] %@ selection replaced detail with %@", state.kind, NSStringFromClass(page.class));
    return YES;
}

static void ApolloDuoSplitRememberSettings(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, YES);
    if (state.changing || ![state.kind isEqualToString:@"settings"]) return;
    NSArray *stack = nav.viewControllers;
    if (!state.split && stack.count > 1) state.lastSettings = [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)];
    else if (nav == state.secondary && stack.count) state.lastSettings = [stack copy];
}

static NSIndexPath *(*sApolloDuoListWillSelectOriginal)(id, SEL, UITableView *, NSIndexPath *);
static NSIndexPath *ApolloDuoListWillSelect(id controller, SEL selector, UITableView *table, NSIndexPath *path) {
    NSIndexPath *candidate = sApolloDuoListWillSelectOriginal
        ? sApolloDuoListWillSelectOriginal(controller, selector, table, path) : path;
    if (!candidate) return nil;
    UIViewController *list = (UIViewController *)controller;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(list.navigationController, NO);
    if (!state.split || !state.feed || state.changing || !state.host.listVisible
        || list.navigationController != state.primary || list.isEditing || table.isEditing) return candidate;

    // willSelect still has UIKit's VISIBLE path. The Following module maps
    // didSelect into native section space later, so resolving a row there would
    // double-map reordered/FOLLOWING sections and could suppress the wrong row.
    NSString *target = ApolloSubredditListNameAtIndexPath(table, candidate);
    // Linked feeds retain earlier feeds in Back history. Portrait can also
    // append comments, so compare with the last feed rather than either end.
    NSUInteger feedPages = ApolloDuoFeedStackKeptCount(state.feed);
    UIViewController *visibleFeed = feedPages ? state.feed.viewControllers[feedPages - 1] : nil;
    NSString *current = ApolloNamedSubredditForPostsController(visibleFeed);
    if (target.length == 0 || current.length == 0
        || [target caseInsensitiveCompare:current] != NSOrderedSame) return candidate;

    __weak ApolloDuoSplitHost *weakHost = state.host;
    __weak UITableView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *liveTable = weakTable;
        [[liveTable cellForRowAtIndexPath:candidate] setHighlighted:NO animated:YES];
        for (NSIndexPath *selected in liveTable.indexPathsForSelectedRows) {
            [liveTable deselectRowAtIndexPath:selected animated:YES];
        }
        [weakHost setListVisible:NO animated:YES];
    });
    ApolloLog(@"[DuoSplit] current subreddit reselected; dismissing drawer without navigation");
    // Cancel before Apollo fetches or replaces the feed. In particular, retain
    // both its scroll position and any currently open comments navigation stack.
    return nil;
}

static void ApolloDuoInstallListReselectionGuard(Class listClass) {
    SEL selector = @selector(tableView:willSelectRowAtIndexPath:);
    Method existing = class_getInstanceMethod(listClass, selector);
    sApolloDuoListWillSelectOriginal = existing
        ? (NSIndexPath *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(existing) : NULL;
    const char *types = existing ? method_getTypeEncoding(existing) : "@@:@@";
    // Prefer an override on this class, preserving any inherited delegate method.
    if (!class_addMethod(listClass, selector, (IMP)ApolloDuoListWillSelect, types)) {
        class_replaceMethod(listClass, selector, (IMP)ApolloDuoListWillSelect, types);
    }
}

// List navigation can reuse the current feed without calling push. Finish
// the row interaction here so both that path and ordinary pushes dismiss.
@interface ApolloDuoSubredditList : UIViewController @end
%group ApolloDuoSubredditListHooks
%hook ApolloDuoSubredditList
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig(tableView, indexPath);
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(((UIViewController *)self).navigationController, NO);
    // A picked row is a feed switch, which can reuse the visible feed page.
    if (state.feed && !((UIViewController *)self).isEditing)
        ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventFeedOpened, 0.0);
    if (!state.feed || state.changing || ((UIViewController *)self).isEditing) return;
    __weak ApolloDuoSplitHost *host = state.host;
    __weak UITableView *table = tableView;
    dispatch_async(dispatch_get_main_queue(), ^{
        // UIKit marks selection after the delegate returns.
        for (NSIndexPath *path in table.indexPathsForSelectedRows) {
            [table deselectRowAtIndexPath:path animated:YES];
        }
        [host setListVisible:NO animated:YES];
    });
}
%end
%end

@interface ApolloDuoSplitNavigation : UINavigationController @end
%group ApolloDuoSplitNavigationHooks
%hook ApolloDuoSplitNavigation
- (void)viewDidLoad {
    %orig;
    ApolloDuoInstallBackSwipe((id)self);
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    %orig(navigation, controller, animated);
    ApolloDuoInstallBackSwipe(navigation);
    ApolloDuoNoteNativeBackShown(navigation);
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    // Native didShow finalizes the bar after push/pop and column migration.
    // Relayout the host then so it does not keep the outgoing Back reservation.
    if (navigation == state.feed) {
        [state.host.viewIfLoaded setNeedsLayout];
        // A push, a pop or a new root on the feed (a subreddit switch, a
        // feed link, Search) leaves a closed thread behind.
        if (!state.changing) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventCheck, 0.0);
    }
    ApolloDuoPostsRestoreFeedLinkDetail(state, navigation, controller);
    if (navigation == state.secondary) ApolloDuoSplitSyncGallerySidebar(state);
    if (ApolloDuoPostsPopReachedBackstop(state, navigation, controller)) {
        // A Swift-direct pop (the tab-bar pan, the goBack key command) left
        // the thread pane on its backstop. Close the column at once, without
        // animation, under a snapshot of the pane: the column is reparented,
        // which must wait until UIKit has finished this transition, and the
        // snapshot holds the pane until the close lays out the full-width feed
        // in the same transaction. Apollo also queued the thread as a forward
        // page, which the split's own close never does, and a later forward
        // pan would push it over a new thread. Drop it on purpose with
        // Apollo's own didReceiveMemoryWarning override, which empties
        // poppedViewControllers (the native wipe ApolloForwardSwipeExpiry
        // relies on); the split never edits that Swift array itself. The split
        // remembers that page instead, as any close of the column does, for
        // its own forward swipe on the feed.
        UIViewController *popped = ApolloDuoSplitForwardPage(navigation);
        if (popped) {
            // The pane already shows its backstop: no picture of the thread.
            ApolloDuoPostsRememberClosedThread(state, @[popped], nil, CGRectNull);
            [navigation didReceiveMemoryWarning];
        }
        UIView *surface = state.host.view;
        CGRect pane = ApolloDuoPostsDetailPane(state);
        UIView *snapshot = surface.window && !CGRectIsNull(pane) && !CGRectIsEmpty(pane)
            ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
        if (snapshot) {
            [state.host.postsTransitionSnapshot removeFromSuperview];
            snapshot.frame = pane;
            snapshot.userInteractionEnabled = NO;
            [surface insertSubview:snapshot belowSubview:state.host.listDismiss];
            state.host.postsTransitionSnapshot = snapshot;
        }
        __weak ApolloDuoSplitState *weakState = state;
        __weak ApolloDuoSplitHost *weakHost = state.host;
        __weak UINavigationController *weakNavigation = navigation;
        __weak UIViewController *weakShown = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloDuoSplitState *live = weakState;
            if (ApolloDuoPostsPopReachedBackstop(live, weakNavigation, weakShown)) {
                // Removes the snapshot along with the close's own layout.
                ApolloDuoPostsSetDetail(live, nil, NO);
                ApolloLog(@"[DuoSplit] a pop reached the thread backstop; closed the thread column");
            }
            if (snapshot && weakHost.postsTransitionSnapshot == snapshot) {
                [snapshot removeFromSuperview];
                weakHost.postsTransitionSnapshot = nil;
            }
        });
    }
}
// Apollo's override empties its forward pages; the feed forgets its closed
// thread with them (a real memory warning, or ApolloForwardSwipeExpiry).
- (void)didReceiveMemoryWarning {
    %orig;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (self == state.feed) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventMemoryWarning, 0.0);
}
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.feed && !state.changing && self == state.primary) hidden = YES;
    if (state.split && !state.changing && self == state.secondary &&
        [state.kind isEqualToString:@"account"] && state.secondary.topViewController == state.root) {
        hidden = YES;
    }
    %orig(hidden, animated);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    UINavigationController *nav = (id)self;
    Ivar leftIvar = class_getInstanceVariable(nav.class, "leftScreenEdgePanGestureRecognizer");
    BOOL back = leftIvar && object_getIvar(self, leftIvar) == gesture;
    // One owner for backward navigation, including when folded. Apollo's edge
    // pan otherwise competes with the pane-aware swipe and can pop twice. It
    // owns a pop onto a real page of the same pane (every pop when folded),
    // and the pane swipe stands down for that one.
    if (back && ApolloDuoHasBackSwipe(nav) && !ApolloDuoNativeBackPanOwns(nav)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (!state.split || state.changing) {
        BOOL result = %orig(gesture);
        if (back && result) ApolloDuoNoteNativeBackBegan(nav);
        return result;
    }
    Ivar rightIvar = class_getInstanceVariable(nav.class, "rightScreenEdgePanGestureRecognizer");
    BOOL forward = rightIvar && object_getIvar(self, rightIvar) == gesture;
    if (!back && !forward) return %orig(gesture);
    // The outer controller now contains a host, not a browsable page. Its
    // recognizers must not compete with the detail controller's native pans.
    // A feed with a closed thread to bring back leaves forward to the pane's
    // forward swipe, so one swipe never both reopens the thread and pushes.
    if ((self != state.secondary && !(self == state.feed && !state.host.postsShowingDetail)) || (back && nav.viewControllers.count < 2) ||
        (forward && (!ApolloDuoSplitForwardPage(self) || ApolloDuoSplitCanRestoreClosedThread(nav)))) return NO;
    UIView *view = nav.view;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    CGPoint point = [gesture locationInView:view];
    if (!CGRectContainsPoint(pane, point)) return NO;
    sDuoSplitGesture = (__bridge void *)gesture;
    sDuoSplitGestureView = (__bridge void *)view;
    sDuoSplitGestureOffset = back ? -view.safeAreaInsets.left : view.safeAreaInsets.right;
    BOOL result = %orig(gesture);
    sDuoSplitGesture = NULL;
    sDuoSplitGestureView = NULL;
    sDuoSplitGestureOffset = 0.0;
    if (back && result) ApolloDuoNoteNativeBackBegan(nav);
    return result;
}
- (void)screenEdgePanned:(UIPanGestureRecognizer *)gesture {
    ApolloDuoSplitNativePanReleaseRun(self, gesture, ^{ %orig(gesture); });
}
// Apollo's navigation-bar pan drives the same handler, Back or Forward.
- (void)navigationBarPanned:(UIPanGestureRecognizer *)gesture {
    ApolloDuoSplitNativePanReleaseRun(self, gesture, ^{ %orig(gesture); });
}
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    // Record the completed navigation request using its synchronous PostsType
    // slug. Split replacement may lay out before window attachment and omit
    // appearance callbacks; titles/about models can also arrive later.
    NSString *visited = ApolloDuoSplitIsUnfolded() && ((UINavigationController *)self).viewIfLoaded.window
        ? ApolloNamedSubredditForPostsController(controller) : nil;
    if (ApolloDuoSplitRoutePush(self, controller, animated)) {
        if (visited.length) ApolloSearchRecordVisit(visited);
        ApolloDuoSplitSyncGallerySidebar(ApolloDuoSplitStateForNavigation(self, NO));
        return;
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary || self == state.feed)) {
        controller.extendedLayoutIncludesOpaqueBars = YES;
    }
    if (state.split && [state.kind isEqualToString:@"account"] && self == state.secondary) {
        [state.secondary setNavigationBarHidden:NO animated:NO];
    }
    %orig(controller, state.changing ? NO : animated);
    [state.host.viewIfLoaded setNeedsLayout];
    ApolloDuoSplitRememberSettings(self);
    if (self == state.secondary) ApolloDuoSplitSyncGallerySidebar(state);
}
- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary || self == state.feed)) {
        // New detail pages default to NO even when existing Apollo pages use
        // YES. Prepare them before UIKit installs the stack, so an opaque
        // theme cannot deduct the vertical tab rail's height from their view.
        // Safe areas already describe the sidebar, navigation bar, and rail.
        for (UIViewController *controller in controllers) {
            controller.extendedLayoutIncludesOpaqueBars = YES;
        }
    }
    %orig(controllers, animated);
    [state.host.viewIfLoaded setNeedsLayout];
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popViewControllerAnimated:animated];
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    // A pop from anywhere else (a key command, a button) ends a drag first.
    ApolloDuoPostsCancelInteractiveClose(state, NO, 0.0);
    // A pop Apollo's own interactive Back drives, whether it reaches here as
    // the pan begins or as it ends, is a native page pop: never one of the
    // split's own (thread close, Account pages, feed-link Back).
    BOOL native = ApolloDuoNativeBackInFlight(self);
    if (!native && state.feed && !state.changing && self == state.secondary && state.secondary.viewControllers.count == 2) {
        UIViewController *page = state.secondary.topViewController;
        ApolloDuoPostsSetDetail(state, nil, animated);
        return page;
    }
    if (!native && state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && self == state.secondary && detail.viewControllers.count > 1) {
        UIViewController *page = detail.topViewController;
        ApolloDuoAccountSetPages(state, [detail.viewControllers subarrayWithRange:NSMakeRange(0, detail.viewControllers.count - 1)]);
        ApolloDuoSplitSyncGallerySidebar(state);
        return page;
    }
    if (!native && state.feed && self == state.feed) {
        UIViewController *popped = ApolloDuoPostsPopFeedLink(state, animated);
        if (popped) return popped;
    }
    UIViewController *page = %orig(animated);
    [state.host.viewIfLoaded setNeedsLayout];
    if (self == state.secondary) ApolloDuoSplitSyncGallerySidebar(state);
    ApolloDuoSplitScheduleUpdate();
    return page;
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popToRootViewControllerAnimated:animated];
    NSArray *pages = %orig(animated);
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (self == state.secondary) ApolloDuoSplitSyncGallerySidebar(state);
    ApolloDuoSplitScheduleUpdate();
    return pages;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoInstallBackSwipe((id)self);
    ApolloDuoSplitScheduleUpdate();
}
%end
%end

%hook UITabBarController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    if (self != (id)ApolloMainTabBarController() ||
        (self != sDuoSplitKnownTabs && !ApolloDuoRailHasVisibleSideBar() && ApolloDuoCurrentMode() == ApolloDuoModePhone)) {
        %orig(size, coordinator);
        return;
    }
    // Fold, unfold or rotation: a thread close following the finger is let
    // go before the columns change (it needs no layout to go).
    ApolloDuoPostsCancelActiveInteractiveClose();
    UINavigationController *selectedNavigation = (id)self.selectedViewController;
    UINavigationController *detailNavigation = [selectedNavigation isKindOfClass:UINavigationController.class]
        ? ApolloDuoSplitDetailNavigation(selectedNavigation) : nil;
    UIViewController *selectedPage = detailNavigation.topViewController;
    BOOL profileSection = NO;
    for (UIViewController *page in detailNavigation.viewControllers) {
        if ([ApolloDuoSplitKind(page) isEqualToString:@"account"] && page != selectedPage) profileSection = YES;
    }
    UITableView *sectionTable = profileSection ? ApolloDuoSplitFindTable(selectedPage.viewIfLoaded) : nil;
    NSIndexPath *anchor = sectionTable.indexPathsForVisibleRows.firstObject;
    CGFloat anchorOffset = anchor ? CGRectGetMinY([sectionTable rectForRowAtIndexPath:anchor])
        - sectionTable.contentOffset.y - sectionTable.adjustedContentInset.top : 0;
    __weak UITableView *weakSectionTable = sectionTable;
    void (^restoreSectionPosition)(void) = ^{
        UITableView *table = weakSectionTable;
        if (!anchor || !table.window || table.dragging || table.decelerating
            || anchor.section >= table.numberOfSections
            || anchor.row >= [table numberOfRowsInSection:anchor.section]) return;
        CGFloat y = CGRectGetMinY([table rectForRowAtIndexPath:anchor])
            - anchorOffset - table.adjustedContentInset.top;
        CGFloat minimum = -table.adjustedContentInset.top;
        CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
        [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(maximum, MAX(minimum, y))) animated:NO];
    };
    // Install/remove column containers before UIKit forwards the new size to
    // children. Waiting for viewDidLayoutSubviews exposed one full-width frame
    // and the old transition guard then delayed splitting until animation end.
    sDuoSplitResizingTabs = self;
    sDuoSplitTargetSize = size;
    sDuoSplitSizeCoordinator = coordinator;
    ApolloLog(@"[DuoSplit] preparing all tabs for %.0fx%.0f", size.width, size.height);
    [UIView performWithoutAnimation:^{ ApolloDuoSplitUpdate(); }];
    %orig(size, coordinator);
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        ApolloDuoSplitUpdate();
        // Texture enqueues row-height updates when the table's width changes.
        // Commit that existing measurement during UIKit's size animation, so
        // the old wrapping does not remain until a second row animation runs.
        [self.view layoutIfNeeded];
        // The split can keep the previous orientation's rail insets through
        // this animation; correct them inside it so the navigation pill never
        // renders under the status region.
        ApolloDuoSplitRepairSafeAreas(self);
        ApolloDuoAccountRefreshPortraitGrid(self);
        UINavigationController *selected = (id)self.selectedViewController;
        if ([selected isKindOfClass:UINavigationController.class]) {
            UIViewController *page = ApolloDuoSplitDetailNavigation(selected).topViewController;
            UITableView *table = page.isViewLoaded ? ApolloDuoSplitFindTable(page.view) : nil;
            SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
            if ([table respondsToSelector:commit]) {
                ((void (*)(id, SEL))objc_msgSend)(table, commit);
                [table layoutIfNeeded];
            }
        }
        restoreSectionPosition();
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (sDuoSplitSizeCoordinator != coordinator) return;
        restoreSectionPosition();
        sDuoSplitResizingTabs = nil;
        sDuoSplitSizeCoordinator = nil;
        ApolloDuoSplitRepairSafeAreas(self);
        ApolloDuoAccountRefreshPortraitGrid(self);
        ApolloDuoSplitScheduleUpdate();
    }];
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (self == (id)ApolloMainTabBarController()) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedViewController:(UIViewController *)controller {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
    if (mainTabs && controller != self.selectedViewController) ApolloDuoPostsCancelActiveInteractiveClose();
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(controller);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedIndex:(NSUInteger)index {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
    if (mainTabs && index != self.selectedIndex) ApolloDuoPostsCancelActiveInteractiveClose();
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(index);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
%end

%hook UIPanGestureRecognizer
- (CGPoint)locationInView:(UIView *)view {
    CGPoint point = %orig(view);
    if ((__bridge void *)self == sDuoSplitGesture && (__bridge void *)view == sDuoSplitGestureView) {
        point.x += sDuoSplitGestureOffset;
    }
    return point;
}
- (CGPoint)translationInView:(UIView *)view {
    return ApolloDuoSplitReleaseTranslation(self, view, %orig(view));
}
%end

// Apollo manually centers its EmptyStateLabel in ASTableView's full bounds.
// In a modern split those bounds extend behind the primary column. Adjust the
// native geometry at its setter, and on safe-area changes (including hinge-only
// changes with no window resize). Keep native vertical placement and sizing.
static char kDuoEmptyStateAdjusted;
static CGFloat ApolloDuoEmptyStateCenterX(UILabel *label, CGFloat nativeX) {
    UIView *parent = label.superview;
    if (!parent) return nativeX;
    UIViewController *owner = nil;
    for (UIResponder *responder = parent; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            owner = (id)responder;
            break;
        }
    }
    CGRect pane = ApolloDuoSplitContentFrame(owner, parent);
    if (!CGRectIsNull(pane) && CGRectGetWidth(pane) > 0.0) {
        objc_setAssociatedObject(label, &kDuoEmptyStateAdjusted, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectGetMidX(pane);
    }
    if ([objc_getAssociatedObject(label, &kDuoEmptyStateAdjusted) boolValue]) {
        objc_setAssociatedObject(label, &kDuoEmptyStateAdjusted, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectGetMidX(parent.bounds);
    }
    return nativeX;
}

@interface ApolloDuoEmptyStateLabel : UILabel @end
@interface ApolloDuoEmptyStateTable : UITableView @end
%group ApolloDuoEmptyStateHooks
%hook ApolloDuoEmptyStateLabel
- (void)setCenter:(CGPoint)center {
    center.x = ApolloDuoEmptyStateCenterX(self, center.x);
    %orig(center);
}
- (void)setFrame:(CGRect)frame {
    frame.origin.x = ApolloDuoEmptyStateCenterX(self, CGRectGetMidX(frame)) - frame.size.width / 2.0;
    %orig(frame);
}
- (void)safeAreaInsetsDidChange {
    %orig;
    CGPoint center = [(UILabel *)self center];
    CGFloat x = ApolloDuoEmptyStateCenterX(self, center.x);
    if (fabs(center.x - x) > 0.1) [(UILabel *)self setCenter:CGPointMake(x, center.y)];
}
- (void)didMoveToWindow {
    %orig;
    CGPoint center = [(UILabel *)self center];
    CGFloat x = ApolloDuoEmptyStateCenterX(self, center.x);
    if (fabs(center.x - x) > 0.1) [(UILabel *)self setCenter:CGPointMake(x, center.y)];
}
%end
%hook ApolloDuoEmptyStateTable
- (void)layoutSubviews {
    %orig;
    if (!ApolloDuoAccountIsOverviewTable((UITableView *)self)) return;
    for (UIResponder *responder = self; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(((UIViewController *)responder).navigationController, NO);
        if (!state.changing) [state.host scheduleOverviewAlignment];
        break;
    }
}
- (void)safeAreaInsetsDidChange {
    %orig;
    // A label already inside the old safe area does not necessarily receive
    // its own notification when only the sidebar width changes. The table
    // does; refresh the existing label without waiting for another selection.
    Class emptyLabel = NSClassFromString(@"Apollo.EmptyStateLabel");
    for (UIView *view in [(UITableView *)self subviews]) {
        if (![view isKindOfClass:emptyLabel]) continue;
        CGPoint center = view.center;
        CGFloat x = ApolloDuoEmptyStateCenterX((id)view, center.x);
        if (fabs(center.x - x) > 0.1) view.center = CGPointMake(x, center.y);
    }
}
%end
%end

@interface ApolloDuoTabSceneDelegate : NSObject @end
%group ApolloDuoTabSelectionHooks
%hook ApolloDuoTabSceneDelegate
- (BOOL)tabBarController:(UITabBarController *)tabs
 shouldSelectViewController:(UIViewController *)page {
    BOOL allowed = %orig(tabs, page);
    if (!allowed || tabs != (id)ApolloMainTabBarController()
        || ApolloDuoSplitIsUnfolded() || !ApolloDuoCoverChromeIsActive()
        || ![page isKindOfClass:UINavigationController.class]) return allowed;
    UINavigationController *nav = (id)page;
    NSString *kind = ApolloDuoSplitKind(nav.viewControllers.firstObject);
    if (([kind isEqualToString:@"account"] || [kind isEqualToString:@"settings"]
         || [kind isEqualToString:@"inbox"])
        && nav.viewControllers.count > 1 && !nav.transitionCoordinator
        && !tabs.presentedViewController && !nav.presentedViewController) {
        // Only a tab tap returns to the overview. Programmatic selection
        // (including deep links) keeps its requested destination.
        [nav popToRootViewControllerAnimated:NO];
    }
    return allowed;
}
%end
%end

// Friends uses manually positioned tables and a toolbar, rather than a native
// table-controller header. Its original layout assumes the whole window width.
%hook _TtC6Apollo21FriendsViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *controller = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || controller.navigationController != state.secondary) return;
    UIView *view = controller.view;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    if (pane.size.width <= 0 || pane.size.height <= 44) return;
    Ivar toolbarIvar = class_getInstanceVariable([controller class], "segmentedControlToolbar");
    UIToolbar *toolbar = toolbarIvar ? object_getIvar(self, toolbarIvar) : nil;
    CGRect toolbarFrame = CGRectMake(pane.origin.x, pane.origin.y, pane.size.width, 44);
    if (toolbar && !CGRectEqualToRect(toolbar.frame, toolbarFrame)) toolbar.frame = toolbarFrame;
    Ivar segmentIvar = class_getInstanceVariable([controller class], "typeSegmentedControl");
    UISegmentedControl *segments = segmentIvar ? object_getIvar(self, segmentIvar) : nil;
    if (segments) {
        CGRect frame = segments.frame;
        frame.size.width = MAX(0, pane.size.width - 32);
        if (!CGRectEqualToRect(segments.frame, frame)) segments.frame = frame;
    }

}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    UIViewController *controller = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || controller.navigationController != state.secondary) return;
    Ivar toolbarIvar = class_getInstanceVariable(controller.class, "segmentedControlToolbar");
    UIView *toolbar = toolbarIvar ? object_getIvar(self, toolbarIvar) : nil;
    CGFloat top = CGRectGetMaxY(toolbar.frame) + 8;
    for (UIView *child in controller.view.subviews) {
        if (![child isKindOfClass:UITableView.class]) continue;
        UITableView *table = (id)child;
        UIEdgeInsets inset = table.contentInset;
        inset.top = MAX(0, top - (table.adjustedContentInset.top - inset.top));
        if (UIEdgeInsetsEqualToEdgeInsets(inset, table.contentInset)) continue;
        // Returning from a friend's profile runs viewDidAppear again. Keep
        // the existing reading position rather than resetting the list on
        // every return; only translate it by an actual toolbar-inset change.
        CGPoint offset = table.contentOffset;
        CGFloat previousTop = table.adjustedContentInset.top;
        table.contentInset = inset;
        offset.y += previousTop - table.adjustedContentInset.top;
        [table setContentOffset:offset animated:NO];
    }
}

%end

@interface ApolloDuoCommentsPage : UIViewController @end
%group ApolloDuoCommentsLayoutHooks
%hook ApolloDuoCommentsPage
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloDuoCommentsUpdateLayoutControl((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoCommentsScheduleLayoutControl((UIViewController *)self);
}
- (void)viewWillDisappear:(BOOL)animated {
    if (objc_getAssociatedObject(self, &kApolloDuoCommentsLayoutKey)
        || ApolloDuoSplitStateForNavigation(((UIViewController *)self).navigationController, NO).feed)
        ApolloDuoPostsStopGeometry(((UIViewController *)self).viewIfLoaded);
    %orig(animated);
}
%end
%end

// A YouTube video loads in YouTubeLoadingView (thumbnail, spinner, Cancel),
// not in the media viewer: Apollo adds it to the window, pins its four edges
// to the opener's navigation view and slides it up by that view's height.
// Playback then moves to WebKit's fullscreen player over the whole window. In
// the split the opener's navigation view is a column, so loading showed in
// that column and jumped to full screen once the video played. Re-pin those
// edges to the whole split before the first layout; the slide, Cancel and
// playback stay Apollo's own.
static void ApolloDuoSplitCoverYouTubeLoading(UIView *loading) {
    UIView *column = nil;
    NSMutableArray<NSLayoutConstraint *> *edges = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in loading.superview.constraints) {
        if (constraint.firstItem != loading || ![constraint.secondItem isKindOfClass:UIView.class]) continue;
        if (column && constraint.secondItem != column) return;
        column = constraint.secondItem;
        [edges addObject:constraint];
    }
    UINavigationController *nav = (id)column.nextResponder;
    if (edges.count != 4 || ![nav isKindOfClass:UINavigationController.class]) return;
    UIView *surface = ApolloDuoSplitMediaSurface(ApolloDuoSplitStateForNavigation(nav, NO), nav);
    if (!surface || surface == column || surface.window != loading.window) return;
    [NSLayoutConstraint deactivateConstraints:edges];
    [NSLayoutConstraint activateConstraints:@[
        [loading.topAnchor constraintEqualToAnchor:surface.topAnchor],
        [loading.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor],
        [loading.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor],
        [loading.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor],
    ]];
    ApolloLog(@"[DuoSplit] YouTube loading covers the split, not its %.0fpt column",
              CGRectGetWidth(column.bounds));
}

@interface ApolloDuoYouTubeLoading : UIView @end
%group ApolloDuoYouTubeLoadingHooks
%hook ApolloDuoYouTubeLoading
- (void)didMoveToWindow {
    %orig;
    // Apollo activates the column edges right after adding the view. The
    // constraint pass that precedes the first layout re-pins them.
    if (((UIView *)self).window) [(UIView *)self setNeedsUpdateConstraints];
}
- (void)updateConstraints {
    ApolloDuoSplitCoverYouTubeLoading((UIView *)self);
    %orig;
}
%end
%end

%ctor {
    if (!ApolloDeviceIsDuo()) {
        ApolloLog(@"[DuoSplit] not an iPhone Duo; split view hooks NOT installed");
        return;
    }
    Class comments = NSClassFromString(@"Apollo.CommentsViewController");
    if (comments) %init(ApolloDuoCommentsLayoutHooks, ApolloDuoCommentsPage = comments);
    [NSNotificationCenter.defaultCenter addObserverForName:@"ApolloDuoFeedLayoutDidChange"
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            ApolloDuoRefreshLayoutControls();
        }];
    // Posted on the main thread; handled at once, before the app goes inactive.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            ApolloDuoPostsCancelActiveInteractiveClose();
        }];
    // A closed thread outlives only a short trip to the background.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            sDuoPostsBackgroundedAt = CFAbsoluteTimeGetCurrent();
        }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            NSTimeInterval away = sDuoPostsBackgroundedAt > 0 ? CFAbsoluteTimeGetCurrent() - sDuoPostsBackgroundedAt : 0.0;
            sDuoPostsBackgroundedAt = 0;
            ApolloDuoSplitState *state = sDuoPostsClosedThreadState;
            if (state) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventForeground, away);
        }];
    Class subredditList = NSClassFromString(@"Apollo.RedditListViewController");
    if (subredditList) {
        %init(ApolloDuoSubredditListHooks, ApolloDuoSubredditList = subredditList);
        ApolloDuoInstallListReselectionGuard(subredditList);
    }
    Class sceneDelegate = NSClassFromString(@"Apollo.SceneDelegate");
    if (sceneDelegate) %init(ApolloDuoTabSelectionHooks, ApolloDuoTabSceneDelegate = sceneDelegate);
    Class navigation = NSClassFromString(@"Apollo.ApolloNavigationController");
    if (navigation) %init(ApolloDuoSplitNavigationHooks, ApolloDuoSplitNavigation = navigation);
    Class emptyLabel = NSClassFromString(@"Apollo.EmptyStateLabel");
    if (emptyLabel) %init(ApolloDuoEmptyStateHooks, ApolloDuoEmptyStateLabel = emptyLabel,
                         ApolloDuoEmptyStateTable = NSClassFromString(@"ASTableView"));
    Class youTubeLoading = NSClassFromString(@"Apollo.YouTubeLoadingView");
    if (youTubeLoading) %init(ApolloDuoYouTubeLoadingHooks, ApolloDuoYouTubeLoading = youTubeLoading);
    %init;
}
