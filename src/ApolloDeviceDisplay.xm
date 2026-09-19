#import "ApolloDeviceDisplay.h"
#import "ApolloDeviceGeometry.h"

#import "ApolloCommon.h"

// iPhone Duo sizes the guest scene from the *app binary* LC_BUILD_VERSION
// SDK. A 16.0 / 19.0 (iOS 26 glass) guest stays a phone column on the
// inner panel. patch.sh --liquid-glass now advertises 27.1 so UIKit
// grants the full canvas. These hooks are the runtime belt: move the
// ThemeableWindow onto the largest scene when two screens exist, raise
// sizeRestrictions, and resize a leftover letterboxed window. Missing
// 27.1 selectors are skipped (iOS 14).

static void ApolloDeviceDisplayApplySoon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDeviceFillAppWindowToActiveCanvas();
    });
}

%hook _TtC6Apollo13SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    %orig;
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        ApolloDeviceExpandSceneToScreen((UIWindowScene *)scene);
    }
    ApolloDeviceDisplayApplySoon();
}

%end

%hook _TtC6Apollo15ThemeableWindow

- (void)makeKeyAndVisible {
    %orig;
    ApolloDeviceFillWindowToActiveCanvas((UIWindow *)self);
}

- (void)makeKeyWindow {
    %orig;
    ApolloDeviceFillWindowToActiveCanvas((UIWindow *)self);
}

- (void)setWindowScene:(UIWindowScene *)windowScene {
    %orig;
    ApolloDeviceFillWindowToActiveCanvas((UIWindow *)self);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!hidden) ApolloDeviceFillWindowToActiveCanvas((UIWindow *)self);
}

%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDeviceDisplayApplySoon();
    }];
    ApolloLog(@"[DeviceDisplay] canvas fill hook installed");
}
