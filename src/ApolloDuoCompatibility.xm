#import "ApolloDuoCompatibility.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloDeviceGeometry.h"
#import "ApolloDuoRail.h"

#import "ApolloCommon.h"

// Duo window / scene compatibility. Step 1: the guest must occupy the
// entire scene canvas before rail chrome is worth installing.
// DeviceDisplay owns the resize math; this file is the Duo-named hook
// surface so a leftover phone-column window cannot survive first layout
// or a fold/unfold.
//
// Mode keys off ApolloDuoModeFromWindow (UIWindow.bounds):
//   Open   = wide landscape → left rail
//   Closed = portrait-sized Duo → right rail
//   Phone  = regular iPhone → stock tab bar
// Do not read UIScreen.mainScreen.bounds for chrome. reservedRegions
// is never called. Do not write frames from layoutSubviews — FillSoon
// is always async.

static void ApolloDuoCompatibilityLogWindow(UIWindow *window, int dual, const char *why) {
    if (!window) {
        ApolloLog(@"[DuoCompatibility] %s: no app window", why);
        return;
    }
    CGSize size = window.bounds.size;
    int mode = ApolloDuoModeFromWindow(window, dual);
    ApolloLog(@"[DuoCompatibility] %s window=%.0fx%.0f wide=%d mode=%d scene=%p",
              why, size.width, size.height,
              ApolloDuoIsWideWindow(window) ? 1 : 0, mode,
              window.windowScene);
}

static int ApolloDuoCompatibilityDualDisplays(void) {
    CGSize sizes[4];
    unsigned count = 0;
    for (UIScreen *screen in [UIScreen screens]) {
        CGSize size = screen.bounds.size;
        if (size.width <= 0.0 || size.height <= 0.0) continue;
        unsigned i;
        int seen = 0;
        for (i = 0; i < count; i++) {
            if (fabs(sizes[i].width - size.width) < 1.0
                && fabs(sizes[i].height - size.height) < 1.0) {
                seen = 1;
                break;
            }
        }
        if (!seen && count < 4) sizes[count++] = size;
    }
    if (count < 2) return 0;
    return ApolloDisplayScreensAreDual(sizes[0].width, sizes[0].height,
                                       sizes[1].width, sizes[1].height);
}

void ApolloDuoCompatibilityFillSoon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = ApolloDeviceAppWindow();
        ApolloDeviceFillWindowToActiveCanvas(window);
        ApolloDuoRailSync();
        int dual = ApolloDuoCompatibilityDualDisplays();
        if (window && ApolloDuoModeFromWindow(window, dual) == ApolloDuoModePhone
            && ApolloDuoNeedsCanvasFill(window.bounds.size.width, window.bounds.size.height,
                                        window.windowScene.screen.bounds.size.width,
                                        window.windowScene.screen.bounds.size.height)) {
            ApolloDuoCompatibilityLogWindow(window, dual, "still narrow after fill");
        }
    });
}

%hook _TtC6Apollo13SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    %orig;
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        CGSize size = windowScene.coordinateSpace.bounds.size;
        ApolloLog(@"[DuoCompatibility] scene connect canvas=%.0fx%.0f (window bounds, not mainScreen)",
                  size.width, size.height);
        ApolloDeviceExpandSceneToScreen(windowScene);
    }
    ApolloDuoCompatibilityFillSoon();
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    %orig;
    ApolloDuoCompatibilityFillSoon();
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    %orig;
    ApolloDuoCompatibilityFillSoon();
}

%end

%hook _TtC6Apollo15ThemeableWindow

- (void)layoutSubviews {
    %orig;
    // Detect a leftover phone column after UIKit's own layout. Never
    // write window.frame here — that is the 25f8a7b class of loop.
    UIWindow *window = (UIWindow *)self;
    UIWindowScene *scene = window.windowScene ?: ApolloDevicePreferredWindowScene();
    CGRect canvas = CGRectZero;
    if (scene) {
        if ([scene.coordinateSpace respondsToSelector:@selector(bounds)]) {
            canvas = scene.coordinateSpace.bounds;
        }
        if (CGRectIsEmpty(canvas) && scene.screen) canvas = scene.screen.bounds;
    }
    if (ApolloDuoNeedsCanvasFill(window.bounds.size.width, window.bounds.size.height,
                                 canvas.size.width, canvas.size.height)) {
        ApolloDuoCompatibilityFillSoon();
    }
}

%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoCompatibilityFillSoon();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoCompatibilityFillSoon();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoCompatibilityFillSoon();
    }];
    ApolloLog(@"[DuoCompatibility] full-canvas hook installed (mode = UIWindow.bounds; Open=left Closed=right)");
}
