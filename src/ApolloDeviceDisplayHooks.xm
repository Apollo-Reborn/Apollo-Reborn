#import "ApolloDeviceDisplay.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloCommon.h"

// Scene connection, activation and window visibility can arrive in the same
// runloop turn. Coalesce them, and never resize a window inside layoutSubviews.
static void ApolloDeviceDisplayApplySoon(void) {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduled = NO;
        ApolloDeviceFillAppWindowToActiveCanvas();
        ApolloDuoRailSync();
    });
}

%hook _TtC6Apollo13SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    %orig;
    ApolloDeviceDisplayApplySoon();
}

%end

%hook _TtC6Apollo15ThemeableWindow

- (void)makeKeyAndVisible {
    %orig;
    ApolloDeviceDisplayApplySoon();
}

- (void)makeKeyWindow {
    %orig;
    ApolloDeviceDisplayApplySoon();
}

- (void)setWindowScene:(UIWindowScene *)windowScene {
    %orig(windowScene);
    ApolloDeviceDisplayApplySoon();
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);
    if (!hidden) ApolloDeviceDisplayApplySoon();
}

- (void)layoutSubviews {
    %orig;
    UIWindow *window = (UIWindow *)self;
    CGRect canvas = ApolloDeviceSceneCanvasRect(window.windowScene);
    if (ApolloDuoNeedsCanvasFill(window.bounds.size.width, window.bounds.size.height,
                               canvas.size.width, canvas.size.height)) {
        ApolloDeviceDisplayApplySoon();
    }
}

%end

%ctor {
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                      UISceneWillEnterForegroundNotification,
                                      UISceneDidActivateNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                ApolloDeviceDisplayApplySoon();
            }];
    }
    ApolloLog(@"[DeviceDisplay] scene canvas hooks installed");
}
