// Sim-only dev helper: when the APOLLO_OPEN_ROUTE env var is set, open that
// settings route a few seconds after launch so screens can be screenshotted
// via `simctl io` without any UI taps. Compiled ONLY under APOLLO_SIM_BUILD
// (see the Makefile's sim-only file list), so it is never present in a device
// or release build — the env gate then makes it inert unless deliberately set.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "settings/ApolloSettingsRouter.h"
#import "ApolloCommon.h"
#import "ApolloWebSessionLoginViewController.h"

static UIViewController *ApolloSimVisibleController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    UIViewController *visible = window.rootViewController;
    BOOL changed = YES;
    while (visible && changed) {
        changed = NO;
        if (visible.presentedViewController) {
            visible = visible.presentedViewController;
            changed = YES;
        } else if ([visible isKindOfClass:UINavigationController.class]) {
            visible = ((UINavigationController *)visible).visibleViewController;
            changed = YES;
        } else if ([visible isKindOfClass:UITabBarController.class]) {
            visible = ((UITabBarController *)visible).selectedViewController;
            changed = YES;
        } else if ([visible isKindOfClass:UISplitViewController.class]) {
            visible = ((UISplitViewController *)visible).viewControllers.lastObject;
            changed = YES;
        }
    }
    return visible;
}

__attribute__((constructor))
static void ApolloSimOpenRouteInit(void) {
    const char *route = getenv("APOLLO_OPEN_ROUTE");
    const char *sharePicker = getenv("APOLLO_SIM_SHARE_HOST_PICKER");
    const char *webLogin = getenv("APOLLO_SIM_WEB_LOGIN");
    if ((!route || !route[0]) && (!sharePicker || !sharePicker[0]) && (!webLogin || !webLogin[0])) return;
    NSString *routeId = route && route[0] ? [NSString stringWithUTF8String:route] : nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (routeId.length) {
            ApolloLog(@"[SimOpenRoute] opening route %@", routeId);
            ApolloSettingsRouteOpen(routeId);
        }
        if (webLogin && webLogin[0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *presenter = ApolloSimVisibleController();
                if (!presenter) return;
                UIViewController *login = [ApolloWebSessionLoginViewController new];
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
                [presenter presentViewController:nav animated:NO completion:nil];
                ApolloLog(@"[SimOpenRoute] presented current Reddit web login");
            });
        } else if (sharePicker && sharePicker[0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *presenter = ApolloSimVisibleController();
                SEL selector = NSSelectorFromString(@"presentShareLinkHostSheetFromSourceView:");
                ApolloLog(@"[SimOpenRoute] share picker presenter=%@ responds=%d",
                          NSStringFromClass(presenter.class), [presenter respondsToSelector:selector]);
                if (!presenter || ![presenter respondsToSelector:selector]) return;
                ((void (*)(id, SEL, id))objc_msgSend)(presenter, selector, presenter.view);
                ApolloLog(@"[SimOpenRoute] presented Share Link Host picker");
            });
        }
    });
}
