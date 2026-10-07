#import "ApolloReduceRateLimiting.h"

#import "ApolloCommon.h"            // ApolloLog, ApolloAllWindows
#import "ApolloState.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"   // ApolloActiveWebSessionUsername, ApolloWebSessionUsernames
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"

NSNotificationName const ApolloReduceRateLimitingDidChangeNotification = @"ApolloReduceRateLimitingDidChangeNotification";

BOOL ApolloReduceRateLimitingActive(void) {
    if (!sWebJSONEnabled || !sReduceRateLimiting) return NO;
    // The primary web-session index holds API-key-free accounts only (a session
    // kept just for Chat/Modmail on an API-key account lives in a separate
    // poll-only index), so this is "the active account is API-key-free"
    // without a keychain read.
    NSString *active = ApolloActiveWebSessionUsername().lowercaseString;
    return active.length > 0 && [ApolloWebSessionUsernames() containsObject:active];
}

void ApolloReduceRateLimitingSetEnabled(BOOL enabled) {
    sReduceRateLimiting = enabled;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:UDKeyReduceRateLimiting];
    [defaults setBool:YES forKey:UDKeyReduceRateLimitingOffered];
    ApolloLog(@"[ReduceRateLimiting] turned %@", enabled ? @"on" : @"off");
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloReduceRateLimitingDidChangeNotification object:nil];
}

static BOOL ApolloReduceRateLimitingShouldOffer(void) {
    if (sReduceRateLimiting) return NO;
    return ![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyReduceRateLimitingOffered];
}

// Once the offer is on screen it counts as made, answered or not: it never
// asks twice, and the setting stays in Settings either way.
static void ApolloReduceRateLimitingMarkOffered(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyReduceRateLimitingOffered];
}

static BOOL ApolloReduceRateLimitingCanPresentOn(UIViewController *presenter) {
    return presenter.view.window && !presenter.presentedViewController &&
           !presenter.isBeingPresented && !presenter.isBeingDismissed;
}

static UIAlertController *ApolloReduceRateLimitingAlert(NSString *title, NSString *message, void (^then)(void)) {
    void (^done)(void) = [then copy];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        ApolloLog(@"[ReduceRateLimiting] offer declined");
        if (done) done();
    }]];
    UIAlertAction *turnOn = [UIAlertAction actionWithTitle:@"Turn On"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
        ApolloReduceRateLimitingSetEnabled(YES);
        if (done) done();
    }];
    [alert addAction:turnOn];
    alert.preferredAction = turnOn;
    return alert;
}

void ApolloReduceRateLimitingOfferAtSignIn(UIViewController *presenter, void (^then)(void)) {
    if (!ApolloReduceRateLimitingShouldOffer() || !ApolloReduceRateLimitingCanPresentOn(presenter)) {
        // Not offered, so an account that skips it here still gets it at its
        // first rate limit (ApolloReduceRateLimitingOfferAtRateLimit).
        if (then) then();
        return;
    }
    // The sign-in finishes only through `then`, so it must run exactly once:
    // from either button, or below if UIKit didn't put the alert up at all.
    __block BOOL finished = NO;
    void (^finishOnce)(void) = [^{
        if (finished) return;
        finished = YES;
        if (then) then();
    } copy];
    ApolloLog(@"[ReduceRateLimiting] offering at sign-in");
    UIAlertController *alert = ApolloReduceRateLimitingAlert(
        @"Reduce Rate Limiting?",
        @"Reddit allows fewer requests without an API key. This uses fewer: profile pictures show without frames and Community Highlights refresh less often. You can change it in Settings.",
        finishOnce);
    [presenter presentViewController:alert animated:YES completion:^{ ApolloReduceRateLimitingMarkOffered(); }];
    __weak UIAlertController *weakAlert = alert;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (finished || weakAlert.view.window) return;
        ApolloLog(@"[ReduceRateLimiting] sign-in offer was not shown; finishing the sign-in without it");
        finishOnce();
    });
}

BOOL ApolloReduceRateLimitingOfferAtRateLimit(NSTimeInterval seconds) {
    if (!sWebJSONEnabled || !ApolloReduceRateLimitingShouldOffer()) return NO;
    UIViewController *top = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow && !window.hidden) { top = [window visibleViewController]; break; }
    }
    // Never stack on another alert or the sign-in sheet, or present mid-transition
    // (the first 429 can land while launch is still building the window). The
    // toast covers this limit; the offer waits for the next one.
    if (!top || !ApolloReduceRateLimitingCanPresentOn(top) ||
        [top isKindOfClass:[UIAlertController class]] ||
        [top isKindOfClass:[ApolloWebSessionLoginViewController class]]) {
        return NO;
    }
    NSString *wait = seconds < 60.0
        ? @"Try again in under a minute."
        : [NSString stringWithFormat:@"Try again in about %lu min.", (unsigned long)ceil(seconds / 60.0)];
    ApolloLog(@"[ReduceRateLimiting] offering at a rate limit (%.0fs)", seconds);
    UIAlertController *alert = ApolloReduceRateLimitingAlert(
        @"Reddit Rate Limit Reached",
        [NSString stringWithFormat:@"%@ Reddit allows fewer requests without an API key. Turn on Reduce Rate Limiting to use fewer? You can change it in Settings.", wait],
        nil);
    [top presentViewController:alert animated:YES completion:^{ ApolloReduceRateLimitingMarkOffered(); }];
    return YES;
}
