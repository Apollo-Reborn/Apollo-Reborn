#import "ApolloDeviceDisplay.h"
#import "ApolloDeviceGeometry.h"

#import <objc/runtime.h>

#import "ApolloCommon.h"

static Class ApolloThemeableWindowClass(void) {
    return objc_getClass("_TtC6Apollo15ThemeableWindow");
}

UIWindow *ApolloDeviceAppWindow(void) {
    Class themeable = ApolloThemeableWindowClass();
    UIWindow *fallback = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (![window isKindOfClass:[UIWindow class]] || window.hidden) continue;
        if (themeable && [window isKindOfClass:themeable]) return window;
        if (!fallback
            && window.windowLevel == UIWindowLevelNormal
            && window.rootViewController) {
            fallback = window;
        }
    }
    return fallback;
}

// The scene's coordinate space is the app's allotted area, including a
// side-by-side multitasking window. A smaller scene is not a letterboxed
// window: promoting it to screen.bounds stretches content outside that area
// and incorrectly keeps the two-column layout enabled.
CGRect ApolloDeviceSceneCanvasRect(UIWindowScene *scene) {
    if (!scene) return CGRectZero;
    if (@available(iOS 26.0, *)) {
        return scene.effectiveGeometry.coordinateSpace.bounds;
    }
    return scene.coordinateSpace.bounds;
}

void ApolloDeviceFillWindowToActiveCanvas(UIWindow *window) {
    if (!window) return;
    static BOOL filling = NO;
    if (filling) return;
    filling = YES;

    // Once attached, UIKit owns which scene/display this window belongs to.
    // A larger connected display must never override that assignment.
    if (!window.windowScene) window.windowScene = ApolloDevicePreferredWindowScene();
    CGRect canvas = ApolloDeviceSceneCanvasRect(window.windowScene);
    if (!CGRectIsEmpty(canvas)) {
        CGRect frame = window.frame;
        if (fabs(frame.size.width - canvas.size.width) >= 1.0
            || fabs(frame.size.height - canvas.size.height) >= 1.0
            || fabs(frame.origin.x - canvas.origin.x) >= 1.0
            || fabs(frame.origin.y - canvas.origin.y) >= 1.0) {
            ApolloLog(@"[DeviceDisplay] Fitting window %.0fx%.0f to assigned scene %.0fx%.0f",
                      frame.size.width, frame.size.height, canvas.size.width, canvas.size.height);
            window.frame = canvas;
            UIView *root = window.rootViewController.view;
            root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [root setNeedsLayout];
            [root layoutIfNeeded];
        }
    }
    filling = NO;
}

void ApolloDeviceFillAppWindowToActiveCanvas(void) {
    ApolloDeviceFillWindowToActiveCanvas(ApolloDeviceAppWindow());
}
