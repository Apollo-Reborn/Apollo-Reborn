#import "ApolloState.h"
#import "ApolloSignInSplash.h"
#import "ApolloCommon.h"
#import <objc/message.h>
#import "ApolloWebSessionLoginViewController.h"

// The setup assistant already chose the API-key path. Scope this bypass to a
// synchronous main-thread selector call, never across an async auth session.
static BOOL sStartingAPIKeySignIn;

BOOL ApolloStartAPIKeySignIn(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class]) return NO;
    SEL action = @selector(signInSplashViewSignInButtonTappedWithSender:);
    for (UIViewController *tab in tabs.viewControllers) {
        NSArray *controllers = [tab isKindOfClass:UINavigationController.class]
            ? [(UINavigationController *)tab viewControllers] : @[tab];
        for (UIViewController *controller in controllers) {
            if (![NSStringFromClass(controller.class) isEqualToString:@"Apollo.ProfileViewController"] ||
                ![controller respondsToSelector:action]) continue;
            [controller loadViewIfNeeded];
            sStartingAPIKeySignIn = YES;
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(controller, action, nil);
            } @finally {
                sStartingAPIKeySignIn = NO;
            }
            return YES;
        }
    }
    return NO;
}

// Both ProfileViewController and InboxViewController host a SignInSplashView
// when no account is signed in. Their "Sign In with Reddit" button fires
// -signInSplashViewSignInButtonTappedWithSender:, which normally goes straight
// to the OAuth/API-key sign-in flow.
//
// We intercept that tap and present the two-way chooser (same sheet as the
// account switcher's "Add Account") so the user can pick either OAuth or the
// keyless web-session path. Not gated on the Web JSON master flag: the mode is
// chosen per account at sign-in, and a keyless harvest enables the transport
// flag itself. The "Create Account" button is left untouched.

%hook _TtC6Apollo21ProfileViewController

- (void)signInSplashViewSignInButtonTappedWithSender:(id)sender {
    if (sStartingAPIKeySignIn) {
        %orig(sender);
        return;
    }
    UIViewController *host = (UIViewController *)self;
    void (^originalSignIn)(void) = ^{
        %orig;
    };
    ApolloWebSessionPresentSignInChooser(host, originalSignIn);
}

%end

%hook _TtC6Apollo19InboxViewController

- (void)signInSplashViewSignInButtonTappedWithSender:(id)sender {
    UIViewController *host = (UIViewController *)self;
    void (^originalSignIn)(void) = ^{
        %orig;
    };
    ApolloWebSessionPresentSignInChooser(host, originalSignIn);
}

%end
