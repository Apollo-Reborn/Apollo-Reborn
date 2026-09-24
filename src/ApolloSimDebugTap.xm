// Simulator-only debug bridge: synthesize a real UITouch tap inside the app.
//
// idb_companion 1.1.8's HID events are silently dropped by Xcode 27's iOS-27
// simulators, so there is currently no external way to tap the sim from
// scripts. This module lets the host drive taps through the injected tweak
// instead: write "x y" (screen points) to /tmp/apollofix-tap.txt, then post
// the Darwin notification:
//
//   echo "200 560" > /tmp/apollofix-tap.txt
//   xcrun simctl spawn <UDID> notifyutil -p apollofix.debugtap
//
// The synthesized touch goes through -[UIApplication sendEvent:], so it
// exercises genuine hit-testing, responder-chain bubbling, gesture
// recognizers, and ASControlNode tracking — unlike calling handlers directly.
// Never compiled into device builds.
#if APOLLO_SIM_BUILD

#import "ApolloAccountCredentials.h"
#import "ApolloAsyncDisplayGuard.h"
#import "ApolloChatRoomDirectory.h"
#import "ApolloCommentVoteInsights.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloFloatingTabs.h"
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloTranslation.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloWebTextDecoding.h"
#import "ApolloState.h"
#import "ApolloTextureDecls.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "UIWindow+Apollo.h"

void ApolloSubredditIndexDebugDescribeTables(void); // ApolloSubredditIndexPolish.xm (sim-only)
#import <objc/message.h>
#import <mach/mach.h>

@interface UITouch (ApolloSimDebugTap)
- (void)setPhase:(UITouchPhase)phase;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)first;
@end

@interface UIEvent (ApolloSimDebugTap)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

@interface UIApplication (ApolloSimDebugTap)
- (UIEvent *)_touchesEvent;
@end

// The command file and the Darwin notification that announces it are
// machine-global, and several simulators driven by parallel sessions are the
// norm on a dev box — a tap meant for one app landed in every listening app.
// Each launch can therefore name its own pair via the environment
// (SIMCTL_CHILD_APOLLOFIX_TAP_FILE / SIMCTL_CHILD_APOLLOFIX_TAP_NOTIFY on the
// simctl launch line); the historical defaults remain for single-session use.
static NSString *const kApolloSimDefaultTapFile = @"/tmp/apollofix-tap.txt";
static NSString *const kApolloSimDefaultTapNotify = @"apollofix.debugtap";

static NSString *ApolloSimTapFile(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"APOLLOFIX_TAP_FILE"];
    return env.length ? env : kApolloSimDefaultTapFile;
}

static NSString *ApolloSimTapNotify(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"APOLLOFIX_TAP_NOTIFY"];
    return env.length ? env : kApolloSimDefaultTapNotify;
}

// "mediastate": dump the presented fullscreen viewer's player + the audio
// session, for the rotation-mute diagnosis (issue #1072).
static id ApolloSimDebugIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], name);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static void ApolloSimDebugDumpMediaState(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    UIWindowScene *scene = ApolloAllWindows().firstObject.windowScene;
    ApolloLog(@"[SimDebugTap] mediastate: session=%@ orientation=%ld",
              session.category, (long)scene.interfaceOrientation);
    for (UIWindow *window in ApolloAllWindows()) {
        UIViewController *vc = window.rootViewController;
        while (vc) {
            NSString *name = NSStringFromClass([vc class]);
            ApolloLog(@"[SimDebugTap] mediastate: presented chain -> %@ bounds=%@", name,
                      NSStringFromCGRect(vc.view.bounds));
            if ([name containsString:@"MediaPageViewController"]) {
                NSArray *pages = [vc respondsToSelector:@selector(viewControllers)]
                    ? [(UIPageViewController *)vc viewControllers] : @[];
                for (UIViewController *page in pages) {
                    AVPlayer *player = ApolloSimDebugIvar(page, "player");
                    NSString *source = @"player";
                    if (!player) {
                        id container = ApolloSimDebugIvar(page, "playerLayerContainerView");
                        id layer = ApolloSimDebugIvar(container, "playerLayer");
                        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
                            player = [(AVPlayerLayer *)layer player];
                            source = @"playerLayerContainerView";
                        }
                    }
                    ApolloLog(@"[SimDebugTap] mediastate: page=%@ player=%p (%@) muted=%d rate=%.2f bounds=%@",
                              NSStringFromClass([page class]), player, source,
                              player ? (int)[player isMuted] : -1, player ? [player rate] : 0.0f,
                              NSStringFromCGRect(page.view.bounds));
                }
            }
            vc = vc.presentedViewController;
        }
        // The feed table under the viewer: offset/insets, visible rows and
        // each visible cell's video player, so a rotation-driven visibility
        // change can be correlated with the fullscreen player above it.
        UIViewController *root = window.rootViewController;
        UIViewController *content = root;
        if ([content isKindOfClass:[UITabBarController class]]) content = [(UITabBarController *)content selectedViewController];
        if ([content isKindOfClass:[UINavigationController class]]) content = [(UINavigationController *)content topViewController];
        UITableView *table = nil;
        if ([content.view isKindOfClass:[UITableView class]]) table = (UITableView *)content.view;
        for (UIView *sub in content.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]]) { table = (UITableView *)sub; break; }
        }
        if (!table) continue;
        ApolloLog(@"[SimDebugTap] mediastate: feed %@ table bounds=%@ offset=%@ insets=%@ window=%p",
                  NSStringFromClass([content class]), NSStringFromCGRect(table.bounds),
                  NSStringFromCGPoint(table.contentOffset),
                  NSStringFromUIEdgeInsets(table.adjustedContentInset), table.window);
        for (UITableViewCell *cell in table.visibleCells) {
            NSIndexPath *ip = [table indexPathForCell:cell];
            id node = [cell respondsToSelector:@selector(node)] ? [(id)cell node] : nil;
            id rich = ApolloSimDebugIvar(node, "richMediaNode");
            id videoNode = ApolloSimDebugIvar(rich, "videoNode");
            SEL layerSel = NSSelectorFromString(@"playerLayer");
            id layer = [videoNode respondsToSelector:layerSel]
                ? ((id (*)(id, SEL))objc_msgSend)(videoNode, layerSel) : nil;
            AVPlayer *player = [layer isKindOfClass:[AVPlayerLayer class]] ? [(AVPlayerLayer *)layer player] : nil;
            SEL playerSel = NSSelectorFromString(@"player");
            if (!player && [videoNode respondsToSelector:playerSel]) {
                player = ((id (*)(id, SEL))objc_msgSend)(videoNode, playerSel);
            }
            ApolloLog(@"[SimDebugTap] mediastate:   row %ld frame=%@ node=%@ videoNode=%p player=%p muted=%d rate=%.2f",
                      (long)ip.row, NSStringFromCGRect(cell.frame), NSStringFromClass([node class]),
                      videoNode, player, player ? (int)[player isMuted] : -1, player ? [player rate] : 0.0f);
        }
    }
}

static void ApolloSimDebugSendTouch(UITouch *touch) {
    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(_touchesEvent)]) return;
    UIEvent *event = [app _touchesEvent];
    if ([touch respondsToSelector:@selector(setTimestamp:)]) {
        [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
    }
    if ([event respondsToSelector:@selector(_setTimestamp:)]) {
        [event _setTimestamp:NSProcessInfo.processInfo.systemUptime];
    }
    [event _clearTouches];
    [event _addTouch:touch forDelayedDelivery:NO];
    [app sendEvent:event];
}

static void ApolloSimDebugPerformTap(CGPoint point) {
    // Hit-test every visible window from topmost down, not just the key
    // window: alert/overlay windows sit above it, and key-window-only taps
    // sailed straight through their chrome into the app underneath.
    UIView *hitView = nil;
    UIWindow *window = nil;
    NSArray<UIWindow *> *ordered = [ApolloAllWindows() sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIWindow *candidate in ordered) {
        if (candidate.hidden) continue;
        UIView *hit = [candidate hitTest:point withEvent:nil];
        if (hit) { window = candidate; hitView = hit; break; }
    }
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for (%.0f, %.0f)", point.x, point.y);
        return;
    }
    ApolloLog(@"[SimDebugTap] tapping (%.0f, %.0f) hit=%@", point.x, point.y,
              NSStringFromClass(hitView.class));

    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) {
        ApolloLog(@"[SimDebugTap] UITouch private setters unavailable on this runtime");
        return;
    }
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] tap delivered");
    });
}

// "hold x y" command: a stationary touch held long enough to trigger ordinary
// UILongPressGestureRecognizer interactions. This is separate from swipe so a
// long-press test doesn't inject tiny moved phases that can trip movement limits.
static void ApolloSimDebugPerformHold(CGPoint point) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for hold (%.0f, %.0f)", point.x, point.y);
        return;
    }
    ApolloLog(@"[SimDebugTap] holding (%.0f, %.0f) hit=%@", point.x, point.y,
              NSStringFromClass(hitView.class));

    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) return;
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    // A real finger produces stationary samples while it is held. Supplying one
    // gives UIKit's long-press timers a fresh event to advance against in the
    // simulator's synthesized UIEvent stream.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseStationary];
        ApolloSimDebugSendTouch(touch);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] hold delivered");
    });
}

// "swipe x1 y1 x2 y2" command: a real drag (began → moved steps → ended) so a
// scroll view actually scrolls, unlike the single tap above. Reuses the same
// synthesized-touch delivery path.
// steps/interval control the drag speed: the default 12 x 12 ms is a flick that
// commits an interactive pop; a slow, short drag (e.g. 30 x 20 ms to x=45) ends
// below UIKit's commit threshold and cancels it instead.
// `settle` (seconds, default 0) keeps the finger DOWN and stationary at the end
// point before lifting, so the pan recognizer's velocity has decayed to ~0 when
// the touch ends: a drag that stops dead where it is, with no deceleration.
// Without it the synthetic lift carries the last move's velocity and the list
// keeps travelling (measured: a 60pt swipe scrolling 314pt), which cannot land
// the search bar exactly at its collapsed rest the way a paused finger does.
static void ApolloSimDebugPerformSwipeTimed(CGPoint start, CGPoint end, int steps, NSTimeInterval interval,
                                            NSTimeInterval settle) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:start withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for swipe start (%.0f, %.0f)", start.x, start.y);
        return;
    }
    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) return;
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) [touch _setIsFirstTouchForView:YES];
    [touch _setLocationInWindow:start resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    for (int i = 1; i <= steps; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CGFloat t = (CGFloat)i / steps;
            CGPoint p = CGPointMake(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
            [touch _setLocationInWindow:p resetPrevious:NO];
            [touch setPhase:UITouchPhaseMoved];
            ApolloSimDebugSendTouch(touch);
        });
    }
    // A held finger still reports itself: stationary Moved events through the
    // settle window are what let the recognizer's velocity integrator see
    // time passing with no displacement.
    if (settle > 0.0) {
        int holds = MAX(1, (int)(settle / 0.03));
        for (int h = 1; h <= holds; h++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((steps * interval + h * 0.03) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [touch _setLocationInWindow:end resetPrevious:NO];
                [touch setPhase:UITouchPhaseMoved];
                ApolloSimDebugSendTouch(touch);
            });
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((steps * interval + settle + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:end resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] swipe delivered (%.0f,%.0f)->(%.0f,%.0f) over %d x %.0f ms, settle %.0f ms",
                  start.x, start.y, end.x, end.y, steps, interval * 1000.0, settle * 1000.0);
    });
}

// "press x y seconds" command: touch down, hold stationary, touch up. Drives
// UILongPressGestureRecognizer and UIContextMenuInteraction, which idb's
// synthesized HID events fail to trigger reliably.
static void ApolloSimDebugPerformPress(CGPoint point, NSTimeInterval duration) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for press (%.0f, %.0f)", point.x, point.y);
        return;
    }
    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) return;
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) [touch _setIsFirstTouchForView:YES];
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    // Stationary "moved" ticks keep the touch alive for recognizers that
    // sample continuously; a long press tolerates zero movement.
    const NSTimeInterval tick = 0.1;
    for (NSTimeInterval elapsed = tick; elapsed < duration; elapsed += tick) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(elapsed * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch _setLocationInWindow:point resetPrevious:NO];
            [touch setPhase:UITouchPhaseStationary];
            ApolloSimDebugSendTouch(touch);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] press delivered (%.0f,%.0f) duration=%.2f",
                  point.x, point.y, duration);
    });
}

// "dump" command: write the full view hierarchy of every window (class, frame
// in window coords, hidden/alpha/backgroundColor) to /tmp/apollofix-dump.txt so
// the host can inspect z-order and geometry without a debugger attached.
static void ApolloSimDebugDumpView(UIView *view, UIWindow *window, NSInteger depth, NSMutableString *out) {
    CGRect winFrame = [view.superview convertRect:view.frame toView:window];
    NSString *pad = [@"" stringByPaddingToLength:MIN(depth, 40) * 2 withString:@" " startingAtIndex:0];
    UIColor *bg = view.backgroundColor;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSString *bgDesc = @"nil";
    if (bg && [bg getRed:&r green:&g blue:&b alpha:&a]) {
        bgDesc = [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a];
    } else if (bg) {
        bgDesc = bg.description;
    }
    [out appendFormat:@"%@%@ frame=(%.1f,%.1f,%.1f,%.1f)%@ alpha=%.2f bg=%@\n",
        pad, NSStringFromClass(view.class),
        winFrame.origin.x, winFrame.origin.y, winFrame.size.width, winFrame.size.height,
        view.hidden ? @" HIDDEN" : @"", view.alpha, bgDesc];
    for (UIView *subview in view.subviews) {
        ApolloSimDebugDumpView(subview, window, depth + 1, out);
    }
}

// "sbprobe x y [seconds [refreshAt]]" command: tap (x, y) and, for the next
// `seconds` (default 1.2), sample every 33ms the first nav-bar UISearchBar's subtree —
// model frame (bar coordinates), presentation-layer frame and opacity, hidden,
// clipsToBounds and running animation keys of every button / text field /
// container — to /tmp/apollofix-sbprobe.txt. Used to see what UIKit's cancel
// button actually does during the search activation animation. `refreshAt`
// forces a navigation-title refresh that many seconds in, to land the title
// recenter inside the trailing-item swap on purpose (see the title-width
// reservation in ApolloLiquidGlass.xm).
static UISearchBar *ApolloSimDebugFindSearchBar(UIView *view) {
    if ([view isKindOfClass:UISearchBar.class]) return (UISearchBar *)view;
    for (UIView *sub in view.subviews) {
        UISearchBar *found = ApolloSimDebugFindSearchBar(sub);
        if (found) return found;
    }
    return nil;
}

static NSString *ApolloSimDebugProbeLine(UIView *view, UIView *bar) {
    CGRect model = bar ? [view.superview convertRect:view.frame toView:bar] : view.frame;
    CALayer *pres = view.layer.presentationLayer;
    CGRect pf = pres ? pres.frame : CGRectNull;
    return [NSString stringWithFormat:@"%@ model=(%.1f,%.1f,%.1f,%.1f) pres=(%.1f,%.1f,%.1f,%.1f) a=%.2f/%.2f h=%d/%d%@ clip=%d/%d mask=%d anims=%@",
        NSStringFromClass(view.class),
        model.origin.x, model.origin.y, model.size.width, model.size.height,
        pf.origin.x, pf.origin.y, pf.size.width, pf.size.height,
        view.alpha, pres ? pres.opacity : -1.0, (int)view.hidden, pres ? (int)pres.hidden : -1, view.hidden ? @" HIDDEN" : @"",
        (int)view.clipsToBounds, (int)view.layer.masksToBounds, view.layer.mask != nil,
        [view.layer.animationKeys componentsJoinedByString:@","] ?: @""];
}

// Every view from the bar down to (and including) the cancel button's whole
// subtree, plus the bar's ancestors up to the navigation bar: what clips,
// what masks, what is transparent while the cancel button animates in.
static void ApolloSimDebugProbeCollect(UIView *view, UIView *bar, NSMutableString *out, NSInteger depth) {
    // The whole navigation bar subtree, every sample: what is on screen, what
    // is a portal copy, what is hidden or transparent while the cancel button
    // animates in. Text field internals and the tweak's own action strip are
    // noise and skipped; SwiftUI platter internals are cut at depth 9.
    [out appendFormat:@"  %*s%@\n", (int)depth * 2, "", ApolloSimDebugProbeLine(view, bar)];
    if ([view isKindOfClass:UITextField.class] || depth >= 9) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"ApolloNavigationActionsStrip"]) return;
    for (UIView *sub in view.subviews) ApolloSimDebugProbeCollect(sub, bar, out, depth + 1);
}

static UIView *ApolloSimDebugProbeNavBar(UIView *bar) {
    UIView *v = bar;
    while (v && ![v isKindOfClass:UINavigationBar.class]) v = v.superview;
    return v;
}

static void ApolloSimDebugSearchBarProbe(CGPoint point, NSTimeInterval seconds, NSTimeInterval refreshAt) {
    // Optional: force a navigation-title refresh `refreshAt` seconds after the tap, to
    // land the title recenter inside the item swap on purpose (it only happens by chance
    // otherwise) and watch what it does to the title control's width.
    if (refreshAt > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(refreshAt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIWindow *window in ApolloAllWindows()) {
                if (window.hidden) continue;
                UISearchBar *bar = ApolloSimDebugFindSearchBar(window);
                UINavigationBar *navBar = (UINavigationBar *)ApolloSimDebugProbeNavBar(bar);
                if (!navBar) continue;
                ApolloNavigationTitleGlassRefreshNavigationBar(navBar);
                ApolloLog(@"[SimDebugTap] forced title refresh at +%.2fs", refreshAt);
                break;
            }
        });
    }
    NSMutableString *out = [NSMutableString string];
    NSDate *start = [NSDate date];
    __block NSInteger samples = 0;
    NSInteger total = (NSInteger)(seconds / 0.033);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSimDebugPerformTap(point);
    });
    for (NSInteger i = 0; i <= total; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.033 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UISearchBar *bar = nil;
            for (UIWindow *window in ApolloAllWindows()) {
                if (window.hidden) continue;
                bar = ApolloSimDebugFindSearchBar(window);
                if (bar) break;
            }
            [out appendFormat:@"--- t=%.3f bar=%@\n", -[start timeIntervalSinceNow], bar ? @"" : @"(none)"];
            UIView *navBar = ApolloSimDebugProbeNavBar(bar);
            if (navBar) ApolloSimDebugProbeCollect(navBar, bar, out, 0);
            else if (bar) ApolloSimDebugProbeCollect(bar, bar, out, 0);
            if (++samples > total) {
                [out writeToFile:@"/tmp/apollofix-sbprobe.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
                ApolloLog(@"[SimDebugTap] search bar probe written (%lu bytes)", (unsigned long)out.length);
            }
        });
    }
}

// "fieldprobe" command: log everything that decides whether the nav-bar
// search field draws its glass pill — the field's dynamic-material flags,
// its background views and layer tree, the bar's hosting flags and the
// owning navigation item — so a before/after of a cancelled swipe-back can
// be compared line by line.
static void ApolloSimDebugProbeLayer(CALayer *layer, NSInteger depth, NSInteger maxDepth) {
    CGFloat bgAlpha = layer.backgroundColor ? CGColorGetAlpha(layer.backgroundColor) : -1.0;
    CALayer *pres = layer.presentationLayer;
    id source = [layer respondsToSelector:sel_registerName("sourceLayer")]
        ? ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("sourceLayer")) : nil;
    ApolloLog(@"[FieldProbe] %*slayer %@ frame=%@ hidden=%d opacity=%.2f pres=%.2f/%d corner=%.1f bgA=%.2f filters=%lu comp=%d mask=%d subs=%lu%@",
              (int)depth * 2, "", NSStringFromClass(layer.class), NSStringFromCGRect(layer.frame),
              (int)layer.hidden, layer.opacity, pres ? pres.opacity : -1.0, pres ? (int)pres.hidden : -1,
              layer.cornerRadius, bgAlpha,
              (unsigned long)layer.filters.count, layer.compositingFilter != nil, layer.mask != nil,
              (unsigned long)layer.sublayers.count,
              source ? [NSString stringWithFormat:@" source=%@ %@ hidden=%d", NSStringFromClass([source class]),
                        [source isKindOfClass:CALayer.class] ? NSStringFromCGRect(((CALayer *)source).frame) : @"",
                        [source isKindOfClass:CALayer.class] ? (int)((CALayer *)source).hidden : -1] : @"");
    if (depth >= maxDepth) return;
    for (CALayer *sub in layer.sublayers) ApolloSimDebugProbeLayer(sub, depth + 1, maxDepth);
}

static BOOL ApolloSimDebugProbeBool(id object, const char *selectorName) {
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long ApolloSimDebugProbeInteger(id object, const char *selectorName) {
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return -99;
    return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
}

static id ApolloSimDebugProbeObject(id object, const char *selectorName) {
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void ApolloSimDebugFieldProbe(NSString *tag) {
    UISearchBar *bar = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden) continue;
        bar = ApolloSimDebugFindSearchBar(window);
        if (bar) break;
    }
    if (!bar) { ApolloLog(@"[FieldProbe] %@: no search bar in any window", tag); return; }
    UITextField *field = bar.searchTextField;
    NSMutableString *chain = [NSMutableString string];
    for (UIView *v = field; v; v = v.superview) {
        [chain appendFormat:@"%@%@", chain.length ? @" < " : @"", NSStringFromClass(v.class)];
    }
    ApolloLog(@"[FieldProbe] %@ chain: %@", tag, chain);
    UINavigationBar *navBar = (UINavigationBar *)ApolloSimDebugProbeNavBar(bar);
    UINavigationItem *item = navBar.topItem;
    UISearchController *sc = ApolloSimDebugProbeObject(bar, "_searchController");
    ApolloLog(@"[FieldProbe] %@ bar frame=%@ hidden=%d alpha=%.2f style=%ld translucent=%d bg=%@ inlineHosted=%d backdrop=%lld sc=%p active=%d item.sc=%d hidesWhenScrolling=%d placement=%ld",
              tag, NSStringFromCGRect(bar.frame), (int)bar.hidden, bar.alpha, (long)bar.searchBarStyle, (int)bar.translucent,
              bar.backgroundColor, (int)ApolloSimDebugProbeBool(bar, "_isHostedInlineByNavigationBar"),
              ApolloSimDebugProbeInteger(bar, "_backdropStyle"), sc, (int)sc.active, (int)(item.searchController == sc),
              (int)item.hidesSearchBarWhenScrolling,
              (long)ApolloSimDebugProbeInteger(item, "preferredSearchBarPlacement"));
    Ivar topIvar = class_getInstanceVariable(field.class, "_effectBackgroundTop");
    Ivar bottomIvar = class_getInstanceVariable(field.class, "_effectBackgroundBottom");
    Ivar styleIvar = class_getInstanceVariable(field.class, "_backdropStyle");
    long long backdropStyle = -99;
    if (styleIvar) backdropStyle = *(long long *)((uint8_t *)(__bridge void *)field + ivar_getOffset(styleIvar));
    UIView *effectTop = topIvar ? object_getIvar(field, topIvar) : nil;
    UIView *effectBottom = bottomIvar ? object_getIvar(field, bottomIvar) : nil;
    ApolloLog(@"[FieldProbe] %@ field %@ frame=%@ hidden=%d alpha=%.2f border=%ld bg=%@ bgImage=%d wantsDynamic=%d shouldBeGlass=%d pocket=%@ backdropStyle=%lld effectTop=%@ effectBottom=%@ window=%d",
              tag, NSStringFromClass(field.class), NSStringFromCGRect(field.frame), (int)field.hidden, field.alpha,
              (long)field.borderStyle, field.backgroundColor, field.background != nil,
              (int)ApolloSimDebugProbeBool(field, "_wantsDynamicBackgroundMaterial"),
              (int)ApolloSimDebugProbeBool(field, "_backgroundMaterialShouldBeGlass"),
              ApolloSimDebugProbeObject(field, "scrollPocketInteraction"), backdropStyle,
              effectTop ? [NSString stringWithFormat:@"%@ sup=%@ h=%d a=%.2f", NSStringFromClass(effectTop.class), NSStringFromClass(effectTop.superview.class), (int)effectTop.hidden, effectTop.alpha] : @"nil",
              effectBottom ? [NSString stringWithFormat:@"%@ sup=%@ h=%d a=%.2f", NSStringFromClass(effectBottom.class), NSStringFromClass(effectBottom.superview.class), (int)effectBottom.hidden, effectBottom.alpha] : @"nil",
              field.window != nil);
    for (UIView *sub in field.subviews) {
        CGFloat bgAlpha = sub.backgroundColor ? CGColorGetAlpha(sub.backgroundColor.CGColor) : -1.0;
        ApolloLog(@"[FieldProbe] %@   sub %@ frame=%@ hidden=%d alpha=%.2f bgA=%.2f", tag, NSStringFromClass(sub.class),
                  NSStringFromCGRect(sub.frame), (int)sub.hidden, sub.alpha, bgAlpha);
    }
    // The glass pill is UIKit's "background material": when applied, the
    // view renders through a _UIMultiLayer that hosts the material layers
    // beside the content layer. Log both the material bookkeeping and the
    // layer class so a lost pill can be told apart from a cleared material.
    id material = ApolloSimDebugProbeObject(field, "_resolvedBackgroundMaterial");
    ApolloLog(@"[FieldProbe] %@ suppressed: field=%d container=%d bar=%d navBar=%d alphaOverride(field)=%.2f",
              tag, (int)ApolloSimDebugProbeBool(field, "_isBackgroundSuppressed"),
              (int)ApolloSimDebugProbeBool(field.superview, "_isBackgroundSuppressed"),
              (int)ApolloSimDebugProbeBool(bar, "_isBackgroundSuppressed"),
              (int)ApolloSimDebugProbeBool(navBar, "_isBackgroundSuppressed"),
              field.layer.presentationLayer ? field.layer.presentationLayer.opacity : -1.0);
    ApolloLog(@"[FieldProbe] %@ field layer=%@ multiLayer=%d hasMaterial=%d material=%@ barLayer=%@ containerLayer=%@",
              tag, NSStringFromClass(field.layer.class),
              (int)ApolloSimDebugProbeBool(field, "__dbg_renderingModeIsMultiLayer"),
              (int)ApolloSimDebugProbeBool(field, "_hasBackgroundMaterial"),
              material ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass([material class]), material] : @"nil",
              NSStringFromClass(bar.layer.class), NSStringFromClass(field.superview.layer.class));
    // The material lives in an intermediate _UIMultiLayer that UIKit wraps
    // around the view's own layer inside the superview's layer; log from the
    // superlayer down so the wrapper (or its absence) shows.
    CALayer *superlayer = field.layer.superlayer;
    ApolloLog(@"[FieldProbe] %@ field superlayer=%@ isSuperviewLayer=%d", tag,
              NSStringFromClass(superlayer.class), (int)(superlayer == field.superview.layer));
    ApolloSimDebugProbeLayer(superlayer ?: field.layer, 0, 7);
}

static void ApolloSimDebugDumpHierarchy(void) {
    NSMutableString *out = [NSMutableString string];
    for (UIWindow *window in ApolloAllWindows()) {
        [out appendFormat:@"=== window %@ hidden=%d level=%.0f ===\n",
            NSStringFromClass(window.class), window.hidden, (double)window.windowLevel];
        ApolloSimDebugDumpView(window, window, 0, out);
    }
    [out writeToFile:@"/tmp/apollofix-dump.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ApolloLog(@"[SimDebugTap] hierarchy dump written (%lu bytes)", (unsigned long)out.length);
}

static UIResponder *ApolloSimDebugFirstResponder(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *subview in view.subviews) {
        UIResponder *responder = ApolloSimDebugFirstResponder(subview);
        if (responder) return responder;
    }
    return nil;
}

// "text <string>" command: insert into the focused field through UIKeyInput,
// which fires the same editing events as typing.
static void ApolloSimDebugTypeText(NSString *text) {
    UIResponder *responder = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        responder = ApolloSimDebugFirstResponder(window);
        if (responder) break;
    }
    if (![responder conformsToProtocol:@protocol(UIKeyInput)]) {
        ApolloLog(@"[SimDebugTap] no key-input first responder for text command");
        return;
    }
    [(id<UIKeyInput>)responder insertText:text];
    ApolloLog(@"[SimDebugTap] typed %lu chars into %@",
              (unsigned long)text.length, NSStringFromClass(responder.class));
}

// "crash <type>" command: deliberately crash the process to exercise the
// local crash recorder (src/crash/). Types mirror the crash-capture test
// plan: nsexception, abort, badaccess, overflow.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winfinite-recursion"
__attribute__((noinline)) static void ApolloSimDebugRecursiveCrash(volatile NSUInteger value) {
    volatile NSUInteger next = value + 1;
    ApolloSimDebugRecursiveCrash(next);
}
#pragma clang diagnostic pop

static void ApolloSimDebugPerformCrash(NSString *type) {
    ApolloLog(@"[SimDebugTap] deliberate test crash: %@", type);
    if ([type isEqualToString:@"nsexception"]) {
        [@[] objectAtIndex:1];
    } else if ([type isEqualToString:@"abort"]) {
        abort();
    } else if ([type isEqualToString:@"badaccess"]) {
        *(volatile int *)0 = 1;
    } else if ([type isEqualToString:@"overflow"]) {
        ApolloSimDebugRecursiveCrash(0);
    }
    ApolloLog(@"[SimDebugTap] unknown crash type: %@", type);
}

// "insetbottom N" command: ask every visible Apollo ASTableView to accept a
// specific bottom inset. This reproduces the iOS 27 foreground write (153 -> 0)
// without depending on the simulator exhibiting the upstream lifecycle bug.
// ApolloListBottomInsetGuard should guard the zero and log the correction.
static void ApolloSimDebugForceBottomInsetInView(UIView *view, CGFloat bottom) {
    if ([view isKindOfClass:objc_getClass("ASTableView")] && view.window) {
        UIScrollView *scrollView = (UIScrollView *)view;
        UIEdgeInsets inset = scrollView.contentInset;
        CGFloat before = inset.bottom;
        inset.bottom = bottom;
        scrollView.contentInset = inset;
        ApolloLog(@"[SimDebugTap] insetbottom requested=%.1f before=%.1f after=%.1f table=%@",
                  bottom, before, scrollView.contentInset.bottom,
                  NSStringFromClass(scrollView.class));
    }
    for (UIView *subview in view.subviews) {
        ApolloSimDebugForceBottomInsetInView(subview, bottom);
    }
}

static void ApolloSimDebugForceBottomInset(CGFloat bottom) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.hidden) ApolloSimDebugForceBottomInsetInView(window, bottom);
    }
}

// Stamp-key accessors exported by ApolloScrollEdgeEffect.xm (both files are
// ObjC++, so plain C++ linkage matches).
const void *ApolloScrollEdgeEffectTopStampKey(void);
const void *ApolloScrollEdgeEffectForcedHiddenStampKey(void);
void ApolloSubredditListDiagRearm(void);

static void ApolloSimDebugDumpHeaderEffectsInView(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        SEL topSelector = NSSelectorFromString(@"topEdgeEffect");
        if ([view respondsToSelector:topSelector]) {
            id effect = ((id (*)(id, SEL))objc_msgSend)(view, topSelector);
            if (effect) {
                BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"isHidden"));
                id style = ((id (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"style"));
                ApolloLog(@"[SimDebugTap][headerdump] scroll=%@ window=%d effect=%p hidden=%d style=%@ topStamp=%d forcedStamp=%d",
                          NSStringFromClass(view.class), view.window != nil, effect, hidden, style,
                          objc_getAssociatedObject(effect, ApolloScrollEdgeEffectTopStampKey()) != nil,
                          objc_getAssociatedObject(effect, ApolloScrollEdgeEffectForcedHiddenStampKey()) != nil);
            }
        }
    }
    for (UIView *subview in view.subviews) ApolloSimDebugDumpHeaderEffectsInView(subview);
}

static void ApolloSimDebugDumpHeaderEffects(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.hidden) ApolloSimDebugDumpHeaderEffectsInView(window);
    }
}

#pragma mark - gifmem probe (issue #1000)

static double ApolloSimDebugFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1.0;
    return info.phys_footprint / 1048576.0;
}

// Keeps the probe's view + image alive between samples.
static UIImageView *sApolloSimDebugGIFView = nil;
static UIImage *sApolloSimDebugGIFImage = nil;

static void ApolloSimDebugSampleGIFMemory(NSInteger remaining, double baseline) {
    ApolloLog(@"[gifmem] t+%lds footprint %.0f MB (+%.0f)",
              (long)(6 - remaining), ApolloSimDebugFootprintMB(), ApolloSimDebugFootprintMB() - baseline);
    if (remaining <= 0) {
        [sApolloSimDebugGIFView removeFromSuperview];
        sApolloSimDebugGIFView = nil;
        sApolloSimDebugGIFImage = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloLog(@"[gifmem] released: footprint %.0f MB (+%.0f)",
                      ApolloSimDebugFootprintMB(), ApolloSimDebugFootprintMB() - baseline);
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSimDebugSampleGIFMemory(remaining - 1, baseline);
    });
}

static void ApolloSimDebugMeasureGIFMemory(NSString *source) {
    double baseline = ApolloSimDebugFootprintMB();
    ApolloLog(@"[gifmem] baseline footprint %.0f MB, source %@", baseline, source);

    void (^measure)(NSData *) = ^(NSData *data) {
        if (data.length == 0) { ApolloLog(@"[gifmem] no bytes"); return; }
        ApolloLog(@"[gifmem] %.1f MB of source bytes", data.length / 1048576.0);

        UIWindow *window = nil;
        for (UIWindow *candidate in ApolloAllWindows()) if (candidate.isKeyWindow) { window = candidate; break; }
        window = window ?: ApolloAllWindows().firstObject;
        if (!window) { ApolloLog(@"[gifmem] no window"); return; }

        NSDate *start = NSDate.date;
        ApolloGalleryDecodedImage *decoded = [ApolloGalleryImageLoader apollo_debugDecodeData:data];
        if (!decoded) { ApolloLog(@"[gifmem] decode returned nil"); return; }
        ApolloLog(@"[gifmem] decoded %.0fx%.0f in %.2fs, animated=%@",
                  decoded.image.size.width, decoded.image.size.height,
                  -[start timeIntervalSinceNow], decoded.animatedImage ? @"YES" : @"NO");

        // Mounted exactly the way a viewer page mounts it, so the sample covers
        // the frame traffic UIKit generates during playback and not just the
        // decode.
        Class viewClass = NSClassFromString(@"FLAnimatedImageView") ?: UIImageView.class;
        UIImageView *view = [[viewClass alloc] initWithFrame:window.bounds];
        if (decoded.animatedImage && [view respondsToSelector:@selector(setAnimatedImage:)]) {
            [view setValue:decoded.animatedImage forKey:@"animatedImage"];
        } else {
            view.image = decoded.image;
        }
        sApolloSimDebugGIFImage = decoded.image;
        double afterDecode = ApolloSimDebugFootprintMB();
        ApolloLog(@"[gifmem] after build: footprint %.0f MB (+%.0f)", afterDecode, afterDecode - baseline);

        view.contentMode = UIViewContentModeScaleAspectFit;
        [window addSubview:view];
        sApolloSimDebugGIFView = view;
        ApolloLog(@"[gifmem] installed on screen, sampling for 6s…");
        ApolloSimDebugSampleGIFMemory(6, baseline);
    };

    if ([source hasPrefix:@"http"]) {
        NSURL *url = [NSURL URLWithString:source];
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{ measure(data); });
        }] resume];
    } else {
        measure([NSData dataWithContentsOfFile:source]);
    }
}

// "navchurn" command: pop the top controller and push it straight back in the
// same turn. UIKit queues the push and starts it synchronously from inside the
// pop's completeTransition: (the same shape as a push issued from
// didShowViewController:, which nickclyde raised on #1018), so two transitions
// overlap on the stack and ApolloInterruptibleNavTransition must hand each its
// own animator. 1.5 s later this logs what the pair left behind: the stack, the
// interaction flags UIKit/our completion should have restored, the interactive
// in-flight counter, and every sibling of the top view in the transition
// container (a leftover dim/shadow view shows up there as a plain UIView).
static UINavigationController *ApolloSimDebugNavChurnNavigationController(void) {
    UIViewController *vc = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) { vc = window.rootViewController; break; }
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UITabBarController.class]) vc = ((UITabBarController *)vc).selectedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) return (UINavigationController *)vc;
    return vc.navigationController;
}

static void ApolloSimDebugNavChurnReport(UINavigationController *nav, NSString *phase) {
    UIViewController *top = nav.topViewController;
    UIViewController *below = nav.viewControllers.count >= 2
        ? nav.viewControllers[nav.viewControllers.count - 2] : nil;
    NSMutableArray<NSString *> *siblings = [NSMutableArray array];
    for (UIView *view in top.view.superview.subviews) {
        [siblings addObject:[NSString stringWithFormat:@"%@%@%@", NSStringFromClass(view.class),
            view.accessibilityIdentifier ? [@"#" stringByAppendingString:view.accessibilityIdentifier] : @"",
            view == top.view ? @"(top)" : @""]];
    }
    ApolloLog(@"[SimDebugTap] navchurn %@: stack=%lu top=%@ topInteractive=%d belowInteractive=%d "
              "inFlight=%d containerSubviews=[%@]",
              phase, (unsigned long)nav.viewControllers.count, NSStringFromClass(top.class),
              top.view.userInteractionEnabled, below.view.userInteractionEnabled,
              ApolloNavTransitionInFlight(), [siblings componentsJoinedByString:@", "]);
}

// "navchurn appear" variant: the push is issued from the revealed controller's
// viewDidAppear:, which UIKit runs inside the pop's completeTransition:, so the
// pop's completion block is still on the stack when the push is requested.
static __weak UIViewController *sApolloSimNavChurnRevealed;
static __weak UIViewController *sApolloSimNavChurnPopped;

static void ApolloSimDebugNavChurn(NSString *mode) {
    UINavigationController *nav = ApolloSimDebugNavChurnNavigationController();
    if ([mode isEqualToString:@"report"] && nav) {
        ApolloSimDebugNavChurnReport(nav, @"report");
        return;
    }
    if (!nav || nav.viewControllers.count < 2) {
        ApolloLog(@"[SimDebugTap] navchurn: needs a pushed controller (nav=%@ depth=%lu)",
                  nav, (unsigned long)nav.viewControllers.count);
        return;
    }
    ApolloSimDebugNavChurnReport(nav, @"before");
    UIViewController *top = nav.topViewController;
    if ([mode isEqualToString:@"appear"]) {
        sApolloSimNavChurnRevealed = nav.viewControllers[nav.viewControllers.count - 2];
        sApolloSimNavChurnPopped = top;
        ApolloLog(@"[SimDebugTap] navchurn appear: pop %@, push it back from %@'s viewDidAppear:",
                  NSStringFromClass(top.class), NSStringFromClass(sApolloSimNavChurnRevealed.class));
        [nav popViewControllerAnimated:YES];
    } else {
        ApolloLog(@"[SimDebugTap] navchurn: pop %@ and push it back in the same turn",
                  NSStringFromClass(top.class));
        [nav popViewControllerAnimated:YES];
        [nav pushViewController:top animated:YES];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloSimDebugNavChurnReport(nav, @"after");
    });
}

// Grouped on purpose: an ungrouped %hook makes Logos append its registration
// after the closing #endif, where the device build (no APOLLO_SIM_BUILD) has
// none of these declarations. %init(ApolloSimNavChurn) lives in the %ctor below.
%group ApolloSimNavChurn
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *popped = sApolloSimNavChurnPopped;
    if (!popped || self != sApolloSimNavChurnRevealed) return;
    sApolloSimNavChurnRevealed = nil;
    sApolloSimNavChurnPopped = nil;
    UINavigationController *nav = self.navigationController;
    [nav pushViewController:popped animated:YES];
    ApolloLog(@"[SimDebugTap] navchurn appear: pushed %@ from viewDidAppear:; coordinator now %@ "
              "(non-nil means the push started synchronously, inside the pop's completeTransition:)",
              NSStringFromClass(popped.class), nav.transitionCoordinator);
}
%end
%end

// "scrollto Y" command support: pin the tallest on-screen scroll view (the
// comments table on a thread) to a content offset, so a test can land on the
// same comments every run — a synthesized flick's inertia varies run to run.
static UIScrollView *ApolloSimDebugTallestScrollViewIn(UIView *view) {
    UIScrollView *best = nil;
    if ([view isKindOfClass:[UIScrollView class]] && !view.hidden && view.window) {
        best = (UIScrollView *)view;
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *candidate = ApolloSimDebugTallestScrollViewIn(sub);
        if (candidate && (!best || candidate.contentSize.height > best.contentSize.height)) {
            best = candidate;
        }
    }
    return best;
}

static void ApolloSimDebugScrollTo(CGFloat y) {
    UIScrollView *best = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden) continue;
        UIScrollView *candidate = ApolloSimDebugTallestScrollViewIn(window);
        if (candidate && (!best || candidate.contentSize.height > best.contentSize.height)) {
            best = candidate;
        }
    }
    if (!best) { ApolloLog(@"[SimDebugTap] scrollto: no scroll view"); return; }
    CGFloat top = best.adjustedContentInset.top;
    CGFloat maxY = MAX(-top, best.contentSize.height - best.bounds.size.height + best.adjustedContentInset.bottom);
    CGFloat target = MIN(MAX(y - top, -top), maxY);
    [best setContentOffset:CGPointMake(best.contentOffset.x, target) animated:NO];
    ApolloLog(@"[SimDebugTap] scrollto %.0f -> offset %.0f (%@ content %.0f)",
              y, target, NSStringFromClass([best class]), best.contentSize.height);
}

// "lpm on|off" command support: the simulator has no Battery settings pane,
// so Low Power Mode can't be toggled there. Force -[NSProcessInfo
// isLowPowerModeEnabled] instead and post the real power-state notification,
// so the inline-GIF autoplay rules (which must ignore LPM — #634/#1004) and
// anything else listening to the power state react exactly as on a device.
// Swizzled by hand on the CONCRETE class of +[NSProcessInfo processInfo]
// (swift-foundation hands back an _NSSwiftProcessInfo subclass on current
// iOS, so a plain `%hook NSProcessInfo` never sees the call).
static BOOL sApolloSimForceLowPowerMode = NO;
static BOOL (*sApolloSimOrigIsLowPowerModeEnabled)(id, SEL) = NULL;

static BOOL ApolloSimHookedIsLowPowerModeEnabled(id self, SEL _cmd) {
    if (sApolloSimForceLowPowerMode) return YES;
    return sApolloSimOrigIsLowPowerModeEnabled ? sApolloSimOrigIsLowPowerModeEnabled(self, _cmd) : NO;
}

static void ApolloSimInstallLowPowerModeOverride(void) {
    Class cls = object_getClass(NSProcessInfo.processInfo);
    Method m = class_getInstanceMethod(cls, @selector(isLowPowerModeEnabled));
    if (!m) {
        ApolloLog(@"[SimDebugTap] lpm override: no isLowPowerModeEnabled on %@", NSStringFromClass(cls));
        return;
    }
    sApolloSimOrigIsLowPowerModeEnabled = (BOOL (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)ApolloSimHookedIsLowPowerModeEnabled);
    ApolloLog(@"[SimDebugTap] lpm override installed on %@", NSStringFromClass(cls));
}

@interface ASDisplayNode (ApolloSimDebugDisplayGuard)
- (void)setBounds:(CGRect)bounds;
- (CALayer *)layer;
- (void)displayImmediately;
@end

// "bitmapassert" command: push UIKit's legacy image context with a size
// CGBitmapContextCreate rejects, so the SDK-gated assert behind #1097 can be
// observed directly. A glass shell (Apollo relinked against the iOS 26 SDK)
// raises NSInternalInconsistencyException; a classic shell pushes no context
// and raises nothing.
static void ApolloSimDebugBitmapAssert(void) {
    @try {
        UIGraphicsBeginImageContextWithOptions(CGSizeZero, NO, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        ApolloLog(@"[SimDebugTap] bitmapassert: no exception, context %@", context ? @"pushed" : @"absent");
        if (context) UIGraphicsEndImageContext();
    } @catch (NSException *exception) {
        ApolloLog(@"[SimDebugTap] bitmapassert: raised %@: %@", exception.name, exception.reason);
    }
}

// "displayguard W H [capMP]" command: synchronously display a throwaway
// ASTextNode with W x H pt bounds through the same
// _displayBlockWithAsynchronous: path the display queue uses, optionally
// lowering ApolloAsyncDisplayGuard's pixel budget to capMP megapixels first
// (restored afterwards), and log whether the guard skipped the display, caught
// UIKit's assert, or the node rendered.
static void ApolloSimDebugDisplayGuardTest(NSString *payload) {
    NSMutableArray<NSString *> *numbers = [NSMutableArray array];
    for (NSString *part in [payload componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length > 0) [numbers addObject:part];
    }
    if (numbers.count < 2) { ApolloLog(@"[SimDebugTap] malformed displayguard: %@", payload); return; }
    double width = numbers[0].doubleValue;
    double height = numbers[1].doubleValue;
    double capPixels = numbers.count >= 3 ? numbers[2].doubleValue * 1e6 : 0;
    ApolloAsyncDisplayGuardSetMaxPixelsForTesting(capPixels);

    ASTextNode *node = [[objc_getClass("ASTextNode") alloc] init];
    node.attributedText = [[NSAttributedString alloc] initWithString:@"display guard test"
                                                          attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:17]}];
    [node setBounds:CGRectMake(0, 0, width, height)];
    CALayer *layer = [node layer];
    ApolloLog(@"[SimDebugTap] displayguard: displaying ASTextNode %.0fx%.0f pt (cap %.0f MP)",
              width, height, ApolloAsyncDisplayGuardMaxPixels() / 1e6);
    @try {
        [node displayImmediately];
        ApolloLog(@"[SimDebugTap] displayguard: returned, contents %@", layer.contents ? @"set" : @"nil");
    } @catch (NSException *exception) {
        ApolloLog(@"[SimDebugTap] displayguard: exception ESCAPED the guard, %@: %@", exception.name, exception.reason);
    }
    ApolloAsyncDisplayGuardSetMaxPixelsForTesting(0);
}

static void ApolloSimDebugTapNotification(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *contents = [NSString stringWithContentsOfFile:ApolloSimTapFile()
                                                       encoding:NSUTF8StringEncoding error:nil];
        if ([contents hasPrefix:@"bitmapassert"]) {
            ApolloSimDebugBitmapAssert();
            return;
        }
        if ([contents hasPrefix:@"displayguard "]) {
            ApolloSimDebugDisplayGuardTest([contents substringFromIndex:13]);
            return;
        }
        if ([contents hasPrefix:@"insetbottom "]) {
            ApolloSimDebugForceBottomInset([[contents substringFromIndex:12] doubleValue]);
            return;
        }
        // "theme apollo|custom" command: switch to Apollo's stock theme (custom
        // theme runtime off) so the stock search field material can be tested,
        // or back to the last custom theme (the backup's), through the same
        // store calls the theme picker makes.
        if ([contents hasPrefix:@"theme "]) {
            NSString *which = [[contents substringFromIndex:6] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([which isEqualToString:@"apollo"]) {
                [[ApolloThemeStore shared] selectApolloTheme];
                ApolloThemeRuntimeReload();
                ApolloLog(@"[SimDebugTap] theme -> apollo (custom runtime off)");
            } else if ([which isEqualToString:@"custom"]) {
                BOOL restored = [[ApolloThemeStore shared] restoreLastCustomSelection];
                ApolloThemeRuntimeReload();
                ApolloLog(@"[SimDebugTap] theme -> custom (restored=%d)", (int)restored);
            }
            return;
        }
        if ([contents hasPrefix:@"sbprobe "]) {
            NSArray<NSString *> *ps = [[[contents substringFromIndex:8] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@" "];
            if (ps.count >= 2) {
                ApolloSimDebugSearchBarProbe(CGPointMake(ps[0].doubleValue, ps[1].doubleValue),
                                             ps.count >= 3 ? ps[2].doubleValue : 1.2,
                                             ps.count >= 4 ? ps[3].doubleValue : 0.0);
            }
            return;
        }
        if ([contents hasPrefix:@"fieldprobe"]) {
            NSString *tag = [[contents substringFromIndex:10] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugFieldProbe(tag.length ? tag : @"probe");
            return;
        }
        if ([contents hasPrefix:@"dump"]) {
            ApolloSimDebugDumpHierarchy();
            return;
        }
        // "headerdump" command: log every visible scroll view's topEdgeEffect
        // state (pointer, hidden, style, tweak stamps) for header debugging.
        if ([contents hasPrefix:@"headerdump"]) {
            ApolloSimDebugDumpHeaderEffects();
            return;
        }
        // "listdiag" command: re-arm the subreddit-list launch geometry
        // recorder (ApolloSubredditListLaunchSettle) against the list
        // controller, so the settle can be observed on a pop-back without a
        // cold launch.
        if ([contents hasPrefix:@"listdiag"]) {
            ApolloSubredditListDiagRearm();
            return;
        }
        // "indexdiag" command: log every known subreddit table's section-index
        // state (native index color, captured native state, overlay) — see
        // ApolloSubredditIndexDebugDescribeTables in ApolloSubredditIndexPolish.
        if ([contents hasPrefix:@"indexdiag"]) {
            ApolloSubredditIndexDebugDescribeTables();
            return;
        }
        // "headerstyle N" command: switch the Header Style setting through the
        // same path as the settings picker (global + persisted default +
        // change notification), so mode switches — including the live
        // install/remove machinery — can be driven from the host. simctl's
        // `defaults write` can't reach the app container's prefs domain.
        if ([contents hasPrefix:@"headerstyle "]) {
            NSInteger mode = [[contents substringFromIndex:12] integerValue];
            sScrollEdgeEffectStyle = mode;
            [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyScrollEdgeEffectStyle];
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloScrollEdgeEffectStyleChangedNotification object:nil];
            ApolloLog(@"[SimDebugTap] headerstyle -> %ld", (long)mode);
            return;
        }
        // "gifmode N" command: set Autoplay Inline GIFs (1 Never, 2 WiFi Only,
        // 3 Always, 4 Tap to Play) through the same defaults write the settings
        // picker makes, so the KVO reload + live refresh of on-screen GIFs run.
        if ([contents hasPrefix:@"gifmode "]) {
            NSInteger mode = [[contents substringFromIndex:8] integerValue];
            [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyAutoplayInlineGIFs];
            ApolloLog(@"[SimDebugTap] gifmode -> %ld", (long)mode);
            return;
        }
        if ([contents hasPrefix:@"scrollto "]) {
            ApolloSimDebugScrollTo([[contents substringFromIndex:9] doubleValue]);
            return;
        }
        if ([contents hasPrefix:@"lpm "]) {
            NSString *payload = [[contents substringFromIndex:4] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            sApolloSimForceLowPowerMode = [payload isEqualToString:@"on"];
            [[NSNotificationCenter defaultCenter] postNotificationName:NSProcessInfoPowerStateDidChangeNotification
                                                                object:NSProcessInfo.processInfo];
            ApolloLog(@"[SimDebugTap] lpm -> %d (isLowPowerModeEnabled=%d)",
                      sApolloSimForceLowPowerMode, NSProcessInfo.processInfo.isLowPowerModeEnabled);
            return;
        }
        if ([contents hasPrefix:@"crash "]) {
            NSString *payload = [[contents substringFromIndex:6] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugPerformCrash(payload);
            return;
        }
        if ([contents hasPrefix:@"navchurn"]) {
            NSString *mode = [[contents substringFromIndex:8] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugNavChurn(mode);
            return;
        }
        // "openurl <url>" command: route a reddit / apollo:// URL through
        // Apollo's own scheme handling from INSIDE the process. `simctl openurl`
        // goes through SpringBoard, which on iOS 26 fronts an "Open in Apollo?"
        // confirmation that no in-process bridge can tap — this skips it.
        if ([contents hasPrefix:@"openurl "]) {
            NSString *raw = [[contents substringFromIndex:8]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURL *url = [NSURL URLWithString:raw];
            NSURL *apolloURL = [url.scheme.lowercaseString isEqualToString:@"apollo"]
                ? url : ApolloURLByConvertingResolvedURLToApolloScheme(url);
            BOOL routed = apolloURL && ApolloRouteResolvedURLViaApolloScheme(apolloURL);
            ApolloLog(@"[SimDebugTap] openurl %@ -> %@", raw, routed ? @"routed" : @"NOT routed");
            return;
        }
        // "devvitjs <js>" command: evaluate JS in the live interactive-post
        // widget's web view and log the result (DOM inspection without a web
        // inspector). See ApolloDevvitDebugEvaluateJS in ApolloDevvitPosts.xm.
        if ([contents hasPrefix:@"devvitjs "]) {
            extern void ApolloDevvitDebugEvaluateJS(NSString *js);
            ApolloDevvitDebugEvaluateJS([contents substringFromIndex:9]);
            return;
        }
        // "chatjs <js>" command: evaluate JS in the most recently created
        // modern Chat/Modmail web view (the Inbox hub's, normally) and log
        // the result. Lets a sim reproduce web-side states the sim's own
        // WebKit never produces — e.g. `chatjs history.replaceState(null,"",
        // "/chat")` inside a room mimics the device's room-under-a-list-URL
        // desync. See ApolloDirectChatDebugEvaluateJS in ApolloDirectChatWeb.xm.
        if ([contents hasPrefix:@"chatjs "]) {
            extern void ApolloDirectChatDebugEvaluateJS(NSString *js);
            ApolloDirectChatDebugEvaluateJS([contents substringFromIndex:7]);
            return;
        }
        // "chatrooms": log the cached chat room directory (names, participants,
        // newest-message timestamps). "chatresolve <subject>|<partner>|<ts>":
        // resolve a chat mirror's room the way a tapped inbox row does and log
        // the result — exercises the titled-subject corroboration guard with
        // arbitrary partner / timestamp combinations.
        if ([contents hasPrefix:@"chatrooms"]) {
            ApolloChatRoomDirectoryDebugDump();
            return;
        }
        if ([contents hasPrefix:@"chatresolve "]) {
            NSArray<NSString *> *parts = [[contents substringFromIndex:12] componentsSeparatedByString:@"|"];
            NSString *subject = parts.count > 0 ? parts[0] : @"";
            NSString *partner = parts.count > 1 && parts[1].length > 0 ? parts[1] : nil;
            NSTimeInterval timestamp = parts.count > 2 ? parts[2].doubleValue : 0;
            ApolloChatRoomDirectoryResolve(subject, partner, timestamp, ^(NSString *chatPath) {
                ApolloLog(@"[SimDebugTap] chatresolve subject=%@ partner=%@ ts=%.0f -> %@",
                          subject, partner ?: @"(nil)", timestamp, chatPath ?: @"(nil: legacy thread)");
            });
            return;
        }
        // "chatunread <t4_fullname>" / "chatread <t4_fullname> [shared]": flip a
        // legacy-inbox message's read state on Reddit through the client the
        // chat-mirror tap uses (the signed-in account's), or with `shared`
        // through RDKClient.sharedClient — Apollo's app-only bootstrap client,
        // whose read mark Reddit ignores. Re-arms a read mirror as unread so the
        // tap -> back -> refresh cycle can be repeated, and shows both outcomes
        // in the log. Main thread: ApolloActiveAccountClient() requires it.
        if ([contents hasPrefix:@"chatunread "] || [contents hasPrefix:@"chatread "]) {
            BOOL unread = [contents hasPrefix:@"chatunread "];
            NSArray<NSString *> *parts = [[[contents substringFromIndex:unread ? 11 : 9]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                componentsSeparatedByString:@" "];
            NSString *fullName = parts.firstObject ?: @"";
            BOOL useShared = parts.count > 1 && [parts[1] isEqualToString:@"shared"];
            dispatch_async(dispatch_get_main_queue(), ^{
                Class clientClass = objc_getClass("RDKClient");
                id client = useShared
                    ? ((id (*)(id, SEL))objc_msgSend)(clientClass, NSSelectorFromString(@"sharedClient"))
                    : ApolloActiveAccountClient();
                SEL selector = NSSelectorFromString(unread ? @"markMessageWithFullNameAsUnread:completion:"
                                                           : @"markMessageWithFullNameAsRead:completion:");
                NSString *label = [NSString stringWithFormat:@"%@ %@ via %@ client",
                                   unread ? @"chatunread" : @"chatread", fullName,
                                   useShared ? @"shared (app-only)" : @"active account"];
                if (!client || ![client respondsToSelector:selector]) {
                    ApolloLog(@"[SimDebugTap] %@ -> no client (%@)", label, client ? @"selector missing" : @"nil");
                    return;
                }
                void (^completion)(NSError *) = ^(NSError *error) {
                    ApolloLog(@"[SimDebugTap] %@ -> %@", label,
                              error ? [NSString stringWithFormat:@"FAILED: %@", error] : @"ok");
                };
                ((id (*)(id, SEL, id, id))objc_msgSend)(client, selector, fullName, completion);
            });
            return;
        }
        // "devvitload <url>": load another URL in the first on-window widget.
        if ([contents hasPrefix:@"devvitload "]) {
            extern void ApolloDevvitDebugLoadURL(NSString *urlString);
            ApolloDevvitDebugLoadURL([[contents substringFromIndex:11]
                                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
            return;
        }
        // "devvitstats": live/parked/detached widget population + prewarm state.
        if ([contents hasPrefix:@"devvitstats"]) {
            extern void ApolloDevvitDebugStats(void);
            ApolloDevvitDebugStats();
            return;
        }
        // "devvittoggle posts|feed on|off": flip a Devvit setting like its switch.
        if ([contents hasPrefix:@"devvittoggle "]) {
            extern void ApolloDevvitDebugToggle(NSString *which, BOOL on);
            NSArray *parts = [[contents substringFromIndex:13] componentsSeparatedByString:@" "];
            if (parts.count >= 2) ApolloDevvitDebugToggle(parts[0], [parts[1] isEqualToString:@"on"]);
            return;
        }
        // "memwarn": simulate a memory warning in-process.
        if ([contents hasPrefix:@"memwarn"]) {
            SEL sel = NSSelectorFromString(@"_performMemoryWarning");
            UIApplication *app = UIApplication.sharedApplication;
            if ([app respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(app, sel);
                ApolloLog(@"[SimDebugTap] memory warning simulated");
            } else {
                ApolloLog(@"[SimDebugTap] memory warning: _performMemoryWarning unavailable");
            }
            return;
        }
        // "devvitlayout": dump widget-vs-host geometry, force a host layout
        // pass, dump again.
        if ([contents hasPrefix:@"devvitlayout"]) {
            extern void ApolloDevvitDebugLayout(void);
            ApolloDevvitDebugLayout();
            return;
        }
        // "devvitsweep": run the interactive-post stale-width sweep now, with
        // a per-surface geometry dump.
        if ([contents hasPrefix:@"devvitsweep"]) {
            extern void ApolloDevvitDebugSweep(void);
            ApolloDevvitDebugSweep();
            return;
        }
        if ([contents hasPrefix:@"mediastate"]) {
            ApolloSimDebugDumpMediaState();
            return;
        }
        // "rotate <landscape|portrait>" command: rotate the scene from inside
        // the app — Simulator.app menu automation needs accessibility grants a
        // headless agent doesn't have, and simctl has no rotate.
        if ([contents hasPrefix:@"rotate "]) {
            NSString *dir = [[contents substringFromIndex:7] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (@available(iOS 16.0, *)) {
                UIInterfaceOrientationMask mask = [dir isEqualToString:@"landscape"]
                    ? UIInterfaceOrientationMaskLandscapeRight
                    : UIInterfaceOrientationMaskPortrait;
                UIWindowScene *scene = ApolloAllWindows().firstObject.windowScene;
                if (!scene) { ApolloLog(@"[SimDebugTap] rotate: no window scene"); return; }
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
                [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                    ApolloLog(@"[SimDebugTap] rotate error: %@", error.localizedDescription);
                }];
                ApolloLog(@"[SimDebugTap] rotate -> %@", dir);
            } else {
                ApolloLog(@"[SimDebugTap] rotate: needs iOS 16+");
            }
            return;
        }
        if ([contents hasPrefix:@"insight "]) {
            NSString *fullName = [[contents substringFromIndex:8]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *username = ApolloActiveAccountUsername();
            ApolloFetchCommentVoteInsight(fullName, username,
                ^(ApolloCommentVoteInsight *insight, NSError *error) {
                    ApolloLog(@"[SimDebugTap] insight %@ ratio=%.1f upvotes=%lld error=%@",
                              fullName, insight.upvotePercent, insight.reportedUpvotes,
                              error.localizedDescription ?: @"none");
                });
            return;
        }
        // "linkpreview <url>" command: run the real link-preview fetch against
        // an arbitrary page and log what came back. Exercising the fetcher
        // needs no Reddit account, so metadata extraction — charset handling
        // above all (issue #945) — can be verified against live foreign-language
        // pages on a signed-out simulator.
        // "gifmem <path-or-url>" command: measure what the gallery viewer's
        // animated-GIF path actually costs in resident memory. Decodes with the
        // shipping loader entry point, hangs the result on a real on-screen
        // UIImageView, and samples phys_footprint across the first animation
        // loops — the point where issue #1000's jetsam happened.
        if ([contents hasPrefix:@"gifmem "]) {
            NSString *arg = [[contents substringFromIndex:7] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugMeasureGIFMemory(arg);
            return;
        }
        if ([contents hasPrefix:@"linkpreview "]) {
            NSString *urlString = [[contents substringFromIndex:12] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURL *previewURL = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
            if (!previewURL) { ApolloLog(@"[SimDebugTap] malformed linkpreview url: %@", urlString); return; }
            [ApolloLinkPreviewFetcher requestPreviewForURL:previewURL completion:^(ApolloLinkPreview *preview) {
                ApolloLog(@"[SimDebugTap] linkpreview %@\n  site=%@\n  title=%@\n  desc=%@\n  image=%@",
                          urlString, preview.siteName ?: @"(nil)", preview.title ?: @"(nil)",
                          preview.desc ?: @"(nil)", preview.imageURL.absoluteString ?: @"(nil)");
            }];
            return;
        }
        // "safari <url>" command: present Apollo's own in-app browser
        // (ApolloSafariViewController, the SFSafariViewController subclass
        // behind "In-App Safari") for a URL from the topmost view controller,
        // exactly as a link tap would. Needs no Reddit session, so the
        // loading-state appearance (issue #1008) can be exercised headlessly.
        if ([contents hasPrefix:@"safari "]) {
            NSString *urlString = [[contents substringFromIndex:7] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
            if (!url) { ApolloLog(@"[SimDebugTap] malformed safari url: %@", urlString); return; }
            UIViewController *top = nil;
            for (UIWindow *window in ApolloAllWindows()) {
                if (window.hidden || !window.rootViewController) continue;
                top = window.rootViewController;
                if (window.isKeyWindow) break;
            }
            while (top.presentedViewController) top = top.presentedViewController;
            Class safariClass = objc_getClass("_TtC6Apollo26ApolloSafariViewController");
            if (!top || !safariClass) { ApolloLog(@"[SimDebugTap] safari: no presenter/class"); return; }
            id (*msgSend)(id, SEL, NSURL *) = (id (*)(id, SEL, NSURL *))objc_msgSend;
            UIViewController *safariVC = msgSend([safariClass alloc], @selector(initWithURL:), url);
            ApolloLog(@"[SimDebugTap] safari: presenting %@ for %@ from %@",
                      NSStringFromClass(safariVC.class), urlString, NSStringFromClass(top.class));
            [top presentViewController:safariVC animated:YES completion:nil];
            return;
        }
        // "translate <google|libre|auto> <text>" command: run text through the
        // real translation provider pipeline and log the result. Needs no
        // Reddit session — isolates provider/network failures (issue #995).
        if ([contents hasPrefix:@"translate "]) {
            NSString *spec = [[contents substringFromIndex:10] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloTranslationDebugProbe(spec);
            return;
        }
        if ([contents hasPrefix:@"text "]) {
            NSString *payload = [[contents substringFromIndex:5] stringByTrimmingCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            ApolloSimDebugTypeText(payload);
            return;
        }
        // "floattab <keep|state|tap N|close N|release N cx cy vx vy>": drive
        // the Floating Post Tabs feature headlessly (create a tab from the
        // topmost comments view, tap/close bubbles, run the real end-of-drag
        // pipeline for magnet/tuck/dock testing, dump tab state to the log).
        if ([contents hasPrefix:@"floattab "]) {
            NSString *payload = [[contents substringFromIndex:9] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloFloatingTabsDebugCommand(payload);
            return;
        }
        BOOL isSwipe = [contents hasPrefix:@"swipe "];
        BOOL isHold = [contents hasPrefix:@"hold "];
        BOOL isPress = [contents hasPrefix:@"press "];
        NSString *coordString = isSwipe ? [contents substringFromIndex:6]
                              : isHold  ? [contents substringFromIndex:5]
                              : isPress ? [contents substringFromIndex:6]
                                        : contents;
        NSArray<NSString *> *parts = [coordString componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray<NSString *> *numbers = [NSMutableArray array];
        for (NSString *part in parts) if (part.length > 0) [numbers addObject:part];
        if (isSwipe) {
            if (numbers.count < 4) { ApolloLog(@"[SimDebugTap] malformed swipe: %@", contents); return; }
            // Optional 5th/6th/7th numbers: step count, per-step interval in
            // seconds, and a settle time (seconds) the finger holds still at
            // the end point before lifting (0 = lift immediately, with momentum).
            int steps = numbers.count >= 5 ? MAX(1, numbers[4].intValue) : 12;
            NSTimeInterval interval = numbers.count >= 6 ? MAX(0.001, numbers[5].doubleValue) : 0.012;
            NSTimeInterval settle = numbers.count >= 7 ? MAX(0.0, numbers[6].doubleValue) : 0.0;
            ApolloSimDebugPerformSwipeTimed(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue),
                                            CGPointMake(numbers[2].doubleValue, numbers[3].doubleValue),
                                            steps, interval, settle);
            return;
        }
        if (isHold) {
            if (numbers.count < 2) { ApolloLog(@"[SimDebugTap] malformed hold: %@", contents); return; }
            ApolloSimDebugPerformHold(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue));
            return;
        }
        if (isPress) {
            if (numbers.count < 2) { ApolloLog(@"[SimDebugTap] malformed press: %@", contents); return; }
            NSTimeInterval duration = numbers.count >= 3 ? numbers[2].doubleValue : 0.8;
            ApolloSimDebugPerformPress(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue),
                                       duration);
            return;
        }
        if (numbers.count < 2) {
            ApolloLog(@"[SimDebugTap] malformed tap file: %@", contents ?: @"(missing)");
            return;
        }
        ApolloSimDebugPerformTap(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue));
    });
}


%ctor {
    %init(ApolloSimNavChurn);
    ApolloSimInstallLowPowerModeOverride();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        ApolloSimDebugTapNotification, (__bridge CFStringRef)ApolloSimTapNotify(), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    ApolloLog(@"[SimDebugTap] listening for %@ (commands from %@)", ApolloSimTapNotify(), ApolloSimTapFile());
    ApolloLog(@"[CommentInsights][parser] self-tests %@",
              ApolloCommentVoteInsightsRunParserSelfTests() ? @"passed" : @"FAILED");
    NSString *charsetFailure = nil;
    BOOL charsetOK = ApolloWebTextDecodingRunSelfTests(&charsetFailure);
    ApolloLog(@"[WebTextDecoding] self-tests %@", charsetOK ? @"passed"
              : [NSString stringWithFormat:@"FAILED at \"%@\"", charsetFailure]);
}

#endif
