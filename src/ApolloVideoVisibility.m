#import "ApolloVideoVisibility.h"
#import "ApolloCommon.h"
#import "ApolloExecutableSDK.h"
#import "fishhook.h"
#include <mach-o/dyld.h>

// Extends the existing PiP midpoint policy to a tab bar on any edge. No layout writes.
static CGRect ApolloVisibleBarRect(UIView *bar, UIWindow *window) {
    if (!bar || bar.window != window) return CGRectNull;
    for (UIView *ancestor = bar; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) return CGRectNull;
    }
    return CGRectIntersection([bar convertRect:bar.bounds toView:window], window.bounds);
}

BOOL ApolloVideoPointIsVisibleInWindow(UIWindow *window, CGPoint point) {
    if (!window || !CGRectContainsPoint(window.bounds, point)) return NO;
    if (![window.rootViewController isKindOfClass:UITabBarController.class]) return YES;
    UITabBarController *tab = (UITabBarController *)window.rootViewController;
    // The Duo outer navigation bar is hidden while its column bars are visible.
    // Walk attached containment instead of picking only one split's detail stack.
    NSMutableArray<UIViewController *> *pending = [NSMutableArray arrayWithArray:tab.selectedViewController ? @[tab.selectedViewController] : @[]];
    for (NSUInteger i = 0; i < pending.count; i++) {
        UIViewController *controller = pending[i];
        UIView *content = controller.viewIfLoaded;
        if (content.window != window || content.hidden || content.alpha <= 0.01) continue;
        if ([controller isKindOfClass:UINavigationController.class]) {
            CGRect navRect = ApolloVisibleBarRect(((UINavigationController *)controller).navigationBar, window);
            // UIKit extends the secondary bar underneath its sibling column.
            UIEdgeInsets safe = content.safeAreaInsets;
            CGRect pane = [content convertRect:UIEdgeInsetsInsetRect(content.bounds,
                UIEdgeInsetsMake(0, safe.left, 0, safe.right)) toView:window];
            navRect = CGRectIntersection(navRect, pane);
            if (!CGRectIsNull(navRect) && point.x >= CGRectGetMinX(navRect) && point.x < CGRectGetMaxX(navRect)) {
                if (navRect.size.width >= navRect.size.height) {
                    if (point.y < CGRectGetMaxY(navRect)) return NO;
                } else if (CGRectContainsPoint(navRect, point)) return NO;
            }
        }
        [pending addObjectsFromArray:controller.childViewControllers];
    }
    CGRect tabRect = ApolloVisibleBarRect(tab.tabBar, window);
    return CGRectIsNull(tabRect) || !CGRectContainsPoint(tabRect, point);
}

static bool (*sOriginalContainsPoint)(CGRect, CGPoint);
static uintptr_t sAutoplayReturnSites[5];

// All five native midpoint checks share this CoreGraphics import. Guard their exact
// return sites so no hit-testing, layout, player state or unrelated rectangle changes.
static bool ApolloAutoplayContainsPoint(CGRect rect, CGPoint point) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    BOOL autoplayCaller = NO;
    for (size_t i = 0; i < 5; i++) {
        if (caller == sAutoplayReturnSites[i]) { autoplayCaller = YES; break; }
    }
    if (autoplayCaller && NSThread.isMainThread) {
        for (UIWindow *window in ApolloAllWindows()) {
            if (![window.rootViewController isKindOfClass:UITabBarController.class]) continue;
            UITabBarController *tab = (UITabBarController *)window.rootViewController;
            CGSize barSize = tab.tabBar.bounds.size;
            if (barSize.height <= barSize.width || barSize.height < window.bounds.size.height / 2) continue;
            UINavigationController *nav = ApolloNavigationControllerForTabChild(tab.selectedViewController);
            if (!nav) continue;
            CGFloat top = CGRectGetMaxY(nav.navigationBar.frame);
            // Match the native rectangle to its owning window, including its negative
            // height on Duo. This is an identity check, never the corrected geometry.
            CGRect native = CGRectMake(0, top, window.bounds.size.width,
                                        window.bounds.size.height - barSize.height - top);
            if (CGRectEqualToRect(rect, native)) return ApolloVideoPointIsVisibleInWindow(window, point);
        }
    }
    return sOriginalContainsPoint(rect, point);
}

static void ApolloInstallVideoVisibility(const struct mach_header *header, intptr_t slide) {
    // Same native-image identity guard as ApolloMaintainerTint. The input IPA is
    // pinned by the builder; rebasing Reborn does not change these closed binaries.
    const uint8_t apolloUUID[16] = {0x9e,0x4e,0xc7,0xac,0x92,0xb8,0x3a,0x03,0x85,0x6c,0xce,0x36,0x64,0xd7,0x6b,0x97};
    const uint8_t textureUUID[16] = {0x99,0xe7,0x08,0x5f,0x15,0xa8,0x36,0x44,0x8c,0xe0,0xb5,0x4f,0x33,0x95,0xe5,0x06};
    BOOL apollo = ApolloMachOHasUUID(header, apolloUUID);
    if (!apollo && !ApolloMachOHasUUID(header, textureUUID)) return;
    const uintptr_t calls[5] = {0x2066f8, 0x206818, 0x308040, 0x30812c, 0xc4cc0};
    const uint32_t instructions[5] = {0x94200d2c, 0x94200ce4, 0x941c06da, 0x941c069f, 0x94004d42};
    uintptr_t base = (uintptr_t)header;
    size_t first = apollo ? 0 : 4, end = apollo ? 4 : 5;
    for (size_t i = first; i < end; i++) {
        if (*(const uint32_t *)(base + calls[i]) != instructions[i]) {
            ApolloLogError(@"[VideoVisibility] unsupported native call instruction; hook inactive");
            return;
        }
    }
    rebind_symbols_image((void *)header, slide, (struct rebinding[]) {
        {"CGRectContainsPoint", (void *)ApolloAutoplayContainsPoint, NULL}
    }, 1);
    uintptr_t importSlot = apollo ? 0xbb4ee0 : 0x1406f8;
    if (*(void **)(base + importSlot) != (void *)ApolloAutoplayContainsPoint) {
        ApolloLogError(@"[VideoVisibility] native import was not rebound; hook inactive");
        return;
    }
    for (size_t i = first; i < end; i++) sAutoplayReturnSites[i] = base + calls[i] + 4;
    ApolloLog(@"[VideoVisibility] %@ autoplay geometry hook installed", apollo ? @"Apollo" : @"Texture");
}

__attribute__((constructor)) static void ApolloVideoVisibilityInit(void) {
    sOriginalContainsPoint = CGRectContainsPoint;
    _dyld_register_func_for_add_image(ApolloInstallVideoVisibility);
}
