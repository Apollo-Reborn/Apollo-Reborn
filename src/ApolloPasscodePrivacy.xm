// Keep Apollo's content opaque until its native passcode/biometric gate is in
// place. The app creates and reveals its native Padlock blur asynchronously;
// without this cover, the already-restored feed can be composited first.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

#import "ApolloPasscodePrivacyPolicy.h"
#import "ApolloSwiftRuntime.h"

static NSString *const ApolloPasscodeLockEnabledKey = @"TouchIDPasscodeLockEnabled";
static NSString *const ApolloPasscodeAuthenticationDelayKey = @"AuthenticationTimeDelay";
static char ApolloPasscodePrivacyCoverAssociationKey;
static char ApolloPasscodePrivacyPadlockCoverAssociationKey;
static char ApolloPasscodePrivacyModalViewAssociationKey;
static char ApolloPasscodePrivacyPriorModalAssociationKey;
static char ApolloPasscodePrivacySiblingStatesAssociationKey;

@interface ApolloPasscodePrivacySiblingState : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic) BOOL priorAccessibilityElementsHidden;
@property (nonatomic) BOOL priorUserInteractionEnabled;
@end

@implementation ApolloPasscodePrivacySiblingState
@end

static UIWindow *ApolloPasscodePrivacyWindowForSceneDelegate(id sceneDelegate) {
    id candidate = ApolloReadObjectIvar(sceneDelegate, "window");
    return [candidate isKindOfClass:[UIWindow class]] ? candidate : nil;
}

static UIView *ApolloPasscodePrivacyNativeBlurForSceneDelegate(id sceneDelegate) {
    id padlock = ApolloReadObjectIvar(sceneDelegate, "padlock");
    id candidate = ApolloReadObjectIvar(padlock, "blurOverlayView");
    return [candidate isKindOfClass:[UIView class]] ? candidate : nil;
}

static BOOL ApolloPasscodePrivacyReadLastUnlockedBackgroundTime(id padlock,
                                                               NSTimeInterval *time) {
    Class padlockClass = object_getClass(padlock);
    Ivar ivar = class_getInstanceVariable(padlockClass,
                                          "mostRecentEnterBackgroundTimeWhileAppUnlocked");
    if (!ivar) return NO;

    // Current Apollo stores Swift Optional<TimeInterval> inline as the Double
    // payload followed by its one-byte discriminator (0 = some, 1 = none).
    // Missing/unknown layout or a corrupt payload fails closed as a cold
    // launch. Bounds are checked before touching the private Swift storage.
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(padlockClass);
    size_t storageSize = sizeof(NSTimeInterval) + sizeof(uint8_t);
    if (offset < 0 || (size_t)offset > instanceSize ||
        storageSize > instanceSize - (size_t)offset) {
        return NO;
    }

    uint8_t *storage = (uint8_t *)(__bridge void *)padlock + (size_t)offset;
    uint8_t discriminator = 1;
    memcpy(&discriminator, storage + sizeof(NSTimeInterval), sizeof(discriminator));
    if (discriminator != 0) return NO;

    NSTimeInterval value = 0;
    memcpy(&value, storage, sizeof(value));
    if (!isfinite(value)) return NO;
    *time = value;
    return YES;
}

static void ApolloPasscodePrivacyRestoreAccessibility(UIView *cover) {
    UIView *modalView = objc_getAssociatedObject(cover,
                                                 &ApolloPasscodePrivacyModalViewAssociationKey);
    NSNumber *priorModal = objc_getAssociatedObject(cover,
                                                     &ApolloPasscodePrivacyPriorModalAssociationKey);
    if (modalView && priorModal) modalView.accessibilityViewIsModal = priorModal.boolValue;

    objc_setAssociatedObject(cover, &ApolloPasscodePrivacyModalViewAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cover, &ApolloPasscodePrivacyPriorModalAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cover.accessibilityViewIsModal = NO;
    cover.isAccessibilityElement = NO;
    cover.accessibilityLabel = nil;

    NSArray<ApolloPasscodePrivacySiblingState *> *states = objc_getAssociatedObject(
        cover, &ApolloPasscodePrivacySiblingStatesAssociationKey);
    for (ApolloPasscodePrivacySiblingState *state in states) {
        state.view.accessibilityElementsHidden = state.priorAccessibilityElementsHidden;
        state.view.userInteractionEnabled = state.priorUserInteractionEnabled;
    }
    objc_setAssociatedObject(cover, &ApolloPasscodePrivacySiblingStatesAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloPasscodePrivacyProtectAccessibility(UIView *cover,
                                                      UIView *nativeBlur,
                                                      UIWindow *window) {
    UIView *previousModalView = objc_getAssociatedObject(
        cover, &ApolloPasscodePrivacyModalViewAssociationKey);
    NSNumber *previousModal = objc_getAssociatedObject(
        cover, &ApolloPasscodePrivacyPriorModalAssociationKey);

    if (previousModalView != nativeBlur) {
        if (previousModalView && previousModal) {
            previousModalView.accessibilityViewIsModal = previousModal.boolValue;
        }
        objc_setAssociatedObject(cover, &ApolloPasscodePrivacyModalViewAssociationKey,
                                 nativeBlur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cover, &ApolloPasscodePrivacyPriorModalAssociationKey,
                                 nativeBlur ? @(nativeBlur.accessibilityViewIsModal) : nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (nativeBlur) {
        // VoiceOver remains inside Apollo's native gate while the sibling feed
        // is protected. Preserve and later restore the gate's prior modal bit.
        cover.accessibilityViewIsModal = NO;
        cover.isAccessibilityElement = NO;
        cover.accessibilityLabel = nil;
        nativeBlur.accessibilityViewIsModal = YES;
    } else {
        // Fail closed if a future Apollo build moves or delays its native gate.
        cover.isAccessibilityElement = YES;
        cover.accessibilityLabel = @"Apollo is locked";
        cover.accessibilityViewIsModal = YES;
    }

    NSMutableArray<ApolloPasscodePrivacySiblingState *> *states = objc_getAssociatedObject(
        cover, &ApolloPasscodePrivacySiblingStatesAssociationKey);
    if (!states) {
        states = [NSMutableArray array];
        objc_setAssociatedObject(cover, &ApolloPasscodePrivacySiblingStatesAssociationKey,
                                 states, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // The blur can be attached after the synchronous cover. If it was
    // previously treated as an ordinary sibling, restore its exact state
    // before exempting it so the native unlock controls remain operable.
    if (nativeBlur) {
        for (NSInteger index = (NSInteger)states.count - 1; index >= 0; index--) {
            ApolloPasscodePrivacySiblingState *state = states[(NSUInteger)index];
            if (state.view != nativeBlur) continue;
            nativeBlur.accessibilityElementsHidden = state.priorAccessibilityElementsHidden;
            nativeBlur.userInteractionEnabled = state.priorUserInteractionEnabled;
            [states removeObjectAtIndex:(NSUInteger)index];
        }
    }

    // The cover absorbs ordinary window hits, while disabling every sibling
    // except the native Padlock closes gaps from top-level custom overlays and
    // keeps VoiceOver from traversing protected content. Record each prior bit
    // once so repeated lifecycle callbacks cannot overwrite restoration state.
    for (UIView *sibling in window.subviews) {
        if (sibling == cover || sibling == nativeBlur) continue;
        ApolloPasscodePrivacySiblingState *state = nil;
        for (ApolloPasscodePrivacySiblingState *candidate in states) {
            if (candidate.view == sibling) {
                state = candidate;
                break;
            }
        }
        if (!state) {
            state = [[ApolloPasscodePrivacySiblingState alloc] init];
            state.view = sibling;
            state.priorAccessibilityElementsHidden = sibling.accessibilityElementsHidden;
            state.priorUserInteractionEnabled = sibling.userInteractionEnabled;
            [states addObject:state];
        }
        sibling.accessibilityElementsHidden = YES;
        sibling.userInteractionEnabled = NO;
    }
}

static void ApolloPasscodePrivacyRemoveCoverFromWindow(UIWindow *window) {
    UIView *cover = objc_getAssociatedObject(window, &ApolloPasscodePrivacyCoverAssociationKey);
    ApolloPasscodePrivacyRestoreAccessibility(cover);
    [cover removeFromSuperview];
    objc_setAssociatedObject(window, &ApolloPasscodePrivacyCoverAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloPasscodePrivacySetCoverForSceneDelegate(id sceneDelegate,
                                                          BOOL coverRequired) {
    UIWindow *window = ApolloPasscodePrivacyWindowForSceneDelegate(sceneDelegate);
    if (!window) return;
    if (!coverRequired) {
        UIView *cover = objc_getAssociatedObject(window,
                                                 &ApolloPasscodePrivacyCoverAssociationKey);
        id padlock = ApolloReadObjectIvar(sceneDelegate, "padlock");
        if (objc_getAssociatedObject(padlock,
                                     &ApolloPasscodePrivacyPadlockCoverAssociationKey) == cover) {
            objc_setAssociatedObject(padlock,
                                     &ApolloPasscodePrivacyPadlockCoverAssociationKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ApolloPasscodePrivacyRemoveCoverFromWindow(window);
        return;
    }

    UIView *cover = objc_getAssociatedObject(window, &ApolloPasscodePrivacyCoverAssociationKey);
    if (!cover) {
        cover = [[UIView alloc] initWithFrame:window.bounds];
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // Absorb every hit that falls outside the native gate. The native blur
        // is inserted above this view, so its unlock controls remain usable.
        cover.userInteractionEnabled = YES;
        objc_setAssociatedObject(window, &ApolloPasscodePrivacyCoverAssociationKey, cover,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    cover.frame = window.bounds;
    cover.backgroundColor = UIColor.systemBackgroundColor;
    cover.alpha = 1.0;
    cover.hidden = NO;

    // Keep Apollo's own unlock controls above the opaque cover. Padlock's blur
    // is a direct window child in the current app; if that ever changes, adding
    // the cover last still fails closed until the native overlay is attached.
    UIView *nativeBlur = ApolloPasscodePrivacyNativeBlurForSceneDelegate(sceneDelegate);
    BOOL nativeGateUsable = ApolloPasscodePrivacyNativeGateIsUsable(
        nativeBlur.superview == window, nativeBlur.hidden, nativeBlur.alpha);
    if (nativeGateUsable) {
        [window insertSubview:cover belowSubview:nativeBlur];
    } else {
        // A detached, nested, hidden, or transparent blur is not a usable
        // native gate. Keep the cover modal instead of disabling an ancestor
        // that could also disable Apollo's unlock controls.
        nativeBlur = nil;
        [window addSubview:cover];
    }
    ApolloPasscodePrivacyProtectAccessibility(cover, nativeBlur, window);

    id padlock = ApolloReadObjectIvar(sceneDelegate, "padlock");
    if (padlock) {
        // Associate the cover with this scene's Padlock as well, so an unlock
        // in one scene never reveals a different scene's protected content.
        objc_setAssociatedObject(padlock, &ApolloPasscodePrivacyPadlockCoverAssociationKey,
                                 cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloPasscodePrivacyUpdateCoverForSceneDelegate(id sceneDelegate,
                                                             BOOL backgroundSnapshot) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults boolForKey:ApolloPasscodeLockEnabledKey];
    NSInteger delayMinutes = [defaults integerForKey:ApolloPasscodeAuthenticationDelayKey];

    id padlock = ApolloReadObjectIvar(sceneDelegate, "padlock");
    NSTimeInterval lastBackgroundTime = 0;
    BOOL hasLastBackgroundTime = ApolloPasscodePrivacyReadLastUnlockedBackgroundTime(
        padlock, &lastBackgroundTime);
    BOOL coverRequired = backgroundSnapshot
        ? ApolloPasscodePrivacyBackgroundCoverRequired(enabled, delayMinutes)
        : ApolloPasscodePrivacyCoverRequired(
            enabled, delayMinutes, hasLastBackgroundTime, lastBackgroundTime,
            NSProcessInfo.processInfo.systemUptime);
    ApolloPasscodePrivacySetCoverForSceneDelegate(sceneDelegate, coverRequired);
}

static void ApolloPasscodePrivacyInstallForegroundPreflightCover(id sceneDelegate) {
    // Cover every enabled-lock foreground transition before Apollo evaluates
    // its delay. This brackets the native check and eliminates a threshold
    // race without guessing at an earlier wall-clock value.
    BOOL enabled = [NSUserDefaults.standardUserDefaults
        boolForKey:ApolloPasscodeLockEnabledKey];
    ApolloPasscodePrivacySetCoverForSceneDelegate(sceneDelegate, enabled);
}

static void ApolloPasscodePrivacyReconcileForegroundCover(id sceneDelegate) {
    UIView *nativeBlur = ApolloPasscodePrivacyNativeBlurForSceneDelegate(sceneDelegate);
    BOOL enabled = [NSUserDefaults.standardUserDefaults
        boolForKey:ApolloPasscodeLockEnabledKey];

    // Current Apollo's native decision synchronously sets alpha to 1 and adds
    // this exact blur directly to the scene window when a gate is required;
    // its no-lock path sets alpha to 0. Reconcile from that native result
    // after %orig instead of re-reading time and introducing another race.
    BOOL nativeGateRequired = ApolloPasscodePrivacyNativeGateRequiresCover(
        enabled, nativeBlur != nil, nativeBlur.alpha);
    ApolloPasscodePrivacySetCoverForSceneDelegate(sceneDelegate, nativeGateRequired);
}

static void ApolloPasscodePrivacyRemoveCoverForPadlock(id padlock) {
    UIView *cover = objc_getAssociatedObject(padlock,
                                             &ApolloPasscodePrivacyPadlockCoverAssociationKey);
    UIView *container = cover.superview;
    if ([container isKindOfClass:[UIWindow class]] &&
        objc_getAssociatedObject(container, &ApolloPasscodePrivacyCoverAssociationKey) == cover) {
        ApolloPasscodePrivacyRemoveCoverFromWindow((UIWindow *)container);
    } else {
        ApolloPasscodePrivacyRestoreAccessibility(cover);
        [cover removeFromSuperview];
    }
    objc_setAssociatedObject(padlock, &ApolloPasscodePrivacyPadlockCoverAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC6Apollo13SceneDelegate

- (void)scene:(UIScene *)scene
        willConnectToSession:(UISceneSession *)session
        options:(UISceneConnectionOptions *)connectionOptions {
    %orig;
    // UIKit cannot present the new scene until this callback returns, so this
    // closes the cold-launch gap after Apollo has created its window/Padlock.
    ApolloPasscodePrivacyUpdateCoverForSceneDelegate(self, NO);
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    ApolloPasscodePrivacyInstallForegroundPreflightCover(self);
    %orig;
    ApolloPasscodePrivacyReconcileForegroundCover(self);
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Also protect the task-switcher snapshot that will be used on the next
    // foreground transition.
    ApolloPasscodePrivacyUpdateCoverForSceneDelegate(self, YES);
    %orig;
}

%end

%hook _TtC6Apollo7Padlock

- (void)appUnlockSucceededNotification {
    %orig;
    // Failed or cancelled authentication deliberately leaves the cover in
    // place. Only Apollo's native success transition can reveal content.
    ApolloPasscodePrivacyRemoveCoverForPadlock(self);
}

%end
