// Touch ID & Passcode lock: start the relaunch prompt once the scene is active.
//
// With the lock on, Apollo's sceneWillEnterForeground: blurs the window and
// asks for Touch ID right away (Padlock, sub_1000ffea4 in 1.15.11). The scene
// is still inactive then, and if the app was left in landscape it's still in
// the portrait orientation of the Home Screen. The system places its Touch ID
// hint for that orientation, so on a landscape device it points at the bottom
// right instead of at the side button.
//
// The blur still goes up right away. Only the Touch ID request made during
// sceneWillEnterForeground: waits for UISceneDidActivateNotification, when the
// scene is back in its real orientation. Other requests (the "Tap above to
// unlock" button, the Settings toggle) run as normal.

#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Set only while Apollo's sceneWillEnterForeground: runs, so other Touch ID
// requests pass straight through.
static __weak UIScene *sForegroundingScene = nil;

// The one held request. Apollo asks again on every foreground, so a newer
// request replaces one whose scene never became active.
static LAContext *sPendingContext = nil;
static LAPolicy sPendingPolicy = LAPolicyDeviceOwnerAuthentication;
static NSString *sPendingReason = nil;
static void (^sPendingReply)(BOOL, NSError *) = nil;
static id sPendingObserver = nil;

static void ApolloPasscodePromptClearPending(void) {
    if (sPendingObserver) [[NSNotificationCenter defaultCenter] removeObserver:sPendingObserver];
    sPendingObserver = nil;
    sPendingContext = nil;
    sPendingReason = nil;
    sPendingReply = nil;
}

static void ApolloPasscodePromptRunPending(NSString *why) {
    LAContext *context = sPendingContext;
    LAPolicy policy = sPendingPolicy;
    NSString *reason = sPendingReason;
    void (^reply)(BOOL, NSError *) = sPendingReply;
    ApolloPasscodePromptClearPending();
    if (!context || !reply) return;
    ApolloLog(@"[PasscodePrompt] running held lock prompt (%@)", why);
    [context evaluatePolicy:policy localizedReason:reason reply:reply];
}

%group ApolloPasscodeLockPromptHooks

%hook LAContext

- (void)evaluatePolicy:(LAPolicy)policy localizedReason:(NSString *)localizedReason reply:(void (^)(BOOL, NSError *))reply {
    UIScene *scene = sForegroundingScene;
    if (!scene || !reply || ![NSThread isMainThread] ||
        scene.activationState == UISceneActivationStateForegroundActive) {
        %orig;
        return;
    }

    if (sPendingReply) ApolloLog(@"[PasscodePrompt] replacing a held lock prompt whose scene never activated");
    ApolloPasscodePromptClearPending();
    sPendingContext = self;
    sPendingPolicy = policy;
    sPendingReason = [localizedReason copy];
    sPendingReply = [reply copy];

    __weak UIScene *weakScene = scene;
    sPendingObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UISceneDidActivateNotification object:scene queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        // Wait one more main-queue turn so the rotation finishes before the
        // system places the hint.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakScene) {
                ApolloPasscodePromptClearPending();
                return;
            }
            ApolloPasscodePromptRunPending(@"scene activated");
        });
    }];
    ApolloLog(@"[PasscodePrompt] holding lock prompt until the scene activates (state=%ld)",
              (long)scene.activationState);
}

%end

%hook ApolloSceneDelegate

- (void)sceneWillEnterForeground:(UIScene *)scene {
    UIScene *previous = sForegroundingScene;
    sForegroundingScene = scene;
    %orig;
    sForegroundingScene = previous;
}

%end

%end

%ctor {
    Class sceneDelegateClass = objc_getClass("_TtC6Apollo13SceneDelegate");
    if (!class_getInstanceMethod(sceneDelegateClass, @selector(sceneWillEnterForeground:))) {
        ApolloLog(@"[PasscodePrompt] SceneDelegate changed shape; hook NOT installed");
        return;
    }
    %init(ApolloPasscodeLockPromptHooks, ApolloSceneDelegate = sceneDelegateClass);
    ApolloLog(@"[PasscodePrompt] lock prompt deferral hook installed");
}
