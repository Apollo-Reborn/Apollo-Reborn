#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

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
// Only the top edge is ever touched. Earlier builds applied the chosen style
// to all four edges, which painted a hard band behind the tab bar in Hard
// mode; the bottom/left/right edges now always keep the system's treatment.
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
    Class styleClass = objc_getClass("UIScrollEdgeEffectStyle");
    if (!styleClass) return nil;

    SEL selector;
    switch (mode) {
        case ApolloScrollEdgeEffectStyleSoft: selector = NSSelectorFromString(@"softStyle"); break;
        case ApolloScrollEdgeEffectStyleHard: selector = NSSelectorFromString(@"hardStyle"); break;
        default: selector = NSSelectorFromString(@"automaticStyle"); break;
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

static void ApolloApplyHeaderStyleToTopEdge(UIScrollView *scrollView, NSInteger mode) {
    SEL topSelector = NSSelectorFromString(@"topEdgeEffect");
    if (![scrollView respondsToSelector:topSelector]) return;
    id effect = ((id (*)(id, SEL))objc_msgSend)(scrollView, topSelector);
    if (!effect) return;

    objc_setAssociatedObject(effect, &kApolloScrollEdgeEffectIsTopKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL setHiddenSelector = NSSelectorFromString(@"setHidden:");
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
            SEL isHiddenSelector = NSSelectorFromString(@"isHidden");
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
        SEL setStyleSelector = NSSelectorFromString(@"setStyle:");
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
    SEL overrideSelector = NSSelectorFromString(@"_setOverrideContentInsets:forRectEdges:");
    SEL querySelector = NSSelectorFromString(@"_getOverrideContentInsets:overriddenEdges:");
    SEL effectiveSelector = NSSelectorFromString(@"_effectiveContentInset");
    SEL refreshSelector = NSSelectorFromString(@"_updateEffectiveContentInset");
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

static void ApolloApplyScrollEdgeEffectStyleToAllScrollViews(void) {
    // Registered bars on screen first; the ones off screen pick the style up
    // when they next enter a window.
    for (UISearchBar *searchBar in sApolloHeaderStyleSearchBars) {
        if (searchBar.window) ApolloHeaderStyleApplySearchBarInsets(searchBar);
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        ApolloApplyAndNudgeViewTree(window);
    }
    // The rebuild that runs in the same turn as an un-hide/style change can
    // compute pocket geometry from mid-change state (observed: hard band
    // missing its status-bar cover until the next scroll tick). A second
    // nudge on the next runloop turn recomputes from settled geometry.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            ApolloNudgeViewTree(window);
        }
    });
}

// A one-shot UIScrollView lifecycle update is not sufficient on iOS 27. UIKit
// configures some edge effects after didMoveToWindow and may later restore its
// new hard default while navigation chrome changes. SwiftUI solves this through
// an inherited environment value on NavigationStack; Apollo is UIKit, so the
// equivalent app-wide enforcement point is UIScrollEdgeEffect's setters. Both
// hooks act only on effects stamped as top-edge by the apply pass — bottom and
// horizontal edges always keep whatever UIKit wants.
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
    if (IsLiquidGlass() &&
        ApolloHeaderStyleHidesNativeEffect(ApolloResolvedScrollEdgeEffectStyle()) &&
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

%ctor {
    Class edgeEffectClass = objc_getClass("UIScrollEdgeEffect");
    if (edgeEffectClass) {
        %init(ApolloScrollEdgeEffectRuntimeHooks,
              ApolloRuntimeScrollEdgeEffect = edgeEffectClass);
    }
    ApolloLog(@"[HeaderStyle] module loaded, mode=%ld liquidGlass=%d", (long)sScrollEdgeEffectStyle, IsLiquidGlass());
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloScrollEdgeEffectStyleChangedNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(__unused NSNotification *notification) {
        ApolloApplyScrollEdgeEffectStyleToAllScrollViews();
    }];
}
