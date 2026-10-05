// ApolloPixelPals
//
// Pixel Pals fixes: Dynamic Island geometry for devices newer than the iPhone 14
// Pro, the menu freeze guard (issue #305), and the Carrot Weather pal unlock.
//
// --- Dynamic Island geometry ---
// Apollo only knows the iPhone 14 Pro island. One helper (sub_10030afa0) returns
// the pill as (y, width, height) = (11.5, 125, 37) for every DI device (Display
// Zoom has its own smaller table), and every Pixel Pals element is laid out
// from it:
//   - FauxCutOutView (the black pill, which also draws the pal's name tag):
//     frame ((W - 125) / 2, 11.5, 125, 37), set on every portrait layout
//     (sub_10030c638 from -[ThemeableWindow layoutSubviews]).
//   - PixelPalView (the SKView strip the pals walk along): frame
//     ((W - 125) / 2, -2, 125, 14), same layout pass. The PixelPalScene is sized
//     from it right after (setSize: with the strip's frame size), and the pal's
//     walking range is the scene width. The scene's didChangeSize:
//     (sub_100049e20) re-centres the pal whenever the size changes, so the
//     strip must never flip between widths across layouts.
//   - Tap flash overlay (sub_10030d6c4): plain UIView, 125x37 at y=11, corner 18.5.
//   - PixelPalAddedSceneElementImageView (hearts, food, meatbag/gurgle emotes;
//     sub_10004c110, sub_10004e3f4, sub_10004e698, sub_10005470c): added to the
//     window at x = (W - 125) / 2 + <pal node x in scene coords>.
//   - UIDynamics: a UICollisionBehavior boundary "cutoutBoundary", rounded rect
//     ((W - 125) / 2, 12, 125, 37), that dropped food falls onto (sub_100052964);
//     and a straight floor of the same name, (0, 13.5) → (W, 13.5)
//     (sub_1000531dc), that the ball game rolls the ball along (sub_1000511a4).
//   - Wand minigame (sub_1002d261c): maps a SwiftUI drag x into scene x as
//     clamp(x - (W - 125) / 2, 0, 125). Pure Swift with no ObjC entry point, so
//     it is left alone; on a narrower island the wand zones are offset by
//     (125 - islandWidth) / 2.
//
// The island's real rect varies per device and per iOS release (issue #826:
// iPhone Air on iOS 27 kept the island in place while the safe area grew), and
// the iPhone 18 Pro / Pro Max island is much narrower than the 14 Pro's (94.667
// x 36.667 at y=14 on iOS 27; issue #1238: Apollo's 125pt pill bridged the gap
// between two split live activities). So instead of a per-device table we read
// the physical cutout the same way UIKit's status bar does
// (-[_UIStatusBarVisualProvider_DynamicSplit sensorAreaRect]:
// -[UIScreen _exclusionArea].rect scaled by nativeScale/scale) and remap every
// element above from Apollo's pill onto it: the pill takes the island's rect
// exactly, each edge on a whole physical pixel. Islands are 36.667pt tall (16
// Pro and 18 Pro alike), so centring Apollo's 37pt pill on them — the #826
// approach — left its top one pixel above the cutout. An island reported
// clearly wider than Apollo's pill (> 4pt, only plausible as a bad Display Zoom
// conversion) falls back to that vertical centring, so nothing ever widens.
// Frames are rewritten as Apollo writes them (setFrame: / addSubview: /
// addBoundaryWithIdentifier:forPath:), never after the fact, so the strip and
// scene only ever see the corrected size.
//
// The pals walk the island's width, not a live activity's: the app has no view
// of the live island. SpringBoard draws the status bar and live activities, and
// the only island rect it shares with apps (UIApplicationSceneSettings
// .statusBarAvoidanceFrame) is a fixed camera keep-out zone — {163, 0, 76, 54}
// on the 18 Pro with zero, one, or two live activities alike.
//
// --- Freeze guard (issue #305) ---
// Tapping the Dynamic Island Pixel Pals area (pixelPalTappedWithTapGestureRecognizer:)
// or a pal barking for attention (dogBarkedWithNotification:) both present the
// PixelPalOverlayViewController on the *topmost* currently-presented view
// controller — Apollo's presenter (sub_1002cd660) walks rootViewController's
// presentedViewController chain to the end and presents there. When a fullscreen
// media viewer or the in-app web browser is open — especially mid-interactive
// swipe-dismiss — that races the in-flight transition: the overlay is presented
// onto a controller that is being torn down, leaving an orphaned fullscreen
// transition view that swallows every touch. The app looks frozen (the video's
// audio keeps playing underneath) and has to be force-quit.
//
// Fix: refuse to open the Pixel Pals menu whenever any non-Pixel-Pals modal is
// presented, or any present/dismiss transition is in flight, anywhere in the
// window's view-controller chain. This matches the reporters' own diagnosis
// ("preventing the pixel pal menu from opening with any media or website open
// should fix everything") and is a strict superset of Apollo's intended
// behaviour (the menu is already meant to be unreachable while media is open).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

#import "ApolloCommon.h"
#import "palhome/ApolloPalHomeViewController.h"
#import "palhome/ApolloPalHomeChatHead.h"
#import "palhome/ApolloPixelPalCoats.h"
#import "palhome/ApolloPalHomeStore.h"
#import "palhome/ApolloPalSpecies.h"
#import "palhome/ApolloRebornPalSprites.h"
#import "palhome/ApolloPalHomePrompt.h"
#import <SpriteKit/SpriteKit.h>

// Apollo's stock strip height (sub_10030c494) and y (sub_10030c880).
static const CGFloat kApolloPalStripHeight = 14.0;
static const CGFloat kApolloPalStripY = -2.0;
// Stock (non-zoomed) pill and tap-flash sizes. The tap flash hardcodes these
// even under Display Zoom, where the pill itself is smaller.
static const CGFloat kApolloStockPillWidth = 125.0;
static const CGFloat kApolloStockPillHeight = 37.0;
static const CGFloat kApolloStockPillY = 11.5;
// Follow the island unless it comes back clearly wider than Apollo's pill.
static const CGFloat kApolloIslandWidenSlack = 4.0;

// Apollo's own pill rect, captured from the frame it writes to FauxCutOutView.
// Every other element's stock position is derived from the same helper, so this
// is the baseline all remaps are measured against. Main thread only.
static CGRect sApolloPill;
static BOOL sApolloPillKnown = NO;

#pragma mark - Geometry

// Reads the physical Dynamic Island cutout rect in the app's logical
// coordinate space via -[UIScreen _exclusionArea] (private, island devices
// only — nil on notch/older hardware). This is the exact source and
// conversion UIKit's status bar uses, so it tracks new devices and iOS
// releases without a per-device table.
static BOOL ApolloDynamicIslandRect(CGRect *outRect) {
    UIScreen *screen = [UIScreen mainScreen];
    SEL exclusionSel = NSSelectorFromString(@"_exclusionArea");
    if (![screen respondsToSelector:exclusionSel]) return NO;
    id area = ((id (*)(id, SEL))objc_msgSend)(screen, exclusionSel);
    SEL rectSel = NSSelectorFromString(@"rect");
    if (!area || ![area respondsToSelector:rectSel]) return NO;
    CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(area, rectSel);
    // Mirror -[_UIStatusBarVisualProvider_DynamicSplit sensorAreaRect]'s
    // conversion into the current (Display Zoom) coordinate space.
    CGFloat nativeScale = screen.nativeScale;
    CGFloat scale = screen.scale;
    if (nativeScale > 0 && scale > 0 && nativeScale != scale) {
        CGFloat zoom = nativeScale / scale;
        rect.origin.x *= zoom;
        rect.origin.y *= zoom;
        rect.size.width *= zoom;
        rect.size.height *= zoom;
    }
    // Sanity: a small pill near the top of the screen, or the API changed.
    if (CGRectIsEmpty(rect) ||
        rect.origin.y < 0.0 || rect.origin.y > 40.0 ||
        rect.size.height < 20.0 || rect.size.height > 60.0 ||
        rect.size.width < 60.0 || rect.size.width > CGRectGetWidth(screen.bounds) * 0.6) {
        static dispatch_once_t rejectOnce;
        dispatch_once(&rejectOnce, ^{
            ApolloLog(@"[PixelPals] island cutout {%.3f, %.3f, %.3f, %.3f} failed sanity check — ignoring",
                      rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        });
        return NO;
    }
    *outRect = rect;
    return YES;
}

static CGFloat ApolloNativeScale(void) {
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    return nativeScale > 0 ? nativeScale : 3.0;
}

// Rounds each edge (not origin + size) to the nearest physical pixel, so the
// pill's top and bottom land on the same pixel rows as the island.
static CGRect ApolloPixelAlignedRect(CGRect rect) {
    // Work in whole pixels and divide once, so a 375px width comes out as exactly
    // 125pt rather than 263.333 - 138.333 = 125.00000000000001.
    CGFloat s = ApolloNativeScale();
    CGFloat minX = round(CGRectGetMinX(rect) * s);
    CGFloat minY = round(CGRectGetMinY(rect) * s);
    CGFloat maxX = round(CGRectGetMaxX(rect) * s);
    CGFloat maxY = round(CGRectGetMaxY(rect) * s);
    return CGRectMake(minX / s, minY / s, (maxX - minX) / s, (maxY - minY) / s);
}

// The real machine identifier. uname() is remapped in Tweak.xm (newer models
// pose as an iPhone 14 Pro for Apollo's device mapper), so read sysctl for logs.
static NSString *ApolloRealMachineIdentifier(void) {
    char machine[64] = {0};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0) return @"?";
    return @(machine);
}

static NSString *ApolloRectString(CGRect r) {
    return [NSString stringWithFormat:@"{%.3f, %.3f, %.3f, %.3f}", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

// Maps Apollo's pill onto this device's island. Returns NO (leave Apollo's
// layout untouched) until the pill has been captured, or when no correction is
// needed.
static BOOL ApolloPixelPalGeometry(UIWindow *window, CGRect *outApollo, CGRect *outPill) {
    if (!sApolloPillKnown) return NO;
    CGRect apollo = sApolloPill;
    CGRect pill = apollo;
    CGFloat halfPx = 0.5 / ApolloNativeScale();

    CGRect island;
    BOOL haveIsland = ApolloDynamicIslandRect(&island);
    if (haveIsland && CGRectGetWidth(island) <= CGRectGetWidth(apollo) + kApolloIslandWidenSlack) {
        // Take the island rect as-is, each edge on a whole physical pixel. Every
        // island measured so far is 36.667pt tall (16 Pro: {138.333, 14, 125,
        // 36.667}; 18 Pro: {153.667, 14, 94.667, 36.667}), so Apollo's 37pt pill
        // always overhangs it somewhere.
        pill = ApolloPixelAlignedRect(island);
    } else if (haveIsland) {
        // The island came back clearly wider than Apollo's pill — only seen as a
        // suspect Display Zoom conversion. Never widen: keep Apollo's size and
        // centre it on the cutout, floored to the half-pixel grid Apollo's own
        // 11.5 sits on. Within a half-point of Apollo's y is left untouched.
        CGFloat correctY = floor((CGRectGetMidY(island) - CGRectGetHeight(pill) / 2.0) / halfPx) * halfPx;
        if (fabs(correctY - CGRectGetMinY(apollo)) >= 0.75) pill.origin.y = correctY;
    } else if (window &&
               [UIScreen mainScreen].nativeScale == [UIScreen mainScreen].scale &&
               fabs(CGRectGetMinY(apollo) - kApolloStockPillY) < 0.25 &&
               fabs(CGRectGetHeight(apollo) - kApolloStockPillHeight) < 0.25) {
        // Fallback (private API gone): proportional model — gap between DI
        // bottom and safe area scales with safeTop. Wrong on devices where the
        // safe area moved independently of the island (#826), but better than
        // nothing. Vertical only; there is no public source for the width.
        CGFloat safeTop = window.safeAreaInsets.top;
        if (safeTop >= 50.0 && fabs(safeTop - 59.0) >= 0.5) {
            CGFloat scaledGap = 10.5 * safeTop / 59.0;
            pill.origin.y = floor((safeTop - kApolloStockPillHeight - scaledGap) / halfPx) * halfPx;
        }
    }

    // One log line per distinct result, so a device test shows exactly what
    // was measured and what the pals were mapped onto.
    static NSString *lastLogged;
    NSString *summary = [NSString stringWithFormat:
        @"machine=%@ island=%@ apollo=%@ → pill=%@ scale=%.2f/%.2f",
        ApolloRealMachineIdentifier(),
        haveIsland ? ApolloRectString(island) : @"(unavailable)",
        ApolloRectString(apollo), ApolloRectString(pill),
        [UIScreen mainScreen].nativeScale, [UIScreen mainScreen].scale];
    if (![summary isEqualToString:lastLogged]) {
        lastLogged = summary;
        ApolloLog(@"[PixelPals] geometry %@", summary);
    }

    if (CGRectEqualToRect(apollo, pill)) return NO;
    if (outApollo) *outApollo = apollo;
    if (outPill) *outPill = pill;
    return YES;
}

static UIWindow *ApolloPixelPalWindowForView(UIView *view) {
    if ([view isKindOfClass:[UIWindow class]]) return (UIWindow *)view;
    return view.window;
}

#pragma mark - Pill and pal strip

// The pill's "SIR SOAKS / the otter" caption. Apollo keeps it in
// FauxCutOutView.nameTag, a (name: String, title: String) tuple, set in
// sub_10030bae8 from PixelPal's title switch (sub_10074a6a8) and drawn in
// -drawRect:. The name is right already (the borrowed slot's record carries
// the guest's name); the title is the host species', so a Reborn guest gets
// its own. Only ever swaps one *small* ASCII Swift string (<= 15 bytes,
// stored inline in the two words, nothing to retain/release) for another.
typedef struct { uint64_t lo, hi; } ApolloSwiftString;

static BOOL ApolloSwiftSmallString(NSString *text, ApolloSwiftString *out) {
    NSData *bytes = [text dataUsingEncoding:NSASCIIStringEncoding];
    if (!bytes || bytes.length > 15) return NO;
    uint8_t raw[16] = {0};
    memcpy(raw, bytes.bytes, bytes.length);
    raw[15] = (uint8_t)(0xE0 | bytes.length); // small + ASCII, count
    memcpy(out, raw, 16);
    return YES;
}

static void ApolloPalRetitleNameTag(UIView *view) {
    NSDictionary<NSString *, NSString *> *channel = [ApolloPalHomeStore islandChannel];
    if (!channel) return;
    static Ivar nameTag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ nameTag = class_getInstanceVariable(object_getClass(view), "nameTag"); });
    if (!nameTag) return;
    ApolloSwiftString hostTitle, guestTitle;
    // Apollo's own title for the host (see APSpecies: the 9 host titles match).
    if (!ApolloSwiftSmallString([APSpecies speciesWithID:channel[@"host"]].title ?: @"", &hostTitle) ||
        !ApolloSwiftSmallString([APSpecies speciesWithID:channel[@"species"]].title ?: @"", &guestTitle)) return;
    ApolloSwiftString *title = (ApolloSwiftString *)((uint8_t *)(__bridge void *)view + ivar_getOffset(nameTag) + sizeof(ApolloSwiftString));
    if (title->lo == hostTitle.lo && title->hi == hostTitle.hi) *title = guestTitle;
}

%hook _TtC6Apollo14FauxCutOutView

- (void)drawRect:(CGRect)rect {
    ApolloPalRetitleNameTag((UIView *)self);
    %orig;
}

// Apollo writes the stock pill here on every portrait layout. Capture it as the
// baseline, then hand UIKit the island-aligned pill instead.
- (void)setFrame:(CGRect)frame {
    BOOL plausiblePill = CGRectGetWidth(frame) >= 60.0 && CGRectGetWidth(frame) <= 200.0 &&
                         CGRectGetHeight(frame) >= 20.0 && CGRectGetHeight(frame) <= 60.0 &&
                         CGRectGetMinY(frame) >= 0.0 && CGRectGetMinY(frame) <= 40.0;
    if (!plausiblePill) {
        %orig;
        return;
    }

    // A write of our own target back (e.g. frame = frame) is not Apollo's pill.
    static CGRect sLastPill;
    static BOOL sHaveLastPill = NO;
    if (sHaveLastPill && CGRectEqualToRect(frame, sLastPill)) {
        %orig;
        return;
    }

    if (!sApolloPillKnown || !CGRectEqualToRect(frame, sApolloPill)) {
        sApolloPill = frame;
        sApolloPillKnown = YES;
        ApolloLog(@"[PixelPals] captured Apollo pill %@", ApolloRectString(frame));
    }

    UIView *view = (UIView *)self;
    CGRect pill;
    if (ApolloPixelPalGeometry(ApolloPixelPalWindowForView(view.superview), NULL, &pill)) {
        sLastPill = pill;
        sHaveLastPill = YES;
        %orig(pill);
        // Clip to continuous (squircle) corners to match the hardware island.
        // drawRect: fills a plain rounded rect sized from bounds, so this only
        // trims its corners.
        view.clipsToBounds = YES;
        view.layer.cornerRadius = CGRectGetHeight(pill) * 0.5;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        return;
    }
    %orig;
}

%end

%hook _TtC6Apollo12PixelPalView

// The strip the pals walk along. Apollo sizes it to the pill width and centres
// it on the window; follow the pill so the pals stay on top of the real island.
// PixelPalScene is resized from this frame right after.
- (void)setFrame:(CGRect)frame {
    CGRect apollo, pill;
    UIView *view = (UIView *)self;
    if (fabs(CGRectGetHeight(frame) - kApolloPalStripHeight) < 0.5 &&
        ApolloPixelPalGeometry(ApolloPixelPalWindowForView(view.superview), &apollo, &pill) &&
        fabs(CGRectGetWidth(frame) - CGRectGetWidth(apollo)) < 0.5) {
        CGRect fixed = frame;
        fixed.size.width = CGRectGetWidth(pill);
        if (fabs(CGRectGetMinX(frame) - CGRectGetMinX(apollo)) < 0.5) {
            fixed.origin.x = CGRectGetMinX(pill);
        }
        if (fabs(CGRectGetMinY(frame) - kApolloPalStripY) < 0.5) {
            fixed.origin.y = kApolloPalStripY + (CGRectGetMinY(pill) - CGRectGetMinY(apollo));
        }
        static CGRect sLastLogged;
        if (!CGRectEqualToRect(fixed, frame) && !CGRectEqualToRect(fixed, sLastLogged)) {
            sLastLogged = fixed;
            ApolloLog(@"[PixelPals] PixelPalView %@ → %@", ApolloRectString(frame), ApolloRectString(fixed));
        }
        %orig(fixed);
        return;
    }
    %orig;
}

%end

#pragma mark - Food and ball collision boundaries

%hook UICollisionBehavior

// Dropped food falls onto the island (sub_100052964): a rounded-rect boundary
// ((W - pillWidth) / 2, 12, pillWidth, pillHeight) in window coordinates.
- (void)addBoundaryWithIdentifier:(id<NSCopying>)identifier forPath:(UIBezierPath *)bezierPath {
    CGRect apollo, pill;
    if ([(id)identifier isKindOfClass:[NSString class]] &&
        [(NSString *)identifier isEqualToString:@"cutoutBoundary"] &&
        ApolloPixelPalGeometry(nil, &apollo, &pill)) {
        CGRect bounds = bezierPath.bounds;
        CGRect fixed = CGRectMake(CGRectGetMinX(pill),
                                  CGRectGetMinY(bounds) + (CGRectGetMinY(pill) - CGRectGetMinY(apollo)),
                                  CGRectGetWidth(pill),
                                  CGRectGetHeight(pill));
        ApolloLog(@"[PixelPals] cutoutBoundary %@ → %@", ApolloRectString(bounds), ApolloRectString(fixed));
        %orig(identifier, [UIBezierPath bezierPathWithRoundedRect:fixed cornerRadius:CGRectGetHeight(fixed) * 0.5]);
        return;
    }
    %orig;
}

// The ball game (sub_1000511a4) rolls the ball along a straight floor with the
// same identifier: (0, y) → (W, y), y from sub_1000531dc — 13.5 on DI devices,
// 2pt below Apollo's pill top so the ball sits slightly into the island. Keep
// that relationship with the moved pill, or the ball floats above it.
- (void)addBoundaryWithIdentifier:(id<NSCopying>)identifier fromPoint:(CGPoint)p1 toPoint:(CGPoint)p2 {
    CGRect apollo, pill;
    if ([(id)identifier isKindOfClass:[NSString class]] &&
        [(NSString *)identifier isEqualToString:@"cutoutBoundary"] &&
        ApolloPixelPalGeometry(nil, &apollo, &pill)) {
        CGFloat dy = CGRectGetMinY(pill) - CGRectGetMinY(apollo);
        CGPoint fixed1 = CGPointMake(p1.x, p1.y + dy);
        CGPoint fixed2 = CGPointMake(p2.x, p2.y + dy);
        ApolloLog(@"[PixelPals] ball floor y %.3f → %.3f (x %.1f…%.1f)", p1.y, fixed1.y, p1.x, p2.x);
        %orig(identifier, fixed1, fixed2);
        return;
    }
    %orig;
}

%end

#pragma mark - Window: tap flash, scene elements, freeze guard

static BOOL ApolloPixelPalsBlockedByModal(UIWindow *window) {
    Class overlayCls = objc_getClass("_TtC6Apollo29PixelPalOverlayViewController");
    UIViewController *vc = window.rootViewController;
    while (vc) {
        UIViewController *presented = vc.presentedViewController;
        if (!presented) break;  // nothing modally presented here — safe to open
        // A modal present/dismiss is animating at this level — the mid-swipe media
        // dismiss in the repro. We only consult the coordinator once we know a modal
        // is actually presented: on iOS 26 the transitionCoordinator getter recurses
        // into child view controllers, so the root tab controller reports a live
        // coordinator during ordinary feed push/pop too, and checking it
        // unconditionally would wrongly swallow taps during normal navigation.
        if (vc.transitionCoordinator) return YES;
        // The overlay already being up is harmless — Apollo no-ops a re-tap; descend
        // past it and keep checking the rest of the chain.
        if (overlayCls && [presented isKindOfClass:overlayCls]) {
            vc = presented;
            continue;
        }
        // Some other modal (media viewer, in-app web browser, share/settings sheet)
        // is on top — presenting the menu over it is exactly what wedges UIKit.
        return YES;
    }
    return NO;
}

// NO while the floating Pal's iris wipe covers the screen (it does the show).
static BOOL sApolloPalHomeOpenAnimated = YES;

static BOOL ApolloPalHomeOpenFromIsland(UIWindow *window) {
    UIViewController *root = window.rootViewController;
    UITabBarController *tabs = [root isKindOfClass:UITabBarController.class] ? (UITabBarController *)root : nil;
    UIViewController *selected = tabs ? tabs.selectedViewController : root;
    UINavigationController *nav = [selected isKindOfClass:UINavigationController.class] ? (UINavigationController *)selected : selected.navigationController;
    if (!nav || nav.transitionCoordinator) return NO;
    if ([nav.topViewController isKindOfClass:ApolloPalHomeViewController.class]) return YES; // already home
    for (UIViewController *screen in nav.viewControllers) {
        if ([screen isKindOfClass:ApolloPalHomeViewController.class]) {
            [nav popToViewController:screen animated:sApolloPalHomeOpenAnimated];
            return YES;
        }
    }
    [nav pushViewController:[ApolloPalHomeViewController new] animated:sApolloPalHomeOpenAnimated];
    ApolloLog(@"[PixelPals] Island tap → Pal Home");
    return YES;
}

// Pal Home from the island, whatever state the app is in: pushed onto the
// current tab when it can be (so back returns you to where you were), else
// presented full screen (its back button dismisses). Never Apollo's old sheet.
static void ApolloPalHomeShowFromWindow(UIWindow *window) {
    if (ApolloPalHomeOpenFromIsland(window)) return;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    if (!top || top.isBeingPresented || top.isBeingDismissed) {
        // Mid-transition: try again once it settles.
        __weak UIWindow *weakWindow = window;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *strongWindow = weakWindow;
            if (strongWindow && ApolloPalHomeStore.isPalHomeEnabled) ApolloPalHomeShowFromWindow(strongWindow);
        });
        ApolloLog(@"[PixelPals] Pal Home deferred: mid-transition");
        return;
    }
    if ([top isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)top).topViewController isKindOfClass:ApolloPalHomeViewController.class]) return; // already open
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ApolloPalHomeViewController new]];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:nav animated:sApolloPalHomeOpenAnimated completion:nil];
    ApolloLog(@"[PixelPals] Island tap → Pal Home (presented over %@)", NSStringFromClass(top.class));
}

// Pal Home → "Show your Pal: Bubble": Apollo's own Pal (island pill or tab-bar
// strip, plus the hearts and food it drops) keeps running but out of sight, so
// food and distance still count; the floating bubble is the Pal you see.
static BOOL sApolloPalHomeCovering; // Pal Home is on screen: its own Pal, not Apollo's

static BOOL ApolloPixelPalsHiddenForBubble(void) {
    return ApolloPalHomeStore.isPalHomeEnabled && ApolloPalHomeStore.palDisplay == APPalDisplayBubble;
}

// Hearts, food and emotes Apollo drops by its own Pal: not over Pal Home, and
// not while that Pal is hidden for the bubble.
static BOOL ApolloPixelPalsHideDroppedElements(void) {
    return sApolloPalHomeCovering || ApolloPixelPalsHiddenForBubble();
}

void ApolloPixelPalsSetPalHomeCovering(BOOL covering) { sApolloPalHomeCovering = covering; }

void ApolloPixelPalsApplyDisplay(void) {
    BOOL hide = ApolloPixelPalsHiddenForBubble();
    Class themeable = objc_getClass("_TtC6Apollo15ThemeableWindow");
    if (!themeable) return;
    for (UIWindow *window in ApolloAllWindows()) {
        if (![window isKindOfClass:themeable]) continue;
        for (const char *name : {"pixelPalView", "fauxCutOutView"}) {
            Ivar ivar = class_getInstanceVariable(themeable, name);
            UIView *view = ivar ? object_getIvar(window, ivar) : nil;
            if ([view isKindOfClass:UIView.class] && (view.alpha < 0.5) != hide) {
                view.alpha = hide ? 0 : 1;
                ApolloLog(@"[PixelPals] %s %@ (bubble mode)", name, hide ? @"hidden" : @"shown");
            }
        }
    }
}

%hook _TtC6Apollo15ThemeableWindow

- (void)layoutSubviews {
    %orig;
    if (ApolloPixelPalsHiddenForBubble()) ApolloPixelPalsApplyDisplay();
}

// Views Apollo adds to the window positioned from the stock pill: the tap flash
// (sub_10030d6c4) and the hearts / food / emotes placed next to the pal
// (PixelPalAddedSceneElementImageView). Both are framed before being added.
- (void)addSubview:(UIView *)view {
    UIWindow *window = (UIWindow *)self;
    CGRect apollo, pill;
    static Class droppedCls;
    static dispatch_once_t droppedOnce;
    dispatch_once(&droppedOnce, ^{ droppedCls = objc_getClass("_TtC6Apollo34PixelPalAddedSceneElementImageView"); });
    if (view && droppedCls && [view isKindOfClass:droppedCls] && ApolloPixelPalsHideDroppedElements()) view.alpha = 0;
    if (view && ApolloPixelPalGeometry(window, &apollo, &pill)) {
        CGFloat dx = CGRectGetMinX(pill) - CGRectGetMinX(apollo);
        CGFloat dy = CGRectGetMinY(pill) - CGRectGetMinY(apollo);
        CGRect f = view.frame;

        static Class elementCls;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            elementCls = objc_getClass("_TtC6Apollo34PixelPalAddedSceneElementImageView");
        });

        BOOL stockFlashSize = fabs(CGRectGetWidth(f) - kApolloStockPillWidth) < 0.5 &&
                              fabs(CGRectGetHeight(f) - kApolloStockPillHeight) < 0.5;
        BOOL pillFlashSize = fabs(CGRectGetWidth(f) - CGRectGetWidth(apollo)) < 0.5 &&
                             fabs(CGRectGetHeight(f) - CGRectGetHeight(apollo)) < 0.5;
        if ([view isMemberOfClass:[UIView class]] && (stockFlashSize || pillFlashSize) &&
            view.clipsToBounds && view.layer.cornerRadius >= CGRectGetHeight(f) * 0.5 - 0.5) {
            // The flash sits over the pill (y=11 vs the pill's 11.5): take the
            // pill's x and size, keep Apollo's offset from the pill top.
            CGRect fixed = CGRectMake(CGRectGetMinX(pill),
                                      CGRectGetMinY(f) + dy,
                                      CGRectGetWidth(pill),
                                      CGRectGetHeight(pill));
            ApolloLog(@"[PixelPals] tap flash %@ → %@", ApolloRectString(f), ApolloRectString(fixed));
            view.frame = fixed;
            view.layer.cornerRadius = CGRectGetHeight(fixed) * 0.5;
        } else if (elementCls && [view isKindOfClass:elementCls] && view.superview != window) {
            // Positioned at (W - pillWidth) / 2 + <pal x in scene>; the strip
            // moved with the pill, so move the element with it.
            ApolloLog(@"[PixelPals] scene element %@ origin {%.2f, %.2f} → {%.2f, %.2f}",
                      NSStringFromClass([view class]), f.origin.x, f.origin.y, f.origin.x + dx, f.origin.y + dy);
            f.origin.x += dx;
            f.origin.y += dy;
            view.frame = f;
            if (ApolloPixelPalsHideDroppedElements()) view.alpha = 0;
        }
    }
    %orig;
}

// Suppress the Pixel Pals menu while media / a website / any modal is open or
// mid-transition — opening it then races UIKit and freezes the app (issue #305).
// Pal Home replaces Apollo's Pixel Pals care sheet (PixelPalOverlayViewController):
// tapping the island Pal opens Pal Home, pushed onto the tab you're on so
// you come straight back to where you were.
- (void)pixelPalTappedWithTapGestureRecognizer:(id)recognizer {
    if (ApolloPixelPalsBlockedByModal((UIWindow *)self)) {
        ApolloLog(@"[PixelPals] Tap ignored — a modal is open/transitioning (issue #305 freeze guard)");
        return;
    }
    // With Pal Home on, the old sheet never opens (see the presentation hook
    // below, which catches every other route to it too).
    if (ApolloPalHomeStore.isPalHomeEnabled) { ApolloPalHomeShowFromWindow((UIWindow *)self); return; }
    %orig; // Classic: Apollo's own sheet
}

// Tapping the Pal sprite itself (the scene posts "dog barked") opens the
// care sheet too: same destination.
- (void)dogBarkedWithNotification:(id)notification {
    if (ApolloPixelPalsBlockedByModal((UIWindow *)self)) {
        ApolloLog(@"[PixelPals] Bark menu suppressed — a modal is open/transitioning (issue #305 freeze guard)");
        return;
    }
    if (ApolloPalHomeStore.isPalHomeEnabled) { ApolloPalHomeShowFromWindow((UIWindow *)self); return; }
    %orig;
}

%end


#pragma mark - Pal Home

// With Pal Home on, it replaces Pixel Pals: Settings → Pixel Pals opens it
// instead of Apollo's chooser. (Everything the chooser did lives in Pal Home:
// the island on/off is on the Pal card, choosing is the household + shelter.)
// With it off (Classic, the default) Apollo's screens are untouched apart from
// the occasional "Try Pal Home" card (ApolloPalHomePrompt).
%hook UINavigationController
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    static Class chooser;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ chooser = objc_getClass("_TtC6Apollo29PixelPalChooserViewController"); });
    if (chooser && [viewController isKindOfClass:chooser] && ApolloPalHomeStore.isPalHomeEnabled) {
        ApolloLog(@"[PixelPals] Settings → Pixel Pals → Pal Home");
        %orig([ApolloPalHomeViewController new], animated);
        return;
    }
    %orig;
}
%end

%hook _TtC6Apollo29PixelPalChooserViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *chooser = (UIViewController *)self;
    __weak UIViewController *weakChooser = chooser;
    [ApolloPalHomePrompt showInView:chooser.view bottomInset:chooser.view.safeAreaInsets.bottom onTry:^{
        UINavigationController *nav = weakChooser.navigationController;
        if (nav) [nav pushViewController:[ApolloPalHomeViewController new] animated:YES];
    }];
}
%end

// Apollo's care sheet (Classic): the same card, floating at the bottom.
// The definitive gate: with Pal Home on, anything that tries to present
// Apollo's old care sheet gets Pal Home instead (the island taps above, and
// any route we haven't found, e.g. a long press or a notification).
%hook UIViewController
- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion {
    static Class overlay;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ overlay = objc_getClass("_TtC6Apollo29PixelPalOverlayViewController"); });
    if (overlay && [viewController isKindOfClass:overlay] && ApolloPalHomeStore.isPalHomeEnabled) {
        UIViewController *presenter = self;
        UIWindow *window = presenter.view.window ?: presenter.viewIfLoaded.window;
        ApolloLog(@"[PixelPals] Old care sheet blocked (Pal Home is on) → Pal Home");
        if (window) ApolloPalHomeShowFromWindow(window);
        if (completion) completion();
        return;
    }
    %orig;
}
%end

%hook _TtC6Apollo29PixelPalOverlayViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *overlay = (UIViewController *)self;
    UIView *host = overlay.view.window ?: overlay.view;
    if (!host) return;
    __weak UIViewController *weakOverlay = overlay;
    // Clear of the tab bar under the sheet.
    [ApolloPalHomePrompt showInView:host bottomInset:host.safeAreaInsets.bottom + 56 onTry:^{
        UIViewController *sheet = weakOverlay;
        UIWindow *window = sheet.view.window;
        [sheet dismissViewControllerAnimated:YES completion:^{ if (window) ApolloPalHomeOpenFromIsland(window); }];
    }];
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // The card belongs to the sheet: it leaves with it.
    UIView *window = ((UIViewController *)self).view.window;
    for (UIView *view in window.subviews) if ([view isKindOfClass:ApolloPalHomePrompt.class]) [view removeFromSuperview];
}
%end

#pragma mark - Pal coats

// Coat colours (see palhome/ApolloPixelPalCoats.h) and Reborn species on the
// island. Apollo loads every Pal sprite by asset name ("<rawValue>-<action>",
// Hopper: sub_10004a784 & co.) through +[SKTexture textureWithImageNamed:]
// (the island/strip) or +[UIImage imageNamed:] (the chooser). Answering those
// two lets us:
//  - recolour an Apollo Pal to its coat, and
//  - while a Reborn resident is borrowing a slot (ApolloPalHomeStore's island
//    channel), draw that resident (e.g. a capybara) wherever Apollo asks for
//    the slot's species. Apollo's island has no per-species behaviour beyond
//    asset names (only superAI's tap sounds, and it's never a host), so the
//    guest walks, sits and sleeps exactly like a native Pal.
// Sheets are cached per asset + species + coat. Pal Home and the shelter load
// through APPalCreateSheetForUI (not hooked) so they always get exactly the
// resident they ask for.
static UIImage *ApolloPixelPalCoatImage(NSString *name) {
    // Classic Pixel Pals is Apollo's own: no coats, no Reborn guests.
    if (!ApolloPalHomeStore.isPalHomeEnabled) return nil;
    NSString *species = [APPixelPalCoats speciesForAssetName:name];
    if (!species) return nil;
    NSString *action = [name substringFromIndex:species.length + 1];
    NSString *coat = nil;
    NSDictionary<NSString *, NSString *> *channel = [ApolloPalHomeStore islandChannel];
    if (channel && [species isEqualToString:channel[@"host"]]) {
        if (!APRebornHasSprites(channel[@"species"]) && ![APSpecies isApolloSpecies:channel[@"species"]]) return nil;
        species = channel[@"species"];
        coat = channel[@"coat"];
    } else {
        coat = [APPixelPalCoats selectedCoatForSpecies:species];
        if ([coat isEqualToString:@"original"] && !APRebornHasSprites(species)) return nil;
    }
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", name, species, coat];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    // A different selector from the one hooked below, so no recursion.
    __block CGFloat scale = 1;
    CGImageRef sheet = APPalCreateSheet(species, coat, action, ^CGImageRef(NSString *assetName) {
        UIImage *original = [UIImage imageNamed:assetName inBundle:nil compatibleWithTraitCollection:nil];
        scale = original.scale ?: 1;
        return original.CGImage;
    });
    // A Reborn guest with no sheet for this action (e.g. "settings"): let
    // Apollo's own image through rather than show nothing.
    if (!sheet) return nil;
    UIImage *image = [UIImage imageWithCGImage:sheet scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(sheet);
    [cache setObject:image forKey:key];
    return image;
}

// Apollo's own chooser can switch Pals behind our back; when it does, the
// island channel gives its borrowed slot back (stats go home with the guest).
static void ApolloPalHomeReconcileIsland(void) {
    static BOOL busy = NO;
    if (busy) return; // our own PixelPalSettingChanged post
    busy = YES;
    [[ApolloPalHomeStore new] reconcileIsland];
    busy = NO;
}

%hook SKTexture
+ (instancetype)textureWithImageNamed:(NSString *)name {
    UIImage *coat = ApolloPixelPalCoatImage(name);
    return coat ? [SKTexture textureWithImage:coat] : %orig;
}
%end

%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name {
    return ApolloPixelPalCoatImage(name) ?: %orig;
}
%end

#pragma mark - Carrot Weather pal

// Unlock "Artificial Superintelligence" Pixel Pal (normally requires Carrot Weather app installed)
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if ([[url scheme] isEqualToString:@"carrotweather"]) {
        return YES;
    }
    return %orig;
}
%end

// The floating Pal (ApolloPalHomeChatHead) trots along as you scroll. This is
// on every scroll view's hot path, so it's one cheap check unless it's showing.
%hook UIScrollView
- (void)setContentOffset:(CGPoint)offset {
    CGFloat before = ((UIScrollView *)self).contentOffset.y;
    %orig;
    if (ApolloPalChatHeadIsShowing()) ApolloPalChatHeadNoteScroll((UIScrollView *)self, offset.y - before);
}
%end

// From anywhere (the floating Pal): Pal Home on the main window.
void ApolloPalHomeOpenFromAnywhere(BOOL animated) {
    UIViewController *tabs = ApolloMainTabBarController();
    UIWindow *window = tabs.viewIfLoaded.window;
    if (!window) return;
    sApolloPalHomeOpenAnimated = animated;
    ApolloPalHomeShowFromWindow(window);
    sApolloPalHomeOpenAnimated = YES;
}

%ctor {
    %init; // this file's hooks (an explicit %ctor replaces Logos' implicit one)
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect island;
        ApolloPalHomeStore.deviceHasDynamicIsland = ApolloDynamicIslandRect(&island);
        // Apollo's own tab-bar strip (phones without an island) is only offered
        // on the classic tab bar: under Liquid Glass's floating, collapsing bar
        // it has nowhere good to live, so there it's the island or the bubble.
        ApolloPalHomeStore.tabBarSupported = !ApolloPalHomeStore.deviceHasDynamicIsland && !IsLiquidGlass();
        ApolloLog(@"[PixelPals] Dynamic Island: %@", ApolloPalHomeStore.deviceHasDynamicIsland ? @"yes" : @"no");
        ApolloPixelPalsApplyDisplay();
        ApolloPalChatHeadRefresh();
    });
    [NSNotificationCenter.defaultCenter addObserverForName:@"PixelPalSettingChanged" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        ApolloPalHomeReconcileIsland();
        ApolloPixelPalsApplyDisplay();
        ApolloPalChatHeadRefresh(); // the island Pal may have changed
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        ApolloPalHomeReconcileIsland();
        ApolloPalChatHeadRefresh();
        ApolloPalChatHeadWelcomeBack();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:APPalDisplayDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        ApolloPixelPalsApplyDisplay();
        ApolloPalChatHeadRefresh();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) { ApolloPalChatHeadRefresh(); }];
}
