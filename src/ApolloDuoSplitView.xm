// Native sidebar/detail containers for the opened Duo. The tab still owns its
// original ApolloNavigationController: URL routing, tab gestures and account
// switching can keep addressing that object. Only its visible contents change
// at an unfold/fold boundary. UIKit owns all column frames and transitions.
#import "ApolloDuoSplitView.h"
#import "ApolloDuoSplitDivider.h"
#import "ApolloDuoDividerGeometry.h"
#import "ApolloDuoNavigationGestures.h"
#import "ApolloMediaHinge.h"
#import "ApolloSearchRecents.h"
#import "ApolloSearchVisitRecording.h"
#import "ApolloClasses.h"
#import "ApolloAccountCredentials.h"
#import "ApolloDuoAccount.h"
#import "ApolloDuoSubsChrome.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRailLayout.h"
#import "ApolloDuoPaneDrag.h"
#import "ApolloDuoUIKitCompatibility.h"
#import "ApolloSearchNativeBar.h"
#import "ApolloNavigationActions.h"
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
static void ApolloDuoUpdateDivider(ApolloDuoSplitHost *host);
static void ApolloDuoToggleFeedLayout(ApolloDuoSplitHost *host);
static void ApolloDuoToggleVisibleFeedLayout(UIViewController *controller, BOOL enabled);

@protocol ApolloDuoLayoutControl <NSObject>
- (void)updateFeedLayoutButton;
@end

static NSHashTable<id<ApolloDuoLayoutControl>> *sDuoLayoutControls;
static BOOL sDuoFeedLayoutChanging;

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
    return sDuoUnfoldedFeedLayout == 2 ? focusedImage : originalImage;
}

static void ApolloDuoRefreshLayoutButton(UIButton *button, UIBarButtonItem *item) {
    BOOL focused = sDuoUnfoldedFeedLayout == 2;
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

// Accent Navigation Buttons: a Duo glass control takes the theme accent while
// the setting is on, else `neutral` (nil keeps the glass button's own color).
static void ApolloDuoSetButtonForeground(UIButton *button, UIColor *neutral) {
    if (!button.configuration) return;
    UIColor *color = ApolloNavigationButtonAccentColor() ?: neutral;
    UIColor *current = button.configuration.baseForegroundColor;
    if (current == color || [current isEqual:color]) return;
    UIButtonConfiguration *configuration = [button.configuration copy];
    configuration.baseForegroundColor = color;
    button.configuration = configuration;
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

// A thread drag moves the pane's contents through its layer's
// sublayerTransform. The split column re-sets the navigation view's frame on
// every layout (a playing video lays out each frame), which would cancel a
// plain transform; layout never touches sublayerTransform.
static CGFloat ApolloDuoThreadDragOffset(UIView *view) {
    CALayer *layer = view.layer.presentationLayer ?: view.layer;
    return layer.sublayerTransform.m41;
}

static void ApolloDuoSetThreadDragOffset(UIView *view, CGFloat offset) {
    if (!view) return;
    [view.layer removeAnimationForKey:@"ApolloDuoThreadDrag"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.layer.sublayerTransform = offset > 0 ? CATransform3DMakeTranslation(offset, 0, 0) : CATransform3DIdentity;
    [CATransaction commit];
}

// Springs the pane back to its place on the drawer's spring.
static void ApolloDuoSettleThreadDrag(UIView *view, CGFloat from, CGFloat velocity, BOOL animated) {
    ApolloDuoSetThreadDragOffset(view, 0);
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || fabs(from) < 0.5) return;
    double omega = ApolloDuoDrawerSpringOmega();
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
    spring.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(from, 0, 0)];
    spring.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    spring.mass = 1;
    spring.stiffness = omega * omega;
    spring.damping = 2 * omega;
    spring.initialVelocity = ApolloDuoDrawerSpringInitialVelocity(from, 0, velocity);
    spring.duration = spring.settlingDuration;
    // The app opts into ProMotion, but an explicit animation without a range
    // can run at 60 Hz. Ask for the display's full rate for the settle.
    if (@available(iOS 15.0, *)) {
        float maximum = (float)UIScreen.mainScreen.maximumFramesPerSecond;
        if (maximum > 60)
            spring.preferredFrameRateRange = CAFrameRateRangeMake(MIN(80.0f, maximum), maximum, maximum);
    }
    [view.layer addAnimation:spring forKey:@"ApolloDuoThreadDrag"];
}

// Removes a thread drag's feed filler, fading it over `duration`.
static void ApolloDuoRemoveThreadDragFiller(UIView *filler, NSTimeInterval duration) {
    if (!filler) return;
    if (duration <= 0 || UIAccessibilityIsReduceMotionEnabled()) {
        [filler removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ filler.alpha = 0; } completion:^(__unused BOOL finished) {
        [filler removeFromSuperview];
    }];
}

@interface ApolloDuoSplitHost : UIViewController <UISplitViewControllerDelegate, ApolloDuoLayoutControl>
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
// Unfolded from the folded subreddit list: the drawer stays open over an empty
// feed until the reader picks a subreddit or feed.
@property(nonatomic) BOOL listPinned;
@property(nonatomic, strong) UIStackView *pinnedPrompt;
@property(nonatomic) BOOL postsShowingDetail;
@property(nonatomic) BOOL postsSplitEnabled;
@property(nonatomic) BOOL postsColumnsPaired;
@property(nonatomic, strong) ApolloDuoSplitDivider *dividerGrip;
@property(nonatomic, strong) NSNumber *dividerPreviewWidth;
// Text nodes drawing synchronously while the divider resizes the columns.
@property(nonatomic, strong) NSHashTable *dividerHeldText;
@property(nonatomic) NSUInteger dividerHeldTextGeneration;
@property(nonatomic, strong) UIView *postsTransitionSnapshot;
// The feed's trailing edge, stretched across the gap a thread drag opens.
@property(nonatomic, strong) UIView *threadDragFiller;
// The thread pane as a Back drag found it, kept for a later forward drag.
@property(nonatomic, strong) UIView *threadDragPicture;
// A forward drag's picture of the closed thread, sliding in.
@property(nonatomic, strong) UIView *restoreDragPicture;
@property(nonatomic, weak) UINavigationController *searchNavigation;
@property(nonatomic) NSUInteger listAnimationGeneration;
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
// A finger is moving the drawer; setListVisible: then settles it from there.
@property(nonatomic) BOOL listDragging;
// How much of the drawer's travel showed when the drag began.
@property(nonatomic) CGFloat listDragStart;
@property(nonatomic, strong) UIPanGestureRecognizer *listClosePan;
@property(nonatomic, strong) UIPanGestureRecognizer *listCloseStripPan;
- (CGFloat)listTravel;
- (BOOL)beginListDrag:(BOOL)opening;
- (void)moveListDrag:(CGFloat)shown;
- (void)endListDrag:(BOOL)show velocity:(CGFloat)velocity;
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
        self.listDismiss = [UIControl new];
        self.listDismiss.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.12];
        [self.listDismiss addTarget:self action:@selector(dismissList) forControlEvents:UIControlEventTouchUpInside];
        self.listDismiss.hidden = YES;
        [self.view addSubview:self.listDismiss];
        // Stands in for the feed while the pinned drawer waits for a pick.
        UILabel *promptTitle = [UILabel new];
        promptTitle.text = @"No Subreddit Selected";
        promptTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
        UILabel *promptDetail = [UILabel new];
        promptDetail.text = @"Choose a subreddit or feed from the list.";
        promptDetail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        for (UILabel *label in @[promptTitle, promptDetail]) {
            label.textColor = UIColor.secondaryLabelColor;
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.adjustsFontForContentSizeCategory = YES;
        }
        self.pinnedPrompt = [[UIStackView alloc] initWithArrangedSubviews:@[promptTitle, promptDetail]];
        self.pinnedPrompt.axis = UILayoutConstraintAxisVertical;
        self.pinnedPrompt.spacing = 6;
        self.pinnedPrompt.alignment = UIStackViewAlignmentFill;
        self.pinnedPrompt.isAccessibilityElement = NO;
        self.pinnedPrompt.hidden = !self.listPinned;
        [self.view addSubview:self.pinnedPrompt];
        self.listGlass = [[UIVisualEffectView alloc] initWithEffect:nil];
        self.listGlass.clipsToBounds = YES;
        // Move a plain container so the material and list travel together.
        // UIVisualEffectView manages its own compositor geometry.
        self.listContainer = [UIView new];
        self.listContainer.hidden = YES;
        [self.view addSubview:self.listContainer];
        self.listGlass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.listContainer addSubview:self.listGlass];
        self.listClosePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(listClosePanned:)];
        self.listClosePan.name = @"ApolloReborn.Duo.ListClose";
        self.listClosePan.delegate = (id<UIGestureRecognizerDelegate>)self;
        [self.listDismiss addGestureRecognizer:self.listClosePan];
        self.listCloseStripPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(listClosePanned:)];
        self.listCloseStripPan.name = @"ApolloReborn.Duo.ListCloseStrip";
        self.listCloseStripPan.delegate = (id<UIGestureRecognizerDelegate>)self;
        [self.listContainer addGestureRecognizer:self.listCloseStripPan];
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
    [self applyNavigationButtonColor];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyNavigationButtonColor)
                                               name:ApolloNavigationButtonColorDidChangeNotification object:nil];
}
// The list, split and profile controls follow Accent Navigation Buttons like
// Apollo's own navigation buttons.
- (void)applyNavigationButtonColor {
    if (self.splitButton) [self updateSplitButton];
    ApolloDuoSetButtonForeground(self.listButton, nil);
    ApolloDuoSetButtonForeground(self.feedLayoutButton, nil);
    ApolloDuoSetButtonForeground(self.profileBackButton, UIColor.labelColor);
    ApolloDuoSetButtonForeground(self.accountsButton, UIColor.labelColor);
    ApolloDuoSetButtonForeground(self.moreButton, UIColor.labelColor);
    UIButton *buttons[] = { self.listButton, self.splitButton, self.feedLayoutButton,
                            self.profileBackButton, self.accountsButton, self.moreButton };
    for (size_t i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) ApolloNavigationActionsAccentControl(buttons[i]);
    for (UIBarButtonItem *item in self.listNavigationBar.topItem.leftBarButtonItems) ApolloNavigationActionsAccentItem(item);
    UIBarButtonItem *sidebar = self.sidebarNavigationBar.topItem.rightBarButtonItem;
    UIColor *accent = ApolloNavigationButtonAccentColor();
    if (sidebar && sidebar.tintColor != accent) sidebar.tintColor = accent;
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.dividerGrip cancel];
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
    [self.threadDragFiller removeFromSuperview];
    self.threadDragFiller = nil;
    ApolloDuoPostsStopGeometry(self.searchNavigation.viewIfLoaded);
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self.dividerGrip cancel];
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
    if (![self.listNavigationBar.topItem.title isEqualToString:@"Subreddits"])
        self.listNavigationBar.topItem.title = @"Subreddits";
    self.listGlass.backgroundColor = self.listUsesGlass ? UIColor.clearColor
        : (ApolloThemeSubredditListBackgroundColor() ?: UIColor.systemBackgroundColor);
    // Re-vend only on an explicit style change, never on scroll/layout.
    if (refreshRows) [ApolloDuoSplitFindTable(self.subredditList.view) reloadData];
    if (self.listUsesGlass && self.listVisible)
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
    configuration.baseForegroundColor = ApolloNavigationButtonAccentColor() ?: ApolloNavigationChromeColor();
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
// Drawer drags that close the list (named ApolloReborn.Duo.ListClose…)
// can't take a pinned drawer, so it never stops partway off screen.
static void ApolloDuoEnableListCloseDrags(UIView *view, BOOL enabled) {
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if ([gesture.name hasPrefix:@"ApolloReborn.Duo.ListClose"] && gesture.enabled != enabled)
            gesture.enabled = enabled;
    }
}
- (void)updateListCloseDrags {
    ApolloDuoEnableListCloseDrags(self.listDismiss, !self.listPinned);
    ApolloDuoEnableListCloseDrags(self.listContainer, !self.listPinned);
}
- (void)setListPinned:(BOOL)listPinned {
    if (_listPinned == listPinned) return;
    _listPinned = listPinned;
    [self updateListCloseDrags];
    if (!self.pinnedPrompt || self.pinnedPrompt.hidden == !listPinned) return;
    if (listPinned) {
        self.pinnedPrompt.hidden = NO;
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{ self.pinnedPrompt.alpha = 0; } completion:^(BOOL finished) {
        if (self.listPinned) return;
        self.pinnedPrompt.hidden = YES;
        self.pinnedPrompt.alpha = 1;
    }];
}
- (void)toggleList { [self setListVisible:!self.listVisible animated:YES]; }
- (void)dismissList { [self setListVisible:NO animated:YES]; }
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated {
    [self setListVisible:visible animated:animated velocity:0];
}
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated velocity:(CGFloat)velocity {
    if (!self.subredditList) return;
    // A pinned drawer only settles open, so a drag already under way springs back.
    if (!visible && self.listPinned) visible = YES;
    [self updateListCloseDrags];
    if (!visible) [self endListEditing];
    // A drag holds the drawer between its ends; settle it even when the
    // target matches listVisible (a drag that springs back).
    if (self.listVisible == visible && !self.listDragging) return;
    [self.view layoutIfNeeded];
    CGFloat start = [self listOffset];
    BOOL reveal = visible && !self.listVisible;
    self.listDragging = NO;
    self.listVisible = visible;
    [self.view setNeedsLayout];
    if (reveal) [self prepareListReveal];
    self.listDismiss.hidden = NO;
    // The spring's tail is visually settled; let taps reach the feed then.
    self.listDismiss.userInteractionEnabled = visible;
    self.listContainer.hidden = NO;
    NSUInteger generation = ++self.listAnimationGeneration;
    NSTimeInterval duration = animated && !UIAccessibilityIsReduceMotionEnabled() ? 0.25 : 0;
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.listDismiss.alpha = visible ? 1 : 0; } completion:nil];
    __weak typeof(self) weakSelf = self;
    ApolloDuoSlideDrawer(self.listContainer, start, visible ? 0 : -[self listTravel],
                         velocity, animated, ^{
        if (weakSelf.listAnimationGeneration != generation) return;
        weakSelf.listContainer.hidden = !weakSelf.listVisible;
        weakSelf.listDismiss.hidden = !weakSelf.listVisible;
    });
}
- (void)prepareListReveal {
    // Material must be cleared after UIKit installs its initial light-mode
    // table background, before exposing the drawer.
    [self.subredditList.view layoutIfNeeded];
    UITableView *table = ApolloDuoSplitFindTable(self.subredditList.view);
    // Reset before the first reveal frame, after the drawer's safe-area
    // layout, so reopening always starts with the feed shortcuts. A pinned
    // drawer continues the folded list, so it keeps that scroll position.
    if (!self.listPinned)
        [table setContentOffset:CGPointMake(-table.adjustedContentInset.left,
                                           -table.adjustedContentInset.top) animated:NO];
    [table layoutIfNeeded];
    [self updateListAppearance];
}
// How far the drawer travels between hidden and shown: its width plus the
// 12pt gap. Before its first layout, the width viewDidLayoutSubviews will give.
- (CGFloat)listTravel {
    CGFloat width = self.listGlass.bounds.size.width;
    if (width <= 0) width = MIN(360, self.view.bounds.size.width - 96);
    return MAX(0, width) + 12;
}
// The drawer's on-screen translation: -listTravel hidden, 0 shown.
- (CGFloat)listOffset {
    if (self.listContainer.hidden) return -[self listTravel];
    return (self.listContainer.layer.presentationLayer ?: self.listContainer.layer).transform.m41;
}

#pragma mark - Drawer drags

// A drag takes the drawer from wherever it is, including mid-spring. An
// opening drag counts the list as shown from the start (prepared as a reveal,
// and no Back can begin under it); the release then settles either way
// through setListVisible:, carrying the finger's velocity into the spring.
- (BOOL)beginListDrag:(BOOL)opening {
    if (!self.subredditList || !self.view.window) return NO;
    [self.view layoutIfNeeded];
    CGFloat offset = [self listOffset];
    CGFloat scrim = (self.listDismiss.layer.presentationLayer ?: self.listDismiss.layer).opacity;
    if (self.listDismiss.hidden) scrim = 0;
    [self.listContainer.layer removeAnimationForKey:@"ApolloDuoSlide"];
    [self.listDismiss.layer removeAllAnimations];
    self.listAnimationGeneration++;
    if (opening && !self.listVisible) {
        self.listVisible = YES;
        [self prepareListReveal];
    }
    self.listDragging = YES;
    self.listContainer.hidden = NO;
    self.listDismiss.hidden = NO;
    self.listDismiss.userInteractionEnabled = YES;
    self.listDismiss.alpha = scrim;
    self.listContainer.transform = CGAffineTransformMakeTranslation(offset, 0);
    self.listDragStart = offset + [self listTravel];
    ApolloLog(@"[DuoDrag] list drag began opening=%d shown=%.0f", opening, self.listDragStart);
    return YES;
}
// `shown` is how much of the travel is on screen, 0 hidden to listTravel shown.
- (void)moveListDrag:(CGFloat)shown {
    if (!self.listDragging) return;
    CGFloat travel = [self listTravel];
    shown = ApolloDuoDragClamp(shown, travel);
    self.listContainer.transform = CGAffineTransformMakeTranslation(shown - travel, 0);
    self.listDismiss.alpha = travel > 0 ? shown / travel : 0;
}
- (void)endListDrag:(BOOL)show velocity:(CGFloat)velocity {
    if (!self.listDragging) return;
    ApolloLog(@"[DuoDrag] list drag ended show=%d velocity=%.0f", show, velocity);
    [self setListVisible:show animated:!UIAccessibilityIsReduceMotionEnabled() velocity:velocity];
}
// Closing drags that start on the list itself: anywhere on the dimmed feed,
// or in the list's trailing 28pt strip. A tap on the dimmed feed still hides
// the list through listDismiss's own action.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture != self.listCloseStripPan) return YES;
    CGPoint point = [touch locationInView:self.listContainer];
    return point.x >= CGRectGetMaxX(self.listContainer.bounds) - 28;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.listClosePan && gesture != self.listCloseStripPan) return YES;
    UIPanGestureRecognizer *pan = (id)gesture;
    CGPoint translation = [pan translationInView:self.view];
    CGPoint velocity = [pan velocityInView:self.view];
    return self.listVisible && !ApolloDuoSplitIsResizing()
        && ApolloDuoDragIsLeftward(translation.x, translation.y, velocity.x, velocity.y);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // In the strip a row's own drag (unsubscribe) waits for this one; it
    // fails at once on any motion that is not a leftward drag.
    return gesture == self.listCloseStripPan && [other isKindOfClass:UIPanGestureRecognizer.class]
        && !([other.view isKindOfClass:UIScrollView.class] && other == ((UIScrollView *)other.view).panGestureRecognizer);
}
- (void)listClosePanned:(UIPanGestureRecognizer *)pan {
    CGFloat dx = [pan translationInView:self.view].x;
    CGFloat vx = [pan velocityInView:self.view].x;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self beginListDrag:NO];
            [self moveListDrag:self.listDragStart + dx];
            break;
        case UIGestureRecognizerStateChanged:
            if (ApolloDuoSplitIsResizing()) {
                pan.enabled = NO;
                pan.enabled = YES;
                break;
            }
            [self moveListDrag:self.listDragStart + dx];
            break;
        case UIGestureRecognizerStateEnded: {
            CGFloat travel = [self listTravel];
            CGFloat hidden = self.listDragStart - ApolloDuoDragClamp(self.listDragStart + dx, travel);
            [self endListDrag:!ApolloDuoDragCommits(hidden, self.listDragStart, -vx) velocity:vx];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self endListDrag:YES velocity:0];
            break;
        default:
            break;
    }
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
    ApolloDuoUpdateDivider(self);
    if (self.subredditList) {
        CGFloat width = MIN(360, self.view.bounds.size.width - 96);
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
        if (!self.pinnedPrompt.hidden) {
            // Center in the open area beside the drawer, level with its middle.
            CGFloat leading = 12 + width;
            CGFloat trailing = CGRectGetMaxX(self.view.bounds) - self.view.safeAreaInsets.right;
            CGFloat available = MAX(0, trailing - leading - 48);
            CGSize size = [self.pinnedPrompt systemLayoutSizeFittingSize:CGSizeMake(available, UILayoutFittingCompressedSize.height)
                                           withHorizontalFittingPriority:UILayoutPriorityRequired
                                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
            self.pinnedPrompt.bounds = CGRectMake(0, 0, available, size.height);
            self.pinnedPrompt.center = CGPointMake((leading + trailing) / 2, 12 + height / 2);
        }
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
        // Portrait has no Split, so Layout sits beside List instead of
        // crowding Apollo's trailing actions.
        self.feedLayoutButton.hidden = !supportsLayout;
        [self applyFeedLayoutAvailability];
        if (self.feedControlsOwner != owner) {
            ApolloNativeFeedSearchSetDuoControls(self.feedControlsOwner, nil, nil, nil, NO);
            self.feedControlsOwner = owner;
        }
        ApolloNativeFeedSearchSetDuoControls(owner,
            self.listButton.hidden ? nil : self.listBarItem,
            self.splitButton.hidden ? nil : self.splitBarItem,
            self.feedLayoutButton.hidden ? nil : self.feedLayoutBarItem, portrait);
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
// A picture of the Posts split a visited profile was opened from, for a Back
// drag to slide in; the size it was taken at.
@property(nonatomic, strong) UIView *profileBackPicture;
@property(nonatomic) CGSize profileBackPictureSize;
// The profile a Back left, for a forward swipe to bring back, with its
// picture and the Posts pages it returned to (it counts while they show).
@property(nonatomic, strong) UIViewController *profileForwardPage;
@property(nonatomic, strong) UIView *profileForwardPicture;
@property(nonatomic) CGSize profileForwardPictureSize;
@property(nonatomic, copy) NSArray<UIViewController *> *profileForwardStack;
@property(nonatomic, weak) UIViewController *profileForwardFeedTop;
@property(nonatomic, weak) UIViewController *profileForwardDetailTop;
// A cover drag in flight (ApolloDuoSplitBeginCoverDrag): the cover, which way
// it goes, whether the destination slides in from a parallax offset, and what
// a completed drag does under the cover.
@property(nonatomic, strong) UIView *coverDrag;
@property(nonatomic) BOOL coverDragForward;
@property(nonatomic) BOOL coverDragParallax;
// The commit gets a clean picture of what the drag left (taken before the
// cover went up): a snapshot taken during the commit would show the cover.
@property(nonatomic, copy) void (^coverDragCommit)(UIView *leftPicture);
@property(nonatomic, strong) UIView *coverDragLeftPicture;
// The Account detail page a split Back left (the split's own pops never reach
// Apollo's forward pages), while the pages it returned to still show.
@property(nonatomic, strong) UIViewController *accountForwardPage;
@property(nonatomic, copy) NSArray<UIViewController *> *accountForwardStack;
@property(nonatomic) BOOL selectingAccountShortcut;
@property(nonatomic) BOOL changing;
@property(nonatomic) BOOL postsTogglingSplit;
// The thread the last close took from beside the feed, which a forward swipe
// brings back (ApolloDuoSplitRestoreClosedThread) until something forgets it.
@property(nonatomic, strong) ApolloDuoPostsClosedThread *closedThread;
@property(nonatomic) BOOL navigationBarWasHidden;
@property(nonatomic) BOOL needsDefault;
// When the folded Posts tab last showed its bare subreddit list (0 otherwise).
@property(nonatomic) CFTimeInterval foldedListShownAt;
// Unfolding from that list opens the pinned drawer instead of a feed.
@property(nonatomic) BOOL pinListOnOpen;
@property(nonatomic) BOOL halfWidthSidebar;
@property(nonatomic, weak) id<UIViewControllerTransitionCoordinator> pendingNavigationTransition;
@property(nonatomic, weak) UIViewController *searchBackPage;
@property(nonatomic, strong) UIBarButtonItem *searchBackItem;
@property(nonatomic) BOOL searchBackSupplementedNative;
@property(nonatomic) BOOL sidebarHiddenForGallery;
@end
@implementation ApolloDuoSplitState @end

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

// Apollo's native navigation delegate tests a 70pt edge band in its view.
// UIKit extends the secondary view under the sidebar and the trailing rail;
// translate only that delegate's location query into the visible pane's band.
static __thread void *sDuoSplitGesture;
static __thread void *sDuoSplitGestureView;
static __thread CGFloat sDuoSplitGestureOffset;

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
        if (paired) width *= 0.5;
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

UINavigationController *ApolloDuoSplitFeedNavigation(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && !state.changing ? state.feed : nil;
}

BOOL ApolloDuoSplitAllowsNavigationSwipe(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (state.changing) return NO;
    if (!state.split) return YES;
    return !state.host.listVisible && (nav == state.feed || nav == state.secondary);
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
    // A pinned drawer has no feed behind it; the tab reselect does nothing.
    if (state.host.listPinned) {
        ApolloLog(@"[PostsTab] Kept the pinned subreddit list open");
        return YES;
    }
    [state.host setListVisible:NO animated:!UIAccessibilityIsReduceMotionEnabled()];
    ApolloLog(@"[PostsTab] Closed subreddit list");
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
    // Keep UIKit's actual columns authoritative. The grip updates the requested
    // width; no snapshots, private recognizer changes, or navigation handoffs.
    CGFloat postsWidth = half;
    if (postsLandscape && CGRectIsNull(ApolloDuoActiveVerticalDivision(state.host.view))) {
        double share = [NSUserDefaults.standardUserDefaults doubleForKey:UDKeyDuoDividerFeedShare];
        if (!(share > 0 && share < 1) || !isfinite(share)) share = 0.5;
        CGFloat inset = MAX(state.host.view.safeAreaInsets.right, state.secondary.view.safeAreaInsets.right);
        postsWidth = ApolloDuoDividerClamp(state.host.dividerPreviewWidth ? state.host.dividerPreviewWidth.doubleValue : share * canvas.width,
                                           canvas.width, inset);
    }
    // Pin the requested width so ordinary swipes never resize the divider.
    CGFloat maximum = postsLandscape ? postsWidth : (state.feed || halfWidth ? CGFLOAT_MAX : 420.0);
    // Settings' widest native row is "Touch ID & Passcode" + its value +
    // disclosure: a third of the flat inner display (~317pt) cut "Off" to "O".
    // Give that sidebar enough room for the value at the default text size.
    CGFloat sidebarMinimum = [state.kind isEqualToString:@"settings"] ? 340.0 : 240.0;
    CGFloat minimum = postsLandscape ? postsWidth : sidebarMinimum;
    if (split.maximumPrimaryColumnWidth != maximum) split.maximumPrimaryColumnWidth = maximum;
    if (split.minimumPrimaryColumnWidth != minimum) split.minimumPrimaryColumnWidth = minimum;
    CGFloat fraction = halfWidth || state.feed ? 0.5 : 1.0 / 3.0;
    if (postsLandscape && canvas.width > 0) fraction = postsWidth / canvas.width;
    if (halfWidth && !state.feed && canvas.width > 0.0) {
        // End the sidebar at the fold itself rather than an assumed midpoint.
        CGRect fold = ApolloDuoActiveVerticalDivision(state.host.view);
        if (!CGRectIsNull(fold)) fraction = MIN(0.7, MAX(0.3, CGRectGetMinX(fold) / canvas.width));
    }
    if (split.preferredPrimaryColumnWidthFraction != fraction) split.preferredPrimaryColumnWidthFraction = fraction;
    if (@available(iOS 26.0, *)) {
        // UIKit's default secondary minimum (532pt on this inner display)
        // otherwise caps the primary at 419pt even with a 50% preference.
        CGFloat secondaryMinimum = state.feed || halfWidth ? 240.0 : UISplitViewControllerAutomaticDimension;
        if (split.minimumSecondaryColumnWidth != secondaryMinimum) split.minimumSecondaryColumnWidth = secondaryMinimum;
    }
    if (halfWidth && !state.feed) {
        split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        [split showColumn:UISplitViewControllerColumnPrimary];
    }
}

// Only an idle, visible Posts pair offers resizing. The fold retains its
// natural division and never overwrites the saved flat-display preference.
static BOOL ApolloDuoDividerVisible(ApolloDuoSplitHost *host) {
    return host.postsColumnsPaired && host.viewIfLoaded.window && !host.listVisible
        && host.view.bounds.size.width > host.view.bounds.size.height
        && CGRectIsNull(ApolloDuoActiveVerticalDivision(host.view));
}
static BOOL ApolloDuoDividerAvailable(ApolloDuoSplitHost *host) {
    if (!ApolloDuoDividerVisible(host) || host.postsTransitionSnapshot.window
        || sDuoSplitResizingTabs || sDuoFeedLayoutChanging) return NO;
    for (UIViewController *vc = host; vc; vc = vc.parentViewController)
        if (vc.presentedViewController || vc.transitionCoordinator || vc.isBeingDismissed) return NO;
    UINavigationController *thread = (id)[host.split viewControllerForColumn:UISplitViewControllerColumnSecondary];
    return !host.postsNavigation.transitionCoordinator && !thread.transitionCoordinator
        && !host.postsNavigation.topViewController.presentedViewController
        && !thread.topViewController.presentedViewController;
}

// Texture redraws text asynchronously, a frame or more after a resize gives
// its layer new bounds; meanwhile the layer stretches the old bitmap to fit.
// The divider resizes both columns every frame, so the text would stay
// stretched for the whole drag. Draw it synchronously while the divider is
// held: each redraw then lands in the same frame as its new bounds.
static void ApolloDuoDividerHoldText(CALayer *layer, NSHashTable *held) {
    id node = ApolloSendObject(layer, @selector(asyncdisplaykit_node));
    if (node && ![held containsObject:node]
        && ((ApolloClassASTextNode && [node isKindOfClass:ApolloClassASTextNode])
            || (ApolloClassASTextNode2 && [node isKindOfClass:ApolloClassASTextNode2]))
        && ((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(displaysAsynchronously))) {
        [held addObject:node];
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setDisplaysAsynchronously:), NO);
    }
    for (CALayer *sublayer in layer.sublayers) ApolloDuoDividerHoldText(sublayer, held);
}

static void ApolloDuoDividerReleaseText(ApolloDuoSplitHost *host) {
    if (!host.dividerHeldText.count) return;
    // The release's own relayout redraws once more; keep it synchronous so it
    // can't stretch either. Restore after it lands, unless a new drag has
    // taken the text over by then.
    NSUInteger generation = ++host.dividerHeldTextGeneration;
    __weak ApolloDuoSplitHost *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloDuoSplitHost *strongHost = weakHost;
        if (!strongHost || strongHost.dividerHeldTextGeneration != generation || strongHost.dividerGrip.dragging) return;
        NSHashTable *held = strongHost.dividerHeldText;
        strongHost.dividerHeldText = nil;
        for (id node in held)
            ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setDisplaysAsynchronously:), YES);
        ApolloLog(@"[DuoDivider] restored %lu text node(s)", (unsigned long)held.count);
    });
}

static void ApolloDuoUpdateDivider(ApolloDuoSplitHost *host) {
    if (!host.postsNavigation) return;
    if (!host.dividerGrip) {
        host.dividerGrip = [[ApolloDuoSplitDivider alloc] initWithFrame:CGRectZero];
        __weak ApolloDuoSplitHost *weakHost = host;
        host.dividerGrip.canBegin = ^BOOL { return ApolloDuoDividerAvailable(weakHost); };
        host.dividerGrip.changeWidth = ^(CGFloat width, BOOL commit) {
            ApolloDuoSplitHost *strongHost = weakHost;
            if (!strongHost) return;
            ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(strongHost.postsNavigation, NO);
            if (!state || state.host != strongHost) return;
            if (commit) [NSUserDefaults.standardUserDefaults setDouble:width / MAX(1, strongHost.view.bounds.size.width)
                                                                forKey:UDKeyDuoDividerFeedShare];
            strongHost.dividerPreviewWidth = strongHost.dividerGrip.dragging ? @(width) : nil;
            // Before this frame's layout gives the text new bounds.
            if (strongHost.dividerGrip.dragging) {
                strongHost.dividerHeldTextGeneration++;
                if (!strongHost.dividerHeldText) strongHost.dividerHeldText = [NSHashTable weakObjectsHashTable];
                ApolloDuoDividerHoldText(strongHost.split.view.layer, strongHost.dividerHeldText);
            } else {
                ApolloDuoDividerReleaseText(strongHost);
            }
            ApolloDuoSplitApplySidebarWidth(state, state.halfWidthSidebar);
            [strongHost.split.view setNeedsLayout];
            [strongHost.split.view layoutIfNeeded];
            [strongHost.view setNeedsLayout];
        };
        [host.view addSubview:host.dividerGrip];
    }
    UIViewController *thread = [host.split viewControllerForColumn:UISplitViewControllerColumnSecondary];
    // The secondary navigation view spans the canvas on Duo; UIKit insets
    // its content behind the primary. The feed edge is the actual divider.
    CGRect frame = [host.postsNavigation.view convertRect:host.postsNavigation.view.bounds toView:host.view];
    CGFloat inset = MAX(host.view.safeAreaInsets.right, thread.view.safeAreaInsets.right);
    [host.dividerGrip updateWithDivider:CGRectGetMaxX(frame) trailingInset:inset
                               enabled:ApolloDuoDividerVisible(host) && CGRectGetMaxX(frame) > 0];
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
// (the button, a Back) remembers the thread for a forward swipe, as Apollo
// keeps a page popped on a regular iPhone. Apollo forgets that page when a new
// one is pushed or memory runs low; the split forgets the thread on the same
// occasions, and whenever it could no longer come back where it was.
typedef NS_ENUM(NSInteger, ApolloDuoClosedThreadEvent) {
    ApolloDuoClosedThreadEventCheck,          // nothing happened; the facts alone decide
    ApolloDuoClosedThreadEventThreadOpened,   // another thread is opening beside the feed
    ApolloDuoClosedThreadEventFeedOpened,     // a feed is opening: a list row, a feed link, Search, a reroot
    ApolloDuoClosedThreadEventMemoryWarning,  // the feed's didReceiveMemoryWarning, Apollo's forward wipe
    ApolloDuoClosedThreadEventAccountChanged, // Apollo switched account
    ApolloDuoClosedThreadEventScrolledAway,   // Forget Forward Swipe After Scrolling: the feed scrolled on
    ApolloDuoClosedThreadEventForeground,     // the app is back after `away` seconds in the background
};
typedef struct {
    BOOL split;            // the feed pairs a thread beside it (unfolded, landscape, split on)
    BOOL threadOpen;       // a thread shows beside the feed
    BOOL feedPageOnTop;    // the feed page it was closed from is still the feed's top page
    BOOL feedUnchanged;    // and it still shows the same feed (Apollo reuses it in place)
    BOOL accountUnchanged; // and the same account is signed in (Apollo reloads in place for that too)
    BOOL pagesOnStack;     // one of its pages is on a navigation stack again
    NSTimeInterval away;   // Foreground only: the time in the background
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
    if (event == ApolloDuoClosedThreadEventAccountChanged) return @"the account changed";
    if (event == ApolloDuoClosedThreadEventScrolledAway) return @"the feed scrolled away";
    if (event == ApolloDuoClosedThreadEventForeground && facts.away > kApolloDuoClosedThreadBackgroundLimit)
        return @"a long stay in the background";
    if (!facts.split) return @"the split ended";
    if (facts.threadOpen) return @"a thread is beside the feed";
    if (!facts.feedPageOnTop) return @"the feed changed";
    if (!facts.feedUnchanged) return @"the feed page shows another feed";
    if (!facts.accountUnchanged) return @"the feed page belongs to another account";
    if (facts.pagesOnStack) return @"its pages are on a stack again";
    return nil;
}

// What a close remembers: the thread pane's pages above its backstop, the
// thread and anything pushed over it. Nothing when only the backstop is left.
static NSArray *ApolloDuoClosedThreadPages(NSArray *paneStack) {
    return paneStack.count > 1 ? [paneStack subarrayWithRange:NSMakeRange(1, paneStack.count - 1)] : @[];
}

// A thread a Back closed beside the feed, held for the forward swipe: its
// pages strongly (no stack holds them any more) and its feed page weakly.
@interface ApolloDuoPostsClosedThread : NSObject
@property(nonatomic, copy) NSArray<UIViewController *> *pages;
// The thread pane as it looked when it closed, and where, so a forward drag
// can slide it back in under the finger before the real pages return.
@property(nonatomic, strong) UIView *picture;
@property(nonatomic) CGRect pictureFrame;
@property(nonatomic) CGSize surfaceSize;
@property(nonatomic, weak) UIViewController *feedPage;
@property(nonatomic, copy) NSString *feedIdentity;
@property(nonatomic, copy) NSString *account;
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

// The signed-in account, which the same feed page reloads for in place when
// Apollo switches account.
static NSString *ApolloDuoPostsAccountIdentity(void) {
    return ApolloActiveAccountUsername() ?: @"";
}

// The state holding a closed thread, for the app-wide events (the background,
// an account switch).
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
        .accountUnchanged = [ApolloDuoPostsAccountIdentity() isEqualToString:closed.account],
        .pagesOnStack = onStack,
        .away = away,
    };
    NSString *reason = ApolloDuoClosedThreadForgetReason(event, facts);
    if (reason) ApolloDuoPostsForgetClosedThread(state, reason);
}

static void ApolloDuoPostsRememberClosedThread(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages,
                                               UIView *picture, CGRect pictureFrame) {
    UIViewController *feedPage = state.feed.topViewController;
    if (!pages.count || !feedPage) return;
    ApolloDuoSplitState *previous = sDuoPostsClosedThreadState;
    if (previous && previous != state) ApolloDuoPostsForgetClosedThread(previous, @"a thread closed in another split");
    ApolloDuoPostsClosedThread *closed = [ApolloDuoPostsClosedThread new];
    closed.pages = pages;
    closed.feedPage = feedPage;
    closed.feedIdentity = ApolloDuoPostsFeedIdentity(feedPage);
    closed.account = ApolloDuoPostsAccountIdentity();
    closed.picture = picture;
    closed.pictureFrame = pictureFrame;
    closed.surfaceSize = state.host.view.bounds.size;
    state.closedThread = closed;
    sDuoPostsClosedThreadState = state;
    ApolloLog(@"[DuoSplit] remembered the closed thread (%lu page(s)) for a forward swipe", (unsigned long)pages.count);
}

static void ApolloDuoPostsSyncColumnsWithAnimation(ApolloDuoSplitState *state, BOOL animateDisplayMode) {
    if (!state.split || !state.feed) ApolloDuoPostsForgetClosedThread(state, @"the split ended");
    if (!state.feed || !state.split || state.changing) return;
    // A rotation to portrait, the split turned off or a thread put beside the
    // feed by any path ends what a forward swipe could bring back.
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventCheck, 0.0);
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
    if (unchanged) return;
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

// Text in a Texture node is drawn into its layer's contents, and redrawn in
// the background at a new width. A column resize animates that layer's own
// bounds and position from the old width, stretching whichever drawing is
// showing: squashed while a column widens, enlarged while it narrows. Drop
// those animations so each text layer takes its final layout in its row at
// once; the rows and columns around it still animate.
static void ApolloDuoCollectTextLayers(CALayer *layer, NSMutableArray<CALayer *> *out) {
    if (!layer || layer.hidden) return;
    id node = [layer respondsToSelector:@selector(asyncdisplaykit_node)]
        ? ((id (*)(id, SEL))objc_msgSend)(layer, @selector(asyncdisplaykit_node)) : nil;
    if ((ApolloClassASTextNode && [node isKindOfClass:ApolloClassASTextNode])
        || (ApolloClassASTextNode2 && [node isKindOfClass:ApolloClassASTextNode2])) {
        [out addObject:layer];
        return;
    }
    for (CALayer *sublayer in layer.sublayers) ApolloDuoCollectTextLayers(sublayer, out);
}

static void ApolloDuoHoldTextLayout(NSArray<UIView *> *roots) {
    NSMutableArray<CALayer *> *text = [NSMutableArray array];
    for (UIView *root in roots) ApolloDuoCollectTextLayers(root.layer, text);
    NSUInteger held = 0;
    for (CALayer *layer in text) {
        for (NSString *key in layer.animationKeys) {
            CAAnimation *animation = [layer animationForKey:key];
            NSString *path = [animation isKindOfClass:CAPropertyAnimation.class] ? ((CAPropertyAnimation *)animation).keyPath : nil;
            if ([key isEqualToString:@"ApolloDuoPostsGeometry"] || [path hasPrefix:@"bounds"] || [path hasPrefix:@"position"]) {
                [layer removeAnimationForKey:key];
                held++;
            }
        }
    }
    // Texture redraws text at its new width in the background, which leaves
    // a frame or two of the old drawing stretched to the new bounds. Draw the
    // resized ones now instead.
    SEL drawNow = @selector(recursivelyEnsureDisplaySynchronously:);
    NSUInteger drawn = 0;
    for (CALayer *layer in text) {
        id contents = layer.contents;
        if (!contents || CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) continue;
        CGFloat width = CGRectGetWidth(layer.bounds) * layer.contentsScale;
        if (fabs((CGFloat)CGImageGetWidth((__bridge CGImageRef)contents) - width) < 2) continue;
        id node = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(asyncdisplaykit_node));
        if (![node respondsToSelector:drawNow]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, drawNow, YES);
        drawn++;
    }
    if (held || drawn) ApolloLog(@"[DuoSplit] held %lu text animations, redrew %lu of %lu text layers",
                                 (unsigned long)held, (unsigned long)drawn, (unsigned long)text.count);
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

static void ApolloDuoAnimateRetainedGeometry(NSArray<ApolloDuoPostsGeometry *> *geometry,
                                             UIView *feed, UIView *surface, NSTimeInterval duration,
                                             BOOL convertReparentedDescendants, BOOL fadeRecenteredBarItems) {
    NSUInteger count = 0;
    NSMutableArray<UIView *> *faded = [NSMutableArray array];
    for (ApolloDuoPostsGeometry *item in geometry) {
        UIView *view = item.view;
        if (!view || (view != feed && ![view isDescendantOfView:feed])) continue;
        CALayer *layer = view.layer;
        BOOL insideFaded = NO;
        for (UIView *ancestor in faded) if ([view isDescendantOfView:ancestor]) insideFaded = YES;
        if (insideFaded) continue;
        if (fadeRecenteredBarItems && view != feed && ApolloDuoGeometryRecentersBarItem(item, view, feed, surface)) {
            // Crossfade: the old rendering leaves from where it was while the
            // item fades in at its destination, so the bar is never empty.
            UIView *old = [view snapshotViewAfterScreenUpdates:NO];
            if (old) {
                old.frame = item.surfaceFrame;
                old.userInteractionEnabled = NO;
                [surface addSubview:old];
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
            // unconditionally. Search also reparents its retained page and
            // search-bar surfaces into a newly created navigation controller.
            if (!view.superview || (view != feed && !convertReparentedDescendants)) continue;
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
    ApolloDuoAnimateRetainedGeometry(geometry, feed, surface, duration, NO, YES);
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
        || !ApolloDuoSplitIsUnfolded()) return;
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
    sDuoUnfoldedFeedLayout = sDuoUnfoldedFeedLayout == 2 ? 0 : 2;
    [NSUserDefaults.standardUserDefaults setInteger:sDuoUnfoldedFeedLayout forKey:UDKeyDuoUnfoldedFeedLayout];
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
                && ApolloDuoSplitIsUnfolded())
                ApolloDuoPostsAnimateGeometry(transition.geometry, surface, surface, 0.32);
        }
        sDuoFeedLayoutChanging = NO;
        ApolloDuoRefreshLayoutControls();
    });
}

static void ApolloDuoToggleFeedLayout(ApolloDuoSplitHost *host) {
    ApolloDuoToggleVisibleFeedLayout(host.feedControlsOwner, host.feedLayoutButton.enabled);
}

// Feeds and threads outside Posts (a subreddit opened from Inbox, Account or
// Search) need their own control. Inside Posts, the host carries its retained
// layout item between the feed and comments with List and Split.
static NSString *const kApolloDuoPageLayoutID = @"ApolloDuoPageLayoutControl";
static char kApolloDuoPageLayoutKey, kApolloDuoPageLayoutPendingKey;
@interface ApolloDuoPageLayoutControl : NSObject <ApolloDuoLayoutControl>
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UIBarButtonItem *item;
- (void)update;
- (void)toggle;
@end
static NSMapTable<UINavigationItem *, ApolloDuoPageLayoutControl *> *sDuoPageLayoutOwners;

static BOOL ApolloDuoPageShowsLayoutControl(UIViewController *controller) {
    if (!ApolloDuoSplitIsUnfolded()) return NO;
    // Only the Posts tab's split has a feed column; its host owns the control.
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return !state.feed;
}

// NavigationActions calls this before normalizing native items, so an async
// Apollo action refresh cannot remove the independent layout control.
NSArray<UIBarButtonItem *> *ApolloDuoPageLayoutItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    ApolloDuoPageLayoutControl *control = [sDuoPageLayoutOwners objectForKey:item];
    if (!control) return items;
    NSMutableArray *result = [NSMutableArray array];
    if (ApolloDuoPageShowsLayoutControl(control.controller)) [result addObject:control.item];
    for (UIBarButtonItem *candidate in items)
        if (![candidate.accessibilityIdentifier isEqualToString:kApolloDuoPageLayoutID]) [result addObject:candidate];
    return result;
}

@implementation ApolloDuoPageLayoutControl
- (void)updateFeedLayoutButton { ApolloDuoRefreshLayoutButton(nil, self.item); }
- (void)applyNavigationButtonColor {
    UIColor *color = ApolloNavigationButtonAccentColor() ?: ApolloNavigationChromeColor();
    if (![self.item.tintColor isEqual:color]) self.item.tintColor = color;
}
- (void)toggle {
    if (ApolloDuoPageShowsLayoutControl(self.controller))
        ApolloDuoToggleVisibleFeedLayout(self.controller, self.item.enabled);
}
- (void)update {
    [self updateFeedLayoutButton];
    UINavigationItem *navigationItem = self.controller.navigationItem;
    NSArray *items = ApolloDuoPageLayoutItems(navigationItem, navigationItem.rightBarButtonItems);
    if (![(navigationItem.rightBarButtonItems ?: @[]) isEqualToArray:items])
        [navigationItem setRightBarButtonItems:items animated:NO];
}
@end

static void ApolloDuoPageUpdateLayoutControl(UIViewController *controller) {
    ApolloDuoPageLayoutControl *control = objc_getAssociatedObject(controller, &kApolloDuoPageLayoutKey);
    if (!control && !ApolloDuoPageShowsLayoutControl(controller)) return;
    if (!control) {
        control = [ApolloDuoPageLayoutControl new];
        control.controller = controller;
        // A native image item lets UIKit own glyph visibility, accessibility,
        // sizing and glass. No configured UIButton or custom wrapper is needed.
        control.item = [[UIBarButtonItem alloc] initWithImage:ApolloDuoFeedLayoutImage()
            style:UIBarButtonItemStylePlain target:control action:@selector(toggle)];
        control.item.title = @"Feed Layout";
        control.item.accessibilityLabel = @"Feed Layout";
        control.item.accessibilityIdentifier = kApolloDuoPageLayoutID;
        [control applyNavigationButtonColor];
        [NSNotificationCenter.defaultCenter addObserver:control selector:@selector(applyNavigationButtonColor)
                                                   name:ApolloNavigationButtonColorDidChangeNotification object:nil];
        if (@available(iOS 26.0, *)) {
            control.item.hidesSharedBackground = NO;
            control.item.sharesBackground = NO;
        }
        if (@available(iOS 27.1, *)) control.item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        objc_setAssociatedObject(controller, &kApolloDuoPageLayoutKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sDuoPageLayoutOwners) sDuoPageLayoutOwners = [NSMapTable weakToWeakObjectsMapTable];
        [sDuoPageLayoutOwners setObject:control forKey:controller.navigationItem];
        ApolloDuoRegisterLayoutControl(control);
    }
    [control update];
}

static void ApolloDuoPageScheduleLayoutControl(UIViewController *controller) {
    ApolloDuoPageLayoutControl *control = objc_getAssociatedObject(controller, &kApolloDuoPageLayoutKey);
    if (objc_getAssociatedObject(controller, &kApolloDuoPageLayoutPendingKey)
        || (!control && !ApolloDuoPageShowsLayoutControl(controller))) return;
    objc_setAssociatedObject(controller, &kApolloDuoPageLayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *page = weakController;
        if (!page) return;
        objc_setAssociatedObject(page, &kApolloDuoPageLayoutPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoPageUpdateLayoutControl(page);
    });
}

// A split toggle changes only the width of an already open comments page.
// Both native column controllers stay attached; UIKit owns their divider,
// clipping, safe areas, and the disappearance/reappearance of the feed.
// Moving the thread between its own column and the feed's stack rebuilds
// both navigation bars in one pass: for a frame the title sits at the bar's
// leading edge and the bar items swap columns. Hold a picture of the bars
// over that handoff and fade it out once the new ones are laid out.
static void ApolloDuoCoverBarHandoff(ApolloDuoSplitState *state, NSTimeInterval fade) {
    UIView *surface = state.host.view;
    UINavigationBar *bar = state.feed.navigationBar;
    if (!surface.window || !bar.window || UIAccessibilityIsReduceMotionEnabled()) return;
    CGFloat bottom = CGRectGetMaxY([bar convertRect:bar.bounds toView:surface]);
    if (bottom <= 0) return;
    CGRect band = CGRectMake(0, 0, CGRectGetWidth(surface.bounds), MIN(bottom, CGRectGetHeight(surface.bounds)));
    UIView *cover = [surface resizableSnapshotViewFromRect:band afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if (!cover) return;
    cover.frame = band;
    cover.userInteractionEnabled = NO;
    [surface insertSubview:cover belowSubview:state.host.listDismiss];
    [UIView animateWithDuration:fade delay:0.03 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ cover.alpha = 0; }
                     completion:^(__unused BOOL finished) { [cover removeFromSuperview]; }];
}

static void ApolloDuoPostsToggleSplit(ApolloDuoSplitState *state) {
    if (!state.feed || state.changing || state.postsTogglingSplit
        || state.feed.transitionCoordinator || state.secondary.transitionCoordinator) return;
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
        if (animate) ApolloDuoHoldTextLayout(@[state.feed.view, state.secondary.view]);
    };
    void (^finish)(void) = ^{
        state.postsTogglingSplit = NO;
        // Hiding the primary has completed. Rejoin the stacks at the same
        // full-width geometry so subsequent Back uses Apollo's own animator.
        if (state.feed && state.split) {
            if (animate && !state.host.postsSplitEnabled && state.secondary.viewControllers.count > 1)
                ApolloDuoCoverBarHandoff(state, 0.2);
            [UIView performWithoutAnimation:^{
                ApolloDuoPostsSyncColumns(state);
                commitTables();
                // The rail's Back is UIKit's floating copy of one navigation
                // bar, adopted while the thread had its own column. Once the
                // feed takes the thread back onto its stack, re-show the
                // feed's bar so the rail adopts it instead of the detached one.
                if (!state.host.postsSplitEnabled && state.feed.viewControllers.count > 1 && !state.feed.navigationBarHidden) {
                    [state.feed setNavigationBarHidden:YES animated:NO];
                    [state.feed setNavigationBarHidden:NO animated:NO];
                }
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

// Creating/removing the comments column is a containment transition. Animate
// that layout together with the page: the retained live feed must resize as
// comments enter/leave, not jump to its final width before a snapshot slides.
// Once both columns exist, Apollo's native navigation animator owns pushes.
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

// `dragOffset` > 0: a Back drag has the thread pane that far right of its
// place (ApolloDuoSplitDragThread). The close then picks up from the screen
// as the finger left it, carrying `dragVelocity` into its spring.
static void ApolloDuoPostsSetDetailPagesFromDrag(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages,
                                                 BOOL animated, CGFloat dragOffset, CGFloat dragVelocity) {
    if (pages.count) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventThreadOpened, 0.0);
    UIView *surface = state.host.view;
    BOOL entering = pages.count > 0;
    BOOL animate = animated && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    if (!animate) {
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    }
    UIViewController *backstop = state.secondary.viewControllers.firstObject;
    NSArray<UIViewController *> *closedPages = ApolloDuoClosedThreadPages(state.secondary.viewControllers);
    // The pane's picture for a later forward drag: from the start of a Back
    // drag (the pane is shifted by now), else taken here before it closes.
    UIView *closedPicture = nil;
    CGRect closedPictureFrame = CGRectNull;
    if (!pages.count && surface.window) {
        [surface layoutIfNeeded];
        closedPictureFrame = ApolloDuoPostsDetailPane(state);
        closedPicture = dragOffset > 0 ? state.host.threadDragPicture
            : (!CGRectIsNull(closedPictureFrame) && !CGRectIsEmpty(closedPictureFrame)
               ? [surface resizableSnapshotViewFromRect:closedPictureFrame afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil);
    }
    state.host.threadDragPicture = nil;
    NSArray<UIViewController *> *stack = [@[backstop] arrayByAddingObjectsFromArray:pages];
    [state.host.postsTransitionSnapshot removeFromSuperview];
    state.host.postsTransitionSnapshot = nil;
    [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    // The snapshot below is taken from the last rendered frame, so it already
    // shows the dragged pane; the live pane goes back to its place under it.
    dragOffset = animate ? MAX(0, dragOffset) : 0;
    if (!dragOffset) {
        ApolloDuoSetThreadDragOffset(state.secondary.viewIfLoaded, 0);
        ApolloDuoRemoveThreadDragFiller(state.host.threadDragFiller, 0);
        state.host.threadDragFiller = nil;
    }
    if (entering && state.host.postsShowingDetail) {
        [surface layoutIfNeeded];
        [state.secondary setViewControllers:stack animated:animate];
        return;
    }

    [surface layoutIfNeeded];
    NSArray<ApolloDuoPostsGeometry *> *feedGeometry = animate
        ? ApolloDuoPostsCaptureGeometry(state.feed.view, surface) : nil;
    CGRect pane = !entering ? ApolloDuoPostsDetailPane(state) : CGRectNull;
    // A dragged thread sits dragOffset right of the pane, the feed's stretched
    // edge filling the gap; take the thread alone, so the filler can fade
    // over the feed as it widens beneath.
    CGRect shot = dragOffset > 0 && !CGRectIsNull(pane)
        ? CGRectMake(CGRectGetMinX(pane) + dragOffset, CGRectGetMinY(pane),
                     MAX(0, CGRectGetWidth(pane) - dragOffset), CGRectGetHeight(pane)) : pane;
    UIView *snapshot = !entering && animate && !CGRectIsNull(shot) && !CGRectIsEmpty(shot)
        ? [surface resizableSnapshotViewFromRect:shot afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
    if (snapshot) {
        snapshot.frame = shot;
        snapshot.userInteractionEnabled = NO;
        [surface insertSubview:snapshot belowSubview:state.host.listDismiss];
        state.host.postsTransitionSnapshot = snapshot;
    }
    ApolloDuoSetThreadDragOffset(state.secondary.view, 0);
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    ApolloDuoFeedAnchor *feedAnchor = ApolloDuoCaptureFeedAnchor(
        ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded));
    void (^updateColumns)(void) = ^{
        state.changing = YES;
        [state.secondary setViewControllers:stack animated:NO];
        state.changing = NO;
        // Off the pane now: what a forward swipe brings back.
        if (!entering) ApolloDuoPostsRememberClosedThread(state, closedPages, closedPicture, closedPictureFrame);
        ApolloDuoPostsSyncColumns(state);
        [surface layoutIfNeeded];
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
    ApolloDuoPostsAnimateGeometry(feedGeometry, state.feed.view, surface, 0.32);
    ApolloDuoHoldTextLayout(@[state.feed.view]);
    if (entering) {
        // Use the live navigation surface so async comment/media updates
        // remain visible throughout the first push.
        CGRect incomingPane = ApolloDuoPostsDetailPane(state);
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(incomingPane);
        // A forward drag already brought the thread dragOffset short of its
        // place; finish on the drawer's spring from the finger's speed.
        if (!CGRectIsNull(incomingPane) && travel > 0 && dragOffset > 0)
            ApolloDuoSlideDrawer(state.secondary.view, MIN(dragOffset, travel), 0, dragVelocity, YES, nil);
        else if (!CGRectIsNull(incomingPane) && travel > 0)
            ApolloDuoSlideView(state.secondary.view, travel, 0, 0.32, nil);
    } else if (snapshot) {
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
        dispatch_block_t finished = ^{
            [snapshot removeFromSuperview];
            if (weakHost.postsTransitionSnapshot == snapshot) weakHost.postsTransitionSnapshot = nil;
            ApolloDuoSplitScheduleUpdate();
        };
        // A dragged thread is already dragOffset along; the rest of the way
        // rides the drawer's spring from the finger's speed. Clean up from a
        // transaction completion, which also runs when a fold or the app
        // leaving removes the slide early; the slide's own completion runs
        // only for a finished one and would leave the snapshot over the feed.
        [CATransaction begin];
        [CATransaction setCompletionBlock:finished];
        if (dragOffset > 0) ApolloDuoSlideDrawer(snapshot, 0, MAX(0, travel - dragOffset), dragVelocity, YES, nil);
        else ApolloDuoSlideView(snapshot, 0, travel, 0.32, nil);
        [CATransaction commit];
        ApolloDuoRemoveThreadDragFiller(state.host.threadDragFiller, 0.32);
        state.host.threadDragFiller = nil;
    }
    [CATransaction commit];
}

static void ApolloDuoPostsSetDetailPages(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages, BOOL animated) {
    ApolloDuoPostsSetDetailPagesFromDrag(state, pages, animated, 0, 0);
}

static void ApolloDuoPostsSetDetail(ApolloDuoSplitState *state, UIViewController *page, BOOL animated) {
    ApolloDuoPostsSetDetailPages(state, page ? @[page] : @[], animated);
}

// The forward swipe on the full-width Posts feed brings back the thread the
// last close took from beside it, through the normal open: the same pages
// (reading position, reply text and all), not a fresh load. A stale memory
// that no event caught is forgotten here, the first time a swipe asks.
BOOL ApolloDuoSplitCanRestoreClosedThread(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.closedThread || state.feed != nav || !state.split || state.changing || state.postsTogglingSplit) return NO;
    ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventCheck, 0.0);
    return state.closedThread && !state.host.listVisible && !state.host.postsShowingDetail
        && state.secondary.viewControllers.count == 1;
}

BOOL ApolloDuoSplitRestoreClosedThread(UINavigationController *nav) {
    if (!ApolloDuoSplitCanRestoreClosedThread(nav)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    NSArray<UIViewController *> *pages = state.closedThread.pages;
    state.closedThread = nil;
    if (sDuoPostsClosedThreadState == state) sDuoPostsClosedThreadState = nil;
    ApolloLog(@"[DuoSplit] restored the closed thread (%lu page(s)) beside the feed", (unsigned long)pages.count);
    ApolloDuoPostsSetDetailPages(state, pages, YES);
    ApolloDuoPostsSyncColumns(state);
    return YES;
}

#pragma mark - Forward drags

// A forward drag on the full-width feed slides the closed thread's picture in
// from the trailing edge under the finger. Nothing is laid out until release:
// a completed drag reopens the real pages from where the picture is (the
// split's own open, continuing the motion), an early one slides it back out.
// Without a picture (Reduce Motion, a resize since) the drag still restores
// on release, without following the finger.
static CGFloat ApolloDuoRestoreTravel(ApolloDuoSplitState *state) {
    ApolloDuoPostsClosedThread *closed = state.closedThread;
    if (!closed.picture || CGRectIsNull(closed.pictureFrame)
        || !CGSizeEqualToSize(closed.surfaceSize, state.host.view.bounds.size)) return 0;
    return MAX(0, CGRectGetMaxX(state.host.view.bounds) - CGRectGetMinX(closed.pictureFrame));
}

CGFloat ApolloDuoSplitRestoreDragTravel(UINavigationController *nav) {
    return ApolloDuoRestoreTravel(ApolloDuoSplitStateForNavigation(nav, NO));
}

BOOL ApolloDuoSplitBeginRestoreDrag(UINavigationController *nav) {
    if (!ApolloDuoSplitCanRestoreClosedThread(nav)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    CGFloat travel = ApolloDuoRestoreTravel(state);
    if (travel <= 0 || UIAccessibilityIsReduceMotionEnabled()) return NO;
    UIView *picture = state.closedThread.picture;
    [picture.layer removeAllAnimations];
    picture.frame = state.closedThread.pictureFrame;
    picture.transform = CGAffineTransformMakeTranslation(travel, 0);
    picture.userInteractionEnabled = NO;
    [state.host.view insertSubview:picture belowSubview:state.host.listDismiss];
    state.host.restoreDragPicture = picture;
    ApolloLog(@"[DuoDrag] forward drag began travel=%.0f", travel);
    return YES;
}

// `shown` is how far the thread has come in, 0 to travel.
void ApolloDuoSplitMoveRestoreDrag(UINavigationController *nav, CGFloat shown) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    UIView *picture = state.host.restoreDragPicture;
    CGFloat travel = ApolloDuoRestoreTravel(state);
    if (!picture || travel <= 0) return;
    picture.transform = CGAffineTransformMakeTranslation(travel - ApolloDuoDragClamp(shown, travel), 0);
}

void ApolloDuoSplitEndRestoreDrag(UINavigationController *nav, BOOL restore, CGFloat shown, CGFloat velocity) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    UIView *picture = state.host.restoreDragPicture;
    state.host.restoreDragPicture = nil;
    CGFloat travel = ApolloDuoRestoreTravel(state);
    ApolloLog(@"[DuoDrag] forward drag ended restore=%d shown=%.0f velocity=%.0f", restore, shown, velocity);
    if (restore && ApolloDuoSplitCanRestoreClosedThread(nav)) {
        NSArray<UIViewController *> *pages = state.closedThread.pages;
        state.closedThread = nil;
        if (sDuoPostsClosedThreadState == state) sDuoPostsClosedThreadState = nil;
        // The real pane takes over exactly where the picture is.
        CGFloat remaining = travel > 0 ? MAX(1, travel - ApolloDuoDragClamp(shown, travel)) : 0;
        ApolloDuoPostsSetDetailPagesFromDrag(state, pages, YES, remaining, -velocity);
        ApolloDuoPostsSyncColumns(state);
        [picture removeFromSuperview];
        return;
    }
    if (!picture) return;
    CGFloat from = (picture.layer.presentationLayer ?: picture.layer).transform.m41;
    // As with the cover drag: a transaction completion still runs when a fold
    // or the app leaving cuts the slide short, so the picture never lingers.
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (!state.host.restoreDragPicture || state.host.restoreDragPicture != picture) [picture removeFromSuperview];
    }];
    ApolloDuoSlideDrawer(picture, from, travel, velocity, picture.window != nil, nil);
    [CATransaction commit];
}

// The feed's scroll expiry (Forget Forward Swipe After Scrolling) asks about
// the closed thread as it does about Apollo's own forward page: a token for
// "something to forget" (its first page, nil without one), then the forget.
id ApolloDuoSplitClosedThreadToken(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.feed == nav ? state.closedThread.pages.firstObject : nil;
}

void ApolloDuoSplitForgetClosedThreadAfterScrolling(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (state.feed == nav) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventScrolledAway, 0.0);
}

#pragma mark - Pane Back drags

// Whether a native pop in `nav` uncovers a real page of that same pane, so
// Apollo's own interactive Back can own it and follow the finger, as it does
// on a regular iPhone. With no split (folded, portrait) every pop does. In
// the split only a visible pane qualifies: the feed with no thread beside it
// (Apollo's pans stay off the feed while a thread shows), or the detail pane.
// Not the thread right above the Posts backstop (closing it is a column
// change), an empty detail's placeholder, or Account's Overview under the
// shared header: only the split's own Back lays those out. Nor a sidebar
// split's detail page with a kept picture of the page below: its view runs
// under the sidebar, so Apollo's Back would slide its own background over the
// page underneath; the split's cover drag slides the visible pane instead.
static BOOL ApolloDuoSplitPaneBackHasPicture(UINavigationController *nav);
BOOL ApolloDuoSplitPopRevealsContent(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    NSArray<UIViewController *> *pages = nav.viewControllers;
    if (pages.count < 2) return NO;
    if (!state.split) return YES;
    if (state.changing || state.host.listVisible) return NO;
    if (nav == state.feed) return !state.host.postsShowingDetail;
    if (nav != state.secondary) return NO;
    if (state.feed) return pages.count > 2;
    UIViewController *below = pages[pages.count - 2];
    BOOL placeholder = below.class == UIViewController.class;
    BOOL overview = [state.kind isEqualToString:@"account"] && below == state.root;
    return !placeholder && !overview && !ApolloDuoSplitPaneBackHasPicture(nav);
}

// The Posts thread pane shows a thread right above its backstop, so a Back
// there closes the thread column (popViewControllerAnimated: below).
BOOL ApolloDuoSplitCanDragThreadClosed(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && state.feed && !state.changing && nav == state.secondary
        && state.host.postsShowingDetail && nav.viewControllers.count == 2 && state.host.view.window;
}

// Starts a thread drag from wherever the pane is (mid-spring included) and
// returns that offset, or -1 when the thread can't be dragged closed.
CGFloat ApolloDuoSplitBeginThreadDrag(UINavigationController *nav) {
    if (!ApolloDuoSplitCanDragThreadClosed(nav)) return -1;
    UIView *view = nav.view;
    CGFloat offset = MAX(0, ApolloDuoThreadDragOffset(view));
    {
        // The pane as it stands, for a forward drag after the close.
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
        UIView *surface = state.host.view;
        CGRect pane = ApolloDuoPostsDetailPane(state);
        state.host.threadDragPicture = offset < 1 && surface.window && !CGRectIsNull(pane) && !CGRectIsEmpty(pane)
            ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
    }
    ApolloDuoSetThreadDragOffset(view, offset);
    // The feed follows the thread's edge. Re-laying out the real feed every
    // frame would re-measure every row; the close widens the real feed under
    // this filler once the finger lifts. Its bars (plain chrome) stretch from
    // a 2pt slice of their trailing edge; below them the feed's own
    // row color fills the gap, so media and Highlights cards that reach the
    // column edge end there instead of smearing across it.
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    UIView *surface = state.host.view;
    CGRect pane = ApolloDuoPostsDetailPane(state);
    UIView *feedView = state.feed.viewIfLoaded;
    if (!state.host.threadDragFiller && surface.window && feedView.window && !CGRectIsNull(pane) && CGRectGetMinX(pane) > 4) {
        UITableView *table = ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded);
        // Feed rows draw in the theme's card color, which the table's own
        // background (the page color between rows) does not match.
        UIColor *background = ApolloThemeCardBackgroundColor() ?: table.backgroundColor ?: UIColor.systemBackgroundColor;
        UIView *filler = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMinX(pane), CGRectGetMinY(pane),
                                                                  offset, CGRectGetHeight(pane))];
        filler.userInteractionEnabled = NO;
        filler.clipsToBounds = YES;
        filler.backgroundColor = [background resolvedColorWithTraitCollection:feedView.traitCollection];
        UIView *page = state.feed.topViewController.viewIfLoaded ?: feedView;
        CGFloat barsBottom = [surface convertPoint:CGPointMake(0, page.safeAreaInsets.top) fromView:page].y;
        CGFloat barsHeight = MIN(CGRectGetHeight(pane), barsBottom - CGRectGetMinY(pane));
        if (barsHeight > 0) {
            CGRect edge = CGRectMake(CGRectGetMinX(pane) - 4, CGRectGetMinY(pane), 2, barsHeight);
            UIView *bars = [surface resizableSnapshotViewFromRect:edge afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
            if (bars) {
                bars.frame = CGRectMake(0, 0, offset, barsHeight);
                bars.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                [filler addSubview:bars];
            }
        }
        [surface insertSubview:filler belowSubview:state.host.listDismiss];
        state.host.threadDragFiller = filler;
    }
    ApolloLog(@"[DuoDrag] thread drag began offset=%.0f", offset);
    return offset;
}

// Only the live pane moves: no layout, no re-measure, no snapshot. What it
// uncovers on its leading side is its own surface, which runs under the feed.
void ApolloDuoSplitDragThread(UINavigationController *nav, CGFloat offset) {
    ApolloDuoSetThreadDragOffset(nav.viewIfLoaded, MAX(0, offset));
    UIView *filler = ApolloDuoSplitStateForNavigation(nav, NO).host.threadDragFiller;
    CGRect frame = filler.frame;
    frame.size.width = MAX(0, offset);
    filler.frame = frame;
}

// The width a thread drag travels: the visible thread pane, rail included.
CGFloat ApolloDuoSplitThreadDragTravel(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    CGRect pane = state.split ? ApolloDuoPostsDetailPane(state) : CGRectNull;
    return CGRectIsNull(pane) ? 0 : CGRectGetWidth(pane);
}

// Ends a thread drag. A close hands the dragged pane to the split's own
// close (the same one as the close button), which continues from the finger.
// Otherwise the pane springs back with the thread untouched.
void ApolloDuoSplitEndThreadDrag(UINavigationController *nav, BOOL close, CGFloat offset, CGFloat velocity) {
    UIView *view = nav.viewIfLoaded;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    ApolloLog(@"[DuoDrag] thread drag ended close=%d offset=%.0f velocity=%.0f", close, offset, velocity);
    if (close && offset > 0 && ApolloDuoSplitCanDragThreadClosed(nav)) {
        ApolloDuoPostsSetDetailPagesFromDrag(state, @[], YES, offset, velocity);
        return;
    }
    state.host.threadDragPicture = nil;
    if (!view) return;
    CGFloat from = ApolloDuoThreadDragOffset(view);
    BOOL animated = view.window != nil && !UIAccessibilityIsReduceMotionEnabled();
    ApolloDuoSettleThreadDrag(view, from, velocity, animated);
    // The feed's stretched edge shrinks back with the thread.
    UIView *filler = state.host.threadDragFiller;
    state.host.threadDragFiller = nil;
    if (!filler || !animated) {
        [filler removeFromSuperview];
        return;
    }
    CGRect frame = filler.frame;
    frame.size.width = 0;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{ filler.frame = frame; }
                     completion:^(__unused BOOL finished) { [filler removeFromSuperview]; }];
}

// Drawer drags started by a pane Back at the feed root.
BOOL ApolloDuoSplitBeginListDrag(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || !state.feed || state.changing) return NO;
    return [state.host beginListDrag:YES];
}
CGFloat ApolloDuoSplitListDragTravel(UINavigationController *nav) {
    return [ApolloDuoSplitStateForNavigation(nav, NO).host listTravel];
}
CGFloat ApolloDuoSplitListDragStart(UINavigationController *nav) {
    return ApolloDuoSplitStateForNavigation(nav, NO).host.listDragStart;
}
void ApolloDuoSplitMoveListDrag(UINavigationController *nav, CGFloat shown) {
    [ApolloDuoSplitStateForNavigation(nav, NO).host moveListDrag:shown];
}
void ApolloDuoSplitEndListDrag(UINavigationController *nav, BOOL show, CGFloat velocity) {
    [ApolloDuoSplitStateForNavigation(nav, NO).host endListDrag:show velocity:velocity];
}

// Apollo's pan handler (behind screenEdgePanned: and navigationBarPanned:)
// completes a held release at half its navigation view's width. A split
// pane's view runs under the sidebar or the feed column, so a release at 70%
// of the visible pane could spring back. Scale only the translation Apollo
// reads on release, so half is measured on the visible pane; dragging stays
// 1:1, and Apollo takes its own finish or cancel branch.
static __thread void *sDuoSplitReleaseGesture;
static __thread void *sDuoSplitReleaseView;
static __thread CGFloat sDuoSplitReleaseScale = 1.0;

static CGFloat ApolloDuoSplitNativeReleaseScale(UINavigationController *nav, UIPanGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateEnded && gesture.state != UIGestureRecognizerStateCancelled) return 1.0;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || state.changing || ApolloDuoSplitIsResizing()
        || (nav != state.secondary && nav != state.feed)) return 1.0;
    CGRect pane = ApolloDuoSplitContentFrame(nav, nav.view);
    // The content frame keeps the strip under the rail (it centers content);
    // a release is judged on the part you can see.
    CGFloat viewWidth = CGRectGetWidth(nav.view.bounds);
    CGFloat visibleRight = MIN(CGRectGetMaxX(pane), viewWidth - nav.view.safeAreaInsets.right);
    CGFloat paneWidth = CGRectIsNull(pane) ? 0 : visibleRight - CGRectGetMinX(pane);
    return paneWidth > 0 && paneWidth < viewWidth ? viewWidth / paneWidth : 1.0;
}

static void ApolloDuoSplitRunNativePan(UINavigationController *nav, UIPanGestureRecognizer *gesture, void (^handler)(void)) {
    CGFloat scale = ApolloDuoSplitNativeReleaseScale(nav, gesture);
    if (scale == 1.0) {
        handler();
        return;
    }
    void *previousGesture = sDuoSplitReleaseGesture, *previousView = sDuoSplitReleaseView;
    CGFloat previousScale = sDuoSplitReleaseScale;
    sDuoSplitReleaseGesture = (__bridge void *)gesture;
    sDuoSplitReleaseView = (__bridge void *)nav.view;
    sDuoSplitReleaseScale = scale;
    handler();
    sDuoSplitReleaseGesture = previousGesture;
    sDuoSplitReleaseView = previousView;
    sDuoSplitReleaseScale = previousScale;
}

// Apollo's own interactive Back is following the finger (or releasing) on
// `nav`. A pop it drives is a page pop, never one of the split's own.
static BOOL ApolloDuoSplitNativeBackActive(UINavigationController *nav) {
    Ivar ivar = class_getInstanceVariable(nav.class, "leftScreenEdgePanGestureRecognizer");
    UIGestureRecognizer *pan = ivar ? object_getIvar(nav, ivar) : nil;
    if (![pan isKindOfClass:UIGestureRecognizer.class]) return NO;
    UIGestureRecognizerState state = pan.state;
    return state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged
        || state == UIGestureRecognizerStateEnded;
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

// Apollo records forward pages when its own pop override runs, and forgets
// them in didShow only after its own push override (RE: the pushing/popping
// flags in -navigationController:didShowViewController:animated:). The split
// opens subreddits, threads and sidebar destinations with
// setViewControllers:, which skips that push, so a page left by an earlier
// Back stayed queued: a left swipe after picking r/X from the list re-pushed
// the old one. When the split moves a stack forward (its new top is a page
// the stack did not hold), forget the forward pages as a native push would.
// A Back keeps them, as do the user's own Back gestures and buttons.
static BOOL ApolloDuoSplitStackMovesForward(NSArray<UIViewController *> *before, NSArray<UIViewController *> *after) {
    UIViewController *top = after.lastObject;
    return top && [before indexOfObjectIdenticalTo:top] == NSNotFound;
}

static void ApolloDuoSplitForgetForward(UINavigationController *nav, NSArray<UIViewController *> *before) {
    if (before && !ApolloDuoSplitStackMovesForward(before, nav.viewControllers)) return;
    UIViewController *forward = ApolloDuoSplitForwardPage(nav);
    if (!forward) return;
    // The same native wipe as ForwardSwipeExpiry: Apollo's override of
    // -didReceiveMemoryWarning only empties poppedViewControllers.
    [nav didReceiveMemoryWarning];
    ApolloLog(@"[DuoSplit] forgot forward page %@ after the split opened %@",
              NSStringFromClass(forward.class), NSStringFromClass(nav.topViewController.class));
}

// "Default Reddit to Load: Lists" is stored as ["redditsList"] (Apollo's
// DefaultRedditToLoad.redditsList; read from its settings comparison).
static BOOL ApolloDuoSplitStartupShowsList(void) {
    NSArray *choice = [NSUserDefaults.standardUserDefaults arrayForKey:@"DefaultRedditToLoad"];
    id kind = choice.firstObject;
    return [kind isKindOfClass:NSString.class] && [kind caseInsensitiveCompare:@"redditsList"] == NSOrderedSame;
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

// A page's picture as it last showed (a rect of the split host), kept for a
// later drag that slides it back in: Back onto it, or forward to it. Valid
// only for the same rect of a host the same size.
@interface ApolloDuoPagePicture : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic) CGRect rect;
@property(nonatomic) CGSize hostSize;
@end
@implementation ApolloDuoPagePicture @end
static char kApolloDuoPagePicture;

static void ApolloDuoRememberPagePicture(UIViewController *page, UIView *host, CGRect rect) {
    if (!page || !host.window || CGRectIsNull(rect) || CGRectIsEmpty(rect)) return;
    UIView *view = [host resizableSnapshotViewFromRect:rect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if (!view) return;
    ApolloDuoPagePicture *picture = [ApolloDuoPagePicture new];
    picture.view = view;
    picture.rect = rect;
    picture.hostSize = host.bounds.size;
    objc_setAssociatedObject(page, &kApolloDuoPagePicture, picture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoSetPagePicture(UIViewController *page, UIView *view, UIView *host, CGRect rect) {
    if (!page || !view) return;
    ApolloDuoPagePicture *picture = [ApolloDuoPagePicture new];
    picture.view = view;
    picture.rect = rect;
    picture.hostSize = host.bounds.size;
    objc_setAssociatedObject(page, &kApolloDuoPagePicture, picture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *ApolloDuoPagePictureView(UIViewController *page, UIView *host, CGRect rect) {
    ApolloDuoPagePicture *picture = page ? objc_getAssociatedObject(page, &kApolloDuoPagePicture) : nil;
    return picture.view && CGSizeEqualToSize(picture.hostSize, host.bounds.size)
        && CGRectEqualToRect(CGRectIntegral(picture.rect), CGRectIntegral(rect)) ? picture.view : nil;
}

// What a sidebar split's detail shows beside the sidebar, full height (on
// Account's Overview the profile header runs across its top). The detail
// column itself extends beneath the sidebar, so start at the sidebar's
// trailing edge, as Account's header clip does.
static CGRect ApolloDuoAccountDetailRect(ApolloDuoSplitState *state) {
    UIView *host = state.host.viewIfLoaded;
    UIView *primary = [state.kind isEqualToString:@"account"] ? state.host.accountPrimary.viewIfLoaded : state.primary.viewIfLoaded;
    if (!host.window) return CGRectNull;
    CGFloat left = 0;
    if (primary.window && state.split.displayMode != UISplitViewControllerDisplayModeSecondaryOnly)
        left = MAX(0, CGRectGetMaxX([primary convertRect:primary.bounds toView:host]));
    if (left >= CGRectGetWidth(host.bounds)) return CGRectNull;
    return CGRectMake(left, 0, CGRectGetWidth(host.bounds) - left, CGRectGetHeight(host.bounds));
}

static void ApolloDuoAccountSetPagesAnimated(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages,
                                             BOOL animate, BOOL forgetForward) {
    UIView *surface = state.host.view;
    if ([state.secondary.viewControllers isEqualToArray:pages]) return;
    // The page leaving the top, as it shows now: Back onto it, or forward to
    // it, can slide this picture in under the finger.
    if (state.secondary.topViewController != pages.lastObject)
        ApolloDuoRememberPagePicture(state.secondary.topViewController, surface, ApolloDuoAccountDetailRect(state));
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
    BOOL animated = animate && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    NSArray *before = state.secondary.viewControllers;
    [state.secondary setViewControllers:pages animated:animated];
    if (forgetForward) ApolloDuoSplitForgetForward(state.secondary, before);
    state.host.pendingAccountDetail = nil;
    [state.secondary setNavigationBarHidden:pages.count == 1 animated:animated];
}

static void ApolloDuoAccountSetPages(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages) {
    // Any Account navigation other than the split's own Back moves on from
    // the page that Back left.
    state.accountForwardPage = nil;
    state.accountForwardStack = nil;
    ApolloDuoAccountSetPagesAnimated(state, pages, YES, YES);
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
    // Unfolding on the folded subreddit list keeps that list open as the
    // drawer. Decided at the unfold, since the install below can be deferred.
    // The settle time excludes a launch resize before Apollo's default feed.
    if (sDuoSplitResizingTabs && [state.kind isEqualToString:@"subreddits"]
        && outer.viewControllers.count == 1 && outer.tabBarController.selectedViewController == outer
        && state.foldedListShownAt > 0 && CACurrentMediaTime() - state.foldedListShownAt >= 0.5) {
        state.pinListOnOpen = YES;
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
    BOOL pinList = state.pinListOnOpen && outer.viewControllers.count == 1;
    state.pinListOnOpen = NO;
    state.foldedListShownAt = 0;
    if ([state.kind isEqualToString:@"subreddits"] && outer.viewControllers.count == 1 && !pinList) {
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
    // With Lists as the default, an empty Posts split (a launch or unfold with
    // no feed open) shows the list as the pinned drawer instead of Home.
    if (!pinList && detail.count == 0 && [state.kind isEqualToString:@"subreddits"]
        && ApolloDuoSplitStartupShowsList()) {
        pinList = YES;
        ApolloLog(@"[DuoSplit] Default Reddit to Load is Lists; pinning the subreddit list");
    }
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
        postsHost.listPinned = pinList;
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
    state.needsDefault = detail.count == 0 && !pinList;
    state.changing = NO;
    ApolloDuoSearchUpdateBackItem(state);
    ApolloLog(@"[DuoSplit] opened native %@ sidebar/detail pinnedList=%d", state.kind, pinList);
    if (pinList) [host setListVisible:YES animated:NO];
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
        ApolloNativeFeedSearchSetDuoControls(state.host.feedControlsOwner, nil, nil, nil, NO);
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
        state.profileBackPicture = nil;
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

static void ApolloDuoSplitForgetProfileForward(ApolloDuoSplitState *state) {
    if (!state.profileForwardPage) return;
    state.profileForwardPage = nil;
    state.profileForwardPicture = nil;
    state.profileForwardStack = nil;
    state.profileForwardFeedTop = nil;
    state.profileForwardDetailTop = nil;
}

// Close the split and reopen it on the other side of a profile visit, at
// once. Keeps what the opposite swipe needs: a picture of the side left and,
// after a Back, the profile itself with the Posts pages it returned to.
static void ApolloDuoSplitSwapProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward) {
    UINavigationController *outer = state.outer;
    UIView *oldView = state.host.view;
    CGSize size = oldView.bounds.size;
    UIView *picture = oldView.window ? [oldView snapshotViewAfterScreenUpdates:NO] : nil;
    UIViewController *leaving = state.root;
    NSArray *prefix = state.profilePrefix;
    [UIView performWithoutAnimation:^{
        ApolloDuoSplitClose(state, YES);
        NSArray *stack = forward ? [outer.viewControllers arrayByAddingObject:profile] : prefix;
        [outer setViewControllers:stack animated:NO];
        ApolloDuoSplitOpen(state);
        [outer.view layoutIfNeeded];
    }];
    ApolloDuoSplitForgetProfileForward(state);
    if (forward) {
        state.profileBackPicture = picture;
        state.profileBackPictureSize = size;
    } else if (state.split && leaving) {
        state.profileForwardPage = leaving;
        state.profileForwardPicture = picture;
        state.profileForwardPictureSize = size;
        state.profileForwardStack = outer.viewControllers;
        state.profileForwardFeedTop = state.feed.topViewController;
        state.profileForwardDetailTop = state.secondary.topViewController;
    }
}

// Reparent the live pages under one visual transition. A snapshot covers the
// intermediate single-column stack, so UIKit cannot flash that layout first.
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward) {
    if (!state.split || state.changing || state.coverDrag) return;
    UINavigationController *outer = state.outer;
    UIView *oldView = state.host.view;
    UIView *snapshot = [oldView snapshotViewAfterScreenUpdates:NO];
    CGRect frame = [oldView convertRect:oldView.bounds toView:outer.view];
    ApolloDuoSplitSwapProfile(state, profile, forward);
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

static BOOL ApolloDuoSplitStateCanReturnFromProfile(ApolloDuoSplitState *state) {
    return state.split && !state.changing && !state.coverDrag && state.profilePrefix.count
        && [state.kind isEqualToString:@"account"]
        && [state.tabKind isEqualToString:@"subreddits"]
        && state.secondary.viewControllers.count == 1
        && state.secondary.topViewController == state.root;
}

BOOL ApolloDuoSplitCanReturnFromVisitedProfile(UINavigationController *navigation) {
    return ApolloDuoSplitStateCanReturnFromProfile(ApolloDuoSplitStateForNavigation(navigation, NO));
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

// The profile a Back left, while the Posts pages it returned to still show
// unchanged; anything else (another thread or feed, a pop, a reopened split)
// forgets it, as a native push forgets Apollo's forward pages.
static UIViewController *ApolloDuoSplitProfileForwardPage(ApolloDuoSplitState *state) {
    if (!state.profileForwardPage) return nil;
    BOOL current = state.split && !state.profilePrefix.count && [state.kind isEqualToString:@"subreddits"]
        && [state.outer.viewControllers isEqualToArray:state.profileForwardStack]
        && state.feed.topViewController == state.profileForwardFeedTop
        && state.secondary.topViewController == state.profileForwardDetailTop;
    if (!current) {
        ApolloLog(@"[DuoSplit] forgot the visited profile's forward swipe");
        ApolloDuoSplitForgetProfileForward(state);
    }
    return state.profileForwardPage;
}

static BOOL ApolloDuoSplitCanForwardToVisitedProfile(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (!state.split || state.changing || state.coverDrag) return NO;
    // The visible Posts pane: the thread, or the feed when no thread shows.
    if (navigation != state.secondary && !(navigation == state.feed && !state.host.postsShowingDetail)) return NO;
    if (ApolloDuoSplitCanRestoreClosedThread(navigation)) return NO;
    return ApolloDuoSplitProfileForwardPage(state) != nil;
}

static BOOL ApolloDuoSplitForwardToVisitedProfile(UINavigationController *navigation) {
    if (!ApolloDuoSplitCanForwardToVisitedProfile(navigation)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    ApolloDuoSplitNavigateProfile(state, state.profileForwardPage, YES);
    return YES;
}

#pragma mark - Cover drags

// A Back or forward the split lays out itself (leaving or returning to a
// visited profile, Back to Account's Overview, forward in Account, Back from
// a feed link beside a thread) follows the finger without moving any real
// page: a cover over the surface that changes holds a picture of what shows
// now and a kept picture of the destination, and slides both. A completed
// drag runs its commit under the cover once it settles; an early release
// slides it back. The pane the drag began in stays put underneath, so its
// touch carries on. Without a destination picture (Reduce Motion, a resize
// since, never shown) the caller navigates on release instead.
static BOOL ApolloDuoSplitBeginCoverDrag(ApolloDuoSplitState *state, CGRect rect, UIView *incoming,
                                         BOOL forward, BOOL parallax, void (^commit)(UIView *leftPicture)) {
    UIView *host = state.host.viewIfLoaded;
    if (state.coverDrag || !incoming || !host.window || CGRectIsNull(rect) || CGRectIsEmpty(rect)
        || UIAccessibilityIsReduceMotionEnabled()) return NO;
    UIView *leaving = [host resizableSnapshotViewFromRect:rect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if (!leaving) return NO;
    state.coverDragLeftPicture = [host resizableSnapshotViewFromRect:rect afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    CGRect bounds = CGRectMake(0, 0, CGRectGetWidth(rect), CGRectGetHeight(rect));
    CGFloat width = CGRectGetWidth(bounds);
    UIView *cover = [[UIView alloc] initWithFrame:rect];
    cover.userInteractionEnabled = NO;
    cover.clipsToBounds = YES;
    cover.backgroundColor = UIColor.systemBackgroundColor;
    leaving.frame = bounds;
    [incoming.layer removeAllAnimations];
    incoming.transform = CGAffineTransformIdentity;
    incoming.frame = bounds;
    incoming.transform = CGAffineTransformMakeTranslation(forward ? width : (parallax ? -0.3 * width : -width), 0);
    // The page on top is the one sliding the full width: the leaving page on
    // Back, the arriving page going forward.
    [cover addSubview:forward ? leaving : incoming];
    [cover addSubview:forward ? incoming : leaving];
    [host addSubview:cover];
    state.coverDrag = cover;
    state.coverDragForward = forward;
    state.coverDragParallax = parallax;
    state.coverDragCommit = commit;
    ApolloLog(@"[DuoDrag] cover %@ drag began travel=%.0f parallax=%d", forward ? @"forward" : @"Back", width, parallax);
    return YES;
}

static UIView *ApolloDuoCoverLeaving(ApolloDuoSplitState *state) {
    NSArray *views = state.coverDrag.subviews;
    if (views.count < 2) return nil;
    return state.coverDragForward ? views.firstObject : views.lastObject;
}

static UIView *ApolloDuoCoverIncoming(ApolloDuoSplitState *state) {
    NSArray *views = state.coverDrag.subviews;
    if (views.count < 2) return nil;
    return state.coverDragForward ? views.lastObject : views.firstObject;
}

// Where each picture sits `shown` points into the drag (0 to the width).
static void ApolloDuoCoverOffsets(BOOL forward, BOOL parallax, CGFloat width, CGFloat shown,
                                  CGFloat *leaving, CGFloat *incoming) {
    CGFloat d = ApolloDuoDragClamp(shown, width);
    if (forward) {
        *incoming = width - d;
        *leaving = parallax ? -0.3 * d : -d;
    } else {
        *leaving = d;
        *incoming = parallax ? -0.3 * (width - d) : d - width;
    }
}

// A release is judged on the part of the cover you can see: it runs under
// the rail strip, which the drag never reaches.
CGFloat ApolloDuoSplitCoverDragTravel(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    UIView *cover = state.coverDrag, *host = state.host.viewIfLoaded;
    if (!cover) return 0;
    CGFloat visibleRight = MIN(CGRectGetMaxX(cover.frame), CGRectGetWidth(host.bounds) - host.safeAreaInsets.right);
    CGFloat visible = visibleRight - CGRectGetMinX(cover.frame);
    return visible > 0 ? visible : CGRectGetWidth(cover.bounds);
}

// `shown` is how far the drag has gone, 0 to the surface's width.
void ApolloDuoSplitMoveCoverDrag(UINavigationController *navigation, CGFloat shown) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    UIView *leaving = ApolloDuoCoverLeaving(state), *incoming = ApolloDuoCoverIncoming(state);
    if (!leaving || !incoming) return;
    CGFloat leavingX = 0, incomingX = 0;
    ApolloDuoCoverOffsets(state.coverDragForward, state.coverDragParallax, CGRectGetWidth(state.coverDrag.bounds),
                          shown, &leavingX, &incomingX);
    leaving.transform = CGAffineTransformMakeTranslation(leavingX, 0);
    incoming.transform = CGAffineTransformMakeTranslation(incomingX, 0);
}

void ApolloDuoSplitEndCoverDrag(UINavigationController *navigation, BOOL commit, CGFloat shown, CGFloat velocity) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    UIView *cover = state.coverDrag;
    if (!cover) return;
    BOOL forward = state.coverDragForward, parallax = state.coverDragParallax;
    void (^action)(UIView *) = state.coverDragCommit;
    UIView *leftPicture = state.coverDragLeftPicture;
    state.coverDragCommit = nil;
    state.coverDragLeftPicture = nil;
    ApolloLog(@"[DuoDrag] cover %@ drag ended commit=%d shown=%.0f velocity=%.0f",
              forward ? @"forward" : @"Back", commit, shown, velocity);
    UIView *leaving = ApolloDuoCoverLeaving(state), *incoming = ApolloDuoCoverIncoming(state);
    if (!leaving || !incoming) {
        state.coverDrag = nil;
        [cover removeFromSuperview];
        return;
    }
    CGFloat width = CGRectGetWidth(cover.bounds);
    CGFloat leavingTo = 0, incomingTo = 0;
    ApolloDuoCoverOffsets(forward, parallax, width, commit ? width : 0, &leavingTo, &incomingTo);
    // The picture riding under the finger sets the pace; a parallax partner
    // covers less ground in the same time.
    UIView *lead = forward ? incoming : leaving;
    UIView *partner = forward ? leaving : incoming;
    CGFloat leadTo = forward ? incomingTo : leavingTo, partnerTo = forward ? leavingTo : incomingTo;
    CGFloat leadFrom = (lead.layer.presentationLayer ?: lead.layer).transform.m41;
    CGFloat partnerFrom = (partner.layer.presentationLayer ?: partner.layer).transform.m41;
    CGFloat partnerScale = parallax ? 0.3 : 1.0;
    BOOL animated = cover.window != nil;
    __weak ApolloDuoSplitState *weakState = state;
    // A transaction completion also runs when a fold or the app leaving
    // removes the springs early; the slide's own completion runs only for
    // a finished one, which left coverDrag set and refused every later drag.
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        ApolloDuoSplitState *current = weakState;
        if (current.coverDrag == cover) current.coverDrag = nil;
        // The commit re-checks that what it changes is still in place (a
        // fold or rotation mid-drag may have rebuilt the split meanwhile).
        if (commit && action) action(leftPicture);
        [cover removeFromSuperview];
    }];
    ApolloDuoSlideDrawer(partner, partnerFrom, partnerTo, velocity * partnerScale, animated, nil);
    ApolloDuoSlideDrawer(lead, leadFrom, leadTo, velocity, animated, nil);
    [CATransaction commit];
}

// Leaving a visited profile, and a forward swipe back into it, slide across
// the whole split. Their destination pictures are kept by the swap.
static UIView *ApolloDuoSplitProfilePicture(ApolloDuoSplitState *state, BOOL forward) {
    UIView *picture = forward ? state.profileForwardPicture : state.profileBackPicture;
    CGSize size = forward ? state.profileForwardPictureSize : state.profileBackPictureSize;
    return picture && CGSizeEqualToSize(size, state.host.view.bounds.size) ? picture : nil;
}

static BOOL ApolloDuoSplitBeginProfileDrag(UINavigationController *navigation, BOOL forward) {
    if (forward ? !ApolloDuoSplitCanForwardToVisitedProfile(navigation)
                : !ApolloDuoSplitCanReturnFromVisitedProfile(navigation)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    UIViewController *profile = forward ? state.profileForwardPage : nil;
    __weak ApolloDuoSplitState *weakState = state;
    return ApolloDuoSplitBeginCoverDrag(state, state.host.view.bounds, ApolloDuoSplitProfilePicture(state, forward), forward, NO,
                                        ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        BOOL still = forward ? current.split && !current.changing && ApolloDuoSplitProfileForwardPage(current) == profile
                             : ApolloDuoSplitStateCanReturnFromProfile(current);
        if (!still) return;
        ApolloDuoSplitSwapProfile(current, profile, forward);
        // The swap's own picture of the side it left would show the cover.
        if (leftPicture && forward && current.profileBackPicture) current.profileBackPicture = leftPicture;
        if (leftPicture && !forward && current.profileForwardPicture) current.profileForwardPicture = leftPicture;
        ApolloLog(@"[DuoSplit] profile %@ completed under the drag", forward ? @"forward" : @"Back");
    });
}

#pragma mark - Account detail drags

// Account's detail pages are laid out by the split (ApolloDuoAccountSetPages),
// so neither the Back onto Overview nor Apollo's forward push can follow the
// finger natively. Both slide pictures across the detail pane instead: the
// page below (or the forward page) as it last showed, kept by SetPages.
static BOOL ApolloDuoAccountDetailReady(ApolloDuoSplitState *state, UINavigationController *navigation) {
    return state.split && !state.changing && !state.coverDrag && [state.kind isEqualToString:@"account"]
        && navigation == state.secondary && state.secondary.viewIfLoaded.window;
}

// The split's own Back of one Account page; it keeps the page it left for a
// forward swipe, as Apollo's native pop would.
static void ApolloDuoAccountPop(ApolloDuoSplitState *state, BOOL animated) {
    NSArray<UIViewController *> *pages = state.secondary.viewControllers;
    if (pages.count < 2) return;
    UIViewController *page = pages.lastObject;
    NSArray *remaining = [pages subarrayWithRange:NSMakeRange(0, pages.count - 1)];
    ApolloDuoAccountSetPagesAnimated(state, remaining, animated, NO);
    state.accountForwardPage = page;
    state.accountForwardStack = state.secondary.viewControllers;
    ApolloDuoSplitSyncGallerySidebar(state);
}

static BOOL ApolloDuoAccountBeginBackDrag(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (!ApolloDuoAccountDetailReady(state, navigation)) return NO;
    NSArray<UIViewController *> *pages = state.secondary.viewControllers;
    // Pops onto a real page of the pane are Apollo's own interactive Back.
    if (pages.count < 2 || ApolloDuoSplitPopRevealsContent(navigation)) return NO;
    CGRect rect = ApolloDuoAccountDetailRect(state);
    UIView *below = ApolloDuoPagePictureView(pages[pages.count - 2], state.host.view, rect);
    __weak ApolloDuoSplitState *weakState = state;
    return ApolloDuoSplitBeginCoverDrag(state, rect, below, NO, YES, ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        if (!current.split || current.changing || ![current.secondary.viewControllers isEqualToArray:pages]) return;
        ApolloDuoAccountPop(current, NO);
        ApolloDuoSetPagePicture(pages.lastObject, leftPicture, current.host.view, rect);
        ApolloLog(@"[DuoSplit] Account Back completed under the drag");
    });
}

// The page a forward swipe in Account's detail brings back: the one the
// split's own Back left while its pages still show, else Apollo's own.
static UIViewController *ApolloDuoAccountForwardPage(ApolloDuoSplitState *state, BOOL *split) {
    if (state.accountForwardPage && ![state.secondary.viewControllers isEqualToArray:state.accountForwardStack]) {
        state.accountForwardPage = nil;
        state.accountForwardStack = nil;
    }
    if (split) *split = state.accountForwardPage != nil;
    return state.accountForwardPage ?: ApolloDuoSplitForwardPage(state.secondary);
}

static BOOL ApolloDuoAccountCanForward(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    return ApolloDuoAccountDetailReady(state, navigation) && ApolloDuoAccountForwardPage(state, NULL) != nil;
}

// Forward onto `page`: an Apollo forward page is consumed with the rest of
// its forward history, as the split's own pushes do; the split's own keeps
// Apollo's history behind it.
static void ApolloDuoAccountForward(ApolloDuoSplitState *state, UIViewController *page, BOOL splitPage, BOOL animated) {
    NSArray<UIViewController *> *pages = [state.secondary.viewControllers arrayByAddingObject:page];
    state.accountForwardPage = nil;
    state.accountForwardStack = nil;
    ApolloDuoAccountSetPagesAnimated(state, pages, animated, !splitPage);
    ApolloDuoSplitSyncGallerySidebar(state);
}

static BOOL ApolloDuoAccountBeginForwardDrag(UINavigationController *navigation) {
    if (!ApolloDuoAccountCanForward(navigation)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    BOOL splitPage = NO;
    UIViewController *page = ApolloDuoAccountForwardPage(state, &splitPage);
    NSArray<UIViewController *> *pages = state.secondary.viewControllers;
    CGRect rect = ApolloDuoAccountDetailRect(state);
    __weak ApolloDuoSplitState *weakState = state;
    return ApolloDuoSplitBeginCoverDrag(state, rect, ApolloDuoPagePictureView(page, state.host.view, rect), YES, YES,
                                        ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        if (!current.split || current.changing || ![current.secondary.viewControllers isEqualToArray:pages]) return;
        ApolloDuoAccountForward(current, page, splitPage, NO);
        ApolloDuoSetPagePicture(pages.lastObject, leftPicture, current.host.view, rect);
        ApolloLog(@"[DuoSplit] Account forward completed under the drag");
    });
}

// A fold or rotation while a pane's own push or pop is still running (Apollo's
// interactive Back held under the finger): moving the stacks under it left
// the pop to settle on a stack that no longer held its pages, a blank Home
// with the thread gone. End the swipe (the page springs back) and close the
// split once that transition has settled, as Open waits for one.
static BOOL ApolloDuoSplitDeferCloseForPaneTransition(ApolloDuoSplitState *state) {
    if (!state.split || state.changing) return NO;
    for (UINavigationController *nav in @[state.primary ?: (id)NSNull.null, state.feed ?: (id)NSNull.null,
                                          state.secondary ?: (id)NSNull.null]) {
        if (![nav isKindOfClass:UINavigationController.class]) continue;
        id<UIViewControllerTransitionCoordinator> transition = nav.transitionCoordinator;
        if (!transition || transition == sDuoSplitSizeCoordinator) continue;
        if (transition.isInteractive) {
            NSMutableArray<UIGestureRecognizer *> *recognizers = [NSMutableArray array];
            if (nav.viewIfLoaded.gestureRecognizers) [recognizers addObjectsFromArray:nav.view.gestureRecognizers];
            if (nav.navigationBar.gestureRecognizers) [recognizers addObjectsFromArray:nav.navigationBar.gestureRecognizers];
            for (UIGestureRecognizer *recognizer in recognizers) {
                if (![recognizer isKindOfClass:UIPanGestureRecognizer.class]) continue;
                if (recognizer.state != UIGestureRecognizerStateBegan && recognizer.state != UIGestureRecognizerStateChanged) continue;
                recognizer.enabled = NO;
                recognizer.enabled = YES;
            }
        }
        if (state.pendingNavigationTransition != transition) {
            state.pendingNavigationTransition = transition;
            __weak ApolloDuoSplitState *weakState = state;
            [transition animateAlongsideTransition:nil
                                       completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                weakState.pendingNavigationTransition = nil;
                ApolloDuoSplitScheduleUpdate();
            }];
        }
        ApolloLog(@"[DuoSplit] %@ columns stay until a pane's %@ transition settles",
                  state.kind, transition.isInteractive ? @"interactive" : @"animated");
        return YES;
    }
    return NO;
}

static void ApolloDuoSplitUpdate(void) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (sDuoSplitUpdating || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdating = YES;
    ApolloDuoSplitObserveHinge(tabs);
    BOOL open = ApolloDuoSplitShouldOpen(tabs);
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *nav = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, open || child == tabs.selectedViewController);
        if (!state) continue;
        BOOL postsOpen = [state.kind isEqualToString:@"subreddits"] && ApolloDuoSplitIsUnfolded();
        if (!open && !postsOpen) {
            // Closing only: a pane's push or pop still running keeps its
            // columns until it settles (ApolloDuoSplitDeferCloseForPaneTransition).
            if (!ApolloDuoSplitDeferCloseForPaneTransition(state)) ApolloDuoSplitClose(state, NO);
        } else {
            // Native Swift pushes can bypass the ObjC push hook. On rotation
            // into landscape, a profile may also still be on the portrait feed
            // stack. Normalize either path before installing its dashboard.
            if (open) {
                NSArray *pages = [(state.feed.viewControllers ?: @[])
                    arrayByAddingObjectsFromArray:state.secondary.viewControllers ?: @[]];
                for (UIViewController *page in pages) {
                    if (page != state.root && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
                        if (!ApolloDuoSplitDeferCloseForPaneTransition(state)) ApolloDuoSplitClose(state, YES);
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
                // The fold region can publish a beat after the posture
                // change, so keep both panes scrollable while it moves.
                [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                    ApolloDuoSplitApplySidebarWidth(state, halfWidth);
                    [state.split.view layoutIfNeeded];
                } completion:nil];
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

static BOOL ApolloDuoSplitHasDeferredPresentationInWindow(UIWindow *window) {
    if (!window) return NO;
    for (ApolloDuoSplitState *state in sDuoSplitDeferredPresentations.allObjects) {
        if (state.outer.viewIfLoaded.window == window) return YES;
    }
    return NO;
}

%hook UIViewController
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
    // The split as the link leaves it (the feed and its thread), kept on the
    // feed it leaves: a Back drag from the linked feed, with a thread open
    // beside it, slides this back in.
    ApolloDuoRememberPagePicture(visibleFeed, state.host.viewIfLoaded, state.host.viewIfLoaded.bounds);
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
    if (ApolloDuoSplitNativeBackActive(state.feed)) return nil;
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

// Back from a linked feed while a thread from it shows beside it: the split
// returns to the feed the link left with that feed's own thread. The kept
// picture of that split (taken when the link opened) slides in under the
// finger; the real stacks change once the drag completes.
static BOOL ApolloDuoPostsBeginFeedLinkBackDrag(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    NSArray<UIViewController *> *pages = state.feed.viewControllers;
    if (!state.split || state.changing || state.coverDrag || navigation != state.feed || pages.count < 2
        || !state.host.postsShowingDetail || !ApolloDuoPostsUsesSplit(state)) return NO;
    UIViewController *top = pages.lastObject, *previous = pages[pages.count - 2];
    ApolloDuoFeedLinkReturn *ret = objc_getAssociatedObject(previous, &kDuoFeedLinkReturnDetail);
    if (![objc_getAssociatedObject(top, &kDuoFeedLinkPage) boolValue] || !ret.detail.count) return NO;
    UIView *surface = state.host.view;
    NSArray<UIViewController *> *thread = state.secondary.viewControllers;
    __weak ApolloDuoSplitState *weakState = state;
    return ApolloDuoSplitBeginCoverDrag(state, surface.bounds, ApolloDuoPagePictureView(previous, surface, surface.bounds), NO, NO,
                                        ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        if (!current.split || current.changing || ![current.feed.viewControllers isEqualToArray:pages]
            || ![current.secondary.viewControllers isEqualToArray:thread]) return;
        ApolloDuoFeedLinkReturn *restore = objc_getAssociatedObject(previous, &kDuoFeedLinkReturnDetail);
        if (!restore.detail.count) return;
        ApolloDuoPostsReviewClosedThread(current, ApolloDuoClosedThreadEventFeedOpened, 0.0);
        objc_setAssociatedObject(previous, &kDuoFeedLinkReturnDetail, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Apollo's own pop (its thread still shows, so the split leaves it to
        // Apollo): it keeps the linked feed as a forward page, as its Back does.
        [current.feed popViewControllerAnimated:NO];
        UIViewController *backstop = current.secondary.viewControllers.firstObject;
        [current.secondary setViewControllers:[(backstop ? @[backstop] : @[]) arrayByAddingObjectsFromArray:restore.detail]
                                     animated:NO];
        ApolloDuoPostsSyncColumns(current);
        [current.host.view layoutIfNeeded];
        // The linked feed as it showed, for a forward swipe back to it.
        ApolloDuoSetPagePicture(top, leftPicture, current.host.view, current.host.view.bounds);
        ApolloLog(@"[DuoSplit] Back from a feed link completed under the drag; restored %lu thread page(s)",
                  (unsigned long)restore.detail.count);
    });
}

// Settings and Inbox detail pages (Account's are above): a pane whose view
// runs under the sidebar, with a kept picture of the page below.
static BOOL ApolloDuoSplitPaneRunsUnderSidebar(ApolloDuoSplitState *state, UINavigationController *nav) {
    if (!state.split || state.feed || nav != state.secondary || !nav.viewIfLoaded.window) return NO;
    CGRect pane = ApolloDuoSplitContentFrame(nav, nav.view);
    return !CGRectIsNull(pane) && CGRectGetMinX(pane) > 0.5;
}

static BOOL ApolloDuoSplitPaneBackHasPicture(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    NSArray<UIViewController *> *pages = nav.viewControllers;
    if (pages.count < 2 || !ApolloDuoSplitPaneRunsUnderSidebar(state, nav) || UIAccessibilityIsReduceMotionEnabled()) return NO;
    return ApolloDuoPagePictureView(pages[pages.count - 2], state.host.view, ApolloDuoAccountDetailRect(state)) != nil;
}

static BOOL ApolloDuoSidebarBeginBackDrag(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (state.changing || state.coverDrag || [state.kind isEqualToString:@"account"]
        || !ApolloDuoSplitPaneBackHasPicture(navigation)) return NO;
    NSArray<UIViewController *> *pages = navigation.viewControllers;
    CGRect rect = ApolloDuoAccountDetailRect(state);
    UIView *below = ApolloDuoPagePictureView(pages[pages.count - 2], state.host.view, rect);
    __weak ApolloDuoSplitState *weakState = state;
    __weak UINavigationController *weakNavigation = navigation;
    return ApolloDuoSplitBeginCoverDrag(state, rect, below, NO, YES, ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        UINavigationController *pane = weakNavigation;
        if (!current.split || current.changing || pane != current.secondary || ![pane.viewControllers isEqualToArray:pages]) return;
        // Apollo's own pop (not interactive now): it keeps the page as a
        // forward page, as its Back always does.
        [pane popViewControllerAnimated:NO];
        ApolloDuoSetPagePicture(pages.lastObject, leftPicture, current.host.view, rect);
        ApolloLog(@"[DuoSplit] %@ Back completed under the drag", current.kind);
    });
}

// Forward in a sidebar pane: the page Apollo's Back left. Apollo's own
// forward pan begins only at the screen's right edge, which the rail covers
// in the split, and its push would slide the page in under the sidebar, so
// the split owns this forward as it owns the Back.
static UIViewController *ApolloDuoSidebarForwardPage(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (state.changing || [state.kind isEqualToString:@"account"] || !ApolloDuoSplitPaneRunsUnderSidebar(state, navigation))
        return nil;
    return ApolloDuoSplitForwardPage(navigation);
}

static void ApolloDuoSidebarForward(UINavigationController *navigation, UIViewController *page, BOOL animated) {
    // Apollo's push of its own forward page.
    [navigation pushViewController:page animated:animated];
    ApolloLog(@"[DuoSplit] sidebar forward to %@", NSStringFromClass(page.class));
}

static BOOL ApolloDuoSidebarBeginForwardDrag(UINavigationController *navigation) {
    UIViewController *page = ApolloDuoSidebarForwardPage(navigation);
    if (!page) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    NSArray<UIViewController *> *pages = navigation.viewControllers;
    CGRect rect = ApolloDuoAccountDetailRect(state);
    __weak ApolloDuoSplitState *weakState = state;
    __weak UINavigationController *weakNavigation = navigation;
    return ApolloDuoSplitBeginCoverDrag(state, rect, ApolloDuoPagePictureView(page, state.host.view, rect), YES, YES,
                                        ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        UINavigationController *pane = weakNavigation;
        if (!current.split || current.changing || pane != current.secondary || ![pane.viewControllers isEqualToArray:pages]
            || ApolloDuoSplitForwardPage(pane) != page) return;
        ApolloDuoSidebarForward(pane, page, NO);
        ApolloDuoSetPagePicture(pages.lastObject, leftPicture, current.host.view, rect);
        ApolloLog(@"[DuoSplit] %@ forward completed under the drag", current.kind);
    });
}

// A full-width feed page about to leave (a Back button, or Apollo's own
// Back pan as it begins) keeps its picture, for the feed's forward swipe once
// a thread shows beside the feed it returns to.
static void ApolloDuoPostsRememberLeavingFeed(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (!state.split || state.changing || navigation != state.feed || state.host.postsShowingDetail
        || navigation.viewControllers.count < 2) return;
    ApolloDuoRememberPagePicture(navigation.topViewController, state.host.viewIfLoaded, state.host.viewIfLoaded.bounds);
}

// Forward in the feed while a thread shows beside it: the feed page Apollo's
// Back left (a feed link, or any feed popped with the thread open). It opens
// as a feed link does, full width with Back restoring the thread, and slides
// in over the whole split under the finger. Apollo's own forward pan stands
// down here: it would push into the half-width feed.
static UIViewController *ApolloDuoPostsFeedForwardPage(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (!state.split || state.changing || navigation != state.feed || !state.host.postsShowingDetail
        || !ApolloDuoPostsUsesSplit(state)) return nil;
    UIViewController *page = ApolloDuoSplitForwardPage(navigation);
    if (!ApolloDuoIsFeedPage(page) || [page isKindOfClass:ApolloGalleryViewController.class]) return nil;
    NSString *target = ApolloNamedSubredditForPostsController(page);
    NSString *current = ApolloNamedSubredditForPostsController(navigation.topViewController);
    // The feed link route ignores a link to the feed already shown.
    if (target.length && current.length && [target caseInsensitiveCompare:current] == NSOrderedSame) return nil;
    return page;
}

static void ApolloDuoPostsFeedForward(ApolloDuoSplitState *state, UIViewController *page, BOOL animated) {
    if (!ApolloDuoPostsRouteFeedLink(state, state.feed, page, animated)) [state.feed pushViewController:page animated:animated];
    ApolloLog(@"[DuoSplit] feed forward to %@", NSStringFromClass(page.class));
}

static BOOL ApolloDuoPostsBeginFeedForwardDrag(UINavigationController *navigation) {
    UIViewController *page = ApolloDuoPostsFeedForwardPage(navigation);
    if (!page) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    UIView *surface = state.host.view;
    NSArray<UIViewController *> *pages = navigation.viewControllers;
    __weak ApolloDuoSplitState *weakState = state;
    return ApolloDuoSplitBeginCoverDrag(state, surface.bounds, ApolloDuoPagePictureView(page, surface, surface.bounds), YES, NO,
                                        ^(UIView *leftPicture) {
        ApolloDuoSplitState *current = weakState;
        if (!current.split || current.changing || ![current.feed.viewControllers isEqualToArray:pages]
            || ApolloDuoSplitForwardPage(current.feed) != page) return;
        ApolloDuoPostsFeedForward(current, page, NO);
        // The route kept a picture taken under the cover; keep the real one.
        ApolloDuoSetPagePicture(pages.lastObject, leftPicture, current.host.view, current.host.view.bounds);
        ApolloLog(@"[DuoSplit] feed forward completed under the drag");
    });
}

#pragma mark - Split drag entry points

// The pane drag's Pop route: a Back the split lays out itself, following the
// finger when there is a picture of where it goes. NO: run it on release.
BOOL ApolloDuoSplitBeginBackDrag(UINavigationController *navigation) {
    return ApolloDuoSplitBeginProfileDrag(navigation, NO) || ApolloDuoAccountBeginBackDrag(navigation)
        || ApolloDuoSidebarBeginBackDrag(navigation) || ApolloDuoPostsBeginFeedLinkBackDrag(navigation);
}

// Forward swipes the split owns: back into a visited profile, Account's
// detail pages (whose pushes the split lays out, so Apollo's can't follow),
// Settings and Inbox detail pages, and the feed beside a thread.
BOOL ApolloDuoSplitCanForwardInSplit(UINavigationController *navigation) {
    return ApolloDuoSplitCanForwardToVisitedProfile(navigation) || ApolloDuoAccountCanForward(navigation)
        || ApolloDuoSidebarForwardPage(navigation) != nil || ApolloDuoPostsFeedForwardPage(navigation) != nil;
}

BOOL ApolloDuoSplitBeginForwardDrag(UINavigationController *navigation) {
    return ApolloDuoSplitBeginProfileDrag(navigation, YES) || ApolloDuoAccountBeginForwardDrag(navigation)
        || ApolloDuoSidebarBeginForwardDrag(navigation) || ApolloDuoPostsBeginFeedForwardDrag(navigation);
}

// Without a picture to follow, a completed forward swipe navigates at once.
BOOL ApolloDuoSplitForwardInSplit(UINavigationController *navigation) {
    if (ApolloDuoSplitForwardToVisitedProfile(navigation)) return YES;
    UIViewController *sidebarPage = ApolloDuoSidebarForwardPage(navigation);
    if (sidebarPage) {
        ApolloDuoSidebarForward(navigation, sidebarPage, YES);
        return YES;
    }
    UIViewController *feedPage = ApolloDuoPostsFeedForwardPage(navigation);
    if (feedPage) {
        ApolloDuoPostsFeedForward(ApolloDuoSplitStateForNavigation(navigation, NO), feedPage, YES);
        return YES;
    }
    if (!ApolloDuoAccountCanForward(navigation)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    BOOL splitPage = NO;
    UIViewController *page = ApolloDuoAccountForwardPage(state, &splitPage);
    ApolloDuoAccountForward(state, page, splitPage, YES);
    return YES;
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
    if (state.feed && !state.changing && state.host.listPinned) {
        // Any navigation (a list pick, a shortcut, an opened link) ends the
        // pinned drawer; the paths below place the page in its column.
        state.host.listPinned = NO;
        [state.host setListVisible:NO animated:animated && !UIAccessibilityIsReduceMotionEnabled()];
    }
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
            NSArray *feedBefore = state.feed.viewControllers;
            [state.feed setViewControllers:@[page] animated:animate];
            ApolloDuoSplitForgetForward(state.feed, feedBefore);
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
            NSArray *threadBefore = state.secondary.viewControllers;
            ApolloDuoPostsSetDetail(state, page, animated);
            // A thread is a new page for the whole Posts tab, as a native
            // push onto one stack would be: neither pane keeps a forward page.
            ApolloDuoSplitForgetForward(state.feed, nil);
            ApolloDuoSplitForgetForward(state.secondary, threadBefore);
        } else return NO;
        ApolloDuoPostsSyncColumns(state);
        return YES;
    }
    // A feed pushed mid column change bypasses the routes above; it still
    // replaces what a closed thread was closed from.
    if (state.feed && ApolloClassPostsViewController && [page isKindOfClass:ApolloClassPostsViewController])
        ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventFeedOpened, 0.0);
    NSArray<ApolloDuoPostsGeometry *> *searchGeometry = nil;
    CGRect searchViewport = CGRectZero;
    if ([state.kind isEqualToString:@"search"] && nav == state.outer && !state.split
        && ApolloDuoSplitShouldOpen((id)nav.tabBarController)) {
        if (state.outer.view.window && !UIAccessibilityIsReduceMotionEnabled()
            && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"]) {
            // Capture the live Search hierarchy before its controller moves
            // into the new primary navigation container. Retained search-bar
            // and row views will resize with the incoming page, not snap to
            // the narrow column before that page reaches it.
            UIView *oldSurface = state.outer.view;
            [oldSurface layoutIfNeeded];
            searchGeometry = ApolloDuoPostsCaptureGeometry(oldSurface, oldSurface);
            searchViewport = oldSurface.bounds;
        }
        ApolloDuoSplitOpen(state);
    }
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
            // Apollo's popToRoot override queues the popped pages as forward
            // pages. This reselection is not a Back, so drop them.
            ApolloDuoSplitForgetForward(state.secondary, nil);
        }
        ApolloLog(@"[DuoSplit] current Settings destination reselected; keeping root page");
        return YES;
    }
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"account"]) {
        ApolloDuoAccountSetPages(state, @[state.root, page]);
    } else {
        BOOL searchSubreddit = [state.kind isEqualToString:@"search"]
            && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"];
        // A new Search detail may still be loading when UIKit performs the
        // root replacement. Animate its entire live navigation pane, including
        // chrome, rather than a blank page whose content appears afterward.
        // This mirrors the explicit rightward Back across the split boundary.
        NSArray *before = state.secondary.viewControllers;
        [state.secondary setViewControllers:@[page] animated:NO];
        ApolloDuoSplitForgetForward(state.secondary, before);
        if (searchSubreddit) {
            ApolloDuoSearchUpdateBackItem(state);
            // The host was just installed as the outer navigation root.
            // Layout the outer container first so UIKit attaches and sizes
            // its child before checking visibility or reading the pane.
            UIView *surface = state.host.view;
            [UIView performWithoutAnimation:^{
                [state.outer.view layoutIfNeeded];
                [surface layoutIfNeeded];
                [state.secondary.view layoutIfNeeded];
            }];
            CGRect pane = ApolloDuoPostsDetailPane(state);
            BOOL animate = state.outer.view.window && !UIAccessibilityIsReduceMotionEnabled()
                && !CGRectIsNull(pane) && !CGRectIsEmpty(pane);
            if (animate) {
                CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
                if (searchGeometry.count) {
                    // The primary navigation controller is new, but Search's
                    // content is retained. Give its clipping viewport the old
                    // full-width endpoint so its live children remain visible
                    // throughout their coordinated resize into the sidebar.
                    ApolloDuoPostsGeometry *viewport = [ApolloDuoPostsGeometry new];
                    viewport.view = state.primary.view;
                    viewport.bounds = searchViewport;
                    viewport.surfaceFrame = [surface convertRect:searchViewport fromView:state.outer.view];
                    NSMutableArray *geometry = [searchGeometry mutableCopy];
                    [geometry insertObject:viewport atIndex:0];
                    NSHashTable *retained = [NSHashTable weakObjectsHashTable];
                    for (ApolloDuoPostsGeometry *item in geometry) if (item.view) [retained addObject:item.view];
                    CGFloat expansion = CGRectGetWidth(searchViewport) - CGRectGetWidth(state.primary.view.bounds);
                    // UIKit may create new clipping wrappers around the
                    // retained page. Their leading edges stay fixed, and their
                    // widths follow the new navigation viewport as well.
                    for (UIView *wrapper = state.root.view.superview;
                         wrapper && wrapper != state.primary.view;
                         wrapper = wrapper.superview) {
                        if ([retained containsObject:wrapper]) continue;
                        ApolloDuoPostsGeometry *item = [ApolloDuoPostsGeometry new];
                        item.view = wrapper;
                        item.parent = wrapper.superview;
                        CGRect bounds = wrapper.bounds;
                        bounds.size.width += expansion;
                        item.bounds = bounds;
                        item.position = CGPointMake(wrapper.layer.position.x + expansion * wrapper.layer.anchorPoint.x,
                                                    wrapper.layer.position.y);
                        [geometry addObject:item];
                    }
                    ApolloDuoAnimateRetainedGeometry(geometry, state.primary.view, surface, 0.32, YES, NO);
                }
                if (travel > 0) ApolloDuoSlideView(state.secondary.view, travel, 0, 0.32, nil);
            }
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
    // Apollo can fetch before it pushes the picked feed; the pick itself ends
    // the pinned drawer.
    state.host.listPinned = NO;
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
    BOOL postsTab = [ApolloDuoSplitKind(navigation.viewControllers.firstObject) isEqualToString:@"subreddits"];
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, postsTab);
    // A fold restores the bare list while the split is still closing.
    if (postsTab && navigation == state.outer && (!state.split || state.changing)) {
        BOOL bareList = controller == state.root && navigation.viewControllers.count == 1;
        state.foldedListShownAt = bareList ? CACurrentMediaTime() : 0;
    }
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
}
// Apollo's override empties its forward pages; the feed forgets its closed
// thread with them (a real memory warning, or ApolloForwardSwipeExpiry).
- (void)didReceiveMemoryWarning {
    %orig;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (self == state.feed) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventMemoryWarning, 0.0);
    // The visited profile a Back left is a forward page like Apollo's own.
    if (self == state.feed || self == state.secondary || self == state.outer) ApolloDuoSplitForgetProfileForward(state);
    // So is the Account page the split's own Back left. The kept pictures go
    // too: drags without one navigate on release instead.
    if (self == state.secondary) {
        state.accountForwardPage = nil;
        state.accountForwardStack = nil;
    }
    if (self == state.feed || self == state.secondary || self == state.primary) {
        for (UIViewController *page in ((UINavigationController *)self).viewControllers)
            objc_setAssociatedObject(page, &kApolloDuoPagePicture, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        state.profileBackPicture = nil;
        state.profileForwardPicture = nil;
    }
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
    // One owner for each Back, folded included. Apollo's own pan owns a pop
    // onto a real page of the same pane and follows the finger, as on a
    // regular iPhone; the pane drag owns the rest (thread close, drawer, the
    // pops only the split lays out) and stands down for this one.
    if (back && ApolloDuoHasBackSwipe(nav) && !ApolloDuoPaneBackIsNative(nav)) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (!state.split || state.changing) return %orig(gesture);
    // Apollo's navigation-bar pan drives Back and forward too. A forward the
    // split owns (Settings, Account, the feed beside a thread) is the pane's
    // forward swipe; Apollo's push would land under the sidebar or in the
    // half-width feed.
    Ivar barIvar = class_getInstanceVariable(nav.class, "navigationBarPanGestureRecognizer");
    if (barIvar && object_getIvar(self, barIvar) == gesture && [gesture isKindOfClass:UIPanGestureRecognizer.class]
        && [(UIPanGestureRecognizer *)gesture velocityInView:nil].x < 0 && ApolloDuoSplitCanForwardInSplit(nav)) return NO;
    Ivar rightIvar = class_getInstanceVariable(nav.class, "rightScreenEdgePanGestureRecognizer");
    BOOL forward = rightIvar && object_getIvar(self, rightIvar) == gesture;
    if (!back && !forward) return %orig(gesture);
    // The outer controller now contains a host, not a browsable page. Its
    // recognizers must not compete with the detail controller's native pans.
    // A feed with a closed thread to bring back leaves forward to the pane's
    // forward swipe, so one swipe never both reopens the thread and pushes.
    if ((self != state.secondary && !(self == state.feed && !state.host.postsShowingDetail)) || (back && nav.viewControllers.count < 2) ||
        (forward && (!ApolloDuoSplitForwardPage(self) || ApolloDuoSplitCanRestoreClosedThread(nav)
                     || ApolloDuoSplitCanForwardInSplit(nav)))) return NO;
    UIView *view = nav.view;
    UIEdgeInsets insets = view.safeAreaInsets;
    // Forward also starts under a trailing side rail, between its buttons.
    // A finger there is still over the rail when the pan decides to begin.
    if (forward) insets.right = 0.0;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, insets);
    CGPoint point = [gesture locationInView:view];
    if (!CGRectContainsPoint(pane, point)) return NO;
    sDuoSplitGesture = (__bridge void *)gesture;
    sDuoSplitGestureView = (__bridge void *)view;
    // Apollo checks its edge band against the visible pane: shift by the
    // rail's inset, but never past the screen edge for a start under the rail.
    sDuoSplitGestureOffset = back ? -view.safeAreaInsets.left
        : MIN(view.safeAreaInsets.right, MAX(0.0, CGRectGetMaxX(view.bounds) - 1.0 - point.x));
    BOOL result = %orig(gesture);
    sDuoSplitGesture = NULL;
    sDuoSplitGestureView = NULL;
    sDuoSplitGestureOffset = 0.0;
    return result;
}
- (void)screenEdgePanned:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan && [gesture velocityInView:nil].x > 0) ApolloDuoPostsRememberLeavingFeed(self);
    ApolloDuoSplitRunNativePan(self, gesture, ^{ %orig(gesture); });
}
// Apollo's navigation-bar pan drives the same handler, Back or Forward.
- (void)navigationBarPanned:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan && [gesture velocityInView:nil].x > 0) ApolloDuoPostsRememberLeavingFeed(self);
    ApolloDuoSplitRunNativePan(self, gesture, ^{ %orig(gesture); });
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
    // A sidebar pane's page about to be covered: keep its picture, so a Back
    // onto it can slide it in under the finger (ApolloDuoSidebarBeginBackDrag).
    UINavigationController *pane = (id)self;
    if (!state.changing && pane.topViewController && ApolloDuoSplitPaneRunsUnderSidebar(state, pane))
        ApolloDuoRememberPagePicture(pane.topViewController, state.host.viewIfLoaded, ApolloDuoAccountDetailRect(state));
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
    // A pop Apollo's own interactive Back drives is a plain page pop, never
    // one of the split's own (thread close, Account pages, feed-link Back).
    BOOL native = ApolloDuoSplitNativeBackActive(self);
    if (native) ApolloLog(@"[DuoDrag] native Back pop pages=%lu", (unsigned long)((UINavigationController *)self).viewControllers.count);
    if (!native && state.feed && !state.changing && self == state.secondary && state.secondary.viewControllers.count == 2) {
        UIViewController *page = state.secondary.topViewController;
        ApolloDuoPostsSetDetail(state, nil, animated);
        return page;
    }
    if (!native && state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && self == state.secondary && detail.viewControllers.count > 1) {
        UIViewController *page = detail.topViewController;
        ApolloDuoAccountPop(state, animated);
        return page;
    }
    // Apollo's own Back is about to slide this page off: keep its picture so
    // the split's forward swipe in Account can slide it back in.
    if (native && state.split && self == state.secondary && [state.kind isEqualToString:@"account"])
        ApolloDuoRememberPagePicture(((UINavigationController *)self).topViewController, state.host.viewIfLoaded,
                                     ApolloDuoAccountDetailRect(state));
    ApolloDuoPostsRememberLeavingFeed(self);
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
    // Fold, rotation or hinge: no drag survives a resize.
    if (ApolloDeviceIsDuo()) ApolloDuoCancelPaneDrags();
    if (self != (id)ApolloMainTabBarController() ||
        (self != sDuoSplitKnownTabs && !ApolloDuoRailHasVisibleSideBar() && ApolloDuoCurrentMode() == ApolloDuoModePhone)) {
        %orig(size, coordinator);
        return;
    }
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
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(controller);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedIndex:(NSUInteger)index {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
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
    CGPoint translation = %orig(view);
    if ((__bridge void *)self == sDuoSplitReleaseGesture && (__bridge void *)view == sDuoSplitReleaseView) {
        translation.x *= sDuoSplitReleaseScale;
    }
    return translation;
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
@interface ApolloDuoFeedPage : UIViewController @end
%group ApolloDuoCommentsLayoutHooks
%hook ApolloDuoCommentsPage
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloDuoPageUpdateLayoutControl((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoPageScheduleLayoutControl((UIViewController *)self);
}
- (void)viewWillDisappear:(BOOL)animated {
    if (objc_getAssociatedObject(self, &kApolloDuoPageLayoutKey)
        || ApolloDuoSplitStateForNavigation(((UIViewController *)self).navigationController, NO).feed)
        ApolloDuoPostsStopGeometry(((UIViewController *)self).viewIfLoaded);
    %orig(animated);
}
%end
%end

%group ApolloDuoFeedLayoutHooks
%hook ApolloDuoFeedPage
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloDuoPageUpdateLayoutControl((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoPageScheduleLayoutControl((UIViewController *)self);
}
- (void)viewWillDisappear:(BOOL)animated {
    // Posts-tab feeds keep the host's geometry handling; only a standalone
    // feed stops its own layout animation here.
    if (objc_getAssociatedObject(self, &kApolloDuoPageLayoutKey))
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

// Apollo's SlideGestureBuilder (comment and post swipe actions) creates its
// colored gestureDisplayView with the sliding cell view's superview FRAME and
// inserts it into that same superview, then lays out gestureDisplayIcon from
// the sliding view's frame. That only works while the cell's content view sits
// at x = 0. In the split the comments table spans the whole window and its
// cells place their content view at the pane's offset (e.g. 476pt into a 951pt
// cell), so the color and icon were drawn that far to the right, outside the
// cell: swipes still fired with no visual prompt. Give the display view the
// sliding view's frame, which is where Apollo meant it to be.
static void ApolloDuoSlideFitDisplay(id builder) {
    UIView *display = ApolloObjectIvar(builder, "gestureDisplayView");
    if (![display isKindOfClass:UIView.class]) return;
    // Apollo inserts the display view directly below the sliding view.
    NSArray<UIView *> *siblings = display.superview.subviews;
    NSUInteger index = [siblings indexOfObjectIdenticalTo:display];
    if (index == NSNotFound || index + 1 >= siblings.count) return;
    UIView *sliding = siblings[index + 1];
    // The sliding view moves horizontally; its resting frame starts at 0 and
    // shares the display's height.
    CGRect rest = CGRectMake(0.0, CGRectGetMinY(sliding.frame), CGRectGetWidth(sliding.bounds), CGRectGetHeight(sliding.bounds));
    if (CGRectEqualToRect(display.frame, rest)) return;
    ApolloLog(@"[DuoSplit] Swipe reveal moved from %@ to the cell's %@",
              NSStringFromCGRect(display.frame), NSStringFromCGRect(rest));
    display.frame = rest;
}

@interface ApolloDuoSlideGestureBuilder : NSObject @end
%group ApolloDuoSlideGestureHooks
%hook ApolloDuoSlideGestureBuilder
- (void)slidingViewPannedWithGestureRecognizer:(UIPanGestureRecognizer *)gesture {
    %orig(gesture);
    if (gesture.state == UIGestureRecognizerStateBegan) ApolloDuoSlideFitDisplay(self);
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
    Class feed = NSClassFromString(@"Apollo.PostsViewController");
    if (feed) %init(ApolloDuoFeedLayoutHooks, ApolloDuoFeedPage = feed);
    [NSNotificationCenter.defaultCenter addObserverForName:@"ApolloDuoFeedLayoutDidChange"
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            ApolloDuoRefreshLayoutControls();
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
    // The feed page reloads in place for another account, so its identity
    // alone would let the first account's thread come back (Apollo posts these
    // once its selection is coherent; see ApolloTagFilters.xm).
    for (NSNotificationName name in @[@"com.christianselig.RedditCurrentAccountChanged",
                                      @"com.christianselig.RedditAccountChanged"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
            object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
                ApolloDuoSplitState *state = sDuoPostsClosedThreadState;
                if (state) ApolloDuoPostsReviewClosedThread(state, ApolloDuoClosedThreadEventAccountChanged, 0.0);
                // Account's profile reloads in place for the other account, so
                // the page its Back left would otherwise come back under it.
                UITabBarController *tabs = (id)ApolloMainTabBarController();
                if (![tabs isKindOfClass:UITabBarController.class]) return;
                for (UIViewController *child in tabs.viewControllers) {
                    if (![child isKindOfClass:UINavigationController.class]) continue;
                    ApolloDuoSplitState *tab = ApolloDuoSplitStateForNavigation((id)child, NO);
                    tab.accountForwardPage = nil;
                    tab.accountForwardStack = nil;
                }
            }];
    }
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
    Class slideGesture = NSClassFromString(@"Apollo.SlideGestureBuilder");
    if (slideGesture) %init(ApolloDuoSlideGestureHooks, ApolloDuoSlideGestureBuilder = slideGesture);
    %init;
}
