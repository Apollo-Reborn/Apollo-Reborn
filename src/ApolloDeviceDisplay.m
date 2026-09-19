#import "ApolloDeviceDisplay.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDeviceGeometry.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

static Class ApolloThemeableWindowClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("_TtC6Apollo15ThemeableWindow");
    });
    return cls;
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

static CGRect ApolloDeviceSceneCanvasRect(UIWindowScene *scene) {
    if (!scene) return CGRectZero;
    CGRect screenBounds = CGRectZero;
    if (scene.screen) screenBounds = scene.screen.bounds;
    CGRect sceneBounds = CGRectZero;
    if ([scene.coordinateSpace respondsToSelector:@selector(bounds)]) {
        sceneBounds = scene.coordinateSpace.bounds;
    }
    if (CGRectIsEmpty(screenBounds)) return sceneBounds;
    if (CGRectIsEmpty(sceneBounds)) return screenBounds;
    if (ApolloDisplayIsLetterboxed(sceneBounds.size.width, sceneBounds.size.height,
                                   screenBounds.size.width, screenBounds.size.height)) {
        return screenBounds;
    }
    return sceneBounds;
}

void ApolloDeviceExpandSceneToScreen(UIWindowScene *scene) {
    if (!scene) return;
    CGRect canvas = ApolloDeviceSceneCanvasRect(scene);
    if (CGRectIsEmpty(canvas)) return;

    id restrictions = nil;
    if ([scene respondsToSelector:@selector(sizeRestrictions)]) {
        restrictions = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(sizeRestrictions));
    }
    if (restrictions) {
        CGSize size = canvas.size;
        SEL setMax = NSSelectorFromString(@"setMaximumSize:");
        SEL setMin = NSSelectorFromString(@"setMinimumSize:");
        if ([restrictions respondsToSelector:setMax]) {
            ((void (*)(id, SEL, CGSize))objc_msgSend)(restrictions, setMax, size);
        }
        if ([restrictions respondsToSelector:setMin]) {
            CGSize minSize = CGSizeMake(size.width < 320.0 ? size.width : 320.0,
                                        size.height < 320.0 ? size.height : 320.0);
            ((void (*)(id, SEL, CGSize))objc_msgSend)(restrictions, setMin, minSize);
        }
    }

    SEL request = @selector(requestGeometryUpdateWithPreferences:errorHandler:);
    if (![scene respondsToSelector:request]) return;

    Class prefsClass = objc_getClass("UIWindowSceneGeometryPreferencesIOS");
    if (!prefsClass) return;
    id prefs = [prefsClass alloc];
    SEL initFrame = NSSelectorFromString(@"initWithSystemFrame:");
    SEL setFrame = NSSelectorFromString(@"setSystemFrame:");
    if ([prefs respondsToSelector:initFrame]) {
        prefs = ((id (*)(id, SEL, CGRect))objc_msgSend)(prefs, initFrame, canvas);
    } else {
        prefs = [prefs init];
        if (prefs && [prefs respondsToSelector:setFrame]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(prefs, setFrame, canvas);
        }
    }
    if (!prefs) return;

    typedef void (*RequestIMP)(id, SEL, id, void (^)(NSError *));
    ((RequestIMP)objc_msgSend)(scene, request, prefs, ^(NSError *error) {
        if (error) {
            ApolloLog(@"[DeviceDisplay] geometry update declined: %@", error.localizedDescription);
        }
    });
}

static CGRect ApolloDuoLargestScreenBounds(void) {
    CGRect best = CGRectZero;
    double bestArea = -1.0;
    for (UIScreen *screen in [UIScreen screens]) {
        CGRect bounds = screen.bounds;
        double area = ApolloDisplayArea(bounds.size.width, bounds.size.height);
        if (area > bestArea) {
            bestArea = area;
            best = bounds;
        }
    }
    return best;
}

static int ApolloDuoConnectedScreensLookDual(void) {
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
        if (!seen && count < 4) {
            sizes[count++] = size;
        }
    }
    if (count < 2) return 0;
    return ApolloDisplayScreensAreDual(sizes[0].width, sizes[0].height,
                                       sizes[1].width, sizes[1].height);
}

static UIWindowScene *ApolloDuoSceneMatchingCanvas(CGRect canvas) {
    UIApplication *application = [UIApplication sharedApplication];
    if (!application || CGRectIsEmpty(canvas)) return nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        CGRect screenBounds = windowScene.screen ? windowScene.screen.bounds : CGRectZero;
        if (ApolloDisplayIsLetterboxed(screenBounds.size.width, screenBounds.size.height,
                                       canvas.size.width, canvas.size.height)) {
            continue;
        }
        if (fabs(screenBounds.size.width - canvas.size.width) < 1.0
            && fabs(screenBounds.size.height - canvas.size.height) < 1.0) {
            return windowScene;
        }
    }
    return nil;
}

static CGRect ApolloDuoTargetCanvasForWindow(UIWindow *window) {
    UIWindowScene *scene = window.windowScene ?: ApolloDevicePreferredWindowScene();
    CGRect sceneCanvas = ApolloDeviceSceneCanvasRect(scene);
    CGRect largest = ApolloDuoLargestScreenBounds();
    if (CGRectIsEmpty(largest)) return sceneCanvas;
    if (ApolloDuoConnectedScreensLookDual()
        && ApolloDuoNeedsCanvasFill(sceneCanvas.size.width, sceneCanvas.size.height,
                                    largest.size.width, largest.size.height)) {
        return largest;
    }
    if (CGRectIsEmpty(sceneCanvas)) return largest;
    return sceneCanvas;
}

void ApolloDeviceFillWindowToActiveCanvas(UIWindow *window) {
    if (!window) return;
    static BOOL filling = NO;
    if (filling) return;
    filling = YES;

    UIWindowScene *scene = window.windowScene;
    UIWindowScene *preferred = ApolloDevicePreferredWindowScene();
    if (preferred && preferred != scene) {
        CGRect preferredCanvas = ApolloDeviceSceneCanvasRect(preferred);
        CGRect currentCanvas = ApolloDeviceSceneCanvasRect(scene);
        if (ApolloDuoNeedsCanvasFill(currentCanvas.size.width, currentCanvas.size.height,
                                     preferredCanvas.size.width, preferredCanvas.size.height)
            || (CGRectIsEmpty(currentCanvas) && !CGRectIsEmpty(preferredCanvas))) {
            window.windowScene = preferred;
            scene = preferred;
            ApolloLog(@"[DeviceDisplay] App window moved to larger scene %p (%.0fx%.0f)",
                      preferred, preferredCanvas.size.width, preferredCanvas.size.height);
        }
    }
    if (!scene && preferred) {
        window.windowScene = preferred;
        scene = preferred;
    }

    CGRect canvas = ApolloDuoTargetCanvasForWindow(window);
    if (ApolloDuoConnectedScreensLookDual()
        && ApolloDuoNeedsCanvasFill(window.bounds.size.width, window.bounds.size.height,
                                    canvas.size.width, canvas.size.height)) {
        UIWindowScene *match = ApolloDuoSceneMatchingCanvas(canvas);
        if (match && match != window.windowScene) {
            window.windowScene = match;
            scene = match;
            ApolloLog(@"[DeviceDisplay] App window moved onto Duo canvas scene %p (%.0fx%.0f)",
                      match, canvas.size.width, canvas.size.height);
        }
    }
    if (scene) {
        ApolloDeviceExpandSceneToScreen(scene);
        if (CGRectIsEmpty(canvas)) {
            canvas = ApolloDeviceSceneCanvasRect(scene);
        }
        if (!CGRectIsEmpty(canvas)) {
            CGRect frame = window.frame;
            if (ApolloDuoNeedsCanvasFill(frame.size.width, frame.size.height,
                                         canvas.size.width, canvas.size.height)
                || fabs(frame.origin.x - canvas.origin.x) >= 1.0
                || fabs(frame.origin.y - canvas.origin.y) >= 1.0) {
                ApolloLog(@"[DeviceDisplay] Filling window %.0fx%.0f @ (%.0f,%.0f) → %.0fx%.0f wide=%d",
                          frame.size.width, frame.size.height, frame.origin.x, frame.origin.y,
                          canvas.size.width, canvas.size.height,
                          ApolloDuoIsWideBounds(canvas.size.width, canvas.size.height));
                window.frame = canvas;
                UIView *root = window.rootViewController.view;
                if (root) {
                    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    if (ApolloDuoNeedsCanvasFill(root.bounds.size.width, root.bounds.size.height,
                                                 window.bounds.size.width, window.bounds.size.height)
                        || fabs(root.frame.origin.x) >= 1.0
                        || fabs(root.frame.origin.y) >= 1.0) {
                        root.frame = window.bounds;
                    }
                    [root setNeedsLayout];
                    [root layoutIfNeeded];
                }
            }
        }
    }
    filling = NO;
}

void ApolloDeviceFillAppWindowToActiveCanvas(void) {
    ApolloDeviceFillWindowToActiveCanvas(ApolloDeviceAppWindow());
}
