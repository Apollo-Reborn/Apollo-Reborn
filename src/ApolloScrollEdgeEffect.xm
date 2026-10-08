#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloClasses.h"

// MARK: - Header Style (Liquid Glass, iOS 26+)
//
// iOS 26 introduced UIScrollView.topEdgeEffect/bottomEdgeEffect, a glass blur
// rendered where content scrolls under the nav/tab bars. iOS 26 defaults to a
// soft gradient blur; iOS 27 betas default to a hard cutoff with a dividing
// line, which some users find jarring. The "Header Style" setting lets users
// choose the TOP (header) edge treatment explicitly: Soft, Hard, Blur (a
// tweak-drawn progressive blur — see ApolloProgressiveBlur.xm), or Hidden
// (no native edge effect and no replacement blur).
//
// Header Style only changes the top edge. Earlier builds applied its style
// to all four edges, which painted a hard band behind the tab bar in Hard
// mode. Minimize separately suppresses the bottom effect behind its floating
// pill; bottom/left/right styles always keep the system's treatment.
//
// UIScrollEdgeEffect/UIScrollEdgeEffectStyle are public iOS 26 SDK classes,
// but referencing them directly would create a hard class reference that
// could fail to bind on the pre-26 devices this tweak still targets. Access
// everything defensively via objc_getClass/objc_msgSend, mirroring the
// pattern used for other iOS 26-only APIs (see ApolloNativeActionMenus.xm).

NSString *const ApolloScrollEdgeEffectStyleChangedNotification = @"ApolloScrollEdgeEffectStyleChangedNotification";
static char kApolloScrollEdgeEffectForcedHiddenKey;
// Stamped @YES on effects our apply pass fetched via -topEdgeEffect. The
// UIScrollEdgeEffect object itself exposes no edge identity (its state is an
// opaque Swift ivar), so the global setStyle:/setHidden: enforcement hooks
// below rely on this stamp to act on header effects only and leave the
// tab-bar/bottom and horizontal edges to UIKit. An unstamped effect is one we
// have not yet seen through a scroll view — the hooks pass it through, and
// the next apply pass (didMoveToWindow / style-change notification) stamps it
// and applies the mode directly.
static char kApolloScrollEdgeEffectIsTopKey;
static char kApolloProfileHeroVisibleKey;
static char kApolloEdgeHasVisibleProfileHeroKey;

// Debug-only introspection for the sim bridge's "headerdump" command.
const void *ApolloScrollEdgeEffectTopStampKey(void) { return &kApolloScrollEdgeEffectIsTopKey; }
const void *ApolloScrollEdgeEffectForcedHiddenStampKey(void) { return &kApolloScrollEdgeEffectForcedHiddenKey; }

NSInteger ApolloResolvedScrollEdgeEffectStyle(void) {
    NSInteger mode = sScrollEdgeEffectStyle;
    // Blur depends on a private CAFilter. A restored preference can contain
    // raw value 4 even when the picker hides it on this runtime; treat that
    // exactly like the retired Automatic value so the native edge effect,
    // title capsule and settings UI all agree on a usable system fallback.
    if (mode == ApolloScrollEdgeEffectStyleBlur && !ApolloProgressiveBlurAvailable()) {
        mode = ApolloScrollEdgeEffectStyleAutomatic;
    }
    if (mode != ApolloScrollEdgeEffectStyleAutomatic) return mode;
    static BOOL sSystemDefaultsHard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sSystemDefaultsHard = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 27;
    });
    return sSystemDefaultsHard ? ApolloScrollEdgeEffectStyleHard : ApolloScrollEdgeEffectStyleSoft;
}

static BOOL ApolloHeaderStyleHidesNativeEffect(NSInteger mode) {
    return mode == ApolloScrollEdgeEffectStyleBlur || mode == ApolloScrollEdgeEffectStyleHidden;
}

static id ApolloScrollEdgeEffectStyleObjectForMode(NSInteger mode) {
    Class styleClass = ApolloClassUIScrollEdgeEffectStyle;
    if (!styleClass) return nil;

    SEL selector;
    switch (mode) {
        case ApolloScrollEdgeEffectStyleSoft: selector = @selector(softStyle); break;
        case ApolloScrollEdgeEffectStyleHard: selector = @selector(hardStyle); break;
        default: selector = @selector(automaticStyle); break;
    }
    if (![styleClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(styleClass, selector);
}

static BOOL sLoggedScrollEdgeEffectDiagnostics = NO;
static BOOL sLoggedScrollEdgeEffectSetterOverride = NO;

// Logos otherwise emits a compile-time UIScrollEdgeEffect type reference,
// which is availability-annotated for iOS 26 even though this module resolves
// the class dynamically. Hook an unannotated alias and bind it only when the
// runtime class exists so iOS 14-25 retain no hard dependency or warnings.
@interface ApolloRuntimeScrollEdgeEffect : NSObject
@end

// After a LIVE hidden/style change UIKit does not rebuild the effect's render
// layers on its own — the pocket stack resettles only on the next layout pass
// of the scroll view AND the effect view's own subtree (same recipe as
// ApolloScrollEdgePopFix's unfreeze path). Without this, switching modes in
// settings leaves the header with no material until the next natural relayout.
static void ApolloNudgeEdgeEffectRebuild(UIScrollView *scrollView) {
    [scrollView setNeedsLayout];
    for (UIView *container in scrollView.subviews) {
        for (UIView *sub in container.subviews) {
            if ([NSStringFromClass(sub.class) containsString:@"ScrollEdgeEffect"]) {
                [container setNeedsLayout];
                [sub setNeedsLayout];
            }
        }
    }
}

// Minimize keeps one native glass platter throughout its morph. UIKit also draws
// a separate full-width bottom pocket inside the content scroll view. Leaving
// that pocket enabled produces a stationary blur behind the compact pill on
// iOS 27. Keep it disabled for the entire Minimize mode, including expanded, so
// expansion never changes the material sampled by the selected tab at settle.
// This is independent of Header Style and never changes an edge's style.
@interface ApolloMinimizeBottomEdgeState : NSObject
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, weak) id effect;
@property (nonatomic) BOOL nativeHidden;
@property (nonatomic) BOOL writingHidden;
@property (nonatomic) BOOL refreshScheduled;
@end
@implementation ApolloMinimizeBottomEdgeState
@end
static char kApolloMinimizeBottomEdgeStateKey;
static NSHashTable<ApolloMinimizeBottomEdgeState *> *sApolloMinimizeBottomEdges;

static BOOL ApolloMinimizeBottomEdgeEnabled(void) {
    return sTabBarHideStyle == ApolloTabBarHideStyleMinimize &&
        ApolloSupportsNativeTabBarScrollBehavior() &&
        [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyNativeHideBarsOnScroll];
}

static BOOL ApolloMinimizeOwnsBottomEdge(UIScrollView *scrollView) {
    if (!scrollView.window || !ApolloMinimizeBottomEdgeEnabled()) return NO;
    UITabBarController *controller = nil;
    for (UIResponder *responder = scrollView; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            controller = ((UIViewController *)responder).tabBarController;
            if (controller) break;
        }
    }
    UITabBar *bar = controller.tabBar;
    UIView *content = controller.selectedViewController.viewIfLoaded;
    if (!content || ![scrollView isDescendantOfView:content] ||
        bar.window != scrollView.window || bar.hidden) return NO;
    CGRect scrollFrame = [scrollView convertRect:scrollView.bounds toView:bar.window];
    CGRect barFrame = [bar convertRect:bar.bounds toView:bar.window];
    // Only the main content reaching this bottom bar qualifies. Do not hide
    // pockets belonging to embedded carousels, small lists, or modal sheets.
    return scrollFrame.size.width >= barFrame.size.width * 0.75 &&
        scrollFrame.size.height >= bar.window.bounds.size.height * 0.5 &&
        CGRectIntersectsRect(scrollFrame, barFrame);
}

static void ApolloRefreshMinimizeBottomEdge(ApolloMinimizeBottomEdgeState *state) {
    id effect = state.effect;
    if (!effect) return;
    BOOL enabled = ApolloMinimizeBottomEdgeEnabled();
    BOOL hidden = (enabled && ApolloMinimizeOwnsBottomEdge(state.scrollView)) || state.nativeHidden;
    BOOL current = ((BOOL (*)(id, SEL))objc_msgSend)(effect, @selector(isHidden));
    if (current != hidden) {
        state.writingHidden = YES;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setHidden:), hidden);
        state.writingHidden = NO;
        ApolloNudgeEdgeEffectRebuild(state.scrollView);
    }
    if (!enabled) {
        // Restore native intent once, including cached/offscreen views, then
        // stop retaining state or intercepting their bottom-edge updates.
        objc_setAssociatedObject(effect, &kApolloMinimizeBottomEdgeStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sApolloMinimizeBottomEdges removeObject:state];
    }
}

static void ApolloApplyMinimizeBottomEdge(UIScrollView *scrollView) {
    // The settings notification revisits every window when enabled later.
    // Other styles need no bottom-effect lookup, state, or queued refresh.
    if (!ApolloMinimizeBottomEdgeEnabled()) return;
    SEL selector = NSSelectorFromString(@"bottomEdgeEffect");
    if (![scrollView respondsToSelector:selector]) return;
    id effect = ((id (*)(id, SEL))objc_msgSend)(scrollView, selector);
    if (![effect respondsToSelector:@selector(isHidden)] ||
        ![effect respondsToSelector:@selector(setHidden:)]) return;
    ApolloMinimizeBottomEdgeState *state = objc_getAssociatedObject(effect, &kApolloMinimizeBottomEdgeStateKey);
    if (!state) {
        state = [ApolloMinimizeBottomEdgeState new];
        state.effect = effect;
        state.nativeHidden = ((BOOL (*)(id, SEL))objc_msgSend)(effect, @selector(isHidden));
        objc_setAssociatedObject(effect, &kApolloMinimizeBottomEdgeStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sApolloMinimizeBottomEdges) sApolloMinimizeBottomEdges = [NSHashTable weakObjectsHashTable];
        [sApolloMinimizeBottomEdges addObject:state];
    }
    state.scrollView = scrollView;
    ApolloRefreshMinimizeBottomEdge(state);
    // didMoveToWindow can precede the tab controller's final geometry. Check
    // again after that layout without installing another layoutSubviews hook.
    if (!state.refreshScheduled) {
        state.refreshScheduled = YES;
        __weak ApolloMinimizeBottomEdgeState *weakState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloMinimizeBottomEdgeState *current = weakState;
            current.refreshScheduled = NO;
            ApolloRefreshMinimizeBottomEdge(current);
        });
    }
}

static void ApolloApplyHeaderStyleToTopEdge(UIScrollView *scrollView, NSInteger mode) {
    SEL topEdgeEffectSelector = @selector(topEdgeEffect);
    if (![scrollView respondsToSelector:topEdgeEffectSelector]) return;
    id effect = ((id (*)(id, SEL))objc_msgSend)(scrollView, topEdgeEffectSelector);
    if (!effect) return;

    objc_setAssociatedObject(effect, &kApolloScrollEdgeEffectIsTopKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // The profile table and Apollo's intercepting scroll view both participate
    // in the top effect. Inherit the override from their controller's root.
    BOOL heroVisible = NO;
    for (UIView *view = scrollView; view; view = view.superview) {
        if ([objc_getAssociatedObject(view, &kApolloProfileHeroVisibleKey) boolValue]) {
            heroVisible = YES;
            break;
        }
    }
    objc_setAssociatedObject(effect, &kApolloEdgeHasVisibleProfileHeroKey,
                             heroVisible ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (heroVisible && mode == ApolloScrollEdgeEffectStyleHard) {
        mode = ApolloScrollEdgeEffectStyleHidden;
    }

    SEL setHiddenSelector = @selector(setHidden:);
    BOOL hasSetHidden = [effect respondsToSelector:setHiddenSelector];
    if (hasSetHidden) {
        if (ApolloHeaderStyleHidesNativeEffect(mode)) {
            // Blur replaces the system header effect with the tweak-drawn
            // progressive blur; Hidden removes it without a replacement. Remember
            // only the visibility changes made BY THIS FEATURE: stamp an
            // effect solely when this call actually flips it visible→hidden.
            // An effect that is already hidden either belongs to UIKit/Apollo
            // (never stamp — restoring must not un-hide an edge they keep
            // disabled) or was stamped by an earlier pass of ours (stamp is
            // already present and stays).
            SEL isHiddenSelector = @selector(isHidden);
            BOOL alreadyHidden = [effect respondsToSelector:isHiddenSelector] &&
                ((BOOL (*)(id, SEL))objc_msgSend)(effect, isHiddenSelector);
            if (!alreadyHidden) {
                objc_setAssociatedObject(effect, &kApolloScrollEdgeEffectForcedHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setHiddenSelector, YES);
            }
        } else if (objc_getAssociatedObject(effect, &kApolloScrollEdgeEffectForcedHiddenKey)) {
            objc_setAssociatedObject(effect, &kApolloScrollEdgeEffectForcedHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setHiddenSelector, NO);
        }
    }

    // Blur and Hidden leave the hidden native effect's style alone; other modes
    // push their style object — Automatic pushes automaticStyle, which is also
    // what restores system behavior after switching away from Soft/Hard.
    BOOL hasSetStyle = NO;
    id style = nil;
    if (!ApolloHeaderStyleHidesNativeEffect(mode)) {
        SEL setStyleSelector = @selector(setStyle:);
        style = ApolloScrollEdgeEffectStyleObjectForMode(mode);
        hasSetStyle = (style != nil) && [effect respondsToSelector:setStyleSelector];
        if (hasSetStyle) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, setStyleSelector, style);
        }
    }

    if (!sLoggedScrollEdgeEffectDiagnostics) {
        sLoggedScrollEdgeEffectDiagnostics = YES;
        ApolloLog(@"[HeaderStyle] applied mode=%ld effect=%@ setHidden=%d style=%@ setStyle=%d on %@",
                  (long)mode, effect, hasSetHidden, style, hasSetStyle, scrollView);
    }
}

// Declared in ApolloState.h; called from UIScrollView's didMoveToWindow hook in
// ApolloAutoHideTabBar.xm (a second %hook UIScrollView didMoveToWindow here would be a
// duplicate symbol that the Logos internal generator silently drops).
void ApolloApplyScrollEdgeEffectStyle(UIScrollView *scrollView) {
    if (!IsLiquidGlass()) return;
    ApolloApplyHeaderStyleToTopEdge(scrollView, ApolloResolvedScrollEdgeEffectStyle());
    ApolloApplyMinimizeBottomEdge(scrollView);
}

static void ApolloApplyScrollEdgeEffectStyleToViewTree(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        ApolloApplyScrollEdgeEffectStyle((UIScrollView *)view);
    }
    for (UIView *subview in view.subviews) {
        ApolloApplyScrollEdgeEffectStyleToViewTree(subview);
    }
}

void ApolloApplyScrollEdgeEffectStyleToViewController(UIViewController *viewController) {
    if (!IsLiquidGlass() || !viewController.isViewLoaded) return;
    ApolloApplyScrollEdgeEffectStyleToViewTree(viewController.view);
}

// Notification-pass variant: apply AND nudge the rebuild. The lifecycle pass
// (didMoveToWindow) never needs the nudge — those views are about to lay out
// anyway — so it stays out of ApolloApplyScrollEdgeEffectStyle.
static void ApolloApplyAndNudgeViewTree(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        ApolloApplyScrollEdgeEffectStyle((UIScrollView *)view);
        ApolloNudgeEdgeEffectRebuild((UIScrollView *)view);
    }
    for (UIView *subview in view.subviews) {
        ApolloApplyAndNudgeViewTree(subview);
    }
}

void ApolloSetProfileHeroVisible(UIViewController *viewController, BOOL visible) {
    if (!viewController.isViewLoaded) return;
    UIView *root = viewController.view;
    if ([objc_getAssociatedObject(root, &kApolloProfileHeroVisibleKey) boolValue] == visible) return;
    objc_setAssociatedObject(root, &kApolloProfileHeroVisibleKey,
                             visible ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!IsLiquidGlass()) return;
    ApolloApplyAndNudgeViewTree(root);
    ApolloLog(@"[HeaderStyle] profile hero visible=%d mode=%ld", visible,
              (long)ApolloResolvedScrollEdgeEffectStyle());
}

static void ApolloNudgeViewTree(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        ApolloNudgeEdgeEffectRebuild((UIScrollView *)view);
    }
    for (UIView *subview in view.subviews) {
        ApolloNudgeViewTree(subview);
    }
}

// MARK: - Hard: room above a nav-bar-hosted search field
//
// Under the Hard header style UIKit paints the navigation bar's title row as
// a solid band with a hard bottom edge. A search bar hosted in the bar sits in
// its own 54pt row below that band (the search bar registers its own scroll
// pocket, so the band stops above it), and UIKit lays its 44pt field out flush
// with the top of that row (0pt above it on iOS 27, 1pt on iOS 26): the hard
// edge lands exactly on the top of the field and the field reads as cut off
// (reported with #1138; Soft and Blur have no edge there, so the same geometry
// looks padded). The row's height is the bar's to decide — a taller natural
// height, intrinsic size or palette preferredHeight is ignored by the iOS 26
// bar — so the room has to come from inside the row: centre the field in it,
// splitting the row's slack (10pt on iOS 27, 16pt on iOS 26) evenly above and
// below instead of leaving it all at the bottom, through UISearchBar's
// edge-specific content inset override (the SPI UIKit provides for exactly
// this; the field keeps its height). Even, not "as much as possible on top":
// the slack is small, and a field pushed down until it nearly touches the
// content looked just as cramped from the other side. The split is computed
// from the insets UIKit itself resolved for the hosted bar, read while no
// override is active, so each OS keeps its own row.
//
// Timing: the bar's visual provider zeroes its private insets in -prepare
// (and the navigation bar drives the effective-inset recomputation), so an
// override written when the search controller is created is gone by the time
// the bar is hosted. It is applied once the bar is in a window — from the
// UISearchBar didMoveToWindow hook ApolloThemeRuntime.xm already owns — and
// re-applied live when the style changes; every other style hands the insets
// back to UIKit (an empty edge mask). Applied to every nav-bar search bar the
// tweak installs: feed and comments through the native search attach, Settings
// through its own, and the Giphy / theme gallery / AI models / Recently Read
// screens.
static NSHashTable<UISearchBar *> *sApolloHeaderStyleSearchBars;
static char kApolloHeaderStyleSearchBarBaseInsetKey;   // NSValue(UIEdgeInsets): UIKit's own insets

static void ApolloHeaderStyleApplySearchBarInsets(UISearchBar *searchBar) {
    SEL overrideSelector = @selector(_setOverrideContentInsets:forRectEdges:);
    SEL querySelector = @selector(_getOverrideContentInsets:overriddenEdges:);
    SEL effectiveSelector = @selector(_effectiveContentInset);
    SEL refreshSelector = @selector(_updateEffectiveContentInset);
    if (!searchBar || ![searchBar respondsToSelector:overrideSelector] ||
        ![searchBar respondsToSelector:querySelector] ||
        ![searchBar respondsToSelector:effectiveSelector]) return;
    BOOL hard = IsLiquidGlass() && ApolloResolvedScrollEdgeEffectStyle() == ApolloScrollEdgeEffectStyleHard;

    // UIKit's own insets are only readable while nothing overrides them; keep
    // the last such reading as the base the shift is applied to.
    UIEdgeInsets current = UIEdgeInsetsZero;
    NSUInteger overridden = 0;
    ((void (*)(id, SEL, UIEdgeInsets *, NSUInteger *))objc_msgSend)(searchBar, querySelector, &current, &overridden);
    if (overridden == 0) {
        UIEdgeInsets effective = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(searchBar, effectiveSelector);
        objc_setAssociatedObject(searchBar, &kApolloHeaderStyleSearchBarBaseInsetKey,
                                 [NSValue valueWithUIEdgeInsets:effective], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSValue *baseValue = objc_getAssociatedObject(searchBar, &kApolloHeaderStyleSearchBarBaseInsetKey);
    if (hard && !baseValue) return;   // nothing measured yet; the window arrival will
    UIEdgeInsets base = baseValue ? baseValue.UIEdgeInsetsValue : UIEdgeInsetsZero;

    UIEdgeInsets insets = UIEdgeInsetsZero;
    NSUInteger edges = UIRectEdgeNone;   // no edge overridden: UIKit's own insets again
    if (hard) {
        CGFloat slack = MAX(0.0, base.top) + MAX(0.0, base.bottom);
        CGFloat top = round(slack);          // whole points: even split, any odd point below
        top = floor(top / 2.0);
        insets = UIEdgeInsetsMake(top, 0.0, slack - top, 0.0);
        edges = UIRectEdgeTop | UIRectEdgeBottom;
    }
    if (overridden == edges && (edges == UIRectEdgeNone ||
                                (fabs(current.top - insets.top) < 0.01 && fabs(current.bottom - insets.bottom) < 0.01))) {
        return;   // already in place
    }
    ((void (*)(id, SEL, UIEdgeInsets, NSUInteger))objc_msgSend)(searchBar, overrideSelector, insets, edges);
    // The provider stores the override; the navigation bar normally asks for
    // the recomputation, so ask for it here to take effect on this layout.
    if ([searchBar respondsToSelector:refreshSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(searchBar, refreshSelector);
    }
    [searchBar setNeedsLayout];
    ApolloLog(@"[HeaderStyle] search field insets %@: base=(%.1f,%.1f) -> (%.1f,%.1f) edges=%lu on %@",
              hard ? @"centred for Hard" : @"restored", base.top, base.bottom,
              hard ? insets.top : base.top, hard ? insets.bottom : base.bottom,
              (unsigned long)edges, searchBar.placeholder ?: @"");
}

void ApolloHeaderStyleRegisterSearchBar(UISearchBar *searchBar) {
    if (!searchBar || !IsLiquidGlass()) return;
    if (!sApolloHeaderStyleSearchBars) sApolloHeaderStyleSearchBars = [NSHashTable weakObjectsHashTable];
    [sApolloHeaderStyleSearchBars addObject:searchBar];
    if (searchBar.window) ApolloHeaderStyleApplySearchBarInsets(searchBar);
}

void ApolloHeaderStyleSearchBarDidMoveToWindow(UISearchBar *searchBar) {
    if (!searchBar.window || !IsLiquidGlass()) return;
    if (![sApolloHeaderStyleSearchBars containsObject:searchBar]) return;
    ApolloHeaderStyleApplySearchBarInsets(searchBar);
}

// MARK: - Hard: a scroll-away search bar keeps its look while held pinned
//
// The feed and comments search bars scroll away with the list
// (hidesSearchBarWhenScrolling = YES), but they are attached pinned and only
// switched to scroll-away once the screen has appeared: with no large title,
// UIKit lays a scroll-away search bar out collapsed for the push, and the
// field would be missing on arrival (NSBAttachNativeSearch). The same pin
// holds the bar on screen for a few other moments: a re-appearance at the
// top rest, the reveal at the top rest, the teardown after cancelling a
// search, a cancelled swipe back.
//
// Under Hard those pins show (#1361). UIKit draws a pinned search bar as part
// of the bar: the band runs down behind its row, with the band's edge line
// under it, and the field gets a glass background that all but disappears
// against the band. The moment the pin is released the band shrinks back to
// the title row and the field crossfades to its filled background, half a
// second after the push has landed. On a light or tinted theme that reads as
// the search field loading in late; on a black theme as a flash (the row
// stepping from gray to black behind a field that brightens and settles).
// The release can't come earlier: UIKit keeps an item's pinned layout until
// its push completes, and a bar that is scroll-away from the start is laid
// out collapsed for the whole push.
//
// So while such a bar is held pinned under Hard, it keeps the look it will
// have once released:
// - the field is told it is not pinned (-updateIsPinnedInNavigationBar:NO),
//   so it keeps its filled pill instead of turning to glass;
// - a backing view behind the field paints the search row with the list's
//   own background, which is what shows there once the band has shrunk.
// What still changes on release: the band's edge line is UIKit's and stays
// under whatever the band covers, so that 1pt line moves up to the title row;
// and on a freshly pushed screen the placeholder settles a shade dimmer as the
// field takes on UIKit's material, as it does in every style (see the hook).
// UIKit shrinks the band on its next layout pass rather than inside the setter
// that releases the pin, so the backing fades out over a few frames instead of
// leaving the row to the band for one. A release with animations off (a
// cancelled swipe-back's completion runs in performWithoutAnimation) removes
// it at once.
//
// An active search keeps UIKit's own pinned presentation (band behind the
// field); UIKit re-reports the pinned state on every layout of the bar, which
// is where a search starting or ending during a hold is picked up. Soft, Blur
// and Hidden are untouched: without an opaque band the two looks match.
@interface ApolloRuntimeSearchBarVisualProvider : NSObject
- (UISearchBar *)searchBar;
@end

@interface ApolloHeaderStyleHeldSearchBar : NSObject
@property (nonatomic, weak) UISearchBar *searchBar;
@property (nonatomic, weak) UINavigationItem *item;
@property (nonatomic, weak) UIScrollView *backdropScrollView;
@property (nonatomic, strong) UIView *backing;
@property (nonatomic) BOOL lastHeld;
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic) BOOL materialPending;  // a pinned report was answered "not pinned" (see the hook)
@end
@implementation ApolloHeaderStyleHeldSearchBar
@end

static char kApolloHeaderStyleHeldItemKey;   // UINavigationItem -> state
static char kApolloHeaderStyleHeldBarKey;    // UISearchBar -> the same state
static NSHashTable<ApolloHeaderStyleHeldSearchBar *> *sApolloHeaderStyleHeldSearchBars;
// Set once the hooks below install (Liquid Glass, with UIKit's search bar
// provider and its pinned report present). Without them nothing would take a
// backing down again or keep the field's pill, so nothing gets registered.
static BOOL sApolloHeaderStyleHeldSearchBarHooksInstalled;

static BOOL ApolloHeaderStyleHoldsScrollAwayLook(ApolloHeaderStyleHeldSearchBar *state) {
    UISearchBar *searchBar = state.searchBar;
    UINavigationItem *item = state.item;
    if (!searchBar || !item || !IsLiquidGlass()) return NO;
    if (ApolloResolvedScrollEdgeEffectStyle() != ApolloScrollEdgeEffectStyleHard) return NO;
    UISearchController *searchController = item.searchController;
    if (searchController.searchBar != searchBar || searchController.active) return NO;
    if (item.hidesSearchBarWhenScrolling) return NO;   // not held: UIKit's look already matches
    // No band behind the bar (a visible profile hero hides it): nothing to
    // match, and the backing would paint over the hero. An edge effect that
    // can't be read (the list is gone) counts the same: UIKit's look stays.
    UIScrollView *backdrop = state.backdropScrollView;
    id effect = ApolloSendObject(backdrop, @selector(topEdgeEffect));
    if (![effect respondsToSelector:@selector(isHidden)] ||
        ((BOOL (*)(id, SEL))objc_msgSend)(effect, @selector(isHidden))) return NO;
    return YES;
}

// The list's background, as it shows through the search row once the band
// has shrunk. Only an opaque color can stand in for it.
static UIColor *ApolloHeaderStyleHeldBackingColor(ApolloHeaderStyleHeldSearchBar *state) {
    UIColor *color = state.backdropScrollView.backgroundColor;
    if (!color) return nil;
    UIColor *resolved = [color resolvedColorWithTraitCollection:state.searchBar.traitCollection];
    return CGColorGetAlpha(resolved.CGColor) >= 0.99 ? color : nil;
}

static void ApolloHeaderStyleUpdateHeldSearchBar(ApolloHeaderStyleHeldSearchBar *state) {
    UISearchBar *searchBar = state.searchBar;
    if (!searchBar) return;
    BOOL held = ApolloHeaderStyleHoldsScrollAwayLook(state);
    BOOL wasHeld = state.lastHeld;
    state.lastHeld = held;
    UIColor *color = held ? ApolloHeaderStyleHeldBackingColor(state) : nil;
    UIView *backing = state.backing;
    if (color) {
        if (!backing) {
            backing = [[UIView alloc] initWithFrame:searchBar.bounds];
            backing.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            backing.userInteractionEnabled = NO;
            state.backing = backing;
        }
        [backing.layer removeAllAnimations];
        backing.alpha = 1.0;
        backing.backgroundColor = color;
        if (backing.superview != searchBar) {
            backing.frame = searchBar.bounds;
            [searchBar insertSubview:backing atIndex:0];
        }
    } else if (backing) {
        state.backing = nil;
        if (backing.window && [UIView areAnimationsEnabled]) {
            [UIView animateWithDuration:0.2 delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{ backing.alpha = 0.0; }
                             completion:^(__unused BOOL finished) { [backing removeFromSuperview]; }];
        } else {
            [backing removeFromSuperview];
        }
    }
    if (held != wasHeld) {
        ApolloLog(@"[HeaderStyle] scroll-away search bar %@ (%@): backing=%d",
                  held ? @"held pinned, keeping its scroll-away look" : @"released",
                  searchBar.placeholder ?: @"", (int)(state.backing != nil));
    }
}

void ApolloHeaderStyleRegisterScrollAwaySearchBar(UISearchBar *searchBar, UINavigationItem *item,
                                                  UIScrollView *backdropScrollView) {
    if (!searchBar || !item || !sApolloHeaderStyleHeldSearchBarHooksInstalled) return;
    ApolloHeaderStyleHeldSearchBar *state = objc_getAssociatedObject(item, &kApolloHeaderStyleHeldItemKey);
    if (!state || state.searchBar != searchBar) {
        state = [ApolloHeaderStyleHeldSearchBar new];
        objc_setAssociatedObject(item, &kApolloHeaderStyleHeldItemKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(searchBar, &kApolloHeaderStyleHeldBarKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sApolloHeaderStyleHeldSearchBars) sApolloHeaderStyleHeldSearchBars = [NSHashTable weakObjectsHashTable];
        [sApolloHeaderStyleHeldSearchBars addObject:state];
    }
    state.searchBar = searchBar;
    state.item = item;
    state.backdropScrollView = backdropScrollView;
    ApolloHeaderStyleUpdateHeldSearchBar(state);
}

static void ApolloApplyScrollEdgeEffectStyleToAllScrollViews(void) {
    // Registered bars on screen first; the ones off screen pick the style up
    // when they next enter a window.
    for (UISearchBar *searchBar in sApolloHeaderStyleSearchBars) {
        if (searchBar.window) ApolloHeaderStyleApplySearchBarInsets(searchBar);
    }
    for (ApolloHeaderStyleHeldSearchBar *state in sApolloHeaderStyleHeldSearchBars.allObjects) {
        ApolloHeaderStyleUpdateHeldSearchBar(state);
    }
    for (UIWindow *window in ApolloAllWindows()) {
        ApolloApplyAndNudgeViewTree(window);
    }
    // Also release effects on detached/cached controllers when Minimize is
    // disabled. The weak registry does not keep those controllers alive.
    for (ApolloMinimizeBottomEdgeState *state in sApolloMinimizeBottomEdges.allObjects) {
        ApolloRefreshMinimizeBottomEdge(state);
    }
    // The rebuild that runs in the same turn as an un-hide/style change can
    // compute pocket geometry from mid-change state (observed: hard band
    // missing its status-bar cover until the next scroll tick). A second
    // nudge on the next runloop turn recomputes from settled geometry.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloNudgeViewTree(window);
        }
    });
}

// A one-shot UIScrollView lifecycle update is not sufficient on iOS 27. UIKit
// configures some edge effects after didMoveToWindow and may later restore its
// new hard default while navigation chrome changes. SwiftUI solves this through
// an inherited environment value on NavigationStack; Apollo is UIKit, so the
// equivalent app-wide enforcement point is UIScrollEdgeEffect's setters. Both
// Header style hooks act only on stamped top effects. Minimize's separate bottom
// lease records UIKit's latest visibility request while temporarily hiding it.
%group ApolloScrollEdgeEffectRuntimeHooks

%hook ApolloRuntimeScrollEdgeEffect

- (void)setStyle:(id)style {
    NSInteger mode = ApolloResolvedScrollEdgeEffectStyle();
    id selectedStyle = style;
    if (IsLiquidGlass() &&
        objc_getAssociatedObject(self, &kApolloScrollEdgeEffectIsTopKey) &&
        (mode == ApolloScrollEdgeEffectStyleSoft || mode == ApolloScrollEdgeEffectStyleHard)) {
        selectedStyle = ApolloScrollEdgeEffectStyleObjectForMode(mode) ?: style;
        if (!sLoggedScrollEdgeEffectSetterOverride) {
            sLoggedScrollEdgeEffectSetterOverride = YES;
            ApolloLog(@"[HeaderStyle] enforcing mode=%ld for UIKit top-edge updates proposed=%@ selected=%@",
                      (long)mode, style, selectedStyle);
        }
    }
    %orig(selectedStyle);
}

- (void)setHidden:(BOOL)hidden {
    ApolloMinimizeBottomEdgeState *bottom = ApolloMinimizeBottomEdgeEnabled()
        ? objc_getAssociatedObject(self, &kApolloMinimizeBottomEdgeStateKey) : nil;
    if (bottom && !bottom.writingHidden) {
        bottom.nativeHidden = hidden;
        %orig(ApolloMinimizeOwnsBottomEdge(bottom.scrollView) || hidden);
        return;
    }
    NSInteger mode = ApolloResolvedScrollEdgeEffectStyle();
    BOOL hideForHero = mode == ApolloScrollEdgeEffectStyleHard &&
        [objc_getAssociatedObject(self, &kApolloEdgeHasVisibleProfileHeroKey) boolValue];
    if (IsLiquidGlass() &&
        (ApolloHeaderStyleHidesNativeEffect(mode) || hideForHero) &&
        objc_getAssociatedObject(self, &kApolloScrollEdgeEffectIsTopKey)) {
        if (!hidden) {
            // The caller wanted it visible and we are overriding — exactly the
            // change the restore path should undo later.
            objc_setAssociatedObject(self, &kApolloScrollEdgeEffectForcedHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // hidden == YES with our force stamp present is a re-assertion of the
        // hide WE created — the apply pass's own setHidden:YES routes through
        // this very hook, and clearing the stamp here erased the restore
        // record the moment it was written, leaving effects stuck hidden
        // after switching away from Blur/Hidden.
        // hidden == YES with no stamp is UIKit/Apollo's own intent: leave it
        // unstamped so restore never un-hides an edge they keep disabled. If
        // UIKit genuinely wants an edge hidden while our stamp exists, it will
        // simply re-hide it after the restore — self-correcting, unlike a
        // stuck-hidden header.
        %orig(YES);
        return;
    }
    %orig(hidden);
}

%end

%end

// Hard's held scroll-away search bars (see the MARK above): the policy setter
// is where a hold starts and ends; the provider's pinned report, sent on
// every layout of the bar, keeps the field's filled background while held.
%group ApolloHeaderStyleHeldSearchBarHooks

%hook UINavigationItem

- (void)setHidesSearchBarWhenScrolling:(BOOL)hidesSearchBarWhenScrolling {
    %orig;
    ApolloHeaderStyleHeldSearchBar *state = objc_getAssociatedObject(self, &kApolloHeaderStyleHeldItemKey);
    if (state) ApolloHeaderStyleUpdateHeldSearchBar(state);
}

%end

%hook ApolloRuntimeSearchBarVisualProvider

- (void)updateIsPinnedInNavigationBar:(BOOL)pinned {
    UISearchBar *searchBar = [self searchBar];
    ApolloHeaderStyleHeldSearchBar *state = searchBar
        ? objc_getAssociatedObject(searchBar, &kApolloHeaderStyleHeldBarKey) : nil;
    if (!state) {
        %orig;
        return;
    }
    BOOL held = ApolloHeaderStyleHoldsScrollAwayLook(state);
    if (pinned && held) {
        state.materialPending = YES;
        %orig(NO);
    } else {
        // A released field draws its pill through UIKit's dynamic background
        // material, a layer UIKit wraps around the field when the pinned state
        // changes after the bar is hosted. A bar held from the moment it was
        // attached never saw that change and still has the plain fill it was
        // created with. That fill is what keeps the pill visible while the
        // screen slides in (the push shows the bar through a portal, which
        // draws a plain fill but not the material), but its placeholder reads
        // brighter than a released bar's. So once the hold is over, run the
        // change through glass inside this same pass: the field lands on the
        // released material, with nothing drawn in between.
        if (!pinned && state.materialPending) {
            UITextField *field = searchBar.searchTextField;
            CALayer *superlayer = field.layer.superlayer;
            BOOL hasMaterial = field.superview && superlayer && superlayer != field.superview.layer;
            if (hasMaterial) {
                state.materialPending = NO;
            } else if (field.window) {
                state.materialPending = NO;
                %orig(YES);
            }
        }
        %orig;
    }
    // This arrives from the bar's layout pass: keep the backing's color in
    // step (a plain property, not a layout input), and leave adding or
    // removing it for a search that started or ended during the hold to the
    // next turn instead of changing the view tree inside the pass.
    UIView *backing = state.backing;
    UIColor *color = backing ? state.backdropScrollView.backgroundColor : nil;
    if (color && ![backing.backgroundColor isEqual:color]) backing.backgroundColor = color;
    if (held != state.lastHeld && !state.refreshScheduled) {
        state.refreshScheduled = YES;
        __weak ApolloHeaderStyleHeldSearchBar *weakState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloHeaderStyleHeldSearchBar *current = weakState;
            if (!current) return;
            current.refreshScheduled = NO;
            ApolloHeaderStyleUpdateHeldSearchBar(current);
        });
    }
}

%end

%end

%ctor {
    Class edgeEffectClass = objc_getClass("UIScrollEdgeEffect");
    if (edgeEffectClass) {
        %init(ApolloScrollEdgeEffectRuntimeHooks,
              ApolloRuntimeScrollEdgeEffect = edgeEffectClass);
    }
    Class searchProviderClass = objc_getClass("_UISearchBarVisualProviderIOS");
    if (IsLiquidGlass() && searchProviderClass &&
        class_getInstanceMethod(searchProviderClass, @selector(updateIsPinnedInNavigationBar:)) &&
        class_getInstanceMethod(searchProviderClass, @selector(searchBar))) {
        %init(ApolloHeaderStyleHeldSearchBarHooks,
              ApolloRuntimeSearchBarVisualProvider = searchProviderClass);
        sApolloHeaderStyleHeldSearchBarHooksInstalled = YES;
        ApolloLog(@"[HeaderStyle] held scroll-away search bar hooks installed");
    } else if (IsLiquidGlass()) {
        ApolloLog(@"[HeaderStyle] held scroll-away search bar hooks NOT installed: provider/selectors missing");
    }
    ApolloLog(@"[HeaderStyle] module loaded, mode=%ld liquidGlass=%d", (long)sScrollEdgeEffectStyle, IsLiquidGlass());
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloScrollEdgeEffectStyleChangedNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(__unused NSNotification *notification) {
        ApolloApplyScrollEdgeEffectStyleToAllScrollViews();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloTabBarScrollBehaviorChangedNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            ApolloApplyScrollEdgeEffectStyleToAllScrollViews();
        }];
}
