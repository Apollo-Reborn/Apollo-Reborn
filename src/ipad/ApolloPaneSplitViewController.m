// ApolloPaneSplitViewController.m — see ApolloPaneSplitViewController.h

#import "ApolloPaneSplitViewController.h"
#import "ApolloPaneForwardHistory.h"
#import "ApolloPaneRouting.h"
#import "ApolloPaneGeometry.h"
#import "ApolloPaneDiagnostics.h"
#import "ApolloPaneChrome.h"
#import "ApolloPaneFocus.h"
#import "ApolloPaneSidebar.h"
#import "ApolloPaneTransitionObserver.h"
#import "ApolloPaneGeometryPolicy.h"
#import "ApolloPaneColumnHostViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import "../ApolloCommon.h"        // ApolloLog
#import "../ApolloThemeRuntime.h"  // ApolloThemeAccentColor

extern void ApolloSwiftAssignInteractiveTransition(void *storage, const void *object);
static BOOL ApolloPaneSetNativeInteractiveTransition(UINavigationController *nav,
                                                      UIPercentDrivenInteractiveTransition *transition) {
    Class native = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (nav.class != native) return NO;
    Ivar slot = class_getInstanceVariable(native, "interactionController");
    Ivar previous = class_getInstanceVariable(native, "poppedViewControllers");
    if (!slot || !previous || ivar_getOffset(slot) - ivar_getOffset(previous) != sizeof(void *)) return NO;
    ApolloSwiftAssignInteractiveTransition((uint8_t *)(__bridge void *)nav + ivar_getOffset(slot),
                                           (__bridge const void *)transition);
    return YES;
}

extern void *ApolloSwiftListAdapterIndexPathForModelIdentifier(
    const void *mappingStorage, const void *tokenObject);

#pragma mark - Primary context identity

// A utility controller temporarily pushed above a feed does not change what a
// detail selection belongs to. Walk backward to the newest feed-shaped owner;
// tabs without feeds use their stable index/root controller as the context.
static UIViewController *ApolloPanePrimaryContextController(NSArray<UIViewController *> *stack) {
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class litePostsClass = objc_getClass("_TtC6Apollo23LitePostsViewController");
    for (UIViewController *controller in stack.reverseObjectEnumerator) {
        if ((postsClass && [controller isKindOfClass:postsClass]) ||
            (litePostsClass && [controller isKindOfClass:litePostsClass])) {
            return controller;
        }
    }
    return stack.firstObject;
}

static BOOL ApolloPaneStacksIdentityEqual(NSArray<UIViewController *> *left,
                                          NSArray<UIViewController *> *right) {
    if (left.count != right.count) return NO;
    for (NSUInteger index = 0; index < left.count; index++) {
        if (left[index] != right[index]) return NO;
    }
    return YES;
}

static BOOL ApolloPaneStackIsStrictIdentityPrefix(NSArray<UIViewController *> *candidate,
                                                   NSArray<UIViewController *> *fullStack) {
    if (candidate.count >= fullStack.count) return NO;
    for (NSUInteger index = 0; index < candidate.count; index++) {
        if (candidate[index] != fullStack[index]) return NO;
    }
    return YES;
}

static BOOL ApolloPaneStackStartsWithIdentityStack(NSArray<UIViewController *> *stack,
                                                    NSArray<UIViewController *> *prefix) {
    if (stack.count < prefix.count) return NO;
    for (NSUInteger index = 0; index < prefix.count; index++) {
        if (stack[index] != prefix[index]) return NO;
    }
    return YES;
}

static BOOL ApolloPaneControllerIsAttached(UIViewController *controller);

// The native semantic feed value owns identity. A localized/title/count change
// cannot invalidate a selected thread. Keep strings process-local and unlogged.
extern void *ApolloSwiftPanePostsScope(const void *storage);
static NSString *ApolloPanePrimaryContextScope(UIViewController *controller) {
    Class posts = objc_getClass("_TtC6Apollo19PostsViewController");
    if (controller.class != posts) return nil;
    Ivar current = class_getInstanceVariable(posts, "currentPostsType");
    Ivar following = class_getInstanceVariable(posts, "links");
    if (!current || !following || ivar_getOffset(following) - ivar_getOffset(current) != 40) return nil;
    const void *storage = (const uint8_t *)(__bridge const void *)controller + ivar_getOffset(current);
    void *scope = ApolloSwiftPanePostsScope(storage);
    return scope ? CFBridgingRelease(scope) : nil;
}

#pragma mark - Detail placeholder

// Shown in the detail column when nothing is selected. Deliberately plain: the
// point is to read as "this pane is waiting", not to decorate. Themed through
// the theme runtime so it matches whatever palette is active, with system
// fallbacks for the stock (no custom theme) case.
@interface ApolloPaneDetailPlaceholderViewController : UIViewController
- (instancetype)initWithMessage:(NSString *)message symbolName:(NSString *)symbolName;
#if APOLLO_SIM_BUILD
- (UIColor *)apollo_simIconTintColor;
#endif
@end

@implementation ApolloPaneDetailPlaceholderViewController {
    UIImageView *_iconView;
    UILabel *_label;
    NSString *_message;
    NSString *_symbolName;
}

- (instancetype)initWithMessage:(NSString *)message symbolName:(NSString *)symbolName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _message = [message copy];
        _symbolName = [symbolName copy];
    }
    return self;
}

- (instancetype)initWithNibName:(NSString *)nib bundle:(NSBundle *)bundle {
    self = [super initWithNibName:nib bundle:bundle];
    if (self) {
        _message = @"Select a post";
        _symbolName = @"text.bubble";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:_symbolName ?: @"text.bubble"]];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconView.heightAnchor constraintEqualToConstant:44.0].active = YES;

    _label = [[UILabel alloc] init];
    _label.text = _message ?: @"Select a post";
    _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _label.adjustsFontForContentSizeCategory = YES;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.numberOfLines = 0;

    [stack addArrangedSubview:_iconView];
    [stack addArrangedSubview:_label];
    UILabel *hint = [UILabel new];
    hint.text = @"Choose an item in the list to open it here.";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    hint.adjustsFontForContentSizeCategory = YES;
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:hint];
    [self.view addSubview:stack];

    // Center on the safe area, not on the view. Under iOS 26 the split
    // controller floats the sidebar as a glass panel OVER a full-width
    // secondary column, so `view.centerXAnchor` is the window's centre and
    // lands the text half-underneath the sidebar. The safe area is the part of
    // the detail column the sidebar is not covering.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24.0],
    ]];

    [self apollo_applyTheme];
}

// Re-resolve on every trait change: the accent is a dynamic provider color, and
// Apollo overrides the window style, so ambient resolution can land on the wrong
// light/dark variant (see CLAUDE.md, "Theme Accent in Tweak-Drawn UI").
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self apollo_applyTheme];
}

- (void)apollo_applyTheme {
    // The empty detail column takes Apollo's own page background, so it matches
    // the list column beside it under every theme.
    //
    // This was briefly changed to clearColor on the strength of a bad
    // measurement: a pixel sampled at (1100,800) in an open comment thread read
    // #000000, which was taken as "Apollo's pages are black and the helper
    // disagrees". That sample landed on a COMMENT CELL, not the page. Sampling
    // the list column's actual page area under a themed palette gives #191926,
    // and clearColor left the detail column black beside it.
    UIColor *page = ApolloThemePageBackgroundColor();
    self.view.backgroundColor = page ?: UIColor.clearColor;
    static BOOL loggedPage = NO;
    if (!loggedPage) {
        loggedPage = YES;
        UIColor *resolved = [page resolvedColorWithTraitCollection:self.traitCollection];
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [resolved getRed:&r green:&g blue:&b alpha:&a];
        ApolloLog(@"[PanePlaceholder] page background #%02X%02X%02X (alpha %.2f)",
                  (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255), a);
    }
    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor;
    _iconView.tintColor = [accent colorWithAlphaComponent:0.45];
    _label.textColor = UIColor.secondaryLabelColor;
}

#if APOLLO_SIM_BUILD
- (UIColor *)apollo_simIconTintColor {
    return _iconView.tintColor;
}
#endif

@end

// A column holding nothing but its placeholder is "empty" for every decision
// the split controller makes: which column to collapse onto, whether a stale
// thread needs clearing, and where a content-seeking walk should descend.
static BOOL ApolloPaneStackIsPlaceholderOnly(UINavigationController *nav) {
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.count == 0) return YES;
    if (stack.count > 1) return NO;
    return [stack.firstObject isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]];
}

// Do not make a detached column the origin for an alert, activity controller,
// or other presentation. `isViewLoaded` avoids loading an off-screen column as
// a side effect of merely asking what the user can see.
static BOOL ApolloPaneControllerIsAttached(UIViewController *controller) {
    if (!controller.isViewLoaded) return NO;
    UIView *view = controller.viewIfLoaded;
    return view.window != nil && !view.hidden && view.alpha > 0.01;
}

// ApolloNavigationController uses its own UIPanGestureRecognizers rather than
// UIKit's `interactivePopGestureRecognizer`. Read them through the ObjC runtime
// because this file cannot import a generated private-class header, and because
// MSHookIvar is only legal inside Logos hooks in this project.
static UIGestureRecognizer *ApolloPaneNavigationGesture(UINavigationController *nav,
                                                        const char *ivarName) {
    if (!nav || !ivarName) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(nav.class, ivarName);
        id value = ivar ? object_getIvar(nav, ivar) : nil;
        return [value isKindOfClass:[UIGestureRecognizer class]] ? value : nil;
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneSplit] failed reading navigation gesture %s on %@: %@",
                  ivarName, NSStringFromClass(nav.class), exception);
        return nil;
    }
}

// Apollo keeps transition state in private Swift fields. Validate the runtime
// encoding before reading the one-byte Bool storage so a future app update fails
// open to the public coordinator/gesture checks instead of reading a wider field.
static BOOL ApolloPaneNavigationBoolFlag(UINavigationController *navigationController,
                                         const char *ivarName) {
    if (!navigationController || !ivarName) return NO;
    Ivar ivar = class_getInstanceVariable(navigationController.class, ivarName);
    if (!ivar) return NO;
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding || !(encoding[0] == 'B' || encoding[0] == 'c' || encoding[0] == 'C')) {
        return NO;
    }
    uint8_t value = 0;
    @try {
        uint8_t *bytes = (uint8_t *)(__bridge void *)navigationController;
        memcpy(&value, bytes + ivar_getOffset(ivar), sizeof(value));
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return value != 0;
}

static id ApolloPaneNavigationObjectIvar(UINavigationController *navigationController,
                                         const char *ivarName) {
    if (!navigationController || !ivarName) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(navigationController.class, ivarName);
        const char *encoding = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        return encoding && encoding[0] == '@'
            ? object_getIvar(navigationController, ivar) : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL ApolloPaneGestureIsTransitioning(UIGestureRecognizer *gesture) {
    return gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateChanged;
}

#pragma mark - Pane split controller

@interface ApolloPaneMasterSelectionIntent : NSObject
@property (nonatomic, weak) UIViewController *sourceViewController;
@property (nonatomic, weak) id surface;
@property (nonatomic, weak) id identityOwner;
@property (nonatomic, copy) NSIndexPath *indexPath;
@property (nonatomic, copy, nullable) id itemIdentifier;
@property (nonatomic, copy, nullable) NSString *cellFingerprint;
@property (nonatomic) BOOL textureBacked;
@end

@implementation ApolloPaneMasterSelectionIntent
@end

// A selector is a process-stable associated-object key shared with the
// UITableViewCell reuse hook in ApolloPaneRouter.xm. The marker is set only when
// this tweak had to add the Selected trait itself, so cleanup never removes a
// trait supplied by Apollo or UIKit.
static const void *ApolloPaneMasterSelectionAXMarkerKey(void) {
    return NSSelectorFromString(@"apollo_masterSelectionAddedAXSelectedTrait");
}

static UITableView *ApolloPaneMasterSelectionTable(id surface) {
    if ([surface isKindOfClass:[UITableView class]]) return (UITableView *)surface;
    if (![surface respondsToSelector:@selector(view)]) return nil;
    id view = ((id (*)(id, SEL))objc_msgSend)(surface, @selector(view));
    return [view isKindOfClass:[UITableView class]] ? view : nil;
}

static id ApolloPaneMasterSelectionNode(id surface, NSIndexPath *indexPath) {
    if (!surface || [surface isKindOfClass:[UITableView class]] || !indexPath ||
        ![surface respondsToSelector:NSSelectorFromString(@"nodeForRowAtIndexPath:")]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        surface, NSSelectorFromString(@"nodeForRowAtIndexPath:"), indexPath);
}

static id ApolloPaneMasterSelectionObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
        return ivar ? object_getIvar(object, ivar) : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static const void *ApolloPaneMasterSelectionSwiftIvarStorage(id object,
                                                             const char *name) {
    if (!object || !name) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(object_getClass(object));
    if (offset <= 0 || (size_t)offset + sizeof(void *) > instanceSize) return NULL;
    return (const uint8_t *)(__bridge const void *)object + offset;
}

static id ApolloPaneMasterSelectionIdentifierAtPath(id surface, NSIndexPath *indexPath) {
    id node = ApolloPaneMasterSelectionNode(surface, indexPath);
    if (!node) return nil;
    id model = ApolloPaneMasterSelectionObjectIvar(node, "link") ?:
        ApolloPaneMasterSelectionObjectIvar(node, "message");
    if (!model) return nil;
    for (NSString *selectorName in @[ @"fullName", @"identifier", @"diffIdentifier" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![model respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
        if ([value conformsToProtocol:@protocol(NSCopying)]) return value;
    }
    return nil;
}

static BOOL ApolloPaneMasterSelectionPathIsInBounds(UITableView *tableView,
                                                     NSIndexPath *indexPath) {
    if (!tableView || !indexPath || indexPath.section < 0 || indexPath.row < 0 ||
        indexPath.section >= [tableView numberOfSections]) return NO;
    return indexPath.row < [tableView numberOfRowsInSection:indexPath.section];
}

static NSString *ApolloPaneMasterSelectionCellFingerprint(UITableView *tableView,
                                                           NSIndexPath *indexPath) {
    if (!ApolloPaneMasterSelectionPathIsInBounds(tableView, indexPath)) return nil;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return nil;
    // This stays in memory and is never logged. It is validation for static
    // Settings/Inbox matrices, not a user-data diagnostic or a global identity.
    return [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@\x1f%@",
        NSStringFromClass(cell.class), cell.reuseIdentifier ?: @"",
        cell.accessibilityIdentifier ?: @"", cell.textLabel.text ?: @"",
        cell.detailTextLabel.text ?: @""];
}

static void ApolloPaneMasterSelectionSetAccessibilitySelected(UITableViewCell *cell,
                                                               BOOL selected) {
    if (!cell) return;
    const void *key = ApolloPaneMasterSelectionAXMarkerKey();
    BOOL addedByPane = [objc_getAssociatedObject(cell, key) boolValue];
    if (selected) {
        if (!(cell.accessibilityTraits & UIAccessibilityTraitSelected)) {
            cell.accessibilityTraits |= UIAccessibilityTraitSelected;
            objc_setAssociatedObject(cell, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (addedByPane) {
        cell.accessibilityTraits &= ~UIAccessibilityTraitSelected;
        objc_setAssociatedObject(cell, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Shared divider width

static const CGFloat kApolloPaneMinimumPrimaryWidth = 340.0;
static const CGFloat kApolloPaneMaximumPrimaryWidth = 480.0;
static const CGFloat kApolloPaneDefaultPrimaryWidthFraction = 0.42;
static NSString *const kApolloPanePrimaryWidthsDefaultsKey =
    @"ApolloRebornIPadPanePrimaryWidthsByScene";
static char kApolloPaneScenePreferredWidthKey;

@class ApolloPaneDividerControl;

@interface ApolloPaneSplitViewController () <UISplitViewControllerDelegate, UIGestureRecognizerDelegate> {
    BOOL _apollo_loggedResolvedLayout;
    ApolloPaneDividerControl *_apollo_grabber;
    ApolloPaneGeometryScheduler *_apollo_geometryScheduler;
    BOOL _apollo_hasGrabberGeometry;
    BOOL _apollo_lastGrabberHidden;
    CGRect _apollo_lastGrabberFrame;
    BOOL _apollo_navigationGestureObserversInstalled;

    // Compact-mode chrome. UIKit stacks the secondary column's wrapper onto the
    // primary navigation controller when a double-column split collapses. Left
    // alone that exposes TWO bars: the primary bar carrying cross-column Back,
    // then Apollo's real detail bar carrying the title and actions. We hide the
    // empty primary chrome and put an explicit Back affordance on the detail
    // root instead, while retaining UIKit's bridge controller and installing a
    // coordinator-owned edge gesture that cannot leave stale column state.
    BOOL _apollo_compactDetailChromeActive;
    BOOL _apollo_primaryNavBarWasHiddenBeforeCompact;
    BOOL _apollo_detailNavBarWasHiddenBeforeCompact;
    BOOL _apollo_trackingCompactPrimaryPopGesture;
    BOOL _apollo_primaryPopGestureWasEnabled;
    BOOL _apollo_detailPopGestureWasEnabled;
    BOOL _apollo_primaryApolloBackGestureWasEnabled;
    BOOL _apollo_detailApolloBackGestureWasEnabled;
    BOOL _apollo_compactBackUsesRightEdge;
    UIViewController *_apollo_compactPrimaryAnchor;
    UIViewController *_apollo_compactDetailRoot;
    UIBarButtonItem *_apollo_compactBackItem;
    UIPanGestureRecognizer *_apollo_compactBackEdgeGesture;
    UIGestureRecognizer *_apollo_primaryApolloBackGesture;
    UIGestureRecognizer *_apollo_detailApolloBackGesture;
    NSMapTable<UIViewController *, NSNumber *> *_apollo_compactLogicalColumns;
    // iPadOS 26 can truncate an empty-detail pane's primary stack while it
    // collapses. Keep the pre-transition controllers so an inactive tab does
    // not reset merely because the window entered Slide Over.
    NSArray<UIViewController *> *_apollo_preCollapsePrimaryStack;
    NSArray<UIViewController *> *_apollo_compactPrimaryReturnStack;
    NSArray<UIViewController *> *_apollo_postCollapsePrimaryBridgeStack;
    NSArray<UIViewController *> *_apollo_expectedCompactPrimaryRestoreStack;
    NSUInteger _apollo_compactPrimaryRestoreGeneration;
    NSUInteger _apollo_compactPrimaryRestoreLineage;
    NSUInteger _apollo_primaryNavigationMutationGeneration;
    NSUInteger _apollo_compactPrimaryRestoreMutationGeneration;
    NSUInteger _apollo_internalPrimaryStackMutationDepth;
    BOOL _apollo_expectUIKitCompactPrimaryStackReplacement;
    BOOL _apollo_expectOneLateUIKitCompactPrimaryStackReplacement;
    NSUInteger _apollo_lateUIKitCompactPrimaryStableObservations;
    BOOL _apollo_performingCompactShowColumn;
    NSArray<UIViewController *> *_apollo_knownUIKitCompactPrimaryTransientStack;
    NSUInteger _apollo_primaryPopSequence;
    NSUInteger _apollo_pendingPrimaryPopToken;
    BOOL _apollo_pendingPrimaryPopRestoreWasActive;
    BOOL _apollo_expectUIKitExpansionPrimaryMutation;
    BOOL _apollo_pendingPrimaryPopWasExpectedUIKitExpansion;
    BOOL _apollo_pendingPrimaryPopAnimated;
    NSUInteger _apollo_pendingPrimaryPopRestoreGeneration;
    NSUInteger _apollo_pendingPrimaryPopRestoreLineage;
    NSUInteger _apollo_pendingPrimaryPopMutationGeneration;
    NSArray<UIViewController *> *_apollo_pendingPrimaryPopExpectedRestoreStack;
    NSString *_apollo_pendingPrimaryPopOperation;

    // The concrete source must remain in the logical primary stack. The
    // semantic owner is normally the deepest Posts controller (or the tab
    // root), so temporary utility pushes above it do not invalidate detail.
    // Both are weak: a popped/deallocated owner is an immediate mismatch.
    __weak UIViewController *_apollo_detailContextOwner;
    __weak UIViewController *_apollo_detailSemanticOwner;
    NSString *_apollo_detailContextScope;
    BOOL _apollo_contextTrackingReady;
    BOOL _apollo_clearingContext;
    BOOL _apollo_contextReconciliationScheduled;
    NSString *_apollo_pendingContextReconciliationReason;

    // Per-pane latest-intent serialization. Pending work represents semantic
    // navigation, never a pre-resolved physical stack write, so collapse/expand
    // during the wait cannot send a controller to the wrong column.
    dispatch_block_t _apollo_pendingCrossColumnNavigation;
    __weak UIViewController *_apollo_pendingCrossColumnSource;
    __weak UIViewController *_apollo_pendingCrossColumnSemanticOwner;
    BOOL _apollo_pendingCrossColumnHadSource;
    NSString *_apollo_pendingCrossColumnSourceScope;
    NSString *_apollo_pendingCrossColumnReason;
    NSUInteger _apollo_crossColumnIntentSequence;
    NSUInteger _apollo_pendingCrossColumnSequence;
    BOOL _apollo_crossColumnDrainScheduled;
    BOOL _apollo_compactPrimaryRestoreInProgress;
    BOOL _apollo_executingCrossColumnNavigation;
    BOOL _apollo_topologyMutationInProgress;
    NSUInteger _apollo_topologyMutationGeneration;
    BOOL _apollo_compactBackInProgress;
    UIPercentDrivenInteractiveTransition *_apollo_rootInteractiveTransition;
    __weak id<UIViewControllerTransitionCoordinator> _apollo_observedTransitionCoordinator;
    UIBarButtonItem *_apollo_showPrimaryItem;
    __weak UINavigationItem *_apollo_showPrimaryOwner;
    BOOL _apollo_showPrimaryItemOnRight;
    BOOL _apollo_resolvedDisplayRefreshScheduled;
    UISplitViewControllerDisplayMode _apollo_lastSampledDisplayMode;
    UISplitViewControllerSplitBehavior _apollo_lastSampledSplitBehavior;
    BOOL _apollo_lastSampledCollapsed;
    __weak UIViewController *_apollo_lastSampledDetailTop;
    BOOL _apollo_hasSampledResolvedDisplayState;

    // One preferred width belongs to the UIWindowScene, not to a tab. UIKit is
    // still free to resolve a narrower actual column in portrait, Slide Over,
    // or another constrained window; those resolutions never feed back into
    // this value. Only the pane-owned divider, keyboard commands, or its
    // accessibility-adjustable actions publish a new intentional preference.
    CGFloat _apollo_dividerPanStartWidth;
    CGFloat _apollo_dividerPanStartPreference;
    CGFloat _apollo_pendingDividerWidth;
    ApolloPaneFrameScheduler *_apollo_dividerFrameScheduler;
    CGFloat _apollo_lastAppliedPreferredPrimaryWidth;

    // Pane-owned master selection. The opaque intent retains only copied
    // identity while its controller and list surface references remain weak.
    // This cannot keep an inactive tab's view hierarchy alive.
    id _apollo_masterSelectionIntent;
    __weak UIViewController *_apollo_masterSelectionDetailRoot;
    NSUInteger _apollo_masterSelectionGeneration;
    BOOL _apollo_mutatingMasterSelection;
    id _apollo_stagedMasterSelectionIntent;
    NSUInteger _apollo_stagedMasterSelectionGeneration;
#if APOLLO_SIM_BUILD
    BOOL _apollo_simCrossColumnNavigationBlocked;
    NSUInteger _apollo_simLayoutPassCount;
    NSUInteger _apollo_simGeometryRefreshCount;
    NSUInteger _apollo_simGeometryWriteCount;
    NSUInteger _apollo_simThemeNotificationCount;
#endif
}
@property (nonatomic, strong) UINavigationController *apollo_primaryNav;   // the list column
@property (nonatomic, strong) UINavigationController *apollo_detailNav;
@property (nonatomic, strong) UIViewController *apollo_detailHost;
@property (nonatomic, copy) NSString *apollo_emptyMessage;
@property (nonatomic, copy) NSString *apollo_emptySymbol;
- (BOOL)apollo_normalizePreinstalledPrimaryStack;
- (void)apollo_setPrimaryViewControllers:(NSArray<UIViewController *> *)viewControllers;
- (void)apollo_scheduleCompactPrimaryRestoreReconciliation:(NSUInteger)generation
                                               observations:(NSUInteger)observations;
- (BOOL)apollo_navigationOrTopologyTransitionIsActive;
- (nullable id<UIViewControllerTransitionCoordinator>)apollo_activeTransitionCoordinator;
- (void)apollo_scheduleCrossColumnNavigationDrain;
- (void)apollo_drainCrossColumnNavigationIfPossible;
- (void)apollo_removeShowPrimaryItem;
- (void)apollo_refreshShowPrimaryItem;
- (void)apollo_scheduleShowPrimaryItemRefresh;
- (void)apollo_clearMasterSelectionForReason:(NSString *)reason;
- (nullable NSIndexPath *)apollo_resolvedMasterSelectionPath:
    (ApolloPaneMasterSelectionIntent *)intent;
- (void)apollo_deselectMasterSelectionIntent:(ApolloPaneMasterSelectionIntent *)intent;
- (void)apollo_installNavigationGestureObservers;
- (void)apollo_removeNavigationGestureObservers;
- (void)apollo_scheduleResolvedGeometryRefresh;
- (void)apollo_applyResolvedGeometry;
- (void)apollo_synchronizePreferredPrimaryWidth;
- (void)apollo_publishPreferredPrimaryWidth:(CGFloat)width persist:(BOOL)persist;
- (void)apollo_applyScenePreferredPrimaryWidth:(CGFloat)width;
- (void)apollo_dividerPanChanged:(UIPanGestureRecognizer *)gesture;
- (void)apollo_nudgePreferredPrimaryWidth:(CGFloat)delta;
- (NSString *)apollo_primaryWidthAccessibilityValue;
@end

@interface ApolloPaneDividerControl : UIControl <UIPointerInteractionDelegate>
- (instancetype)initWithPane:(ApolloPaneSplitViewController *)pane;
- (void)refreshAccessibilityValue;
- (UIColor *)markerColor;
@end

@implementation ApolloPaneDividerControl {
    __weak ApolloPaneSplitViewController *_pane;
    UIView *_pill;
}

- (instancetype)initWithPane:(ApolloPaneSplitViewController *)pane {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    _pane = pane;
    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Column Divider";
    self.accessibilityHint = @"Adjusts the width of the list column";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;

    _pill = [[UIView alloc] initWithFrame:CGRectZero];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.userInteractionEnabled = NO;
    _pill.layer.cornerRadius = 2.5;
    _pill.alpha = 0.55;
    [self addSubview:_pill];
    [NSLayoutConstraint activateConstraints:@[
        [_pill.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_pill.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_pill.widthAnchor constraintEqualToConstant:5.0],
        [_pill.heightAnchor constraintEqualToConstant:44.0],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:pane action:@selector(apollo_dividerPanChanged:)];
    pan.cancelsTouchesInView = NO;
    pan.delegate = pane;
    [self addGestureRecognizer:pan];

    if (@available(iOS 13.4, *)) {
        [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
    }
    [self refreshAccessibilityValue];
    return self;
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    // The control itself must remain transparent so its 44pt hit target does
    // not look like a bar. Existing pane theming writes the accent here; route
    // that color to the centred 5pt visual marker instead.
    if (_pill) {
        _pill.backgroundColor = backgroundColor;
        [super setBackgroundColor:UIColor.clearColor];
    } else {
        [super setBackgroundColor:backgroundColor];
    }
}

- (void)refreshAccessibilityValue {
    self.accessibilityValue = [_pane apollo_primaryWidthAccessibilityValue];
}

- (UIColor *)markerColor {
    return _pill.backgroundColor;
}

- (void)accessibilityIncrement {
    [_pane apollo_nudgePreferredPrimaryWidth:20.0];
}

- (void)accessibilityDecrement {
    [_pane apollo_nudgePreferredPrimaryWidth:-20.0];
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction
                         styleForRegion:(UIPointerRegion *)region API_AVAILABLE(ios(13.4)) {
    UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:_pill];
    return [UIPointerStyle styleWithEffect:[UIPointerHighlightEffect effectWithPreview:preview]
                                     shape:nil];
}

@end

static CGFloat ApolloPaneUsableWidth(UISplitViewController *pane) {
    UIView *view = pane.viewIfLoaded;
    CGFloat width = CGRectGetWidth(view.bounds);
    if (@available(iOS 26.0, *)) {
        UILayoutGuide *guide = pane.tabBarController.contentLayoutGuide;
        if (guide.owningView.window && view.window) {
            CGRect available = [guide.owningView convertRect:guide.layoutFrame toView:view];
            CGRect intersection = CGRectIntersection(view.bounds, available);
            if (!CGRectIsNull(intersection) && CGRectGetWidth(intersection) > 0.0)
                return CGRectGetWidth(intersection);
        }
    }
    return MAX(0.0, width - view.safeAreaInsets.left - view.safeAreaInsets.right);
}

static CGFloat ApolloPaneClampedPreferredPrimaryWidth(CGFloat width) {
    return ApolloPanePreferredWidth(width);
}

static NSString *ApolloPaneWidthPersistenceSceneKey(UIWindowScene *scene) {
    NSString *identifier = scene.session.persistentIdentifier;
    return identifier.length > 0 ? identifier : nil;
}

static NSNumber *ApolloPanePersistedPrimaryWidth(UIWindowScene *scene) {
    NSString *sceneKey = ApolloPaneWidthPersistenceSceneKey(scene);
    if (!sceneKey) return nil;
    NSDictionary *widths = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kApolloPanePrimaryWidthsDefaultsKey];
    NSNumber *width = [widths[sceneKey] isKindOfClass:[NSNumber class]] ? widths[sceneKey] : nil;
    CGFloat value = width.doubleValue;
    return value >= kApolloPaneMinimumPrimaryWidth &&
        value <= kApolloPaneMaximumPrimaryWidth ? @(value) : nil;
}

static void ApolloPanePersistPrimaryWidth(CGFloat width, UIWindowScene *scene) {
    NSString *sceneKey = ApolloPaneWidthPersistenceSceneKey(scene);
    if (!sceneKey) return;
    NSMutableDictionary *widths = [[NSUserDefaults.standardUserDefaults
        dictionaryForKey:kApolloPanePrimaryWidthsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableSet *openSessions = [NSMutableSet set];
    for (UISceneSession *session in UIApplication.sharedApplication.openSessions)
        [openSessions addObject:session.persistentIdentifier];
    for (NSString *key in widths.allKeys)
        if (![openSessions containsObject:key]) [widths removeObjectForKey:key];
    widths[sceneKey] = @(ApolloPaneClampedPreferredPrimaryWidth(width));
    [NSUserDefaults.standardUserDefaults setObject:widths
                                            forKey:kApolloPanePrimaryWidthsDefaultsKey];
}

@implementation ApolloPaneSplitViewController

- (void)apollo_sceneBecameInactive {
    [_apollo_geometryScheduler cancel];
    [_apollo_dividerFrameScheduler cancel];
    [ApolloPaneTransitionObserver cancelOwner:self];
    ApolloPaneTraceCancel(self);
    [_apollo_rootInteractiveTransition cancelInteractiveTransition];
    _apollo_observedTransitionCoordinator = nil;
}
- (void)apollo_sceneBecameActive {
    if (_apollo_topologyMutationInProgress)
        [self apollo_releaseOrphanedTopologyGateAfterCollapsePolicy:_apollo_topologyMutationGeneration nilObservations:0];
    [self apollo_synchronizePreferredPrimaryWidth];
    [self apollo_scheduleResolvedGeometryRefresh];
    [self apollo_navigationTransitionDidSettle];
}
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // The bounded observer owns temporary closures only. Live navigation and
    // native media/drafts belong to Apollo and are deliberately not evicted.
    if (!self.viewIfLoaded.window) [self apollo_sceneBecameInactive];
}
- (void)apollo_sceneDidDisconnect {
    ApolloPaneRestoreFocusPolicy(self);
    ApolloPaneTraceCancel(self);
    [_apollo_geometryScheduler cancel];
    [ApolloPaneTransitionObserver cancelOwner:self];
    [_apollo_rootInteractiveTransition cancelInteractiveTransition];
    _apollo_rootInteractiveTransition = nil;
    ApolloPaneSetNativeInteractiveTransition(self.apollo_primaryNav, nil);
    _apollo_pendingCrossColumnNavigation = nil;
    _apollo_pendingCrossColumnSource = nil;
    _apollo_pendingCrossColumnSemanticOwner = nil;
    _apollo_pendingCrossColumnSourceScope = nil;
    _apollo_pendingPrimaryPopToken = 0;
    _apollo_pendingPrimaryPopExpectedRestoreStack = nil;
    _apollo_compactPrimaryRestoreGeneration++;
    _apollo_compactPrimaryRestoreInProgress = NO;
    _apollo_topologyMutationGeneration++;
    _apollo_topologyMutationInProgress = NO;
    [_apollo_dividerFrameScheduler cancel];
    _apollo_stagedMasterSelectionGeneration++;
    _apollo_stagedMasterSelectionIntent = nil;
    _apollo_observedTransitionCoordinator = nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Construction runs for all five tab children during the atomic install,
    // but UIKit should materialize only the selected tab. Keep every operation
    // that touches a view or view-owned gesture here so merely wrapping an
    // offscreen navigation stack does not pre-load its entire pane hierarchy.
    [self apollo_installNavigationGestureObservers];
    [self apollo_applyGroundTheme];
    [self apollo_installColumnGrabber];
    ApolloPaneInstallFocus(self);
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(apollo_activeThemeChanged:)
                                               name:@"com.christianselig.ApolloSpecificThemeChanged"
                                             object:nil];
    [self apollo_resolvedDisplayStateMayHaveChanged];
    ApolloLog(@"[PaneLoad] tab %ld loaded pane hierarchy primaryLoaded=%d detailLoaded=%d",
              (long)self.apollo_tabIndex, self.apollo_primaryNav.isViewLoaded,
              self.apollo_detailNav.isViewLoaded);
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (id)apollo_masterSelectionIntentFromSource:(UIViewController *)sourceViewController
                                      surface:(id)surface
                                    indexPath:(NSIndexPath *)indexPath
                               itemIdentifier:(id<NSCopying>)itemIdentifier
                                identityOwner:(id)identityOwner {
    NSAssert(NSThread.isMainThread, @"Pane master selection is main-thread UI state");
    if (!sourceViewController || !surface || ![indexPath isKindOfClass:[NSIndexPath class]]) {
        return nil;
    }
    UITableView *tableView = ApolloPaneMasterSelectionTable(surface);
    if (!ApolloPaneMasterSelectionPathIsInBounds(tableView, indexPath)) return nil;

    BOOL textureBacked = ![surface isKindOfClass:[UITableView class]];
    id resolvedIdentifier = itemIdentifier;
    if (!resolvedIdentifier && textureBacked) {
        resolvedIdentifier = ApolloPaneMasterSelectionIdentifierAtPath(surface, indexPath);
    }
    // A shifting Texture feed must never be tracked by index path alone. If a
    // future node/model shape is unknown, fail closed instead of highlighting a
    // different post or message after a diff update.
    if (textureBacked && !resolvedIdentifier) {
        ApolloLog(@"[PaneSelection] tab %ld ignored Texture selection without stable identity source=%@",
                  (long)self.apollo_tabIndex, NSStringFromClass(sourceViewController.class));
        return nil;
    }

    ApolloPaneMasterSelectionIntent *intent = [ApolloPaneMasterSelectionIntent new];
    intent.sourceViewController = sourceViewController;
    intent.surface = surface;
    intent.identityOwner = identityOwner;
    intent.indexPath = [indexPath copy];
    intent.itemIdentifier = [resolvedIdentifier copyWithZone:nil];
    intent.textureBacked = textureBacked;
    if (!textureBacked) {
        intent.cellFingerprint = ApolloPaneMasterSelectionCellFingerprint(tableView, indexPath);
    }
    return intent;
}

- (void)apollo_stageMasterSelectionIntent:(id)opaqueIntent {
    ApolloPaneMasterSelectionIntent *intent =
        [opaqueIntent isKindOfClass:[ApolloPaneMasterSelectionIntent class]]
            ? opaqueIntent : nil;
    _apollo_stagedMasterSelectionIntent = intent;
    NSUInteger generation = ++_apollo_stagedMasterSelectionGeneration;
    if (!intent) return;
    // Texture's ListAdapter may hand the selected SectionController work to a
    // later main-queue turn. Keep exactly the newest tap briefly, one-shot; a
    // toggle/modal row that never performs a pane route simply expires without
    // changing the currently committed selection.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_apollo_stagedMasterSelectionGeneration == generation) {
            self->_apollo_stagedMasterSelectionIntent = nil;
        }
    });
}

- (id)apollo_claimStagedMasterSelectionIntentForSource:
    (UIViewController *)sourceViewController {
    ApolloPaneMasterSelectionIntent *intent = _apollo_stagedMasterSelectionIntent;
    if (!intent || intent.sourceViewController != sourceViewController) return nil;
    _apollo_stagedMasterSelectionIntent = nil;
    ++_apollo_stagedMasterSelectionGeneration;
    return intent;
}

- (NSIndexPath *)apollo_resolvedMasterSelectionPath:(ApolloPaneMasterSelectionIntent *)intent {
    UITableView *tableView = ApolloPaneMasterSelectionTable(intent.surface);
    if (!tableView || !intent.indexPath) return nil;
    if (intent.itemIdentifier && intent.identityOwner) {
        const void *mappingStorage = ApolloPaneMasterSelectionSwiftIvarStorage(
            intent.identityOwner, "objectToIndexPathMapping");
        void *pathObject = mappingStorage
            ? ApolloSwiftListAdapterIndexPathForModelIdentifier(
                mappingStorage, (__bridge const void *)intent.itemIdentifier)
            : NULL;
        NSIndexPath *mappedPath = pathObject ? CFBridgingRelease(pathObject) : nil;
        if (ApolloPaneMasterSelectionPathIsInBounds(tableView, mappedPath)) {
            intent.indexPath = [mappedPath copy];
            return intent.indexPath;
        }
        return nil;
    }
    if (intent.itemIdentifier) {
        id cachedIdentifier = ApolloPaneMasterSelectionIdentifierAtPath(
            intent.surface, intent.indexPath);
        if ([cachedIdentifier isEqual:intent.itemIdentifier]) return intent.indexPath;

        // Never instantiate offscreen Texture nodes to find an identity. Search
        // only the nodes already materialized by the list and defer painting if
        // the selected item is currently outside that window.
        for (NSIndexPath *visiblePath in tableView.indexPathsForVisibleRows ?: @[]) {
            id visibleIdentifier = ApolloPaneMasterSelectionIdentifierAtPath(
                intent.surface, visiblePath);
            if ([visibleIdentifier isEqual:intent.itemIdentifier]) {
                intent.indexPath = [visiblePath copy];
                return intent.indexPath;
            }
        }
        return nil;
    }

    if (!ApolloPaneMasterSelectionPathIsInBounds(tableView, intent.indexPath)) return nil;
    NSString *currentFingerprint = ApolloPaneMasterSelectionCellFingerprint(
        tableView, intent.indexPath);
    if (intent.cellFingerprint && currentFingerprint &&
        ![intent.cellFingerprint isEqualToString:currentFingerprint]) return nil;
    return intent.indexPath;
}

- (void)apollo_deselectMasterSelectionIntent:(ApolloPaneMasterSelectionIntent *)intent {
    if (!intent) return;
    UITableView *tableView = ApolloPaneMasterSelectionTable(intent.surface);
    NSIndexPath *path = intent.indexPath;
    if (!tableView || !path) return;
    _apollo_mutatingMasterSelection = YES;
    @try {
        if ([tableView.indexPathsForSelectedRows containsObject:path]) {
            [tableView deselectRowAtIndexPath:path animated:NO];
        }
        ApolloPaneMasterSelectionSetAccessibilitySelected(
            [tableView cellForRowAtIndexPath:path], NO);
    } @finally {
        _apollo_mutatingMasterSelection = NO;
    }
}

- (void)apollo_clearMasterSelectionForReason:(NSString *)reason {
    ApolloPaneMasterSelectionIntent *oldIntent = _apollo_masterSelectionIntent;
    if (!oldIntent) return;
    _apollo_masterSelectionIntent = nil;
    _apollo_masterSelectionDetailRoot = nil;
    ++_apollo_masterSelectionGeneration;
    [self apollo_deselectMasterSelectionIntent:oldIntent];
    ApolloLog(@"[PaneSelection] tab %ld cleared master selection reason=%@",
              (long)self.apollo_tabIndex, reason ?: @"detail invalidated");
}

- (void)apollo_refreshMasterSelection {
    ApolloPaneMasterSelectionIntent *intent = _apollo_masterSelectionIntent;
    if (!intent) return;
    UIViewController *source = intent.sourceViewController;
    id surface = intent.surface;
    NSArray<UIViewController *> *logicalPrimary = self.apollo_logicalPrimaryControllers;
    if (!source || !surface || ![logicalPrimary containsObject:source]) {
        [self apollo_clearMasterSelectionForReason:@"source left primary branch"];
        return;
    }

    UITableView *tableView = ApolloPaneMasterSelectionTable(surface);
    if (!tableView) {
        [self apollo_clearMasterSelectionForReason:@"source surface deallocated"];
        return;
    }

    // Compact is deliberately phone-like: preserve logical identity while the
    // list is hidden, but do not expose an invisible Selected element to VoiceOver.
    if (self.isCollapsed) {
        [self apollo_deselectMasterSelectionIntent:intent];
        return;
    }

    UIViewController *detailRoot = _apollo_masterSelectionDetailRoot;
    if (!detailRoot || self.apollo_detailIsEmpty ||
        self.apollo_detailNav.viewControllers.firstObject != detailRoot) {
        [self apollo_clearMasterSelectionForReason:@"detail branch changed"];
        return;
    }

    NSIndexPath *resolvedPath = [self apollo_resolvedMasterSelectionPath:intent];
    if (!resolvedPath) {
        // A dynamic item may simply be offscreen. Remove a stale physical mark
        // but keep its semantic identity so a later appearance/expansion can
        // re-resolve it without scrolling the user's list.
        [self apollo_deselectMasterSelectionIntent:intent];
        return;
    }

    _apollo_mutatingMasterSelection = YES;
    @try {
        for (NSIndexPath *selectedPath in tableView.indexPathsForSelectedRows ?: @[]) {
            if (![selectedPath isEqual:resolvedPath]) {
                ApolloPaneMasterSelectionSetAccessibilitySelected(
                    [tableView cellForRowAtIndexPath:selectedPath], NO);
                [tableView deselectRowAtIndexPath:selectedPath animated:NO];
            }
        }
        [tableView selectRowAtIndexPath:resolvedPath animated:NO
                         scrollPosition:UITableViewScrollPositionNone];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:resolvedPath];
        [cell setSelected:YES animated:NO];
        ApolloPaneMasterSelectionSetAccessibilitySelected(cell, YES);
    } @finally {
        _apollo_mutatingMasterSelection = NO;
    }
}

- (void)apollo_commitMasterSelectionIntent:(id)opaqueIntent
                                detailRoot:(UIViewController *)detailRoot {
    ApolloPaneMasterSelectionIntent *intent =
        [opaqueIntent isKindOfClass:[ApolloPaneMasterSelectionIntent class]]
            ? opaqueIntent : nil;
    [self apollo_clearMasterSelectionForReason:intent
        ? @"detail selection replaced" : @"detail replaced without master selection"];
    if (!intent || !detailRoot) return;

    _apollo_masterSelectionIntent = intent;
    _apollo_masterSelectionDetailRoot = detailRoot;
    NSUInteger generation = ++_apollo_masterSelectionGeneration;
    [self apollo_refreshMasterSelection];

    // Apollo has source-specific delayed deselection paths (notably Chat and
    // Modmail). Reassert only this still-current generation after their queued
    // work settles; the UITableView/ASTableNode hooks below also reject later
    // attempts while the branch remains committed.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_apollo_masterSelectionGeneration == generation) {
            [self apollo_refreshMasterSelection];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_apollo_masterSelectionGeneration == generation) {
            [self apollo_refreshMasterSelection];
        }
    });
    ApolloLog(@"[PaneSelection] tab %ld committed master selection source=%@ texture=%d",
              (long)self.apollo_tabIndex,
              NSStringFromClass(intent.sourceViewController.class), intent.textureBacked);
}

- (BOOL)apollo_shouldRetainMasterSelectionForSurface:(id)surface
                                           indexPath:(NSIndexPath *)indexPath {
    if (_apollo_mutatingMasterSelection || self.isCollapsed ||
        !_apollo_masterSelectionIntent || !surface || !indexPath) return NO;
    ApolloPaneMasterSelectionIntent *intent = _apollo_masterSelectionIntent;
    UITableView *candidateTable = ApolloPaneMasterSelectionTable(surface);
    UITableView *ownedTable = ApolloPaneMasterSelectionTable(intent.surface);
    if (!candidateTable || candidateTable != ownedTable) return NO;
    NSIndexPath *resolved = [self apollo_resolvedMasterSelectionPath:intent];
    return resolved && [resolved isEqual:indexPath] &&
        _apollo_masterSelectionDetailRoot == self.apollo_detailNav.viewControllers.firstObject &&
        !self.apollo_detailIsEmpty;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    ApolloPaneInstallLinkInteractions(self);
    ApolloPaneSidebarFirstAppearance(self.tabBarController);
    ApolloPaneRefreshFocus(self);
    ApolloPaneInstallChromeForController(self.apollo_primaryNav.topViewController);
    ApolloPaneInstallChromeForController(self.apollo_detailNav.topViewController);
    [self apollo_synchronizePreferredPrimaryWidth];
    [self apollo_refreshMasterSelection];
    [self apollo_scheduleResolvedGeometryRefresh];
}

- (void)apollo_setPrimaryViewControllers:(NSArray<UIViewController *> *)viewControllers {
    ++_apollo_internalPrimaryStackMutationDepth;
    @try {
        [self.apollo_primaryNav setViewControllers:viewControllers animated:NO];
    } @finally {
        --_apollo_internalPrimaryStackMutationDepth;
    }
}

- (void)apollo_primaryNavigationStackDidMutateExternally {
    if (_apollo_internalPrimaryStackMutationDepth > 0) return;
    ++_apollo_primaryNavigationMutationGeneration;
    if (!_apollo_compactPrimaryRestoreInProgress) return;

    // The expected stack describes only UIKit's transient showColumn merge.
    // Once Apollo or the user performs a real public stack mutation, that
    // intent owns the branch and every outstanding restore callback is stale.
    ++_apollo_compactPrimaryRestoreGeneration;
    _apollo_compactPrimaryRestoreInProgress = NO;
    _apollo_expectedCompactPrimaryRestoreStack = nil;
    _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
    _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
    _apollo_lateUIKitCompactPrimaryStableObservations = 0;
    _apollo_knownUIKitCompactPrimaryTransientStack = nil;
    _apollo_expectUIKitExpansionPrimaryMutation = NO;
    _apollo_compactPrimaryReturnStack = nil;
    _apollo_postCollapsePrimaryBridgeStack = nil;
    ApolloLog(@"[PaneSplit] tab %ld invalidated compact primary restore after navigation mutation",
              (long)self.apollo_tabIndex);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self apollo_navigationTransitionDidSettle];
    });
}

- (void)apollo_primaryNavigationPushDidMutateExternally:
        (NSArray<UIViewController *> *)viewControllers {
    if (_apollo_internalPrimaryStackMutationDepth > 0) return;
    BOOL matchesInitialExpansionPrefix =
        _apollo_expectUIKitCompactPrimaryStackReplacement &&
        ApolloPaneStackIsStrictIdentityPrefix(
            viewControllers, _apollo_expectedCompactPrimaryRestoreStack);
    BOOL matchesKnownExpansionTransient =
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement &&
        _apollo_knownUIKitCompactPrimaryTransientStack &&
        ApolloPaneStacksIdentityEqual(
            viewControllers, _apollo_knownUIKitCompactPrimaryTransientStack);
    BOOL isAuthorizedExpansionNormalization =
        _apollo_compactPrimaryRestoreInProgress &&
        _apollo_expectUIKitExpansionPrimaryMutation &&
        (matchesInitialExpansionPrefix || matchesKnownExpansionTransient);
    if (isAuthorizedExpansionNormalization) {
        // Apollo implements UIKit's expansion request by "pushing" the root
        // already present in the stack, which normalizes [root, feed] to
        // [root]. This exact expansion-owned prefix is system topology, while
        // every real deeper push is immediate user/app intent and must win even
        // if its own animated transition coordinator is still attached.
        [self apollo_primaryNavigationStackWasReplacedExternally:viewControllers];
        return;
    }
    ApolloLog(@"[PaneRestore] tab %ld rejected primary push depth=%lu expected=%lu "
              @"expansion=%d initialMatch=%d lateMatch=%d top=%@",
              (long)self.apollo_tabIndex, (unsigned long)viewControllers.count,
              (unsigned long)_apollo_expectedCompactPrimaryRestoreStack.count,
              _apollo_expectUIKitExpansionPrimaryMutation,
              matchesInitialExpansionPrefix, matchesKnownExpansionTransient,
              NSStringFromClass(viewControllers.lastObject.class));
    [self apollo_primaryNavigationStackDidMutateExternally];
}

- (void)apollo_primaryNavigationStackWasReplacedExternally:
        (NSArray<UIViewController *> *)viewControllers {
    if (_apollo_internalPrimaryStackMutationDepth > 0) return;
    BOOL hasUIKitTransitionProvenance = _apollo_pendingPrimaryPopToken != 0 ||
        _apollo_performingCompactShowColumn || _apollo_topologyMutationInProgress ||
        self.transitionCoordinator ||
        [self apollo_navigationControllerIsTransitioning:self.apollo_primaryNav];
    if (_apollo_expectUIKitCompactPrimaryStackReplacement &&
        _apollo_compactPrimaryRestoreInProgress &&
        (hasUIKitTransitionProvenance ||
         _apollo_expectUIKitExpansionPrimaryMutation) &&
        ApolloPaneStackIsStrictIdentityPrefix(
            viewControllers, _apollo_expectedCompactPrimaryRestoreStack)) {
        // `showColumn:Primary` or the subsequent expansion performs one public
        // set-stack merge after we arm the restore token. Its final setter can
        // arrive after UIKit has detached every observable coordinator, so the
        // explicitly armed one-shot is itself the provenance. Retain only the
        // exact strict-prefix identity it produced; public pop APIs still carry
        // their own tokens and any different set invalidates the generation.
        _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
        _apollo_expectUIKitExpansionPrimaryMutation = NO;
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = YES;
        _apollo_lateUIKitCompactPrimaryStableObservations = 0;
        _apollo_knownUIKitCompactPrimaryTransientStack = [viewControllers copy];
        ApolloLog(@"[PaneSplit] tab %ld captured UIKit compact primary transient depth %lu",
                  (long)self.apollo_tabIndex, (unsigned long)viewControllers.count);
        return;
    }
    if (_apollo_knownUIKitCompactPrimaryTransientStack &&
        ApolloPaneStacksIdentityEqual(
            viewControllers, _apollo_knownUIKitCompactPrimaryTransientStack) &&
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement) {
        // Repeated writes while UIKit still owns the transition are part of
        // the merge itself; they must not spend the one post-coordinator slot.
        // Only a matching write after every transition signal disappears is
        // the late replacement for which the stabilization lease exists.
        if (hasUIKitTransitionProvenance) {
            _apollo_lateUIKitCompactPrimaryStableObservations = 0;
            return;
        }
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
        _apollo_lateUIKitCompactPrimaryStableObservations = 0;
        return;
    }
    if (_apollo_compactPrimaryRestoreInProgress &&
        _apollo_expectUIKitCompactPrimaryStackReplacement &&
        hasUIKitTransitionProvenance) {
        // UIKit may briefly publish a bridge-shaped stack before the strict
        // prefix we capture. Keep the one system slot armed, but do not let a
        // non-final intermediate shape cancel its own restore lease.
        return;
    }
    if (_apollo_compactPrimaryRestoreInProgress &&
        !ApolloPaneStacksIdentityEqual(
            viewControllers, _apollo_expectedCompactPrimaryRestoreStack)) {
        ApolloLog(@"[PaneRestore] tab %ld rejected primary set depth=%lu expected=%lu "
                  @"provenance=%d expansion=%d initial=%d late=%d strictPrefix=%d top=%@",
                  (long)self.apollo_tabIndex, (unsigned long)viewControllers.count,
                  (unsigned long)_apollo_expectedCompactPrimaryRestoreStack.count,
                  hasUIKitTransitionProvenance,
                  _apollo_expectUIKitExpansionPrimaryMutation,
                  _apollo_expectUIKitCompactPrimaryStackReplacement,
                  _apollo_expectOneLateUIKitCompactPrimaryStackReplacement,
                  ApolloPaneStackIsStrictIdentityPrefix(
                      viewControllers, _apollo_expectedCompactPrimaryRestoreStack),
                  NSStringFromClass(viewControllers.lastObject.class));
        [self apollo_primaryNavigationStackDidMutateExternally];
    }
}

- (NSUInteger)apollo_primaryNavigationPopWillBeginWithOperation:(NSString *)operation
                                                        animated:(BOOL)animated {
    NSUInteger token = ++_apollo_primaryPopSequence;
    _apollo_pendingPrimaryPopToken = token;
    _apollo_pendingPrimaryPopRestoreWasActive = _apollo_compactPrimaryRestoreInProgress;
    _apollo_pendingPrimaryPopWasExpectedUIKitExpansion =
        _apollo_expectUIKitExpansionPrimaryMutation;
    _apollo_pendingPrimaryPopAnimated = animated;
    _apollo_pendingPrimaryPopRestoreGeneration =
        _apollo_compactPrimaryRestoreGeneration;
    _apollo_pendingPrimaryPopRestoreLineage =
        _apollo_compactPrimaryRestoreLineage;
    _apollo_pendingPrimaryPopMutationGeneration =
        _apollo_compactPrimaryRestoreMutationGeneration;
    _apollo_pendingPrimaryPopExpectedRestoreStack =
        [_apollo_expectedCompactPrimaryRestoreStack copy];
    _apollo_pendingPrimaryPopOperation = [operation copy];
    return token;
}

- (void)apollo_primaryNavigationPopDidSettle:(NSUInteger)token
                                 beforeStack:(NSArray<UIViewController *> *)beforeStack
                                    cancelled:(BOOL)cancelled {
    if (token == 0 || token != _apollo_pendingPrimaryPopToken) return;
    BOOL restoreWasActiveAtStart = _apollo_pendingPrimaryPopRestoreWasActive;
    BOOL wasExpectedUIKitExpansion =
        _apollo_pendingPrimaryPopWasExpectedUIKitExpansion;
    BOOL popWasAnimated = _apollo_pendingPrimaryPopAnimated;
    NSUInteger popRestoreGeneration = _apollo_pendingPrimaryPopRestoreGeneration;
    NSUInteger popRestoreLineage = _apollo_pendingPrimaryPopRestoreLineage;
    NSUInteger popMutationGeneration =
        _apollo_pendingPrimaryPopMutationGeneration;
    NSArray<UIViewController *> *popExpectedRestoreStack =
        _apollo_pendingPrimaryPopExpectedRestoreStack;
    NSString *popOperation = _apollo_pendingPrimaryPopOperation ?: @"unknown";
    _apollo_pendingPrimaryPopToken = 0;
    _apollo_pendingPrimaryPopRestoreWasActive = NO;
    _apollo_pendingPrimaryPopWasExpectedUIKitExpansion = NO;
    _apollo_pendingPrimaryPopAnimated = NO;
    _apollo_pendingPrimaryPopRestoreGeneration = 0;
    _apollo_pendingPrimaryPopRestoreLineage = 0;
    _apollo_pendingPrimaryPopMutationGeneration = 0;
    _apollo_pendingPrimaryPopExpectedRestoreStack = nil;
    _apollo_pendingPrimaryPopOperation = nil;
    BOOL committed = !cancelled && !ApolloPaneStacksIdentityEqual(
        beforeStack, self.apollo_primaryNav.viewControllers);
    NSArray<UIViewController *> *settled = self.apollo_primaryNav.viewControllers;
    BOOL matchesInitialExpansionPrefix =
        _apollo_expectUIKitCompactPrimaryStackReplacement &&
        ApolloPaneStackIsStrictIdentityPrefix(
            settled, _apollo_expectedCompactPrimaryRestoreStack);
    BOOL matchesKnownExpansionTransient =
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement &&
        _apollo_knownUIKitCompactPrimaryTransientStack &&
        ApolloPaneStacksIdentityEqual(
            settled, _apollo_knownUIKitCompactPrimaryTransientStack);
    UIUserInterfaceSizeClass horizontalSizeClass =
        self.traitCollection.horizontalSizeClass;
    BOOL hasConcreteTopologyTrait =
        horizontalSizeClass == UIUserInterfaceSizeClassCompact ||
        horizontalSizeClass == UIUserInterfaceSizeClassRegular;
    BOOL isObservedUIKitTopologyPop = committed && restoreWasActiveAtStart &&
        _apollo_compactPrimaryRestoreInProgress && popWasAnimated &&
        [popOperation isEqualToString:@"popToViewController"] &&
        hasConcreteTopologyTrait &&
        popRestoreLineage != 0 &&
        popRestoreLineage == _apollo_compactPrimaryRestoreLineage &&
        popMutationGeneration == _apollo_compactPrimaryRestoreMutationGeneration &&
        _apollo_primaryNavigationMutationGeneration ==
            _apollo_compactPrimaryRestoreMutationGeneration &&
        ApolloPaneStacksIdentityEqual(
            popExpectedRestoreStack, _apollo_expectedCompactPrimaryRestoreStack) &&
        (matchesInitialExpansionPrefix || matchesKnownExpansionTransient);
    if (isObservedUIKitTopologyPop) {
        // Simulator tracing on iPadOS 26 establishes that UIKit's final merge
        // normalization is Apollo's animated popToViewController:, not the
        // normal Back selector (popViewController:). It may settle immediately
        // before or after the regular trait is installed, so accept either
        // concrete topology trait—but never unspecified—and only with the same
        // restore lineage and authorized identity shape.
        if (matchesInitialExpansionPrefix) {
            _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
            _apollo_knownUIKitCompactPrimaryTransientStack = [settled copy];
        }
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = YES;
        _apollo_lateUIKitCompactPrimaryStableObservations = 0;
        _apollo_expectUIKitExpansionPrimaryMutation = NO;
        ApolloLog(@"[PaneRestore] tab %ld captured UIKit expansion popToViewController depth %lu",
                  (long)self.apollo_tabIndex, (unsigned long)settled.count);
        [self apollo_scheduleCompactPrimaryRestoreReconciliation:
            _apollo_compactPrimaryRestoreGeneration observations:0];
        return;
    }
    if (committed &&
        (restoreWasActiveAtStart || !_apollo_compactPrimaryRestoreInProgress)) {
        ApolloLog(@"[PaneRestore] tab %ld committed primary pop op=%@ animated=%d depth=%lu "
                  @"expected=%lu restoreAtStart=%d restoreNow=%d expansion=%d generation=%lu/%lu",
                  (long)self.apollo_tabIndex, popOperation, popWasAnimated,
                  (unsigned long)settled.count,
                  (unsigned long)_apollo_expectedCompactPrimaryRestoreStack.count,
                  restoreWasActiveAtStart, _apollo_compactPrimaryRestoreInProgress,
                  wasExpectedUIKitExpansion, (unsigned long)popRestoreGeneration,
                  (unsigned long)_apollo_compactPrimaryRestoreGeneration);
        [self apollo_primaryNavigationStackDidMutateExternally];
        return;
    }
    // A cancelled/refused pop leaves the lease valid. A pane-owned compact
    // Back begins before it creates the lease, so its later commit also lands
    // here: the newly armed restore already describes the committed stack.
    if (_apollo_compactPrimaryRestoreInProgress) {
        if (committed && ApolloPaneStackIsStrictIdentityPrefix(
                settled, _apollo_expectedCompactPrimaryRestoreStack)) {
            _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
            _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = YES;
            _apollo_lateUIKitCompactPrimaryStableObservations = 0;
            _apollo_knownUIKitCompactPrimaryTransientStack = [settled copy];
        }
        [self apollo_scheduleCompactPrimaryRestoreReconciliation:
            _apollo_compactPrimaryRestoreGeneration observations:0];
    } else {
        [self apollo_navigationTransitionDidSettle];
    }
}

- (void)apollo_scheduleCompactPrimaryRestoreReconciliation:(NSUInteger)generation
                                               observations:(NSUInteger)observations {
    if (observations >= 120) {
        _apollo_compactPrimaryRestoreInProgress = NO;
        _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
        ApolloLog(@"[PaneTransition] compact restoration timed out; preserving current stacks");
        [self apollo_navigationTransitionDidSettle];
        return;
    }
    __weak ApolloPaneSplitViewController *weakSelf = self;
    NSTimeInterval delay = 0.05;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloPaneSplitViewController *self = weakSelf;
        if (!self) return;
        if (self->_apollo_compactPrimaryRestoreGeneration != generation ||
            !self->_apollo_compactPrimaryRestoreInProgress) return;
        BOOL transitionStillActive = self->_apollo_pendingPrimaryPopToken != 0 ||
            self->_apollo_topologyMutationInProgress ||
            self.apollo_activeTransitionCoordinator ||
            [self apollo_navigationControllerIsTransitioning:self.apollo_primaryNav] ||
            [self apollo_navigationControllerIsTransitioning:self.apollo_detailNav];
        if (transitionStillActive) {
            self->_apollo_lateUIKitCompactPrimaryStableObservations = 0;
            [self apollo_scheduleCompactPrimaryRestoreReconciliation:generation
                                                         observations:observations + 1];
            return;
        }

        // UIKit can publish one final copy of its compact merge after the
        // transition coordinator has already detached. Give that explicitly
        // granted write three stable samples to arrive, then revoke the grant
        // and take one more sample before repairing. The post-revocation turn
        // is important: a genuine app mutation after the grace period must go
        // through the normal invalidation path instead of being mistaken for
        // UIKit's late merge.
        if (self->_apollo_expectUIKitCompactPrimaryStackReplacement ||
            self->_apollo_expectOneLateUIKitCompactPrimaryStackReplacement) {
            if (++self->_apollo_lateUIKitCompactPrimaryStableObservations < 3) {
                [self apollo_scheduleCompactPrimaryRestoreReconciliation:generation
                                                             observations:observations + 1];
                return;
            }
            self->_apollo_expectUIKitCompactPrimaryStackReplacement = NO;
            self->_apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
            self->_apollo_lateUIKitCompactPrimaryStableObservations = 0;
            [self apollo_scheduleCompactPrimaryRestoreReconciliation:generation
                                                         observations:observations + 1];
            return;
        }

        NSArray<UIViewController *> *expected =
            self->_apollo_expectedCompactPrimaryRestoreStack;
        NSArray<UIViewController *> *settled = self.apollo_primaryNav.viewControllers;
        BOOL settledIsExpected = ApolloPaneStacksIdentityEqual(settled, expected);
        BOOL settledIsKnownUIKitTransient =
            self->_apollo_knownUIKitCompactPrimaryTransientStack &&
            ApolloPaneStacksIdentityEqual(
                settled, self->_apollo_knownUIKitCompactPrimaryTransientStack);
        @try {
            if (!transitionStillActive && expected.count > 0 &&
                settledIsKnownUIKitTransient) {
                [self apollo_setPrimaryViewControllers:expected];
                ApolloLog(@"[PaneSplit] tab %ld restored settled primary depth %lu -> %lu",
                          (long)self.apollo_tabIndex, (unsigned long)settled.count,
                          (unsigned long)expected.count);
            } else if (!transitionStillActive && !settledIsExpected) {
                ApolloLog(@"[PaneSplit] tab %ld left newer primary branch intact after restore settle",
                          (long)self.apollo_tabIndex);
            }
        } @catch (NSException *exception) {
            ApolloLog(@"[PaneSplit] tab %ld compact primary restore failed safely: %@",
                      (long)self.apollo_tabIndex, exception);
        } @finally {
            if (self->_apollo_compactPrimaryRestoreGeneration == generation) {
                self->_apollo_compactPrimaryRestoreInProgress = NO;
                self->_apollo_expectedCompactPrimaryRestoreStack = nil;
                self->_apollo_expectUIKitCompactPrimaryStackReplacement = NO;
                self->_apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
                self->_apollo_lateUIKitCompactPrimaryStableObservations = 0;
                self->_apollo_knownUIKitCompactPrimaryTransientStack = nil;
                self->_apollo_expectUIKitExpansionPrimaryMutation = NO;
                self->_apollo_compactPrimaryReturnStack = nil;
                self->_apollo_postCollapsePrimaryBridgeStack = nil;
                [self apollo_navigationTransitionDidSettle];
            }
        }
    });
}

+ (instancetype)paneControllerWithRootNavigationController:(UINavigationController *)rootNavigationController
                                                  tabIndex:(NSInteger)tabIndex {
    if (!rootNavigationController) return nil;

    ApolloPaneSplitViewController *pane =
        [[self alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    pane->_apollo_tabIndex = tabIndex;
    @try {
        [pane apollo_configureWithRootNavigationController:rootNavigationController];
        return pane;
    } @catch (NSException *exception) {
        // A factory failure must not leak owner-map registrations, gesture
        // targets, or containment even when the caller itself later fails to
        // complete its wider transaction.
        @try {
            [pane apollo_prepareForInstallationRollback];
        } @catch (NSException *rollbackException) {
            ApolloLog(@"[PaneSplit] tab %ld factory cleanup also threw: %@",
                      (long)tabIndex, rollbackException);
        }
        @throw;
    }
}

- (void)apollo_prepareForInstallationRollback {
    [self apollo_removeShowPrimaryItem];
    // Invalidate every delayed navigation/topology callback before releasing
    // the staged hierarchy. Any already-enqueued block will observe a changed
    // generation or an empty pending intent and become a no-op.
    _apollo_pendingCrossColumnNavigation = nil;
    _apollo_pendingCrossColumnSource = nil;
    _apollo_pendingCrossColumnSemanticOwner = nil;
    _apollo_pendingCrossColumnReason = nil;
    _apollo_pendingPrimaryPopExpectedRestoreStack = nil;
    _apollo_expectedCompactPrimaryRestoreStack = nil;
    _apollo_compactPrimaryReturnStack = nil;
    _apollo_postCollapsePrimaryBridgeStack = nil;
    ++_apollo_crossColumnIntentSequence;
    ++_apollo_topologyMutationGeneration;
    ++_apollo_compactPrimaryRestoreGeneration;

    [self apollo_removeNavigationGestureObservers];
    NSMutableArray<UINavigationController *> *navigationControllers = [NSMutableArray array];
    if (self.apollo_primaryNav) [navigationControllers addObject:self.apollo_primaryNav];
    if (self.apollo_detailNav) [navigationControllers addObject:self.apollo_detailNav];
    for (UINavigationController *navigationController in navigationControllers) {
        ApolloPaneUnregisterNavigationController(navigationController);
    }

    self.delegate = nil;
    // UISplitViewController owns column containment. Replace both columns with
    // inert controllers before the stock tab bar reclaims the original nav;
    // manually removing child views would bypass UIKit appearance bookkeeping.
    [self setViewController:[UIViewController new]
                  forColumn:UISplitViewControllerColumnPrimary];
    [self setViewController:[UIViewController new]
                  forColumn:UISplitViewControllerColumnSecondary];
    self.apollo_primaryNav = nil;
    self.apollo_detailNav = nil;
    self.apollo_detailHost = nil;
    ApolloLog(@"[PaneSplit] tab %ld detached for failed installation rollback",
              (long)self.apollo_tabIndex);
}

- (BOOL)apollo_validateInstallationWithOriginalNavigationController:
    (UINavigationController *)navigationController
                                                        originalStack:
    (NSArray<UIViewController *> *)originalStack {
    if (!navigationController || self.apollo_primaryNav != navigationController) {
        ApolloLog(@"[PaneSplit] tab %ld install validation failed: primary identity", (long)self.apollo_tabIndex);
        return NO;
    }
    if ([self viewControllerForColumn:UISplitViewControllerColumnPrimary] != navigationController) {
        ApolloLog(@"[PaneSplit] tab %ld install validation failed: primary column", (long)self.apollo_tabIndex);
        return NO;
    }
    if (!self.apollo_detailNav || self.apollo_detailNav == navigationController) {
        ApolloLog(@"[PaneSplit] tab %ld install validation failed: detail navigation", (long)self.apollo_tabIndex);
        return NO;
    }
    ApolloPaneColumnHostViewController *detailHost =
        [self.apollo_detailHost isKindOfClass:[ApolloPaneColumnHostViewController class]]
            ? (ApolloPaneColumnHostViewController *)self.apollo_detailHost : nil;
    BOOL detailContainmentValid = detailHost &&
        detailHost.hostedNavigationController == self.apollo_detailNav &&
        (detailHost.isViewLoaded
            ? self.apollo_detailNav.parentViewController == detailHost
            : self.apollo_detailNav.parentViewController == nil);
    if (!detailHost ||
        [self viewControllerForColumn:UISplitViewControllerColumnSecondary] != detailHost ||
        !detailContainmentValid) {
        ApolloLog(@"[PaneSplit] tab %ld install validation failed: detail containment column=%@ "
                  @"host=%@ hostLoaded=%d storedNav=%@ navParent=%@",
                  (long)self.apollo_tabIndex,
                  [self viewControllerForColumn:UISplitViewControllerColumnSecondary],
                  detailHost, detailHost.isViewLoaded, detailHost.hostedNavigationController,
                  self.apollo_detailNav.parentViewController);
        return NO;
    }
    if (!ApolloPaneNavigationControllerIsRegisteredToSplit(navigationController, self) ||
        !ApolloPaneNavigationControllerIsRegisteredToSplit(self.apollo_detailNav, self)) {
        ApolloLog(@"[PaneSplit] tab %ld install validation failed: owner registration", (long)self.apollo_tabIndex);
        return NO;
    }

    NSMutableArray<UIViewController *> *reconstructed =
        [navigationController.viewControllers mutableCopy] ?: [NSMutableArray array];
    if (!self.apollo_detailIsEmpty) {
        [reconstructed addObjectsFromArray:self.apollo_detailNav.viewControllers];
    }
    BOOL stackMatches = ApolloPaneStacksIdentityEqual(reconstructed, originalStack);
    if (!stackMatches) {
        ApolloLog(@"[PaneSplit] tab %ld install validation failed: stack reconstruction %lu != %lu",
                  (long)self.apollo_tabIndex, (unsigned long)reconstructed.count,
                  (unsigned long)originalStack.count);
    }
    return stackMatches;
}

// WHY EVERY PANE IS TWO COLUMNS.
//
// The app has exactly one persistent navigation surface, and it is not a column
// of these split views — it is the tab bar controller's own sidebar
// (`mode = .tabSidebar`, installed by ApolloPaneInstall). That sidebar is fixed:
// it lists the same destinations no matter which tab is selected, and selecting
// one replaces the content beside it. A per-tab column that changed identity as
// you moved between tabs is exactly the thing that read as janky.
//
// So each tab contributes list + detail and nothing more, giving a stable
// three-region app:
//
//     [ sidebar: destinations ] [ list ] [ detail ]
//        UIKit, never changes    the tab's own stack   comment thread
//
// The tab's navigation controller goes into the LIST column verbatim, which is
// what keeps Apollo's own structure intact: the subreddit list pushes to a feed
// inside that one column, exactly as it does on iPhone. Only genuinely
// detail-shaped screens (a post's comments) leave for the second column.
//
// An earlier revision gave the Home tab a third column for the subreddit list.
// That produced four visible columns next to the sidebar, two competing
// subreddit switchers (the column and Apollo's own "Home v" title menu), and a
// left pane whose contents changed per tab. All three problems are structural,
// not cosmetic, and they go away by letting the sidebar be the only sidebar.
- (void)apollo_configureWithRootNavigationController:(UINavigationController *)rootNav {
    self.apollo_primaryNav = rootNav;

    // The empty state names what THIS tab puts in the detail column. "No Post
    // Selected" beside a settings index or a search field is just wrong, and it
    // was a large part of why those two tabs read as nonsense on iPad.
    NSString *message = @"Select a post";
    NSString *symbol = @"text.bubble";
    NSString *rootClass = NSStringFromClass([rootNav.viewControllers.firstObject class]) ?: @"";
    if ([rootClass hasSuffix:@"SettingsViewController"]) {
        message = @"Choose a setting";
        symbol = @"gearshape";
    } else if ([rootClass hasSuffix:@"InboxListViewController"]) {
        message = @"Choose a conversation";
        symbol = @"envelope";
    } else if ([rootClass hasSuffix:@"SearchViewController"]) {
        message = @"Search Reddit";
        symbol = @"magnifyingglass";
    } else if ([rootClass hasSuffix:@"ProfileViewController"]) {
        // The profile's detail column holds whatever row you picked — a post
        // list, trophies, friends — so it cannot promise a post.
        message = @"Explore your profile";
        symbol = @"person.crop.circle";
    }

    self.apollo_detailNav = [self apollo_makeNavigationControllerWithRoot:
        [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:message symbolName:symbol]];
#if APOLLO_SIM_BUILD
    ApolloPaneInstallSimCheckpoint(@"configure-detail", self.apollo_tabIndex);
#endif
    ApolloPaneRegisterNavigationController(self.apollo_primaryNav, self);
    ApolloPaneRegisterNavigationController(self.apollo_detailNav, self);
    self.apollo_emptyMessage = message;
    self.apollo_emptySymbol = symbol;

    // Apollo handles cold URLs, notification responses, Handoff/Siri, and
    // restoration synchronously inside SceneDelegate's will-connect body. The
    // pane installer deliberately runs after that body, so a cold destination
    // can already be sitting in the original navigation stack by the time this
    // controller is constructed. Apply the same edge-by-edge policy used by
    // the live push router before either navigation controller is attached.
    if (![self apollo_normalizePreinstalledPrimaryStack]) {
        [NSException raise:@"ApolloPaneInstallationException"
                    format:@"tab %ld could not normalize its preinstalled stack",
                           (long)self.apollo_tabIndex];
    }
#if APOLLO_SIM_BUILD
    ApolloPaneInstallSimCheckpoint(@"configure-normalize", self.apollo_tabIndex);
#endif

    _apollo_contextTrackingReady = YES;
    if (!self.apollo_detailIsEmpty && !_apollo_detailContextOwner) {
        [self apollo_recordDetailBranchFromPrimarySource:nil];
    }

    [self setViewController:rootNav forColumn:UISplitViewControllerColumnPrimary];
#if APOLLO_SIM_BUILD
    ApolloPaneInstallSimCheckpoint(@"configure-primary", self.apollo_tabIndex);
#endif
    // The secondary column is the full-width one the sidebar floats over, so it
    // is the one that needs the safe-area host (see ApolloPaneColumnHostViewController).
    // The primary column is already laid out as its own inset panel.
    self.apollo_detailHost =
        [[ApolloPaneColumnHostViewController alloc] initWithNavigationController:self.apollo_detailNav];
    [self setViewController:self.apollo_detailHost forColumn:UISplitViewControllerColumnSecondary];
#if APOLLO_SIM_BUILD
    ApolloPaneInstallSimCheckpoint(@"configure-secondary", self.apollo_tabIndex);
#endif

    // Tile, never overlay: a detail pane that floats over the list re-creates
    // the blown-up-iPhone feel this layout exists to remove.
    self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;

    // Without these the columns end 64pt short of the window, leaving a dead
    // black strip along the bottom of the app.
    //
    // Recovered from UIKit's -[UITabBarController _frameForViewController:]: the
    // tab bar's height is subtracted from a child's frame unless the tab bar is
    // hidden, the child extends under the bottom edge, or — for an OPAQUE tab
    // bar, which Apollo's is — the child sets extendedLayoutIncludesOpaqueBars.
    // Apollo sets that flag on every controller it pushes (its own push body
    // does it, which is why the router mirrors it when re-homing), so its stock
    // screens run full height and nothing reserves the strip.
    //
    // This pane is a UISplitViewController we constructed, so it never inherited
    // the flag and UIKit dutifully reserved room for a tab bar that sidebar mode
    // had already taken off screen. Setting it here matches what every other
    // controller in the app already does. Confirmed against the stock hierarchy:
    // with the pane layout off, Apollo's tab child is the full 1032pt tall.
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;

    // The list column carries the bounds that matter: Apollo's post cells are
    // tuned around iPhone Pro Max width and degrade below ~340pt, so that is the
    // floor rather than UIKit's ~320pt sidebar default.
    //
    // The fraction is taken of the space LEFT OVER after the tab sidebar, not of
    // the screen — the split view is a child of the tab bar controller's content
    // area. On a 13" iPad that is roughly 780pt in portrait and 1115pt in
    // landscape, landing the list near its 340pt floor in portrait and around
    // 470pt in landscape, with the detail column always the larger share.
    self.preferredPrimaryColumnWidthFraction = kApolloPaneDefaultPrimaryWidthFraction;
    self.minimumPrimaryColumnWidth = kApolloPaneMinimumPrimaryWidth;
    self.maximumPrimaryColumnWidth = kApolloPaneMaximumPrimaryWidth;
    if (@available(iOS 26.0, *)) self.minimumSecondaryColumnWidth = 420.0;

    // Apollo installs its own screen-edge pans on every navigation controller
    // (left = interactive pop, right = "go forward", re-pushing from the per-nav
    // poppedViewControllers array — confirmed by RE, see the plan doc §2). Those
    // sit on exactly the edges UIKit would use for primary show/hide, so keep the
    // split gesture off. `isCollapsed == NO` does NOT prove this list is visible:
    // constrained regular widths can resolve to SecondaryOnly. For column-style
    // split views `displayModeButtonItem` is explicitly unsupported. UIKit's
    // automatic column-style item would be installed on the wrapper host's
    // navigation bar, which this layout intentionally hides; the visible inner
    // detail navigation therefore owns one native UIBarButtonItem whose action
    // calls the public showColumn: API.
    self.presentsWithGesture = NO;
    if (@available(iOS 14.5, *)) {
        self.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;
    }

    // Keep the tab's original title/icon on the tab bar item: the tab bar reads
    // the child's tabBarItem, and the child is now this pane rather than the
    // navigation controller Apollo configured.
    // Keep the tab's original title and icon. ORDER AND SOURCE BOTH MATTER.
    //
    // -[UIViewController setTitle:] writes through to the tab bar item, so
    // assigning `title` after `tabBarItem` overwrites the item's label. And the
    // navigation controller's own title is the wrong source for it: on the
    // profile tab Apollo names the controller "Comments" while its tab bar item
    // is the account name, so copying the controller title renamed the profile
    // destination to "Comments" in both the tab bar and the sidebar.
    //
    //   tab 0  navTitle=(null)    itemTitle=Posts
    //   tab 1  navTitle=(null)    itemTitle=Inbox
    //   tab 2  navTitle=Comments  itemTitle=corderjones   <- the one that broke
    //   tab 3  navTitle=(null)    itemTitle=Search
    //   tab 4  navTitle=(null)    itemTitle=Settings
    //
    // The tab bar item is what the user has always seen, so it is the source of
    // truth; the item is assigned last so it wins outright.
    self.title = rootNav.tabBarItem.title ?: rootNav.title;
    self.tabBarItem = rootNav.tabBarItem;

    self.delegate = self;

    ApolloLog(@"[PaneSplit] tab %ld configured listRoot=%@ depth=%lu",
              (long)self.apollo_tabIndex,
              NSStringFromClass([rootNav.viewControllers.firstObject class]),
              (unsigned long)rootNav.viewControllers.count);
}

- (NSArray<UIGestureRecognizer *> *)apollo_navigationGesturesForController:
    (UINavigationController *)navigationController {
    if (!navigationController) return @[];
    NSMutableArray<UIGestureRecognizer *> *gestures = [NSMutableArray array];
    if (navigationController.interactivePopGestureRecognizer) {
        [gestures addObject:navigationController.interactivePopGestureRecognizer];
    }
    static const char *kNavigationGestureNames[] = {
        "leftScreenEdgePanGestureRecognizer",
        "rightScreenEdgePanGestureRecognizer",
    };
    for (size_t index = 0;
         index < sizeof(kNavigationGestureNames) / sizeof(kNavigationGestureNames[0]);
         index++) {
        UIGestureRecognizer *gesture = ApolloPaneNavigationGesture(
            navigationController, kNavigationGestureNames[index]);
        if (gesture && ![gestures containsObject:gesture]) [gestures addObject:gesture];
    }
    return gestures;
}

- (void)apollo_installNavigationGestureObservers {
    if (_apollo_navigationGestureObserversInstalled) return;
    for (UINavigationController *navigationController in
            @[ self.apollo_primaryNav, self.apollo_detailNav ]) {
        for (UIGestureRecognizer *gesture in
                [self apollo_navigationGesturesForController:navigationController]) {
            [gesture addTarget:self action:@selector(apollo_navigationGestureStateChanged:)];
        }
    }
    _apollo_navigationGestureObserversInstalled = YES;
}

- (void)apollo_removeNavigationGestureObservers {
    // Do not inspect a navigation controller's gesture properties during an
    // install rollback unless this pane actually loaded and attached targets;
    // cleanup itself must not defeat offscreen lazy loading.
    if (!_apollo_navigationGestureObserversInstalled) return;
    for (UINavigationController *navigationController in
            @[ self.apollo_primaryNav, self.apollo_detailNav ]) {
        for (UIGestureRecognizer *gesture in
                [self apollo_navigationGesturesForController:navigationController]) {
            [gesture removeTarget:self action:@selector(apollo_navigationGestureStateChanged:)];
        }
    }
    _apollo_navigationGestureObserversInstalled = NO;
}

// Splits a stock stack Apollo constructed before pane installation at its first
// logical detail edge. Once a path reaches detail the shared policy is
// rightward-only, so the entire remaining suffix belongs in the detail column.
//
// This is intentionally done while both navigation controllers are detached.
// Moving already-visible controllers between attached parents during scene
// connection produces transient double-parent warnings and broken appearance
// callbacks on some iPadOS releases.
- (BOOL)apollo_normalizePreinstalledPrimaryStack {
    NSArray<UIViewController *> *originalPrimary = [self.apollo_primaryNav.viewControllers copy];
    if (originalPrimary.count < 2) return YES;

    NSUInteger detailStart = NSNotFound;
    ApolloPaneColumn sourceColumn = ApolloPaneColumnPrimary;
    for (NSUInteger index = 1; index < originalPrimary.count; index++) {
        UIViewController *source = originalPrimary[index - 1];
        UIViewController *destination = originalPrimary[index];
        ApolloPaneColumn destinationColumn =
            ApolloPaneResolveLogicalColumn(source, destination, sourceColumn, NULL);
        if (destinationColumn == ApolloPaneColumnSecondary) {
            detailStart = index;
            break;
        }
        sourceColumn = destinationColumn;
    }

    if (detailStart == NSNotFound || detailStart == 0) return YES;

    NSArray<UIViewController *> *primary =
        [originalPrimary subarrayWithRange:NSMakeRange(0, detailStart)];
    NSArray<UIViewController *> *detail =
        [originalPrimary subarrayWithRange:NSMakeRange(detailStart,
                                                       originalPrimary.count - detailStart)];
    NSArray<UIViewController *> *originalDetail = [self.apollo_detailNav.viewControllers copy];
    NSMutableArray<NSNumber *> *originalOpaqueFlags =
        [NSMutableArray arrayWithCapacity:detail.count];
    for (UIViewController *controller in detail) {
        [originalOpaqueFlags addObject:@(controller.extendedLayoutIncludesOpaqueBars)];
    }

    @try {
        [self apollo_setPrimaryViewControllers:primary];
        for (UIViewController *controller in detail) {
            controller.extendedLayoutIncludesOpaqueBars = YES;
        }
        [self.apollo_detailNav setViewControllers:detail animated:NO];
        _apollo_detailContextOwner = ApolloPanePrimaryContextController(primary);
        _apollo_detailSemanticOwner = _apollo_detailContextOwner;
        _apollo_detailContextScope =
            ApolloPanePrimaryContextScope(_apollo_detailContextOwner);
        ApolloLog(@"[PaneSplit] tab %ld normalized cold stack primaryDepth=%lu detailDepth=%lu "
                  @"detailRoot=%@",
                  (long)self.apollo_tabIndex, (unsigned long)primary.count,
                  (unsigned long)detail.count,
                  NSStringFromClass(detail.firstObject.class));
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneSplit] tab %ld cold-stack normalization threw: %@; restoring stock stack",
                  (long)self.apollo_tabIndex, exception);
        @try {
            [self.apollo_detailNav setViewControllers:originalDetail animated:NO];
            [self apollo_setPrimaryViewControllers:originalPrimary];
            for (NSUInteger index = 0; index < detail.count; index++) {
                detail[index].extendedLayoutIncludesOpaqueBars = originalOpaqueFlags[index].boolValue;
            }
        } @catch (NSException *restoreException) {
            ApolloLog(@"[PaneSplit] tab %ld cold-stack restore also threw: %@",
                      (long)self.apollo_tabIndex, restoreException);
        }
        return NO;
    }
}

// Prefer Apollo's own navigation controller subclass so the detail column
// inherits its nav bar theming, transition animator and key commands rather
// than looking like a foreign UIKit screen bolted on beside Apollo's chrome.
// Falls back to a stock navigation controller if the class ever moves.
- (UINavigationController *)apollo_makeNavigationControllerWithRoot:(UIViewController *)placeholder {
    Class apolloNav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (apolloNav) {
        @try {
            UINavigationController *nav = [[apolloNav alloc] initWithRootViewController:placeholder];
            if ([nav isKindOfClass:[UINavigationController class]]) return nav;
            ApolloLog(@"[PaneSplit] ApolloNavigationController init returned %@; using stock",
                      NSStringFromClass([nav class]));
        } @catch (NSException *exception) {
            ApolloLog(@"[PaneSplit] ApolloNavigationController init threw: %@; using stock", exception);
        }
    } else {
        ApolloLog(@"[PaneSplit] ApolloNavigationController class not found; using stock");
    }
    return [[UINavigationController alloc] initWithRootViewController:placeholder];
}

// One-shot diagnostic: what UIKit actually resolved, versus what we asked for.
// preferredDisplayMode/preferredSplitBehavior are requests, and UIKit overrides
// both when the available width cannot honor them.
// A visible grabber on the column divider.
//
// Deliberately NOT a hit-testable control: UIKit's own separator already owns
// the drag, and putting a view in front of it would break the resize rather than
// advertise it. This is a pure marker — userInteractionEnabled = NO — pinned to
// the divider so touches pass straight through to the real thing.
//
// The divider's own view is private and re-created across layouts, so the
// grabber belongs to the pane root. Its geometry is refreshed from stable
// safe-area/transition callbacks rather than from viewDidLayoutSubviews.
- (void)apollo_installColumnGrabber {
    if (_apollo_grabber) return;

    ApolloPaneDividerControl *grabber =
        [[ApolloPaneDividerControl alloc] initWithPane:self];
    grabber.layer.zPosition = 1000.0;
    grabber.hidden = YES;
    [self.view addSubview:grabber];
    _apollo_grabber = grabber;
    _apollo_lastGrabberHidden = YES;
    [self apollo_applyGrabberTheme];
}

- (void)apollo_applyGrabberTheme {
    UIColor *accent = ApolloThemeAccentColor() ?: _apollo_grabber.tintColor;
    _apollo_grabber.backgroundColor = accent ?: UIColor.separatorColor;
}

static NSArray<UIBarButtonItem *> *ApolloPaneBarItemsByRemovingIdentity(
    NSArray<UIBarButtonItem *> *items, UIBarButtonItem *removedItem) {
    if (!removedItem || items.count == 0) return items ?: @[];
    NSMutableArray<UIBarButtonItem *> *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (UIBarButtonItem *item in items) {
        if (item != removedItem) [kept addObject:item];
    }
    return kept;
}

- (void)apollo_removeShowPrimaryItem {
    UINavigationItem *owner = _apollo_showPrimaryOwner;
    UIBarButtonItem *item = _apollo_showPrimaryItem;
    if (owner && item) {
        NSArray<UIBarButtonItem *> *left = ApolloPaneBarItemsByRemovingIdentity(
            owner.leftBarButtonItems, item);
        NSArray<UIBarButtonItem *> *right = ApolloPaneBarItemsByRemovingIdentity(
            owner.rightBarButtonItems, item);
        if (left.count != owner.leftBarButtonItems.count) {
            owner.leftBarButtonItems = left.count > 0 ? left : nil;
        }
        if (right.count != owner.rightBarButtonItems.count) {
            owner.rightBarButtonItems = right.count > 0 ? right : nil;
        }
    }
    _apollo_showPrimaryOwner = nil;
    _apollo_showPrimaryItemOnRight = NO;
}

- (UIBarButtonItem *)apollo_showPrimaryItem {
    if (_apollo_showPrimaryItem) return _apollo_showPrimaryItem;
    UIImage *image = [UIImage systemImageNamed:@"sidebar.leading"];
    if (!image) image = [UIImage systemImageNamed:@"sidebar.left"];
    if (!image) image = [UIImage systemImageNamed:@"list.bullet"];
    UIBarButtonItem *item = image
        ? [[UIBarButtonItem alloc] initWithImage:image
                                           style:UIBarButtonItemStylePlain
                                          target:self
                                          action:@selector(apollo_showPrimaryItemActivated:)]
        : [[UIBarButtonItem alloc] initWithTitle:@"Show List"
                                           style:UIBarButtonItemStylePlain
                                          target:self
                                          action:@selector(apollo_showPrimaryItemActivated:)];
    item.accessibilityIdentifier = @"ApolloPaneShowPrimary";
    item.accessibilityLabel = @"Show List";
    item.accessibilityHint = @"Shows the list column";
    _apollo_showPrimaryItem = item;
    return item;
}

- (void)apollo_refreshShowPrimaryItem {
    _apollo_resolvedDisplayRefreshScheduled = NO;
    BOOL needsRecovery = self.viewIfLoaded.window && !self.isCollapsed &&
        !ApolloPaneSplitShowsPrimary(self);
    UIViewController *top = self.apollo_detailNav.topViewController;
    if (!needsRecovery || !top) {
        [self apollo_removeShowPrimaryItem];
        if (_apollo_showPrimaryItem) _apollo_showPrimaryItem.enabled = YES;
        return;
    }

    UIBarButtonItem *item = [self apollo_showPrimaryItem];
    UINavigationItem *navigationItem = top.navigationItem;
    // At the detail root there is no native Back item to compete with, so the
    // structural control belongs on the leading edge. A deeper detail screen
    // keeps UIKit's Back policy untouched and receives the item at the trailing
    // edge alongside (never replacing) its own actions.
    BOOL placeOnRight = self.apollo_detailNav.viewControllers.count > 1;
    NSArray<UIBarButtonItem *> *left = navigationItem.leftBarButtonItems ?: @[];
    NSArray<UIBarButtonItem *> *right = navigationItem.rightBarButtonItems ?: @[];
    NSUInteger leftCount = 0, rightCount = 0;
    for (UIBarButtonItem *candidate in left) if (candidate == item) leftCount++;
    for (UIBarButtonItem *candidate in right) if (candidate == item) rightCount++;
    BOOL alreadyCorrect = _apollo_showPrimaryOwner == navigationItem &&
        _apollo_showPrimaryItemOnRight == placeOnRight &&
        (placeOnRight ? (rightCount == 1 && leftCount == 0)
                      : (leftCount == 1 && rightCount == 0));
    if (alreadyCorrect) {
        item.enabled = ![self apollo_navigationOrTopologyTransitionIsActive];
        return;
    }

    [self apollo_removeShowPrimaryItem];
    NSArray<UIBarButtonItem *> *existing = placeOnRight
        ? navigationItem.rightBarButtonItems : navigationItem.leftBarButtonItems;
    NSMutableArray<UIBarButtonItem *> *merged =
        [ApolloPaneBarItemsByRemovingIdentity(existing, item) mutableCopy];
    if (placeOnRight) [merged insertObject:item atIndex:0];
    else [merged addObject:item];
    if (placeOnRight) navigationItem.rightBarButtonItems = merged;
    else navigationItem.leftBarButtonItems = merged;
    _apollo_showPrimaryOwner = navigationItem;
    _apollo_showPrimaryItemOnRight = placeOnRight;
    item.enabled = ![self apollo_navigationOrTopologyTransitionIsActive];
    ApolloLog(@"[PaneDisplay] tab %ld installed Show List owner=%@ side=%@ mode=%ld",
              (long)self.apollo_tabIndex, NSStringFromClass(top.class),
              placeOnRight ? @"right" : @"left", (long)self.displayMode);
}

- (void)apollo_scheduleShowPrimaryItemRefresh {
    if (_apollo_resolvedDisplayRefreshScheduled) return;
    _apollo_resolvedDisplayRefreshScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self apollo_refreshShowPrimaryItem];
    });
}

- (void)apollo_resolvedDisplayStateMayHaveChanged {
    [self apollo_scheduleShowPrimaryItemRefresh];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self apollo_refreshMasterSelection];
    });
    [self apollo_scheduleResolvedGeometryRefresh];
}

- (void)apollo_prepareDetailControllerForDisplay:(UIViewController *)viewController {
    if (!viewController || self.isCollapsed ||
        self.apollo_detailNav.topViewController != viewController) return;

    // goToSettingsTab updates selectedViewController synchronously, but UIKit
    // may defer attaching and sizing that pane until the next run-loop turn.
    // Finish only that already-requested layout now; otherwise a cold settings
    // route sees the navigation controller's stale full-window width and the
    // readable inset cannot be computed until after a visible frame.
    UITabBarController *tabs = self.tabBarController;
    if (tabs.selectedViewController == self) {
        [tabs.view layoutIfNeeded];
        [self.view layoutIfNeeded];
        [self.apollo_detailHost.view layoutIfNeeded];
    }
    [(ApolloPaneColumnHostViewController *)self.apollo_detailHost
        apollo_prepareReadableWidthForTopController];
}

- (void)apollo_showPrimaryItemActivated:(UIBarButtonItem *)sender {
    if (self.isCollapsed || ApolloPaneSplitShowsPrimary(self)) {
        [self apollo_resolvedDisplayStateMayHaveChanged];
        return;
    }
    if ([self apollo_navigationOrTopologyTransitionIsActive]) {
        sender.enabled = NO;
        [self apollo_scheduleShowPrimaryItemRefresh];
        return;
    }

    sender.enabled = NO;
    ApolloLog(@"[PaneDisplay] tab %ld Show List activated mode=%ld behavior=%ld",
              (long)self.apollo_tabIndex, (long)self.displayMode, (long)self.splitBehavior);
    [self showColumn:UISplitViewControllerColumnPrimary];
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    __weak ApolloPaneSplitViewController *weakSelf = self;
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
            completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf apollo_resolvedDisplayStateMayHaveChanged];
                });
            }];
    }
    // UIKit is allowed to perform this transition without publishing a
    // coordinator. The delayed idempotent refresh covers both that path and a
    // coordinator completion that never fires because the action was ignored.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf apollo_resolvedDisplayStateMayHaveChanged];
    });
}

- (void)apollo_revealDetailAfterPrimarySelectionIfNeeded {
    if (self.isCollapsed ||
        self.displayMode != UISplitViewControllerDisplayModeOneOverSecondary) return;
    ApolloLog(@"[PaneDisplay] tab %ld dismissing primary overlay after detail selection",
              (long)self.apollo_tabIndex);
    [self hideColumn:UISplitViewControllerColumnPrimary];
    [self apollo_resolvedDisplayStateMayHaveChanged];
}

- (void)apollo_layoutColumnGrabber {
    UIViewController *list = [self viewControllerForColumn:UISplitViewControllerColumnPrimary];
    UIView *detailView = self.apollo_detailNav.viewIfLoaded;
    BOOL hidden = !_apollo_grabber || !list.isViewLoaded || !list.view.superview ||
        !detailView.superview ||
        !ApolloPaneSplitShowsTiledPrimary(self);
    CGRect resolvedFrame = CGRectZero;
    if (hidden) goto apply;

    CGRect listFrame = [list.view.superview convertRect:list.view.frame toView:self.view];
    CGRect detailFrame = [detailView.superview convertRect:detailView.frame toView:self.view];
    CGRect visibleBounds = self.view.bounds;
    BOOL listIntersects = CGRectIntersectsRect(listFrame, visibleBounds);
    BOOL detailIntersects = CGRectIntersectsRect(detailFrame, visibleBounds);
    BOOL primaryOnLeadingEdge = ApolloPanePrimaryIsPhysicallyLeft(
        self.primaryEdge == UISplitViewControllerPrimaryEdgeLeading,
        self.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
    CGFloat listBoundary = primaryOnLeadingEdge ? CGRectGetMaxX(listFrame) : CGRectGetMinX(listFrame);
    CGFloat detailBoundary = primaryOnLeadingEdge ? CGRectGetMinX(detailFrame) : CGRectGetMaxX(detailFrame);
    if (CGRectIsEmpty(listFrame) || CGRectIsEmpty(detailFrame) ||
        !listIntersects || !detailIntersects || fabs(listBoundary - detailBoundary) > 32.0) {
        hidden = YES;
        goto apply;
    }

    // The visible pill remains 5x44pt, but its real control is 44x64pt so touch,
    // pointer, and Switch Control users do not have to hit a decorative sliver.
    static const CGFloat kWidth = 44.0, kHeight = 64.0;
    resolvedFrame = CGRectMake(listBoundary - kWidth / 2.0,
                               CGRectGetMidY(listFrame) - kHeight / 2.0,
                               kWidth, kHeight);

apply:
    if (_apollo_grabber.hidden != hidden) {
        _apollo_grabber.hidden = hidden;
#if APOLLO_SIM_BUILD
        _apollo_simGeometryWriteCount++;
#endif
    }
    if (!hidden && (!_apollo_hasGrabberGeometry ||
        fabs(_apollo_lastGrabberFrame.origin.x - resolvedFrame.origin.x) > 0.5 ||
        fabs(_apollo_lastGrabberFrame.origin.y - resolvedFrame.origin.y) > 0.5 ||
        fabs(_apollo_lastGrabberFrame.size.width - resolvedFrame.size.width) > 0.5 ||
        fabs(_apollo_lastGrabberFrame.size.height - resolvedFrame.size.height) > 0.5)) {
        if (!CGRectEqualToRect(_apollo_grabber.frame, resolvedFrame)) {
            _apollo_grabber.frame = resolvedFrame;
#if APOLLO_SIM_BUILD
            _apollo_simGeometryWriteCount++;
#endif
        }
    }
    _apollo_hasGrabberGeometry = YES;
    _apollo_lastGrabberHidden = hidden;
    _apollo_lastGrabberFrame = resolvedFrame;
    [_apollo_grabber refreshAccessibilityValue];
}

#pragma mark - Shared divider width

- (void)apollo_applyScenePreferredPrimaryWidth:(CGFloat)width {
    CGFloat clamped = ApolloPaneResolvedWidth(width, ApolloPaneUsableWidth(self));
    if (fabs(_apollo_lastAppliedPreferredPrimaryWidth - clamped) <= 0.5 &&
        fabs(self.preferredPrimaryColumnWidth - clamped) <= 0.5) return;
    _apollo_lastAppliedPreferredPrimaryWidth = clamped;
    // A non-automatic absolute value takes precedence over the configured
    // fraction. minimum/maximum remain requests to UIKit, which may still
    // resolve narrower when the window cannot fit both columns.
    self.preferredPrimaryColumnWidth = clamped;
    [_apollo_grabber refreshAccessibilityValue];
    [self apollo_scheduleResolvedGeometryRefresh];
}

- (void)apollo_synchronizePreferredPrimaryWidth {
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene;
    if (!scene) return;

    NSNumber *sceneWidth = objc_getAssociatedObject(scene, &kApolloPaneScenePreferredWidthKey);
    if (!sceneWidth) {
        sceneWidth = ApolloPanePersistedPrimaryWidth(scene);
        if (!sceneWidth) {
            CGFloat availableWidth = ApolloPaneUsableWidth(self);
            CGFloat defaultWidth = availableWidth > 0.0
                ? availableWidth * kApolloPaneDefaultPrimaryWidthFraction : 420.0;
            sceneWidth = @(ApolloPaneClampedPreferredPrimaryWidth(defaultWidth));
        }
        objc_setAssociatedObject(scene, &kApolloPaneScenePreferredWidthKey, sceneWidth,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[PaneWidth] scene initialized preferred=%.0f persisted=%d",
                  sceneWidth.doubleValue, ApolloPanePersistedPrimaryWidth(scene) != nil);
    }

    [self apollo_applyScenePreferredPrimaryWidth:sceneWidth.doubleValue];
}

- (void)apollo_publishPreferredPrimaryWidth:(CGFloat)width persist:(BOOL)persist {
    CGFloat clamped = ApolloPaneClampedPreferredPrimaryWidth(width);
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene;
    if (scene) {
        objc_setAssociatedObject(scene, &kApolloPaneScenePreferredWidthKey, @(clamped),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (persist) ApolloPanePersistPrimaryWidth(clamped, scene);
    }

    [self apollo_applyScenePreferredPrimaryWidth:clamped];
    if (persist) {
        ApolloLog(@"[PaneWidth] tab %ld committed scene preference %.0f (resolved %.0f)",
                  (long)self.apollo_tabIndex, clamped, self.primaryColumnWidth);
    }
}

- (void)apollo_dividerPanChanged:(UIPanGestureRecognizer *)gesture {
    CGFloat direction = ApolloPanePrimaryIsPhysicallyLeft(
        self.primaryEdge == UISplitViewControllerPrimaryEdgeLeading,
        self.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) ? 1.0 : -1.0;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        ApolloPaneTraceBegin(self, @"divider");
        NSNumber *saved = objc_getAssociatedObject(self.view.window.windowScene, &kApolloPaneScenePreferredWidthKey);
        _apollo_dividerPanStartPreference = saved ? saved.doubleValue : self.preferredPrimaryColumnWidth;
        _apollo_dividerPanStartWidth = ApolloPaneClampedPreferredPrimaryWidth(
            self.primaryColumnWidth > 0.0 ? self.primaryColumnWidth
                                          : self.preferredPrimaryColumnWidth);
    }
    CGFloat translation = [gesture translationInView:self.view].x * direction;
    CGFloat target = ApolloPaneClampedPreferredPrimaryWidth(
        _apollo_dividerPanStartWidth + translation);
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            _apollo_pendingDividerWidth = target;
            if (!_apollo_dividerFrameScheduler) {
                _apollo_dividerFrameScheduler = [[ApolloPaneFrameScheduler alloc] initWithOwner:self
                    update:^(ApolloPaneSplitViewController *pane) {
                        [pane apollo_publishPreferredPrimaryWidth:pane->_apollo_pendingDividerWidth persist:NO];
                    }];
            }
            [_apollo_dividerFrameScheduler request];
            break;
        case UIGestureRecognizerStateEnded:
            [_apollo_dividerFrameScheduler cancel];
            ApolloPaneTraceEnd(self, @"divider");
            [self apollo_publishPreferredPrimaryWidth:target persist:YES];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [_apollo_dividerFrameScheduler cancel];
            ApolloPaneTraceEnd(self, @"divider");
            [self apollo_publishPreferredPrimaryWidth:_apollo_dividerPanStartPreference persist:NO];
            break;
        default:
            break;
    }
}

- (void)apollo_resetPreferredPrimaryWidth {
    CGFloat width = ApolloPaneUsableWidth(self) * kApolloPaneDefaultPrimaryWidthFraction;
    [self apollo_publishPreferredPrimaryWidth:width persist:YES];
}

- (void)apollo_nudgePreferredPrimaryWidth:(CGFloat)delta {
    if (!ApolloPaneSplitShowsTiledPrimary(self)) return;
    NSNumber *saved = objc_getAssociatedObject(self.viewIfLoaded.window.windowScene, &kApolloPaneScenePreferredWidthKey);
    CGFloat current = saved ? saved.doubleValue : self.preferredPrimaryColumnWidth;
    [self apollo_publishPreferredPrimaryWidth:current + delta persist:YES];
    [_apollo_grabber refreshAccessibilityValue];
}

- (NSString *)apollo_primaryWidthAccessibilityValue {
    NSNumber *saved = objc_getAssociatedObject(self.viewIfLoaded.window.windowScene, &kApolloPaneScenePreferredWidthKey);
    CGFloat preferred = saved ? saved.doubleValue : self.preferredPrimaryColumnWidth;
    CGFloat resolved = self.primaryColumnWidth;
    if (preferred <= 0.0 || preferred == UISplitViewControllerAutomaticDimension) return @"Automatic";
    if (resolved > 0.0 && fabs(preferred - resolved) > 1.0) {
        return [NSString stringWithFormat:@"Preferred %.0f points, currently %.0f points",
                                          preferred, resolved];
    }
    return [NSString stringWithFormat:@"%.0f points", preferred];
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray<UIKeyCommand *> *commands = [[super keyCommands] mutableCopy] ?: [NSMutableArray array];
    UIKeyCommand *narrow = [UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow
                                              modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate
                                                     action:@selector(apollo_narrowPrimaryColumn:)];
    narrow.discoverabilityTitle = @"Narrow List Column";
    UIKeyCommand *widen = [UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow
                                             modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate
                                                    action:@selector(apollo_widenPrimaryColumn:)];
    widen.discoverabilityTitle = @"Widen List Column";
    [commands addObjectsFromArray:@[ narrow, widen ]];
    UIKeyCommand *list = [UIKeyCommand keyCommandWithInput:@"1" modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate action:@selector(apollo_focusList:)];
    list.discoverabilityTitle = @"Focus list";
    UIKeyCommand *detail = [UIKeyCommand keyCommandWithInput:@"2" modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate action:@selector(apollo_focusDetail:)];
    detail.discoverabilityTitle = @"Focus detail";
    [commands addObjectsFromArray:@[list, detail]];
    UIViewController *focused = ApolloPaneFocusedController(self);
    if (focused.navigationItem.searchController ||
        [NSStringFromClass(focused.class) hasSuffix:@"CommentsViewController"]) {
        UIKeyCommand *find = [UIKeyCommand keyCommandWithInput:@"f" modifierFlags:UIKeyModifierCommand action:@selector(apollo_findInFocusedPane:)];
        find.discoverabilityTitle = @"Find in focused pane";
        [commands addObject:find];
    }
    return commands;
}

- (BOOL)canBecomeFirstResponder { return YES; }
- (void)apollo_focusList:(id)sender { ApolloPaneFocusColumn(self, NO, YES); }
- (void)apollo_focusDetail:(id)sender { ApolloPaneFocusColumn(self, YES, YES); }
- (void)apollo_findInFocusedPane:(id)sender {
    UIViewController *controller = ApolloPaneFocusedController(self);
    if (ApolloPanePresentCommentsFind(controller)) return;
    UISearchController *search = controller.navigationItem.searchController;
    if (search) {
        search.active = YES;
        [search.searchBar becomeFirstResponder];
    }
}

- (void)apollo_narrowPrimaryColumn:(UIKeyCommand *)command {
    [self apollo_nudgePreferredPrimaryWidth:-20.0];
}

- (void)apollo_widenPrimaryColumn:(UIKeyCommand *)command {
    [self apollo_nudgePreferredPrimaryWidth:20.0];
}

// The ground the floating columns sit on.
//
// On iPhone the tab bar controller's own background is never visible. On iPadOS
// 26 it is: the sidebar floats over it, and it shows in the margins around and
// between the columns. Left alone it is UIKit's black, which is why the app read
// as "not themeable" — Apollo's pages were #191926 under the active palette
// while the ground behind them stayed #000000.
- (void)apollo_applyGroundTheme {
    UIView *view = self.viewIfLoaded;
    if (!view) return;
    view.backgroundColor = ApolloThemePageBackgroundColor() ?: view.backgroundColor;
}

- (void)apollo_activeThemeChanged:(NSNotification *)notification {
    (void)notification;
#if APOLLO_SIM_BUILD
    _apollo_simThemeNotificationCount++;
#endif
    // Apollo's canonical theme notification arrives for both stock-theme
    // selection and custom-theme invalidation. Repaint every surface owned by
    // the pane itself; Apollo continues to repaint the hosted app controllers.
    [self apollo_applyGroundTheme];
    [self apollo_applyGrabberTheme];
    for (UIViewController *controller in self.apollo_detailNav.viewControllers) {
        if ([controller isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]]) {
            [(ApolloPaneDetailPlaceholderViewController *)controller apollo_applyTheme];
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    BOOL beginsExpansion =
        previous.horizontalSizeClass == UIUserInterfaceSizeClassCompact &&
        self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular;
    BOOL ownsPendingCompactPrimaryRestore =
        _apollo_compactPrimaryRestoreInProgress &&
        _apollo_primaryNavigationMutationGeneration ==
            _apollo_compactPrimaryRestoreMutationGeneration;
    if (beginsExpansion && ownsPendingCompactPrimaryRestore) {
        // The primary navigation controller can receive Apollo's
        // push(existing-root) normalization before splitViewControllerDidExpand:
        // is delivered. Arm the expansion-owned mutation slot at the trait
        // boundary—the earliest supported topology signal—so that exact
        // normalization is captured while a genuine deeper push still
        // invalidates through the source-aware push reporter.
        _apollo_expectUIKitExpansionPrimaryMutation = YES;
        _apollo_lateUIKitCompactPrimaryStableObservations = 0;
        if (_apollo_knownUIKitCompactPrimaryTransientStack.count > 0) {
            _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = YES;
        } else {
            _apollo_expectUIKitCompactPrimaryStackReplacement = YES;
        }
        ApolloLog(@"[PaneSplit] tab %ld armed compact primary restore at expansion trait boundary",
                  (long)self.apollo_tabIndex);
    }
    if (self.isViewLoaded) {
        [self apollo_applyGroundTheme];
        [self apollo_applyGrabberTheme];
        [self apollo_scheduleShowPrimaryItemRefresh];
        [self apollo_scheduleResolvedGeometryRefresh];
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self apollo_scheduleResolvedGeometryRefresh];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak ApolloPaneSplitViewController *weakSelf = self;
    [coordinator animateAlongsideTransition:nil
        completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            [weakSelf apollo_scheduleResolvedGeometryRefresh];
        }];
}

#if APOLLO_SIM_BUILD
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _apollo_simLayoutPassCount++;
}
#endif

- (void)apollo_scheduleResolvedGeometryRefresh {
    if (!_apollo_geometryScheduler) {
        _apollo_geometryScheduler = [[ApolloPaneGeometryScheduler alloc] initWithOwner:self update:^(id owner) {
            [owner apollo_applyResolvedGeometry];
        }];
    }
    [_apollo_geometryScheduler requestAfterCoordinator:self.transitionCoordinator];
}

- (void)apollo_applyResolvedGeometry {
#if APOLLO_SIM_BUILD
    _apollo_simGeometryRefreshCount++;
#endif
    [self apollo_synchronizePreferredPrimaryWidth];
    [(ApolloPaneColumnHostViewController *)self.apollo_detailHost
        apollo_scheduleListColumnGeometryRefresh];
    [self apollo_layoutColumnGrabber];

    UIViewController *detailTop = self.apollo_detailNav.topViewController;
    BOOL resolvedStateChanged = !_apollo_hasSampledResolvedDisplayState ||
        _apollo_lastSampledDisplayMode != self.displayMode ||
        _apollo_lastSampledSplitBehavior != self.splitBehavior ||
        _apollo_lastSampledCollapsed != self.isCollapsed ||
        _apollo_lastSampledDetailTop != detailTop;
    if (resolvedStateChanged) {
        _apollo_hasSampledResolvedDisplayState = YES;
        _apollo_lastSampledDisplayMode = self.displayMode;
        _apollo_lastSampledSplitBehavior = self.splitBehavior;
        _apollo_lastSampledCollapsed = self.isCollapsed;
        _apollo_lastSampledDetailTop = detailTop;
        ApolloLog(@"[PaneDisplay] tab %ld resolved mode=%ld behavior=%ld collapsed=%d "
                  @"primaryVisible=%d tiled=%d detailTop=%@",
                  (long)self.apollo_tabIndex, (long)self.displayMode,
                  (long)self.splitBehavior, self.isCollapsed,
                  ApolloPaneSplitShowsPrimary(self), ApolloPaneSplitShowsTiledPrimary(self),
                  NSStringFromClass(detailTop.class));
        // Navigation-item reconciliation remains deferred so this geometry
        // transaction cannot synchronously invalidate navigation layout.
        [self apollo_scheduleShowPrimaryItemRefresh];
    }
    if (_apollo_loggedResolvedLayout) return;
    if (CGRectIsEmpty(self.view.bounds)) return;
    _apollo_loggedResolvedLayout = YES;
    // supplementaryColumnWidth is NOT read here: it THROWS on a double-column
    // split view ("supplementaryColumnWidth properties unsupported for style =
    // DoubleColumn"), and every pane is double-column now.
    // `paneH` vs `hostH` is the tab-bar-reservation check: they must be equal.
    // A short pane means extendedLayoutIncludesOpaqueBars stopped taking effect
    // and the dead bottom strip is back.
    ApolloLog(@"[PaneSplit] tab %ld resolved displayMode=%ld splitBehavior=%ld size=%.0fx%.0f "
              @"hostH=%.0f primaryW=%.0f primaryVisible=%d tiled=%d",
              (long)self.apollo_tabIndex, (long)self.displayMode, (long)self.splitBehavior,
              self.view.bounds.size.width, self.view.bounds.size.height,
              self.tabBarController.view.bounds.size.height, self.primaryColumnWidth,
              ApolloPaneSplitShowsPrimary(self), ApolloPaneSplitShowsTiledPrimary(self));
}

#pragma mark - Column access

- (UINavigationController *)apollo_navigationControllerForColumn:(ApolloPaneColumn)column {
    switch (column) {
        case ApolloPaneColumnPrimary:
        // There is no supplementary column any more — the tab sidebar took that
        // role — so "the list column" and "the primary column" are one and the
        // same. Kept as a distinct case so callers can still say which they mean.
        case ApolloPaneColumnSupplementary:
            return self.apollo_primaryNav;
        case ApolloPaneColumnSecondary:
            return self.apollo_detailNav;
        case ApolloPaneColumnInPlace:
            return nil;
    }
    return nil;
}

- (BOOL)apollo_detailIsEmpty {
    return ApolloPaneStackIsPlaceholderOnly(self.apollo_detailNav);
}

- (UIViewController *)apollo_preferredContentColumnController {
    UINavigationController *primary = self.apollo_primaryNav;
    UINavigationController *detail = self.apollo_detailNav;
    BOOL detailHasContent = !self.apollo_detailIsEmpty;
    BOOL primaryAttached = ApolloPaneControllerIsAttached(primary);
    BOOL detailAttached = ApolloPaneControllerIsAttached(detail);

    if (self.isCollapsed) {
        // A populated secondary can survive collapse through UIKit's bridge.
        // Compact chrome is activated only for that outcome, and its hosted
        // navigation controller remains attached even though the split reports
        // one visible column. Returning primary here used to present alerts and
        // share sheets from the feed hidden behind the comments screen.
        if (_apollo_compactDetailChromeActive && detailHasContent && detailAttached) return detail;

        // Empty compact panes, compact navigations that began after collapse,
        // and the completed cross-column Back path all live on primary.
        if (primaryAttached) return primary;
        if (detailHasContent && detailAttached) return detail;
        return _apollo_compactDetailChromeActive && detailHasContent ? detail : primary;
    }

    switch (self.displayMode) {
        case UISplitViewControllerDisplayModeOneOverSecondary:
            // The list is the foreground overlay even when populated detail
            // remains attached behind its dimming view.
            if (primaryAttached) return primary;
            if (detailAttached) return detail;
            break;
        case UISplitViewControllerDisplayModeSecondaryOnly:
            // The offscreen primary often remains loaded and parented. Present
            // from the sole visible detail/placeholder column.
            if (detailAttached) return detail;
            if (primaryAttached) return primary;
            break;
        case UISplitViewControllerDisplayModeOneBesideSecondary:
        default:
            if (detailHasContent && detailAttached) return detail;
            if (primaryAttached) return primary;
            if (detailAttached) return detail;
            break;
    }
    if (primaryAttached) return primary;
    // Before the hierarchy has attached, preserve the semantic choice without
    // forcing either navigation controller's view to load.
    return detailHasContent ? detail : primary;
}

- (void)apollo_recordCompactViewController:(UIViewController *)viewController
                              logicalColumn:(ApolloPaneColumn)column {
    if (!viewController) return;
    if (!_apollo_compactLogicalColumns) {
        _apollo_compactLogicalColumns = [NSMapTable weakToStrongObjectsMapTable];
    }
    if (column == ApolloPaneColumnSecondary) {
        [_apollo_compactLogicalColumns setObject:@(column) forKey:viewController];
    } else {
        [_apollo_compactLogicalColumns removeObjectForKey:viewController];
    }
}

- (BOOL)apollo_compactViewControllerBelongsToDetail:(UIViewController *)viewController {
    if (!viewController) return NO;
    if ([self.apollo_detailNav.viewControllers containsObject:viewController]) return YES;
    return [[_apollo_compactLogicalColumns objectForKey:viewController] integerValue] ==
        ApolloPaneColumnSecondary;
}

- (BOOL)apollo_isColumnBridgeController:(UIViewController *)controller {
    if (!controller) return NO;
    if (controller == self.apollo_detailHost || controller == self.apollo_detailNav) return YES;
    if (![controller isKindOfClass:UINavigationController.class]) return NO;
    NSArray *stack = ((UINavigationController *)controller).viewControllers;
    return stack.count == 1 && stack.firstObject == self.apollo_detailHost;
}

- (NSArray<UIViewController *> *)apollo_logicalPrimaryControllers {
    NSArray<UIViewController *> *stack = self.apollo_primaryNav.viewControllers;
    NSUInteger detailStart = NSNotFound;
    for (NSUInteger index = 0; index < stack.count; index++) {
        if ([self apollo_isColumnBridgeController:stack[index]] ||
            [self apollo_compactViewControllerBelongsToDetail:stack[index]]) {
            detailStart = index;
            break;
        }
    }
    return detailStart == NSNotFound ? stack :
        [stack subarrayWithRange:NSMakeRange(0, detailStart)];
}

- (UIViewController *)apollo_primaryContextViewController {
    if (_apollo_compactPrimaryRestoreInProgress &&
        _apollo_expectedCompactPrimaryRestoreStack.count > 0) {
        return ApolloPanePrimaryContextController(_apollo_expectedCompactPrimaryRestoreStack);
    }
    return ApolloPanePrimaryContextController(self.apollo_logicalPrimaryControllers);
}

- (BOOL)apollo_hasDetailBranchForContextTracking {
    return !self.apollo_detailIsEmpty ||
        self.apollo_logicalPrimaryControllers.count < self.apollo_primaryNav.viewControllers.count;
}

#pragma mark - Cross-column transition serialization

- (BOOL)apollo_navigationControllerIsTransitioning:(UINavigationController *)navigationController {
    if (!navigationController) return NO;
    if (navigationController.transitionCoordinator) return YES;
    if (ApolloPaneNavigationBoolFlag(navigationController, "pushing") ||
        ApolloPaneNavigationBoolFlag(navigationController, "popping")) return YES;
    if (ApolloPaneNavigationObjectIvar(navigationController, "interactionController")) return YES;
    if (ApolloPaneGestureIsTransitioning(navigationController.interactivePopGestureRecognizer)) return YES;
    if (ApolloPaneGestureIsTransitioning(
            ApolloPaneNavigationGesture(navigationController,
                                        "leftScreenEdgePanGestureRecognizer"))) return YES;
    if (ApolloPaneGestureIsTransitioning(
            ApolloPaneNavigationGesture(navigationController,
                                        "rightScreenEdgePanGestureRecognizer"))) return YES;
    return NO;
}

- (id<UIViewControllerTransitionCoordinator>)apollo_activeTransitionCoordinator {
    id<UIViewControllerTransitionCoordinator> coordinator = self.apollo_primaryNav.transitionCoordinator;
    if (!coordinator) coordinator = self.apollo_detailNav.transitionCoordinator;
    if (!coordinator) coordinator = self.transitionCoordinator;
    return coordinator;
}

- (BOOL)apollo_navigationOrTopologyTransitionIsActive {
#if APOLLO_SIM_BUILD
    if (_apollo_simCrossColumnNavigationBlocked) return YES;
#endif
    return _apollo_executingCrossColumnNavigation || _apollo_compactBackInProgress || _apollo_topologyMutationInProgress ||
        _apollo_compactPrimaryRestoreInProgress || _apollo_pendingPrimaryPopToken != 0 ||
        self.apollo_activeTransitionCoordinator ||
        [self apollo_navigationControllerIsTransitioning:self.apollo_primaryNav] ||
        [self apollo_navigationControllerIsTransitioning:self.apollo_detailNav];
}

- (void)apollo_scheduleCrossColumnNavigationDrain {
    if (_apollo_crossColumnDrainScheduled || !_apollo_pendingCrossColumnNavigation) return;
    _apollo_crossColumnDrainScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_apollo_crossColumnDrainScheduled = NO;
        [self apollo_drainCrossColumnNavigationIfPossible];
    });
}

- (BOOL)apollo_pendingCrossColumnSourceIsStillCurrent {
    UIViewController *source = _apollo_pendingCrossColumnSource;
    // A route whose weak source and semantic owner were both deallocated is
    // stale, not equivalent to a deliberate source-less clear operation.
    if (!source) return !_apollo_pendingCrossColumnHadSource;

    NSArray<UIViewController *> *logicalPrimary = self.apollo_logicalPrimaryControllers;
    if (_apollo_compactPrimaryRestoreInProgress &&
        _apollo_expectedCompactPrimaryRestoreStack.count > 0) {
        UIViewController *anticipatedOwner = ApolloPanePrimaryContextController(
            _apollo_expectedCompactPrimaryRestoreStack);
        if (source == anticipatedOwner &&
            _apollo_pendingCrossColumnSemanticOwner == anticipatedOwner) {
            NSString *capturedScope = _apollo_pendingCrossColumnSourceScope;
            NSString *anticipatedScope = ApolloPanePrimaryContextScope(anticipatedOwner);
            return !capturedScope ||
                (anticipatedScope && [capturedScope isEqualToString:anticipatedScope]);
        }
    }
    if (![logicalPrimary containsObject:source]) return NO;
    if (!self.isCollapsed && !ApolloPaneSplitShowsPrimary(self)) return NO;
    // UIKit may append a private bridge above the captured primary source while
    // collapsing a populated pane. All compact pushes now coalesce through this
    // queue, so a newer user navigation cannot hide above the source unnoticed;
    // preserve the intent when semantic ownership still matches below.
    if (logicalPrimary.lastObject != source && !self.isCollapsed) return NO;
    UIViewController *semanticOwner = ApolloPanePrimaryContextController(logicalPrimary);
    if (!semanticOwner || semanticOwner != _apollo_pendingCrossColumnSemanticOwner) return NO;

    NSString *capturedScope = _apollo_pendingCrossColumnSourceScope;
    NSString *currentScope = ApolloPanePrimaryContextScope(semanticOwner);
    return !capturedScope || (currentScope && [capturedScope isEqualToString:currentScope]);
}

- (void)apollo_observeActiveTransitionForPendingNavigation {
    id<UIViewControllerTransitionCoordinator> coordinator = self.apollo_activeTransitionCoordinator;
    if (!coordinator || coordinator == _apollo_observedTransitionCoordinator) return;
    _apollo_observedTransitionCoordinator = coordinator;
    __weak ApolloPaneSplitViewController *weakSelf = self;
    __weak id<UIViewControllerTransitionCoordinator> weakCoordinator = coordinator;
    BOOL accepted = [coordinator animateAlongsideTransition:nil
        completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            BOOL cancelled = context.isCancelled;
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloPaneSplitViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                if (strongSelf->_apollo_observedTransitionCoordinator == weakCoordinator) {
                    strongSelf->_apollo_observedTransitionCoordinator = nil;
                }
                ApolloLog(@"[PaneTransition] tab %ld coordinator settled cancelled=%d",
                          (long)strongSelf.apollo_tabIndex, cancelled);
                [strongSelf apollo_navigationTransitionDidSettle];
            });
        }];
    if (!accepted && _apollo_observedTransitionCoordinator == coordinator) {
        // Bounded, weak fallback. A held interactive gesture has no deadline:
        // after this watchdog expires its terminal event wakes the queue.
        // Retain the observed coordinator identity to prevent repeated polling.
        [ApolloPaneTransitionObserver observeOwner:self key:@"pendingNavigation" timeout:6.0
            ready:^BOOL(ApolloPaneSplitViewController *pane) {
                return ![pane apollo_navigationOrTopologyTransitionIsActive];
            } completion:^(ApolloPaneSplitViewController *pane, BOOL timedOut) {
                if (timedOut) return;
                pane->_apollo_observedTransitionCoordinator = nil;
                [pane apollo_navigationTransitionDidSettle];
            }];
    }
}

- (void)apollo_performCrossColumnNavigationTransaction:(dispatch_block_t)navigation {
    if (!navigation) return;
    BOOL ownsTransaction = !_apollo_executingCrossColumnNavigation;
    if (ownsTransaction) _apollo_executingCrossColumnNavigation = YES;
    @try {
        navigation();
    } @finally {
        if (ownsTransaction) {
            _apollo_executingCrossColumnNavigation = NO;
            [self apollo_scheduleCrossColumnNavigationDrain];
        }
    }
}

- (void)apollo_drainCrossColumnNavigationIfPossible {
    if (!_apollo_pendingCrossColumnNavigation || _apollo_executingCrossColumnNavigation) return;
    if ([self apollo_navigationOrTopologyTransitionIsActive]) {
        [self apollo_observeActiveTransitionForPendingNavigation];
        return;
    }

    NSUInteger sequence = _apollo_pendingCrossColumnSequence;
    NSString *reason = _apollo_pendingCrossColumnReason ?: @"cross-column navigation";
    if (![self apollo_pendingCrossColumnSourceIsStillCurrent]) {
        ApolloLog(@"[PaneTransition] tab %ld dropped stale intent %lu reason=%@",
                  (long)self.apollo_tabIndex, (unsigned long)sequence, reason);
        _apollo_pendingCrossColumnNavigation = nil;
        _apollo_pendingCrossColumnSource = nil;
        _apollo_pendingCrossColumnSemanticOwner = nil;
        _apollo_pendingCrossColumnHadSource = NO;
        _apollo_pendingCrossColumnSourceScope = nil;
        _apollo_pendingCrossColumnReason = nil;
        return;
    }

    dispatch_block_t navigation = _apollo_pendingCrossColumnNavigation;
    _apollo_pendingCrossColumnNavigation = nil;
    _apollo_pendingCrossColumnSource = nil;
    _apollo_pendingCrossColumnSemanticOwner = nil;
    _apollo_pendingCrossColumnHadSource = NO;
    _apollo_pendingCrossColumnSourceScope = nil;
    _apollo_pendingCrossColumnReason = nil;
    _apollo_executingCrossColumnNavigation = YES;
    ApolloLog(@"[PaneTransition] tab %ld applying settled intent %lu reason=%@",
              (long)self.apollo_tabIndex, (unsigned long)sequence, reason);
    @try {
        navigation();
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneTransition] tab %ld intent %lu threw: %@",
                  (long)self.apollo_tabIndex, (unsigned long)sequence, exception);
    } @finally {
        _apollo_executingCrossColumnNavigation = NO;
    }
    [self apollo_scheduleCrossColumnNavigationDrain];
}

- (BOOL)apollo_deferCrossColumnNavigationIfNeeded:(dispatch_block_t)navigation
                              sourceViewController:(UIViewController *)sourceViewController
                                            reason:(NSString *)reason {
    if (!navigation) return NO;
    if (!NSThread.isMainThread) {
        __weak ApolloPaneSplitViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloPaneSplitViewController *pane = weakSelf;
            if (pane && ![pane apollo_deferCrossColumnNavigationIfNeeded:navigation
                sourceViewController:sourceViewController reason:reason]) {
                [pane apollo_performCrossColumnNavigationTransaction:navigation];
            }
        });
        return YES;
    }

    BOOL alreadyPending = _apollo_pendingCrossColumnNavigation != nil;
    if (!alreadyPending && ![self apollo_navigationOrTopologyTransitionIsActive]) return NO;

    NSUInteger sequence = ++_apollo_crossColumnIntentSequence;
    NSArray<UIViewController *> *logicalPrimary = self.apollo_logicalPrimaryControllers;
    UIViewController *semanticOwner = nil;
    if (sourceViewController) {
        semanticOwner = [logicalPrimary containsObject:sourceViewController]
            ? ApolloPanePrimaryContextController(logicalPrimary)
            : sourceViewController;
    }
    _apollo_pendingCrossColumnNavigation = [navigation copy];
    _apollo_pendingCrossColumnSource = sourceViewController;
    _apollo_pendingCrossColumnSemanticOwner = semanticOwner;
    _apollo_pendingCrossColumnHadSource = sourceViewController != nil;
    _apollo_pendingCrossColumnSourceScope =
        sourceViewController ? ApolloPanePrimaryContextScope(semanticOwner) : nil;
    _apollo_pendingCrossColumnReason = [reason copy] ?: @"cross-column navigation";
    _apollo_pendingCrossColumnSequence = sequence;
    ApolloLog(@"[PaneTransition] tab %ld %@ intent %lu reason=%@",
              (long)self.apollo_tabIndex, alreadyPending ? @"coalesced" : @"deferred",
              (unsigned long)sequence, _apollo_pendingCrossColumnReason);
    [self apollo_observeActiveTransitionForPendingNavigation];
    [self apollo_scheduleCrossColumnNavigationDrain];
    return YES;
}

- (void)apollo_navigationTransitionDidSettle {
    ApolloPaneRefreshFocus(self);
    ApolloPaneRegisterNavigationItems(self.apollo_primaryNav);
    ApolloPaneRegisterNavigationItems(self.apollo_detailNav);
    ApolloPaneInstallChromeForController(self.apollo_primaryNav.topViewController);
    ApolloPaneInstallChromeForController(self.apollo_detailNav.topViewController);
    if (_apollo_compactDetailChromeActive) {
        BOOL nested = self.apollo_detailNav.viewControllers.count > 1;
        self.apollo_detailNav.interactivePopGestureRecognizer.enabled = nested && _apollo_detailPopGestureWasEnabled;
        _apollo_detailApolloBackGesture.enabled = nested && _apollo_detailApolloBackGestureWasEnabled;
    }

    _apollo_observedTransitionCoordinator = nil;
    [self apollo_scheduleShowPrimaryItemRefresh];
    [self apollo_scheduleCrossColumnNavigationDrain];
    [self apollo_refreshMasterSelection];
}

- (void)apollo_navigationGestureStateChanged:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled &&
        gesture.state != UIGestureRecognizerStateFailed) return;
    ApolloLog(@"[PaneTransition] tab %ld navigation gesture terminal state=%ld",
              (long)self.apollo_tabIndex, (long)gesture.state);
    [self apollo_navigationTransitionDidSettle];
}

#if APOLLO_SIM_BUILD
static NSString *ApolloPaneSimColorDescription(UIColor *color, UITraitCollection *traits) {
    UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha]) return @"unresolved";
    return [NSString stringWithFormat:@"#%02X%02X%02X/%02X",
        (unsigned)lrint(red * 255.0), (unsigned)lrint(green * 255.0),
        (unsigned)lrint(blue * 255.0), (unsigned)lrint(alpha * 255.0)];
}

- (NSString *)apollo_simThemeState {
    ApolloPaneDetailPlaceholderViewController *placeholder = nil;
    for (UIViewController *controller in self.apollo_detailNav.viewControllers) {
        if ([controller isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]]) {
            placeholder = (ApolloPaneDetailPlaceholderViewController *)controller;
            break;
        }
    }
    UITraitCollection *traits = self.traitCollection;
    return [NSString stringWithFormat:
        @"tab=%ld loaded=%d attached=%d style=%ld notifications=%lu ground=%@ marker=%@ "
         "placeholderLoaded=%d placeholder=%@ icon=%@",
        (long)self.apollo_tabIndex, self.isViewLoaded, self.viewIfLoaded.window != nil,
        (long)traits.userInterfaceStyle, (unsigned long)_apollo_simThemeNotificationCount,
        ApolloPaneSimColorDescription(self.viewIfLoaded.backgroundColor, traits),
        ApolloPaneSimColorDescription([_apollo_grabber markerColor], traits),
        placeholder.isViewLoaded,
        ApolloPaneSimColorDescription(placeholder.viewIfLoaded.backgroundColor, traits),
        ApolloPaneSimColorDescription([placeholder apollo_simIconTintColor], traits)];
}

- (void)apollo_simSetPreferredPrimaryColumnWidth:(CGFloat)width {
    [self apollo_synchronizePreferredPrimaryWidth];
    [self apollo_publishPreferredPrimaryWidth:width persist:YES];
}

- (NSString *)apollo_simPreferredPrimaryColumnWidthState {
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene;
    NSNumber *sceneWidth = scene
        ? objc_getAssociatedObject(scene, &kApolloPaneScenePreferredWidthKey) : nil;
    return [NSString stringWithFormat:
        @"tab=%ld loaded=%d attached=%d hSize=%ld collapsed=%d tiled=%d "
         "scenePreferred=%.0f requested=%.0f resolved=%.0f grabberHidden=%d "
         "grabberFrame=%@ pointerInteractions=%lu keyCommands=%lu "
         "accessibilityLabel=%@ accessibilityValue=%@",
        (long)self.apollo_tabIndex, self.isViewLoaded, self.viewIfLoaded.window != nil,
        (long)self.traitCollection.horizontalSizeClass, self.isCollapsed,
        ApolloPaneSplitShowsTiledPrimary(self), sceneWidth.doubleValue,
        self.preferredPrimaryColumnWidth, self.primaryColumnWidth,
        _apollo_grabber.hidden, NSStringFromCGRect(_apollo_grabber.frame),
        (unsigned long)_apollo_grabber.interactions.count,
        (unsigned long)self.keyCommands.count,
        _apollo_grabber.accessibilityLabel ?: @"(nil)",
        _apollo_grabber.accessibilityValue ?: @"(nil)"];
}

- (BOOL)apollo_simAdjustDivider:(NSString *)operation {
    if (!_apollo_grabber || _apollo_grabber.hidden) return NO;
    if ([operation isEqualToString:@"increment"]) {
        [_apollo_grabber accessibilityIncrement];
        return YES;
    }
    if ([operation isEqualToString:@"decrement"]) {
        [_apollo_grabber accessibilityDecrement];
        return YES;
    }
    if ([operation isEqualToString:@"keyboard-widen"]) {
        [self apollo_widenPrimaryColumn:nil];
        return YES;
    }
    if ([operation isEqualToString:@"keyboard-narrow"]) {
        [self apollo_narrowPrimaryColumn:nil];
        return YES;
    }
    return NO;
}

- (void)apollo_simSetCrossColumnNavigationBlocked:(BOOL)blocked {
    _apollo_simCrossColumnNavigationBlocked = blocked;
    ApolloLog(@"[PaneTransition] tab %ld simulator gate=%d",
              (long)self.apollo_tabIndex, blocked);
    if (!blocked) [self apollo_navigationTransitionDidSettle];
}

- (NSString *)apollo_simCrossColumnNavigationState {
    return [NSString stringWithFormat:@"blocked=%d active=%d pending=%d sequence=%lu reason=%@",
        _apollo_simCrossColumnNavigationBlocked,
        [self apollo_navigationOrTopologyTransitionIsActive],
        _apollo_pendingCrossColumnNavigation != nil,
        (unsigned long)_apollo_pendingCrossColumnSequence,
        _apollo_pendingCrossColumnReason ?: @"(nil)"];
}

- (void)apollo_simSetResolvedLayoutMode:(NSString *)mode {
    NSString *normalized = mode.lowercaseString;
    if ([normalized isEqualToString:@"regular"] ||
        [normalized isEqualToString:@"tiled"] ||
        [normalized isEqualToString:@"reset"]) {
        self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
        self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        [self showColumn:UISplitViewControllerColumnPrimary];
    } else if ([normalized isEqualToString:@"overlay"]) {
        self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
        self.preferredDisplayMode = UISplitViewControllerDisplayModeOneOverSecondary;
        [self showColumn:UISplitViewControllerColumnPrimary];
    } else if ([normalized isEqualToString:@"secondary"]) {
        self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorOverlay;
        self.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        [self hideColumn:UISplitViewControllerColumnPrimary];
    } else {
        ApolloLog(@"[PaneDisplayTest] unknown mode=%@", normalized);
        return;
    }
    ApolloLog(@"[PaneDisplayTest] requested mode=%@ preferredMode=%ld preferredBehavior=%ld",
              normalized, (long)self.preferredDisplayMode,
              (long)self.preferredSplitBehavior);
    [self apollo_resolvedDisplayStateMayHaveChanged];
}

- (NSDictionary *)apollo_simStructuredSnapshot {
    NSMutableArray *columns = [NSMutableArray array];
    NSUInteger loaded = 0, visible = 0;
    for (UINavigationController *nav in @[self.apollo_primaryNav, self.apollo_detailNav]) {
        UIView *view = nav.viewIfLoaded;
        UIView *bar = nav.isViewLoaded ? nav.navigationBar : nil;
        UIView *search = nav.topViewController.navigationItem.searchController.searchBar;
        CGRect frame = view.window ? [view convertRect:view.bounds toView:self.viewIfLoaded] : CGRectZero;
        CGRect context = bar.window ? [bar convertRect:bar.bounds toView:self.viewIfLoaded] : CGRectZero;
        CGRect searchFrame = search.window ? [search convertRect:search.bounds toView:self.viewIfLoaded] : CGRectZero;
        for (UIViewController *controller in nav.viewControllers) {
            loaded += controller.isViewLoaded;
            visible += controller.viewIfLoaded.window != nil;
        }
        [columns addObject:@{@"depth": @(nav.viewControllers.count), @"frame": NSStringFromCGRect(frame),
            @"navigationContainer": NSStringFromCGRect(context), @"search": NSStringFromCGRect(searchFrame),
            @"barHidden": @(nav.navigationBarHidden)}];
    }
    return @{@"tab": @(self.apollo_tabIndex), @"collapsed": @(self.isCollapsed),
        @"bounds": NSStringFromCGRect(self.viewIfLoaded.bounds), @"displayMode": @(self.displayMode),
        @"tabContentGuide": NSStringFromCGRect(self.tabBarController.contentLayoutGuide.layoutFrame),
        @"columns": columns, @"logicalPrimaryDepth": @(self.apollo_logicalPrimaryControllers.count),
        @"emptyDetail": @(self.apollo_detailIsEmpty), @"loaded": @(loaded), @"visible": @(visible),
        @"pendingNavigation": @(_apollo_pendingCrossColumnNavigation != nil),
        @"watchdogs": @([ApolloPaneTransitionObserver activeCountForOwner:self] + [ApolloPaneTransitionObserver activeCountForOwner:self.apollo_primaryNav] + [ApolloPaneTransitionObserver activeCountForOwner:self.apollo_detailNav]),
        @"layoutPasses": @(_apollo_simLayoutPassCount), @"geometryRefreshes": @(_apollo_simGeometryRefreshCount),
        @"geometryWrites": @(_apollo_simGeometryWriteCount),
        @"preferredWidth": [self apollo_primaryWidthAccessibilityValue]};
}

- (NSString *)apollo_simResolvedLayoutState {
    UIViewController *primary = [self viewControllerForColumn:UISplitViewControllerColumnPrimary];
    CGRect primaryFrame = CGRectZero;
    CGRect secondaryFrame = CGRectZero;
    if (primary.isViewLoaded && primary.view.superview) {
        primaryFrame = [primary.view.superview convertRect:primary.view.frame toView:self.view];
    }
    UIView *visibleSecondaryView = self.apollo_detailNav.viewIfLoaded;
    if (visibleSecondaryView.superview) {
        secondaryFrame = [visibleSecondaryView.superview
            convertRect:visibleSecondaryView.frame toView:self.view];
    }
    BOOL primaryGeometry = primary.viewIfLoaded.window && !primary.view.hidden && primary.view.alpha > 0.01 &&
        CGRectIntersectsRect(primaryFrame, self.view.bounds);
    BOOL secondaryGeometry = visibleSecondaryView.window && !visibleSecondaryView.hidden && visibleSecondaryView.alpha > 0.01 &&
        CGRectIntersectsRect(secondaryFrame, self.view.bounds);
    BOOL secondaryAPI = YES;
    if (@available(iOS 26.0, *)) {
        secondaryAPI = [self isShowingColumn:UISplitViewControllerColumnSecondary];
    }
    NSUInteger showListCount = 0;
    NSUInteger compactBackCount = 0;
    for (UIViewController *controller in self.apollo_detailNav.viewControllers) {
        for (UIBarButtonItem *item in controller.navigationItem.leftBarButtonItems ?: @[]) {
            if (item == _apollo_showPrimaryItem) showListCount++;
            if (item == _apollo_compactBackItem) compactBackCount++;
        }
        for (UIBarButtonItem *item in controller.navigationItem.rightBarButtonItems ?: @[]) {
            if (item == _apollo_showPrimaryItem) showListCount++;
            if (item == _apollo_compactBackItem) compactBackCount++;
        }
    }
    return [NSString stringWithFormat:
        @"hSize=%ld collapsed=%d preferredMode=%ld resolvedMode=%ld "
         "preferredBehavior=%ld resolvedBehavior=%ld primaryAPI=%d primaryGeometry=%d "
         "secondaryAPI=%d secondaryGeometry=%d primaryFrame=%@ secondaryFrame=%@ "
         "showListCount=%lu showListEnabled=%d showListSide=%@ compactBackCount=%lu state={%@}",
        (long)self.traitCollection.horizontalSizeClass, self.isCollapsed,
        (long)self.preferredDisplayMode, (long)self.displayMode,
        (long)self.preferredSplitBehavior, (long)self.splitBehavior,
        ApolloPaneSplitShowsPrimary(self), primaryGeometry,
        secondaryAPI, secondaryGeometry,
        NSStringFromCGRect(primaryFrame), NSStringFromCGRect(secondaryFrame),
        (unsigned long)showListCount, _apollo_showPrimaryItem.enabled,
        _apollo_showPrimaryOwner ? (_apollo_showPrimaryItemOnRight ? @"right" : @"left") : @"none",
        (unsigned long)compactBackCount, [self apollo_simCrossColumnNavigationState]];
}

- (BOOL)apollo_simActivateShowPrimaryItem {
    if (!_apollo_showPrimaryOwner || !_apollo_showPrimaryItem.enabled) return NO;
    [self apollo_showPrimaryItemActivated:_apollo_showPrimaryItem];
    return YES;
}

- (NSString *)apollo_simLayoutPassStateReset:(BOOL)reset {
    ApolloPaneColumnHostViewController *host =
        [self.apollo_detailHost isKindOfClass:[ApolloPaneColumnHostViewController class]]
            ? (ApolloPaneColumnHostViewController *)self.apollo_detailHost : nil;
    NSString *hostState = [host apollo_simLayoutPassStateReset:reset] ?: @"host unavailable";
    NSString *state = [NSString stringWithFormat:
        @"panePasses=%lu paneRefreshes=%lu paneWrites=%lu grabberHidden=%d "
         "grabberFrame=%@ %@ pass=%d",
        (unsigned long)_apollo_simLayoutPassCount,
        (unsigned long)_apollo_simGeometryRefreshCount,
        (unsigned long)_apollo_simGeometryWriteCount,
        _apollo_grabber.hidden, NSStringFromCGRect(_apollo_grabber.frame), hostState,
        !_apollo_geometryScheduler.isPending];
    if (reset) {
        _apollo_simLayoutPassCount = 0;
        _apollo_simGeometryRefreshCount = 0;
        _apollo_simGeometryWriteCount = 0;
    }
    return state;
}

- (NSString *)apollo_simMasterSelectionState {
    [self apollo_refreshMasterSelection];
    ApolloPaneMasterSelectionIntent *intent = _apollo_masterSelectionIntent;
    UITableView *tableView = ApolloPaneMasterSelectionTable(intent.surface);
    NSIndexPath *resolvedPath = intent ? [self apollo_resolvedMasterSelectionPath:intent] : nil;
    UITableViewCell *cell = resolvedPath ? [tableView cellForRowAtIndexPath:resolvedPath] : nil;
    NSUInteger selectedCount = tableView.indexPathsForSelectedRows.count;
    BOOL pathSelected = resolvedPath &&
        [tableView.indexPathsForSelectedRows containsObject:resolvedPath];
    BOOL axSelected = cell && (cell.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
    BOOL detailMatches = intent && _apollo_masterSelectionDetailRoot &&
        _apollo_masterSelectionDetailRoot == self.apollo_detailNav.viewControllers.firstObject;
    BOOL expectsPhysical = intent && !self.isCollapsed && detailMatches;
    BOOL passed = !intent
        ? selectedCount == 0
        : (!expectsPhysical || !resolvedPath
            ? selectedCount == 0
            : selectedCount == 1 && pathSelected && cell.selected && axSelected);
    return [NSString stringWithFormat:
        @"logical=%d source=%@ texture=%d keyHash=%lu cached=%@ resolved=%@ "
         "detailMatch=%d collapsed=%d selectedCount=%lu pathSelected=%d "
         "cellVisible=%d cellSelected=%d axSelected=%d pass=%d",
        intent != nil, NSStringFromClass(intent.sourceViewController.class),
        intent.textureBacked, (unsigned long)[intent.itemIdentifier hash],
        intent.indexPath ?: @"(nil)", resolvedPath ?: @"(nil)", detailMatches,
        self.isCollapsed, (unsigned long)selectedCount, pathSelected,
        cell != nil, cell.selected, axSelected, passed];
}

+ (void)apollo_simRunDeallocatedSourceProbe {
    __block BOOL incorrectlyApplied = NO;
    __block BOOL deferAccepted = NO;
    __weak UIViewController *weakDisposable = nil;
    __block ApolloPaneSplitViewController *probePane = nil;
    @autoreleasepool {
        __strong UIViewController *disposable = [UIViewController new];
        disposable.title = @"Task 11 Disposable Source";
        weakDisposable = disposable;
        UINavigationController *navigationController =
            [[UINavigationController alloc] initWithRootViewController:disposable];
        probePane = [ApolloPaneSplitViewController
            paneControllerWithRootNavigationController:navigationController tabIndex:99];
        [probePane apollo_simSetCrossColumnNavigationBlocked:YES];
        deferAccepted = [probePane apollo_deferCrossColumnNavigationIfNeeded:^{
            incorrectlyApplied = YES;
            ApolloLog(@"[PaneTransitionTest] ERROR applied deallocated-source intent");
        } sourceViewController:disposable reason:@"sim deallocated source"];
        [navigationController setViewControllers:@[ [UIViewController new] ] animated:NO];
        disposable = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL sourceNil = weakDisposable == nil;
        ApolloLog(@"[PaneTransitionTest] releasing deallocated-source intent accepted=%d sourceNil=%d%@",
                  deferAccepted, sourceNil,
                  deferAccepted && sourceNil ? @"" : @" ERROR inconclusive probe setup");
        [probePane apollo_simSetCrossColumnNavigationBlocked:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *state = [probePane apollo_simCrossColumnNavigationState];
            BOOL passed = deferAccepted && sourceNil && !incorrectlyApplied &&
                [state containsString:@"pending=0"];
            ApolloLog(@"[PaneTransitionTest] deallocated-source %@ applied=%d state={%@}",
                      passed ? @"PASS" : @"ERROR", incorrectlyApplied, state);
            probePane = nil;
        });
    });
}
#endif

- (void)apollo_recordDetailBranchFromPrimarySource:(UIViewController *)sourceViewController {
    NSArray<UIViewController *> *logicalPrimary = self.apollo_logicalPrimaryControllers;
    UIViewController *semanticOwner = ApolloPanePrimaryContextController(logicalPrimary);
    UIViewController *concreteOwner = sourceViewController;
    if (!concreteOwner || ![logicalPrimary containsObject:concreteOwner]) {
        concreteOwner = semanticOwner;
    }
    _apollo_detailContextOwner = concreteOwner;
    _apollo_detailSemanticOwner = semanticOwner;
    _apollo_detailContextScope = ApolloPanePrimaryContextScope(semanticOwner);
    ApolloLog(@"[PaneContext] tab %ld recorded detail owner=%@ semantic=%@ scoped=%d",
              (long)self.apollo_tabIndex, NSStringFromClass(concreteOwner.class),
              NSStringFromClass(semanticOwner.class),
              _apollo_detailContextScope != nil);
}

- (void)apollo_prepareForCompactPrimaryContextChange {
    if (!self.isCollapsed || !_apollo_compactDetailChromeActive) return;
    [self apollo_restoreCompactDetailNavigationItem];
    [self apollo_stopTrackingCompactPrimaryPopGesture];
    [self.apollo_primaryNav setNavigationBarHidden:_apollo_primaryNavBarWasHiddenBeforeCompact
                                          animated:NO];
    [self.apollo_detailNav setNavigationBarHidden:_apollo_detailNavBarWasHiddenBeforeCompact
                                         animated:NO];
    [self apollo_resetCompactDetailChromeState];
    if (@available(iOS 14.0, *)) {
        _apollo_performingCompactShowColumn = YES;
        @try {
            [self showColumn:UISplitViewControllerColumnPrimary];
        } @finally {
            _apollo_performingCompactShowColumn = NO;
        }
    }
}

- (void)apollo_reconcileDetailAfterPrimaryMutation:(NSString *)reason {
    if (!_apollo_contextTrackingReady || _apollo_clearingContext ||
        (![self apollo_hasDetailBranchForContextTracking] &&
         !_apollo_pendingCrossColumnNavigation)) return;

    // A delayed didShow/set-stack reconciliation from the previous navigation
    // must not coalesce a valid newer selection into a Clear. The queued route
    // owns its own source/scope token; keep it when that token still matches.
    if (_apollo_pendingCrossColumnNavigation &&
        [self apollo_pendingCrossColumnSourceIsStillCurrent]) {
        ApolloLog(@"[PaneContext] tab %ld kept valid pending route during reconciliation reason=%@",
                  (long)self.apollo_tabIndex, reason ?: @"primary mutation");
        return;
    }

    NSArray<UIViewController *> *logicalPrimary = self.apollo_logicalPrimaryControllers;
    UIViewController *current = ApolloPanePrimaryContextController(logicalPrimary);
    UIViewController *owner = _apollo_detailContextOwner;
    UIViewController *semanticOwner = _apollo_detailSemanticOwner;
    NSString *currentScope = ApolloPanePrimaryContextScope(current);
    BOOL ownerChanged = !owner || ![logicalPrimary containsObject:owner] ||
        !semanticOwner || current != semanticOwner;
    BOOL provenScopeChange = !ownerChanged && _apollo_detailContextScope && currentScope &&
        ![_apollo_detailContextScope isEqualToString:currentScope];
    if (!ownerChanged && !provenScopeChange) return;

    ApolloLog(@"[PaneContext] tab %ld clearing detail reason=%@ ownerChanged=%d scopeChanged=%d",
              (long)self.apollo_tabIndex, reason ?: @"primary mutation",
              ownerChanged, provenScopeChange);
    [self apollo_clearDetailColumn];
}

- (void)apollo_scheduleDetailReconciliationAfterPrimaryMutation:(NSString *)reason {
    if (reason.length > 0) _apollo_pendingContextReconciliationReason = [reason copy];
    if (_apollo_contextReconciliationScheduled) return;
    _apollo_contextReconciliationScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_apollo_contextReconciliationScheduled = NO;
        NSString *settledReason = self->_apollo_pendingContextReconciliationReason;
        self->_apollo_pendingContextReconciliationReason = nil;
        [self apollo_reconcileDetailAfterPrimaryMutation:settledReason ?: @"primary mutation settled"];
    });
}

- (void)apollo_forcePrimaryContextChangedForViewController:(UIViewController *)viewController
                                                    reason:(NSString *)reason {
    if (!_apollo_contextTrackingReady || _apollo_clearingContext) return;
    BOOL visibleOwner = viewController == _apollo_detailSemanticOwner ||
        viewController == _apollo_detailContextOwner;
    BOOL pendingOwner = _apollo_pendingCrossColumnNavigation &&
        (viewController == _apollo_pendingCrossColumnSource ||
         viewController == _apollo_pendingCrossColumnSemanticOwner);
    if (!visibleOwner && !pendingOwner) return;
    ApolloLog(@"[PaneContext] tab %ld clearing detail for forced in-place change reason=%@",
              (long)self.apollo_tabIndex, reason ?: @"unknown");
    [self apollo_clearDetailColumn];
}

- (void)apollo_accountContextDidChange {
    if (!_apollo_contextTrackingReady || _apollo_clearingContext) return;
    // Home, Inbox and Profile content is tied to the active Reddit account.
    // Settings is not, and Search can remain a valid public query.
    if (self.apollo_tabIndex < 0 || self.apollo_tabIndex > 2) return;
    if (![self apollo_hasDetailBranchForContextTracking] &&
        !_apollo_pendingCrossColumnNavigation) return;
    ApolloLog(@"[PaneContext] tab %ld clearing account-scoped detail",
              (long)self.apollo_tabIndex);
    [self apollo_clearDetailColumn];
}

// A detail route opened while an EMPTY pane is already compact has to push on
// the one visible primary navigation stack. On expansion, move the contiguous
// logical-detail suffix back to the real detail navigation controller so the
// feed remains on the left and the route the user opened remains on the right.
- (void)apollo_migrateCompactLogicalStackIfNeeded {
    NSArray<UIViewController *> *primaryStack = self.apollo_primaryNav.viewControllers;
    NSUInteger detailStart = NSNotFound;
    for (NSUInteger index = 0; index < primaryStack.count; index++) {
        if ([self apollo_compactViewControllerBelongsToDetail:primaryStack[index]]) {
            detailStart = index;
            break;
        }
    }
    if (detailStart == NSNotFound) return;
    if (detailStart == 0) {
        ApolloLog(@"[PaneSplit] tab %ld refused compact migration with no primary anchor",
                  (long)self.apollo_tabIndex);
        return;
    }

    NSArray<UIViewController *> *primaryControllers =
        [primaryStack subarrayWithRange:NSMakeRange(0, detailStart)];
    NSArray<UIViewController *> *detailControllers =
        [primaryStack subarrayWithRange:NSMakeRange(detailStart, primaryStack.count - detailStart)];

    // These controllers are changing physical owners. Any Forward entries in
    // the destination detail nav belong to its previous branch, while entries
    // left in the primary nav can only refer to logical-detail controllers
    // popped during compact navigation (the first compact detail push already
    // cleared older primary Forward state through Apollo's native push path).
    // Move both stacks as one rollback-capable transaction. History and logical
    // ownership are committed only after both UIKit mutations succeed.
    NSArray<UIViewController *> *oldPrimary = self.apollo_primaryNav.viewControllers;
    NSArray<UIViewController *> *oldDetail = self.apollo_detailNav.viewControllers;
    @try {
        [self apollo_setPrimaryViewControllers:primaryControllers];
        [self.apollo_detailNav setViewControllers:detailControllers animated:NO];
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneSplit] tab %ld compact migration failed; rolling back: %@",
                  (long)self.apollo_tabIndex, exception);
        @try {
            [self apollo_setPrimaryViewControllers:oldPrimary];
            [self.apollo_detailNav setViewControllers:oldDetail animated:NO];
        } @catch (NSException *rollbackException) {
            ApolloLog(@"[PaneSplit] tab %ld compact migration rollback failed: %@",
                      (long)self.apollo_tabIndex, rollbackException);
        }
        return;
    }
    ApolloPaneClearForwardHistory(self.apollo_detailNav);
    ApolloPaneClearForwardHistory(self.apollo_primaryNav);
    for (UIViewController *controller in detailControllers) {
        [_apollo_compactLogicalColumns removeObjectForKey:controller];
    }
    ApolloLog(@"[PaneSplit] tab %ld expanded; migrated %lu compact detail controller(s), primary depth=%lu",
              (long)self.apollo_tabIndex, (unsigned long)detailControllers.count,
              (unsigned long)primaryControllers.count);
}

- (void)apollo_clearDetailColumn {
    if (_apollo_clearingContext) return;
    if (!_apollo_executingCrossColumnNavigation) {
        __weak ApolloPaneSplitViewController *weakSelf = self;
        if ([self apollo_deferCrossColumnNavigationIfNeeded:^{
                [weakSelf apollo_clearDetailColumn];
            }
                                  sourceViewController:nil
                                                reason:@"clear detail"]) return;
    }

    _apollo_clearingContext = YES;
    @try {
        NSArray<UIViewController *> *oldPrimary = self.apollo_primaryNav.viewControllers;
        NSArray<UIViewController *> *oldDetail = self.apollo_detailNav.viewControllers;
        BOOL compactChromeWasActive = _apollo_compactDetailChromeActive;
        NSArray<UIViewController *> *liveLogicalPrimary = self.apollo_logicalPrimaryControllers;
        BOOL removesLogicalDetail = liveLogicalPrimary.count < oldPrimary.count &&
            liveLogicalPrimary.count > 0;
        NSArray<UIViewController *> *logicalDetail = removesLogicalDetail
            ? [oldPrimary subarrayWithRange:NSMakeRange(liveLogicalPrimary.count,
                                                       oldPrimary.count - liveLogicalPrimary.count)]
            : @[];
        NSArray<UIViewController *> *logicalPrimary = liveLogicalPrimary;
        NSArray<UIViewController *> *capturedReturnStack = _apollo_compactPrimaryReturnStack;
        BOOL capturedReturnMatchesAnchor = capturedReturnStack.count > 0 &&
            capturedReturnStack.lastObject == _apollo_compactPrimaryAnchor;
        BOOL liveIsTruncatedReturn = ApolloPaneStackIsStrictIdentityPrefix(
            liveLogicalPrimary, capturedReturnStack);
        BOOL liveIsExactCapturedBridgeStack = ApolloPaneStacksIdentityEqual(
            liveLogicalPrimary, _apollo_postCollapsePrimaryBridgeStack);
        BOOL restoresCapturedPrimary = compactChromeWasActive &&
            capturedReturnMatchesAnchor &&
            (liveIsTruncatedReturn || liveIsExactCapturedBridgeStack);
        if (restoresCapturedPrimary) {
            logicalPrimary = [capturedReturnStack copy];
        }
        BOOL writesPrimary = removesLogicalDetail || restoresCapturedPrimary;
        BOOL replacesPhysicalDetail = !self.apollo_detailIsEmpty;
        NSArray<UIViewController *> *placeholder = replacesPhysicalDetail ? @[
            [[ApolloPaneDetailPlaceholderViewController alloc]
                initWithMessage:self.apollo_emptyMessage symbolName:self.apollo_emptySymbol]
        ] : oldDetail;

        @try {
            if (writesPrimary) {
                [self apollo_setPrimaryViewControllers:logicalPrimary];
                if (!ApolloPaneStacksIdentityEqual(self.apollo_primaryNav.viewControllers,
                                                   logicalPrimary)) {
                    @throw [NSException exceptionWithName:@"ApolloPanePrimaryClearPostcondition"
                                                   reason:@"Primary navigation rejected compact recovery"
                                                 userInfo:nil];
                }
            }
            if (replacesPhysicalDetail) {
                [self.apollo_detailNav setViewControllers:placeholder animated:NO];
                if (!ApolloPaneStacksIdentityEqual(self.apollo_detailNav.viewControllers,
                                                   placeholder)) {
                    @throw [NSException exceptionWithName:@"ApolloPaneDetailClearPostcondition"
                                                   reason:@"Detail navigation rejected placeholder"
                                                 userInfo:nil];
                }
            }
        } @catch (NSException *exception) {
            ApolloLog(@"[PaneSplit] tab %ld detail clear failed; rolling back: %@",
                      (long)self.apollo_tabIndex, exception);
            @try {
                [self apollo_setPrimaryViewControllers:oldPrimary];
                [self.apollo_detailNav setViewControllers:oldDetail animated:NO];
            } @catch (NSException *rollbackException) {
                ApolloLog(@"[PaneSplit] tab %ld detail clear rollback failed: %@",
                          (long)self.apollo_tabIndex, rollbackException);
            }
            return;
        }

        NSArray<UIViewController *> *expectedPrimary = nil;
        NSUInteger restoreGeneration = 0;
        if (compactChromeWasActive && logicalPrimary.count > 0) {
            expectedPrimary = [logicalPrimary copy];
            restoreGeneration = ++_apollo_compactPrimaryRestoreGeneration;
            _apollo_compactPrimaryRestoreMutationGeneration =
                _apollo_primaryNavigationMutationGeneration;
            ++_apollo_compactPrimaryRestoreLineage;
            _apollo_expectedCompactPrimaryRestoreStack = expectedPrimary;
            _apollo_compactPrimaryRestoreInProgress = YES;
            _apollo_expectUIKitCompactPrimaryStackReplacement = YES;
            _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
            _apollo_lateUIKitCompactPrimaryStableObservations = 0;
            _apollo_knownUIKitCompactPrimaryTransientStack = nil;
        }

        // Compact chrome is coordinator-owned state too. Tear it down only
        // after both stack writes succeed, so a UIKit exception leaves the old
        // visible branch and its Back affordance fully usable. Arm the one-shot
        // stack token first so the public set-stack call made by showColumn:
        // can identify its exact transient shape synchronously.
        [self apollo_prepareForCompactPrimaryContextChange];
        // `showColumn:Primary` can repeat UIKit's compact merge policy and
        // truncate [index, feed] to [index] asynchronously. The full captured
        // stack was committed before showColumn: above; only revalidate/repair
        // after that coordinator settles, never write during its setup.
        if (expectedPrimary.count > 0) {
            [self apollo_scheduleCompactPrimaryRestoreReconciliation:restoreGeneration
                                                         observations:0];
        }

        // Commit bookkeeping only after UIKit accepted every required stack
        // mutation. Even an already-visible placeholder may retain stale Forward
        // history, so detail invalidation is unconditional.
        ApolloPaneClearForwardHistory(self.apollo_detailNav);
        if (writesPrimary) ApolloPaneClearForwardHistory(self.apollo_primaryNav);
        for (UIViewController *controller in logicalDetail) {
            [_apollo_compactLogicalColumns removeObjectForKey:controller];
        }
        _apollo_detailContextOwner = nil;
        _apollo_detailSemanticOwner = nil;
        _apollo_detailContextScope = nil;
        [self apollo_clearMasterSelectionForReason:@"detail clear committed"];
        if (!compactChromeWasActive || logicalPrimary.count == 0) {
            _apollo_compactPrimaryReturnStack = nil;
            _apollo_postCollapsePrimaryBridgeStack = nil;
            _apollo_expectedCompactPrimaryRestoreStack = nil;
            _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
            _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
            _apollo_lateUIKitCompactPrimaryStableObservations = 0;
            _apollo_knownUIKitCompactPrimaryTransientStack = nil;
        }
        if (restoresCapturedPrimary) {
            ApolloLog(@"[PaneSplit] tab %ld restored captured compact primary depth %lu -> %lu",
                      (long)self.apollo_tabIndex, (unsigned long)liveLogicalPrimary.count,
                      (unsigned long)logicalPrimary.count);
        }
        if (removesLogicalDetail) {
            ApolloLog(@"[PaneSplit] tab %ld removed %lu compact logical-detail controller(s)",
                      (long)self.apollo_tabIndex, (unsigned long)logicalDetail.count);
        }
        ApolloLog(@"[PaneSplit] tab %ld detail column cleared and forward history invalidated",
                  (long)self.apollo_tabIndex);
        [self apollo_resolvedDisplayStateMayHaveChanged];
    } @finally {
        _apollo_clearingContext = NO;
    }
}

#pragma mark - Compact navigation chrome

- (void)apollo_restoreCompactDetailNavigationItem {
    UIViewController *root = _apollo_compactDetailRoot;
    UIBarButtonItem *back = _apollo_compactBackItem;
    if (!root || !back) return;

    // Own only the item we inserted. Restoring an old snapshot of the entire
    // array (and both Back booleans) can erase legitimate native changes made
    // while compact, such as entering Edit mode or updating account actions.
    NSMutableArray<UIBarButtonItem *> *current =
        [root.navigationItem.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
    NSUInteger index = [current indexOfObjectIdenticalTo:back];
    if (index == NSNotFound) return;
    [current removeObjectAtIndex:index];
    root.navigationItem.leftBarButtonItems = current.count > 0 ? current : nil;
}

- (void)apollo_stopTrackingCompactPrimaryPopGesture {
    // While our percent-driven return owns the native transition, its gesture
    // must keep receiving samples and Apollo's competing recognizers must stay
    // disabled. Restore their original states only after commit/cancellation.
    if (_apollo_rootInteractiveTransition) return;
    UIGestureRecognizer *primaryPop = self.apollo_primaryNav.interactivePopGestureRecognizer;
    if (_apollo_trackingCompactPrimaryPopGesture) {
        [primaryPop removeTarget:self action:@selector(apollo_compactPrimaryPopGestureChanged:)];
        primaryPop.enabled = _apollo_primaryPopGestureWasEnabled;
        _apollo_trackingCompactPrimaryPopGesture = NO;
    }
    self.apollo_detailNav.interactivePopGestureRecognizer.enabled = _apollo_detailPopGestureWasEnabled;
    if (_apollo_primaryApolloBackGesture) {
        _apollo_primaryApolloBackGesture.enabled = _apollo_primaryApolloBackGestureWasEnabled;
        _apollo_primaryApolloBackGesture = nil;
    }
    if (_apollo_detailApolloBackGesture) {
        _apollo_detailApolloBackGesture.enabled = _apollo_detailApolloBackGestureWasEnabled;
        _apollo_detailApolloBackGesture = nil;
    }
    if (_apollo_compactBackEdgeGesture && !_apollo_rootInteractiveTransition) {
        [_apollo_compactBackEdgeGesture.view removeGestureRecognizer:_apollo_compactBackEdgeGesture];
        _apollo_compactBackEdgeGesture.delegate = nil;
        _apollo_compactBackEdgeGesture = nil;
    }
}

- (void)apollo_resetCompactDetailChromeState {
    [self apollo_restoreCompactDetailNavigationItem];
    [self apollo_stopTrackingCompactPrimaryPopGesture];
    _apollo_compactDetailChromeActive = NO;
    _apollo_compactPrimaryAnchor = nil;
    _apollo_compactDetailRoot = nil;
    _apollo_compactBackItem = nil;
}

- (void)apollo_activateCompactDetailChrome {
    [self apollo_removeShowPrimaryItem];
    if (_apollo_compactDetailChromeActive || self.apollo_detailIsEmpty) return;

    UINavigationController *primary = self.apollo_primaryNav;
    UINavigationController *detail = self.apollo_detailNav;
    UIViewController *root = detail.viewControllers.firstObject;
    if (!primary || !detail || !root || !_apollo_compactPrimaryAnchor) {
        ApolloLog(@"[PaneSplit] tab %ld compact chrome unavailable (primary=%d detail=%d root=%d anchor=%d)",
                  (long)self.apollo_tabIndex, primary != nil, detail != nil, root != nil,
                  _apollo_compactPrimaryAnchor != nil);
        return;
    }

    _apollo_primaryNavBarWasHiddenBeforeCompact = primary.navigationBarHidden;
    _apollo_detailNavBarWasHiddenBeforeCompact = detail.navigationBarHidden;
    _apollo_compactDetailRoot = root;

    UIBarButtonItem *back = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(apollo_compactBackToPrimary:)];
    back.accessibilityLabel = self.tabBarItem.title.length > 0
        ? [NSString stringWithFormat:@"Back to %@", self.tabBarItem.title]
        : @"Back";
    back.accessibilityIdentifier = @"ApolloPaneCompactBack";
    _apollo_compactBackItem = back;
    NSArray<UIBarButtonItem *> *existing = root.navigationItem.leftBarButtonItems ?: @[];
    root.navigationItem.leftBarButtonItems = [@[ back ] arrayByAddingObjectsFromArray:existing];

    // The primary bar contains only UIKit's cross-column Back item. Apollo's
    // inner detail bar already owns the useful title/actions, so keeping both
    // wastes 54pt and looks like a navigation controller embedded in another.
    [primary setNavigationBarHidden:YES animated:NO];
    if (_apollo_detailNavBarWasHiddenBeforeCompact) {
        [detail setNavigationBarHidden:NO animated:NO];
    }

    UIGestureRecognizer *popGesture = primary.interactivePopGestureRecognizer;
    if (popGesture) {
        _apollo_primaryPopGestureWasEnabled = popGesture.enabled;
        [popGesture addTarget:self action:@selector(apollo_compactPrimaryPopGestureChanged:)];
        // This recognizer lives above a nested navigation controller after the
        // split collapse and loses the touch arbitration in practice. Disable
        // it while compact and replace it with a root-only edge recognizer on
        // the view the user is actually touching. The target remains attached
        // defensively in case UIKit completes a programmatic interactive pop.
        popGesture.enabled = NO;
        _apollo_trackingCompactPrimaryPopGesture = YES;
    }

    UIGestureRecognizer *detailPopGesture = detail.interactivePopGestureRecognizer;
    _apollo_detailPopGestureWasEnabled = detailPopGesture.enabled;
    detailPopGesture.enabled = NO;

    // ApolloNavigationController does not use the UIKit recognizer above for
    // its interactive transitions. Its own left-edge pan on the collapsed
    // primary can pop UIKit's column bridge without telling this coordinator,
    // leaving the list visible while the detail column still claims to be
    // populated. Disable both nested Apollo recognizers while compact and
    // restore their exact prior state on Back or expansion.
    _apollo_primaryApolloBackGesture =
        ApolloPaneNavigationGesture(primary, "leftScreenEdgePanGestureRecognizer");
    _apollo_detailApolloBackGesture =
        ApolloPaneNavigationGesture(detail, "leftScreenEdgePanGestureRecognizer");
    _apollo_primaryApolloBackGestureWasEnabled = _apollo_primaryApolloBackGesture.enabled;
    _apollo_detailApolloBackGestureWasEnabled = _apollo_detailApolloBackGesture.enabled;
    _apollo_primaryApolloBackGesture.enabled = NO;
    _apollo_detailApolloBackGesture.enabled = detail.viewControllers.count > 1 &&
        _apollo_detailApolloBackGestureWasEnabled;
    detailPopGesture.enabled = detail.viewControllers.count > 1 && _apollo_detailPopGestureWasEnabled;

    UIPanGestureRecognizer *edge = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(apollo_compactBackEdgeGestureChanged:)];
    UIUserInterfaceLayoutDirection direction = detail.view.effectiveUserInterfaceLayoutDirection;
    _apollo_compactBackUsesRightEdge = direction == UIUserInterfaceLayoutDirectionRightToLeft;
    edge.minimumNumberOfTouches = 1;
    edge.maximumNumberOfTouches = 1;
    edge.delegate = self;
    // Attach above UIKit's collapsed-column bridge. The hosted detail view is
    // visible through that bridge but is not the reliable recipient of a touch
    // that begins at the physical window edge.
    [self.view addGestureRecognizer:edge];
    _apollo_compactBackEdgeGesture = edge;
    _apollo_compactDetailChromeActive = YES;
    ApolloLog(@"[PaneSplit] tab %ld compact detail chrome active; primary bar hidden, detail Back installed",
              (long)self.apollo_tabIndex);
}

- (void)apollo_refreshCompactDetailChromeAfterRootReplacement {
    if (!self.isCollapsed || !_apollo_compactDetailChromeActive) return;
    UIViewController *anchor = _apollo_compactPrimaryAnchor;
    BOOL restorePrimaryHidden = _apollo_primaryNavBarWasHiddenBeforeCompact;
    BOOL restoreDetailHidden = _apollo_detailNavBarWasHiddenBeforeCompact;
    [self apollo_resetCompactDetailChromeState];
    _apollo_compactPrimaryAnchor = anchor;
    [self apollo_activateCompactDetailChrome];
    // Activation samples compact's temporary bar visibility. Retain the actual
    // pre-collapse values for Back/expansion restoration.
    _apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
    _apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
}

- (void)apollo_finishCompactBackToPrimary {
    if (!_apollo_compactDetailChromeActive || _apollo_compactBackInProgress) return;
    if (!_apollo_executingCrossColumnNavigation) {
        __weak ApolloPaneSplitViewController *weakSelf = self;
        if ([self apollo_deferCrossColumnNavigationIfNeeded:^{
                [weakSelf apollo_finishCompactBackToPrimary];
            }
                                  sourceViewController:nil
                                                reason:@"compact Back"]) return;
    }
    _apollo_compactBackInProgress = YES;

    UINavigationController *primary = self.apollo_primaryNav;
    UINavigationController *detail = self.apollo_detailNav;
    UIViewController *anchor = _apollo_compactPrimaryAnchor;
    UIViewController *detailRoot = _apollo_compactDetailRoot;
    BOOL restorePrimaryHidden = _apollo_primaryNavBarWasHiddenBeforeCompact;
    BOOL restoreDetailHidden = _apollo_detailNavBarWasHiddenBeforeCompact;

    [self apollo_restoreCompactDetailNavigationItem];
    [self apollo_stopTrackingCompactPrimaryPopGesture];

    // During the cross-column pop, show exactly the primary bar that owns the
    // transition and temporarily hide the detail bar. Restoring both at once
    // would reintroduce the two-bar frame for the duration of the animation.
    [detail setNavigationBarHidden:YES animated:NO];
    [primary setNavigationBarHidden:restorePrimaryHidden animated:NO];

    __weak ApolloPaneSplitViewController *weakOwner = self;
    void (^complete)(void) = ^{
        ApolloPaneSplitViewController *self = weakOwner;
        if (!self) return;
        self->_apollo_rootInteractiveTransition = nil;
        ApolloPaneSetNativeInteractiveTransition(primary, nil);
        if (detail.viewControllers.firstObject != detailRoot) {
            self->_apollo_compactBackInProgress = NO;
            UIViewController *currentRoot = detail.viewControllers.firstObject;
            if (self.isCollapsed && !self.apollo_detailIsEmpty) {
                // A replacement may have rebuilt chrome while the old Back
                // animation was settling. Preserve that new ownership; if it
                // did not, rebuild against the new root now.
                if (!self->_apollo_compactDetailChromeActive ||
                    self->_apollo_compactDetailRoot != currentRoot) {
                    [self apollo_resetCompactDetailChromeState];
                    self->_apollo_compactPrimaryAnchor = anchor;
                    self->_apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
                    self->_apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
                    [self apollo_activateCompactDetailChrome];
                    self->_apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
                    self->_apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
                } else {
                    [primary setNavigationBarHidden:YES animated:NO];
                    [detail setNavigationBarHidden:NO animated:NO];
                }
                ApolloLog(@"[PaneSplit] tab %ld compact Back kept replacement detail chrome",
                          (long)self.apollo_tabIndex);
            } else {
                [primary setNavigationBarHidden:restorePrimaryHidden animated:NO];
                [detail setNavigationBarHidden:restoreDetailHidden animated:NO];
                [self apollo_resetCompactDetailChromeState];
                ApolloLog(@"[PaneSplit] tab %ld compact Back settled after branch/topology changed",
                          (long)self.apollo_tabIndex);
            }
            return;
        }
        // This clear is the commit phase of the already-started Back action.
        // Execute it directly so it cannot coalesce over a newer user route
        // that arrived during the pop. The central clear transaction restores
        // the captured primary return stack before discarding this branch.
        [self apollo_performCrossColumnNavigationTransaction:^{
            [self apollo_clearDetailColumn];
        }];
        if (!self.apollo_detailIsEmpty) {
            self->_apollo_compactBackInProgress = NO;
            [primary setNavigationBarHidden:YES animated:NO];
            [detail setNavigationBarHidden:NO animated:NO];
            [self apollo_resetCompactDetailChromeState];
            self->_apollo_compactPrimaryAnchor = anchor;
            self->_apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
            self->_apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
            [self apollo_activateCompactDetailChrome];
            self->_apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
            self->_apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
            ApolloLog(@"[PaneSplit] tab %ld compact Back clear failed; retained detail for retry",
                      (long)self.apollo_tabIndex);
            return;
        }
        self->_apollo_compactBackInProgress = NO;
        ApolloLog(@"[PaneSplit] tab %ld compact Back returned to primary and cleared detail",
                  (long)self.apollo_tabIndex);
    };
    void (^restoreCancelled)(void) = ^{
        ApolloPaneSplitViewController *self = weakOwner;
        if (!self) return;
        [self->_apollo_rootInteractiveTransition cancelInteractiveTransition];
        self->_apollo_rootInteractiveTransition = nil;
        ApolloPaneSetNativeInteractiveTransition(primary, nil);
        self->_apollo_compactBackInProgress = NO;
        if (!self.isCollapsed || self.apollo_detailIsEmpty) {
            [primary setNavigationBarHidden:restorePrimaryHidden animated:NO];
            [detail setNavigationBarHidden:restoreDetailHidden animated:NO];
            [self apollo_resetCompactDetailChromeState];
            ApolloLog(@"[PaneSplit] tab %ld compact Back cancellation settled after topology changed",
                      (long)self.apollo_tabIndex);
            return;
        }
        [primary setNavigationBarHidden:YES animated:NO];
        [detail setNavigationBarHidden:NO animated:NO];
        // We removed only coordinator-owned chrome and gestures above. Rebuild
        // them from the still-valid detail branch when UIKit refuses or cancels
        // the native pop; the detail stack and context remain untouched.
        [self apollo_resetCompactDetailChromeState];
        self->_apollo_compactPrimaryAnchor = anchor;
        self->_apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
        self->_apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
        [self apollo_activateCompactDetailChrome];
        // Activation samples the temporary compact visibility we just restored;
        // retain the real pre-collapse values for the eventual successful Back
        // or expansion.
        self->_apollo_primaryNavBarWasHiddenBeforeCompact = restorePrimaryHidden;
        self->_apollo_detailNavBarWasHiddenBeforeCompact = restoreDetailHidden;
        ApolloLog(@"[PaneSplit] tab %ld compact Back cancelled/refused; restored %@ detail chrome",
                  (long)self.apollo_tabIndex,
                  detail.viewControllers.firstObject == detailRoot ? @"original" : @"replacement");
    };

    if (anchor && [primary.viewControllers containsObject:anchor] && primary.topViewController != anchor) {
        NSArray<UIViewController *> *popped = [primary popToViewController:anchor animated:YES];
        if (popped.count == 0) {
            restoreCancelled();
            return;
        }
        __block BOOL backResolutionFinished = NO;
        void (^resolveBack)(BOOL) = ^(BOOL cancelled) {
            if (backResolutionFinished) return;
            backResolutionFinished = YES;
            if (!cancelled && primary.topViewController == anchor) complete();
            else restoreCancelled();
        };
        id<UIViewControllerTransitionCoordinator> coordinator = primary.transitionCoordinator;
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                BOOL cancelled = context.isCancelled;
                dispatch_async(dispatch_get_main_queue(), ^{ resolveBack(cancelled); });
            }];
        }
        // Registration can be rejected when UIKit hands the coordinator off,
        // and an accepted coordinator is not contractually required to call a
        // late completion. Poll to the terminal stack as an idempotent watchdog
        // rather than leaving compact chrome permanently half-torn-down.
        [ApolloPaneTransitionObserver observeOwner:self key:@"compactBack" timeout:6.0
            ready:^BOOL(ApolloPaneSplitViewController *pane) {
                return ![pane apollo_navigationControllerIsTransitioning:pane.apollo_primaryNav];
            } completion:^(ApolloPaneSplitViewController *pane, BOOL timedOut) {
                // A person may hold an interactive Back for longer than the
                // watchdog. Never cancel or restore chrome under their finger.
                if (timedOut && pane->_apollo_rootInteractiveTransition) return;
                resolveBack(timedOut || primary.topViewController != anchor);
            }];
    } else {
        complete();
    }
}

- (void)apollo_compactBackToPrimary:(UIBarButtonItem *)sender {
    [self apollo_finishCompactBackToPrimary];
}

- (BOOL)accessibilityPerformEscape {
    if (!_apollo_compactDetailChromeActive) return [super accessibilityPerformEscape];
    if (self.apollo_detailNav.viewControllers.count > 1) {
        [self.apollo_detailNav popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
        return YES;
    }
    ApolloLog(@"[PaneSplit] tab %ld compact accessibility escape accepted",
              (long)self.apollo_tabIndex);
    [self apollo_finishCompactBackToPrimary];
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.view == _apollo_grabber &&
        [gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (!ApolloPaneSplitShowsTiledPrimary(self)) return NO;
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.view];
        return fabs(velocity.x) > fabs(velocity.y);
    }
    if (gestureRecognizer != _apollo_compactBackEdgeGesture) return YES;
    if (!_apollo_compactDetailChromeActive || !self.isCollapsed ||
        self.apollo_detailNav.viewControllers.count != 1 ||
        [self apollo_navigationOrTopologyTransitionIsActive]) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint location = [pan locationInView:pan.view];
    CGPoint translation = [pan translationInView:pan.view];
    CGFloat initialX = location.x - translation.x;
    CGFloat width = pan.view.bounds.size.width;
    BOOL startsAtEdge = _apollo_compactBackUsesRightEdge
        ? initialX >= width - 24.0 : initialX <= 24.0;
    CGPoint velocity = [pan velocityInView:pan.view];
    CGFloat backVelocity = velocity.x * (_apollo_compactBackUsesRightEdge ? -1.0 : 1.0);
    BOOL shouldBegin = startsAtEdge && backVelocity > 0.0 && fabs(velocity.x) > fabs(velocity.y);
    ApolloLog(@"[PaneSplit] tab %ld compact edge Back begin=%d initialX=%.0f velocity=(%.0f,%.0f)",
              (long)self.apollo_tabIndex, shouldBegin, initialX, velocity.x, velocity.y);
    return shouldBegin;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // The divider/root Back owns its touch exclusively. UIKit's column
    // bookkeeping remains intact without sharing scrolling or voting gestures.
    return NO;
}

- (void)apollo_compactBackEdgeGestureChanged:(UIPanGestureRecognizer *)gesture {
    CGFloat direction = _apollo_compactBackUsesRightEdge ? -1.0 : 1.0;
    CGFloat width = MAX(1.0, CGRectGetWidth(gesture.view.bounds));
    CGFloat progress = MIN(1.0, MAX(0.0, [gesture translationInView:gesture.view].x * direction / width));
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (!_apollo_compactPrimaryAnchor ||
            ![self.apollo_primaryNav.viewControllers containsObject:_apollo_compactPrimaryAnchor]) return;
        UIPercentDrivenInteractiveTransition *transition = [UIPercentDrivenInteractiveTransition new];
        transition.completionCurve = UIViewAnimationCurveEaseOut;
        if (!ApolloPaneSetNativeInteractiveTransition(self.apollo_primaryNav, transition)) return;
        _apollo_rootInteractiveTransition = transition;
        // Apollo's native animator and delegate consume its typed interaction
        // slot. The existing transactional root Back owns commit/cancel; there
        // is no second simulated animation or speculative stack mutation.
        [self apollo_performCrossColumnNavigationTransaction:^{ [self apollo_finishCompactBackToPrimary]; }];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        [_apollo_rootInteractiveTransition updateInteractiveTransition:progress];
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled ||
               gesture.state == UIGestureRecognizerStateFailed) {
        CGFloat velocity = [gesture velocityInView:gesture.view].x * direction;
        BOOL commit = gesture.state == UIGestureRecognizerStateEnded &&
            (progress >= 0.35 || (velocity >= 500.0 && progress >= 0.05));
        if (commit) [_apollo_rootInteractiveTransition finishInteractiveTransition];
        else [_apollo_rootInteractiveTransition cancelInteractiveTransition];
        ApolloPaneSetNativeInteractiveTransition(self.apollo_primaryNav, nil);
    }
}

- (void)apollo_compactPrimaryPopGestureChanged:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled &&
        gesture.state != UIGestureRecognizerStateFailed) return;

    void (^inspectSettledStack)(BOOL) = ^(BOOL cancelled) {
        if (!self->_apollo_compactDetailChromeActive) return;
        if (cancelled) {
            ApolloLog(@"[PaneSplit] tab %ld native compact pop cancelled; kept detail",
                      (long)self.apollo_tabIndex);
            return;
        }
        if (self.apollo_primaryNav.topViewController != self->_apollo_compactPrimaryAnchor) return;
        [self apollo_performCrossColumnNavigationTransaction:^{
            [self apollo_clearDetailColumn];
        }];
        ApolloLog(@"[PaneSplit] tab %ld compact edge Back returned to primary and cleared detail",
                  (long)self.apollo_tabIndex);
    };
    id<UIViewControllerTransitionCoordinator> coordinator = self.apollo_primaryNav.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            inspectSettledStack(context.isCancelled);
        }];
    } else {
        // Non-interactive/programmatic paths can deliver the recognizer terminal
        // state after the coordinator has already detached.
        dispatch_async(dispatch_get_main_queue(), ^{ inspectSettledStack(NO); });
    }
}

#pragma mark - UISplitViewControllerDelegate

- (void)splitViewController:(UISplitViewController *)svc
    willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    ApolloLog(@"[PaneDisplay] tab %ld display transition %ld -> %ld collapsed=%d",
              (long)self.apollo_tabIndex, (long)self.displayMode,
              (long)displayMode, self.isCollapsed);
    // Remove a no-longer-valid recovery item synchronously. The item for a new
    // SecondaryOnly state is installed only after UIKit resolves the transition,
    // so it cannot be tapped while columns are still moving.
    if (displayMode != UISplitViewControllerDisplayModeSecondaryOnly) {
        [self apollo_removeShowPrimaryItem];
    }
    __weak ApolloPaneSplitViewController *weakSelf = self;
    id<UIViewControllerTransitionCoordinator> coordinator = svc.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
            completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf apollo_resolvedDisplayStateMayHaveChanged];
                });
            }];
    } else {
        [self apollo_resolvedDisplayStateMayHaveChanged];
    }
}

- (void)apollo_releaseOrphanedTopologyGateAfterCollapsePolicy:(NSUInteger)generation
                                             nilObservations:(NSUInteger)nilObservations {
    (void)nilObservations;
    __block NSUInteger stableSamples = 0;
    [ApolloPaneTransitionObserver observeOwner:self key:@"topologyPolicy" timeout:6.0
        ready:^BOOL(ApolloPaneSplitViewController *pane) {
            if (!pane->_apollo_topologyMutationInProgress || pane->_apollo_topologyMutationGeneration != generation) return YES;
            if (pane.transitionCoordinator) { stableSamples = 0; return NO; }
            return ++stableSamples >= 2;
        } completion:^(ApolloPaneSplitViewController *pane, BOOL timedOut) {
            if (pane->_apollo_topologyMutationGeneration != generation) return;
            pane->_apollo_topologyMutationInProgress = NO;
            ApolloLog(@"[PaneTransition] topology policy released timeout=%d", timedOut);
            [pane apollo_navigationTransitionDidSettle];
        }];
}

// Collapsing to compact (Slide Over, a narrow Stage Manager window, portrait on
// a small iPad) must land on today's single-stack app. Surface the detail
// column only when it actually holds something — otherwise the user would
// collapse into a "No Post Selected" screen with their feed hidden behind it.
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
        topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    _apollo_topologyMutationInProgress = YES;
    NSUInteger topologyGeneration = ++_apollo_topologyMutationGeneration;
    // If UIKit asks for a collapse policy but abandons the transition, neither
    // didCollapse nor didExpand is guaranteed. Release an orphaned gate once the
    // next run-loop observes no split coordinator and no collapsed topology.
    [self apollo_releaseOrphanedTopologyGateAfterCollapsePolicy:topologyGeneration
                                                nilObservations:0];
    _apollo_preCollapsePrimaryStack = [self.apollo_primaryNav.viewControllers copy];
    _apollo_postCollapsePrimaryBridgeStack = nil;
    // Land on the deepest column the user has actually reached, so collapsing
    // feels like the single stack they navigated rather than a jump backwards.
    if (!self.apollo_detailIsEmpty) {
        // Capture the last real list controller before UIKit appends its bridge
        // controller. It is the native target for compact cross-column Back.
        _apollo_compactPrimaryAnchor = self.apollo_primaryNav.topViewController;
        _apollo_compactPrimaryReturnStack = [_apollo_preCollapsePrimaryStack copy];
        ApolloLog(@"[PaneSplit] tab %ld collapsing onto secondary", (long)self.apollo_tabIndex);
        return UISplitViewControllerColumnSecondary;
    }
    _apollo_compactPrimaryAnchor = nil;
    _apollo_compactPrimaryReturnStack = nil;
    _apollo_postCollapsePrimaryBridgeStack = nil;
    _apollo_expectedCompactPrimaryRestoreStack = nil;
    _apollo_compactPrimaryRestoreInProgress = NO;
    _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
    _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
    _apollo_lateUIKitCompactPrimaryStableObservations = 0;
    _apollo_knownUIKitCompactPrimaryTransientStack = nil;
    _apollo_expectUIKitExpansionPrimaryMutation = NO;
    ++_apollo_compactPrimaryRestoreGeneration;
    ApolloLog(@"[PaneSplit] tab %ld collapsing onto primary", (long)self.apollo_tabIndex);
    return UISplitViewControllerColumnPrimary;
}

// UIKit merges the columns' navigation stacks on collapse, which would drag the
// placeholder along with them. Strip it afterwards rather than trying to
// predict the merge: the result is the same whichever way UIKit combines them.
- (void)splitViewControllerDidCollapse:(UISplitViewController *)svc {
    [self apollo_removeShowPrimaryItem];
    @try {
    // UIKit merges onto whichever navigation controller survived as the top
    // column, which is not necessarily the primary one.
    UINavigationController *nav = self.apollo_primaryNav;
    for (UINavigationController *candidate in @[ self.apollo_detailNav, self.apollo_primaryNav ]) {
        if (candidate.viewControllers.count > 1) { nav = candidate; break; }
    }
    NSArray<UIViewController *> *stack = nav.viewControllers;
    NSMutableArray<UIViewController *> *cleaned = [NSMutableArray arrayWithCapacity:stack.count];
    for (UIViewController *vc in stack) {
        if (![vc isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]]) [cleaned addObject:vc];
    }
    if (cleaned.count != stack.count && cleaned.count > 0) {
        [nav setViewControllers:cleaned animated:NO];
        ApolloLog(@"[PaneSplit] tab %ld collapsed; stripped %lu placeholder(s)",
                  (long)self.apollo_tabIndex, (unsigned long)(stack.count - cleaned.count));
    }

    // With an empty secondary, iPadOS 26 sometimes resets a primary navigation
    // stack such as [RedditList, Posts] to [RedditList] during its column merge.
    // Restore only a strict captured prefix: a different live shape represents
    // real application navigation and must win.
    NSArray<UIViewController *> *capturedPrimary = _apollo_preCollapsePrimaryStack;
    NSArray<UIViewController *> *livePrimary = self.apollo_primaryNav.viewControllers;
    BOOL liveIsCapturedPrefix = livePrimary.count < capturedPrimary.count;
    for (NSUInteger index = 0; liveIsCapturedPrefix && index < livePrimary.count; index++) {
        liveIsCapturedPrefix = livePrimary[index] == capturedPrimary[index];
    }
    if (self.apollo_detailIsEmpty && liveIsCapturedPrefix) {
        @try {
            [self apollo_setPrimaryViewControllers:capturedPrimary];
            ApolloLog(@"[PaneSplit] tab %ld collapsed; restored primary depth %lu -> %lu",
                      (long)self.apollo_tabIndex, (unsigned long)livePrimary.count,
                      (unsigned long)capturedPrimary.count);
        } @catch (NSException *exception) {
            ApolloLog(@"[PaneSplit] tab %ld failed restoring collapsed primary stack: %@",
                      (long)self.apollo_tabIndex, exception);
        }
    }
    if (!self.apollo_detailIsEmpty) {
        NSArray<UIViewController *> *capturedReturn = _apollo_compactPrimaryReturnStack;
        NSArray<UIViewController *> *postCollapsePrimary = self.apollo_primaryNav.viewControllers;
        if (capturedReturn.count > 0 && postCollapsePrimary.count > capturedReturn.count &&
            ApolloPaneStackStartsWithIdentityStack(postCollapsePrimary, capturedReturn)) {
            // Capture UIKit's exact bridge identity before user navigation can
            // append anything. Clear may remove this precise shape later, but
            // must never mistake an arbitrary newer suffix for bridge chrome.
            _apollo_postCollapsePrimaryBridgeStack = [postCollapsePrimary copy];
        }
        [self apollo_activateCompactDetailChrome];
    }
    // The snapshot exists only to repair UIKit's synchronous collapse result.
    // Keeping it for the entire compact session would retain controllers the
    // user subsequently pops or replaces.
        _apollo_preCollapsePrimaryStack = nil;
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneSplit] tab %ld collapse reconciliation failed safely: %@",
                  (long)self.apollo_tabIndex, exception);
    } @finally {
        _apollo_topologyMutationInProgress = NO;
        [self apollo_scheduleShowPrimaryItemRefresh];
        [self apollo_scheduleResolvedGeometryRefresh];
        [self apollo_navigationTransitionDidSettle];
    }
}

// Expanding back to regular width. The detail column may have been emptied
// entirely by the collapse merge, so restore its placeholder; without a root
// view controller the column renders as a black rectangle.
- (void)splitViewControllerDidExpand:(UISplitViewController *)svc {
    // A compact Back/clear may have already committed the full primary stack,
    // while UIKit's asynchronous showColumn: merge is still temporarily
    // presenting only a prefix. Expanding in that narrow window invalidates the
    // compact-only callback below, so carry its exact expected stack into this
    // reconciliation instead of discarding the only copy of the user's path.
    BOOL ownsPendingCompactPrimaryRestore = _apollo_compactPrimaryRestoreInProgress &&
        _apollo_primaryNavigationMutationGeneration ==
            _apollo_compactPrimaryRestoreMutationGeneration;
    NSArray<UIViewController *> *pendingCompactPrimaryRestore =
        ownsPendingCompactPrimaryRestore
            ? [_apollo_expectedCompactPrimaryRestoreStack copy] : nil;
    ++_apollo_topologyMutationGeneration;
    NSUInteger expansionRestoreGeneration = ++_apollo_compactPrimaryRestoreGeneration;
    _apollo_lateUIKitCompactPrimaryStableObservations = 0;
    BOOL settlesPendingCompactRestore = pendingCompactPrimaryRestore.count > 0;
    _apollo_compactPrimaryRestoreInProgress = settlesPendingCompactRestore;
    _apollo_expectedCompactPrimaryRestoreStack = settlesPendingCompactRestore
        ? pendingCompactPrimaryRestore : nil;
    _apollo_expectUIKitExpansionPrimaryMutation = settlesPendingCompactRestore;
    if (settlesPendingCompactRestore &&
        _apollo_knownUIKitCompactPrimaryTransientStack.count > 0) {
        // Expansion is a fresh UIKit topology transaction. Even if the old
        // generation had just revoked its late-write grace and was waiting for
        // the final repair sample, this generation can publish the same merge
        // once more after its own coordinator detaches. Re-arm the exact-only
        // grant for that new owner instead of misclassifying its write as app
        // navigation.
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = YES;
    } else if (settlesPendingCompactRestore) {
        // The old generation may have reached its post-grace final-sample
        // window before ever seeing UIKit's first merge. Expansion creates a
        // new topology owner, so re-arm the bounded initial strict-prefix slot
        // as well; otherwise its first ambient-signal-free setter is mistaken
        // for app navigation and the list column collapses to its root.
        _apollo_expectUIKitCompactPrimaryStackReplacement = YES;
    }
    if (!settlesPendingCompactRestore) {
        _apollo_expectUIKitCompactPrimaryStackReplacement = NO;
        _apollo_expectOneLateUIKitCompactPrimaryStackReplacement = NO;
        _apollo_lateUIKitCompactPrimaryStableObservations = 0;
        _apollo_knownUIKitCompactPrimaryTransientStack = nil;
    }
    _apollo_topologyMutationInProgress = YES;
    @try {
    if (_apollo_compactDetailChromeActive) {
        [self.apollo_primaryNav setNavigationBarHidden:_apollo_primaryNavBarWasHiddenBeforeCompact animated:NO];
        [self.apollo_detailNav setNavigationBarHidden:_apollo_detailNavBarWasHiddenBeforeCompact animated:NO];
        [self apollo_resetCompactDetailChromeState];
        ApolloLog(@"[PaneSplit] tab %ld expanded; restored regular column chrome",
                  (long)self.apollo_tabIndex);
    } else {
        _apollo_compactPrimaryAnchor = nil;
    }
    [self apollo_migrateCompactLogicalStackIfNeeded];
    if (self.apollo_detailNav.viewControllers.count == 0) {
        [self.apollo_detailNav setViewControllers:@[
            [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:self.apollo_emptyMessage
                                                                   symbolName:self.apollo_emptySymbol]
        ] animated:NO];
        ApolloLog(@"[PaneSplit] tab %ld expanded; restored detail placeholder", (long)self.apollo_tabIndex);
    }
        _apollo_preCollapsePrimaryStack = nil;
        _apollo_compactPrimaryReturnStack = nil;
        _apollo_postCollapsePrimaryBridgeStack = nil;
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneSplit] tab %ld expansion reconciliation failed safely: %@",
                  (long)self.apollo_tabIndex, exception);
        if (self.apollo_detailNav.viewControllers.count == 0) {
            @try {
                [self.apollo_detailNav setViewControllers:@[
                    [[ApolloPaneDetailPlaceholderViewController alloc]
                        initWithMessage:self.apollo_emptyMessage symbolName:self.apollo_emptySymbol]
                ] animated:NO];
            } @catch (NSException *recoveryException) {
                ApolloLog(@"[PaneSplit] tab %ld expansion placeholder recovery failed: %@",
                          (long)self.apollo_tabIndex, recoveryException);
            }
        }
    } @finally {
        _apollo_preCollapsePrimaryStack = nil;
        _apollo_compactPrimaryReturnStack = nil;
        _apollo_postCollapsePrimaryBridgeStack = nil;
        _apollo_topologyMutationInProgress = NO;
        [self apollo_scheduleShowPrimaryItemRefresh];
        [self apollo_scheduleResolvedGeometryRefresh];
        if (settlesPendingCompactRestore) {
            [self apollo_scheduleCompactPrimaryRestoreReconciliation:
                expansionRestoreGeneration observations:0];
        } else {
            [self apollo_navigationTransitionDidSettle];
        }
    }
}

@end
