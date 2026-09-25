#import "ApolloWebAuthViewController.h"
#import "ApolloManualSignInViewController.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionStore.h"
#import "ApolloState.h"
#import "ApolloCommon.h"
#import "Defaults.h"

#import <WebKit/WebKit.h>

@interface ApolloWebAuthViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSURL *authURL;
@property (nonatomic, copy) NSString *redirectURIString;
@property (nonatomic, copy) NSURL *redirectURL;
@property (nonatomic, copy) ASWebAuthenticationSessionCompletionHandler completion;
@property (nonatomic) BOOL finished;
// Set once a rejected-sign-in alert has been shown, so Reddit's own 400
// authorize page (Old Reddit's names the bad field) doesn't stack a second one.
@property (nonatomic) BOOL explainedRejectedSignIn;
@end

@implementation ApolloWebAuthViewController

- (instancetype)initWithURL:(NSURL *)url
                redirectURI:(NSString *)redirectURI
          completionHandler:(ASWebAuthenticationSessionCompletionHandler)completion {
    self = [super init];
    if (self) {
        _authURL = [url copy];
        _redirectURIString = [redirectURI copy];
        _redirectURL = [NSURL URLWithString:redirectURI];
        _completion = [completion copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sign In to Reddit";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(_cancelTapped)];

    // Options menu — "Switch to Old Reddit" (rewrite mid-flow to old.reddit.com,
    // useful on any iOS) and "Manual Sign-In (Reynard)" (external-browser fallback
    // for devices where neither the modern nor old login page renders, e.g. iOS
    // 15.3.1). On iOS 15 and earlier we also auto-rewrite to old.reddit below.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                 menu:nil];
    [self _rebuildOptionsMenu];

    // iOS 15 and earlier can't render the modern Reddit login page.
    // Rewrite www.reddit.com → old.reddit.com before the first load.
    if (![self _isModernRedditSupported]) {
        ApolloLog(@"[WebAuth] iOS < 16 detected — auto-switching to old.reddit.com");
        self.authURL = [self _rewriteToOldReddit:self.authURL];
    }

    // Non-persistent data store mirrors Apollo's prefersEphemeralWebBrowserSession = YES
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                    UIViewAutoresizingFlexibleLeftMargin  | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.center = self.view.center;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    ApolloLog(@"[WebAuth] Loading auth URL: %@", self.authURL);
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.authURL]];
    // Automate transition to manual sign-in for iOS 15.3.1 and below.
    if (@available(iOS 15.4, *)) {
        // iOS 15.4+ is supported. Let the web view load normally.
    } else {
        ApolloLog(@"[WebAuth] iOS <= 15.3.1 detected. Automating manual sign-in fallback.");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _showManualSignIn];
        });
    }
}

- (BOOL)_isModernRedditSupported {
    if (@available(iOS 16, *)) return YES;
    return NO;
}

- (NSURL *)_rewriteToOldReddit:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([c.host isEqualToString:@"www.reddit.com"] || [c.host isEqualToString:@"reddit.com"]) {
        c.host = @"old.reddit.com";
    }
    return c.URL ?: url;
}

- (void)_switchToOldReddit {
    // The grant endpoint has no Old Reddit equivalent, so restart from the
    // authorize request if the web view ever ends up sitting on it.
    NSURL *current = self.webView.URL;
    NSURL *base = (current && ![self _isGrantEndpointURL:current]) ? current : self.authURL;
    NSURL *rewritten = [self _rewriteToOldReddit:base];
    ApolloLog(@"[WebAuth] Switching to old Reddit: %@", rewritten);
    [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
    // didFinishNavigation rebuilds the menu, disabling this action once loaded.
}

// Rebuilds the right-bar options menu, disabling "Switch to Old Reddit" when the
// web view is already on old.reddit.com. Keeping it a menu (rather than toggling
// the bar button's enabled state) means the manual fallback stays reachable.
- (void)_rebuildOptionsMenu {
    BOOL onOldReddit = [self.webView.URL.host isEqualToString:@"old.reddit.com"];
    __weak typeof(self) weakSelf = self;

    UIAction *oldReddit = [UIAction actionWithTitle:@"Switch to Old Reddit"
                                              image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
        [weakSelf _switchToOldReddit];
    }];
    if (onOldReddit) oldReddit.attributes = UIMenuElementAttributesDisabled;

    UIAction *manual = [UIAction actionWithTitle:@"Manual Sign-In (Reynard)"
                                           image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        [weakSelf _showManualSignIn];
    }];

    UIMenu *menu = [UIMenu menuWithTitle:@"Sign-In Options" children:@[oldReddit, manual]];
    self.navigationItem.rightBarButtonItem.menu = menu;
}

- (void)_showManualSignIn {
    __weak typeof(self) weakSelf = self;
    ApolloManualSignInViewController *vc = [[ApolloManualSignInViewController alloc]
        initWithAuthURL:self.authURL
            redirectURI:self.redirectURIString
             onComplete:^(NSURL *callbackURL) {
        ApolloLog(@"[WebAuth] manual sign-in produced callback: %@", callbackURL);
        [weakSelf _finishWithURL:callbackURL error:nil];
    }];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)_cancelTapped {
    ApolloLog(@"[WebAuth] User cancelled sign-in");
    [self _finishWithURL:nil
                   error:[NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain
                                            code:ASWebAuthenticationSessionErrorCodeCanceledLogin
                                        userInfo:nil]];
}

// OAuth has already authenticated Reddit in this webview. Capture its
// cookies before the ephemeral data store is torn down so Chat, Modmail, and
// Polls normally need no second sign-in. This is best-effort and time-bounded;
// the OAuth callback always wins even if Reddit blocks the auxiliary probe.
- (void)_harvestFeatureSessionThenFinishWithURL:(NSURL *)url {
    [self.spinner startAnimating];
    __block BOOL didFinish = NO;
    __weak typeof(self) weakSelf = self;
    void (^finishOnce)(void) = ^{
        if (didFinish) return;
        didFinish = YES;
        [weakSelf _finishWithURL:url error:nil];
    };
    // Safety net: never let a hung probe block sign-in.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!didFinish) {
            ApolloLog(@"[WebAuth] Auxiliary session auto-harvest timed out — completing OAuth");
        }
        finishOnce();
    });
    [ApolloWebSessionLoginViewController harvestFeatureSessionFromWebView:self.webView
                                                               completion:^(__unused NSString *username) {
        finishOnce();
    }];
}

#pragma mark - Rejected sign-in

// Reddit's new consent page (www.reddit.com/api/v1/authorize) no longer checks
// client_id/redirect_uri when it renders. For a key + redirect URI that don't
// match a registered Reddit app it still shows Accept/Decline (with no app name
// and no permission list), and only the POST to /svc/shreddit/oauth-grant
// fails, with a bare HTTP 400 "{}" body — which used to be all the user saw
// (#1232). Old Reddit rejects the same request up front with a 400 page naming
// the bad field ("invalid client id" / "invalid redirect_uri parameter").
// Both verified against reddit.com on 2026-09-25.
- (BOOL)_isRedditHost:(NSString *)host {
    NSString *lower = host.lowercaseString;
    return [lower isEqualToString:@"reddit.com"] || [lower hasSuffix:@".reddit.com"];
}

- (BOOL)_isGrantEndpointURL:(NSURL *)url {
    return [self _isRedditHost:url.host] && [url.path isEqualToString:@"/svc/shreddit/oauth-grant"];
}

// Old Reddit's consent page answers a bad key with a 400 page here. The new
// page currently returns 200 regardless, but is matched on any reddit.com host
// in case Reddit moves that check up front too. Apollo requests either
// /api/v1/authorize or /api/v1/authorize.compact.
- (BOOL)_isAuthorizePageURL:(NSURL *)url {
    return [self _isRedditHost:url.host] && [url.path hasPrefix:@"/api/v1/authorize"];
}

// The auth URL's client_id/redirect_uri come from ApolloEffectiveRedditClientId()
// and ApolloEffectiveRedirectURI(): the ACTIVE account's saved key when it has
// one, else the default in Settings. Every account is auto-pinned to the default
// in effect when it first signed in (ApolloUserAvatars.xm), so once the default
// changes (e.g. to Dystopia after an old key was revoked), a sign-in started
// while that account is active still sends its old key. Returns that account's
// username when the request didn't use the default, nil otherwise.
- (NSString *)_accountWhoseSavedKeyWasUsed {
    NSString *clientId = @"", *redirect = @"";
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:self.authURL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"client_id"]) clientId = item.value ?: @"";
        else if ([item.name isEqualToString:@"redirect_uri"]) redirect = item.value ?: @"";
    }
    NSString *defaultRedirect = sRedirectURI.length > 0 ? sRedirectURI : defaultRedirectURI;
    if ([clientId isEqualToString:(sRedditClientId ?: @"")] && [redirect isEqualToString:defaultRedirect]) {
        return nil;
    }
    NSString *active = ApolloActiveAccountUsername();
    if (active.length == 0) return nil;
    return ApolloAccountCredentialsFor(active).hasCustomCredentials ? active : nil;
}

- (void)_explainRejectedSignInWithStatus:(NSInteger)status offerOldReddit:(BOOL)offerOldReddit {
    if (self.finished || self.presentedViewController) return;
    self.explainedRejectedSignIn = YES;

    NSString *title = nil;
    NSString *message = nil;
    if (status == 400) {
        NSString *account = [self _accountWhoseSavedKeyWasUsed];
        ApolloLog(@"[WebAuth] Rejected key came from %@", account.length > 0 ? [@"the saved key for u/" stringByAppendingString:account] : @"the default in Settings");
        title = @"Reddit Didn't Accept This API Key";
        NSString *base = @"The Reddit API Key and Redirect URI used for this sign-in don't match a Reddit app, so Reddit won't connect your account. Both have to match the app exactly (for Dystopia, the Redirect URI is dystopia://response).";
        if (account.length > 0) {
            // The switcher's ⋯ only opens the key editor for API-key rows; an
            // API-Key-Free row gets the web-session sheet instead (same test as
            // -[ApolloAccountSwitcherViewController editButtonTapped:]).
            NSString *fix = ApolloWebSessionFor(account) != nil
                ? [NSString stringWithFormat:@"u/%@ signs in without an API key, so that key can't be edited. To fix it, cancel, long-press the Profile tab, swipe left on u/%@ and tap Remove, then add it back.", account, account]
                : [NSString stringWithFormat:@"To fix it, cancel, long-press the Profile tab, tap ⋯ next to u/%@, then tap Clear Custom Key for This Account.", account];
            message = [NSString stringWithFormat:@"%@\n\nThis sign-in used the key saved for u/%@, not your default key. %@", base, account, fix];
        } else {
            message = [base stringByAppendingString:@"\n\nCheck them in Settings → Apollo Reborn → Accounts & API Keys, or sign in without an API key instead."];
        }
    } else {
        title = @"Reddit Couldn't Finish Signing In";
        message = [NSString stringWithFormat:@"Reddit returned an error (HTTP %ld). Wait a few minutes and try again, or switch to Old Reddit and accept there.", (long)status];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (offerOldReddit) {
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Switch to Old Reddit"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [weakSelf _switchToOldReddit];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_finishWithURL:(NSURL *)url error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    ASWebAuthenticationSessionCompletionHandler completion = self.completion;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(url, error);
    }];
}

#pragma mark - WKNavigationDelegate

// Matches scheme + host + path against our configured redirect URI, ignoring query
// and fragment (Reddit appends ?state=&code= or ?error= to the registered URI).
// Matching the full URI — not just the scheme — is what lets http/https redirect
// URIs (Reddit "Web app" API clients) work: every Reddit page navigation shares the
// same https scheme, so scheme-only matching would fire on the wrong navigation.
- (BOOL)_isCallbackURL:(NSURL *)url {
    if (!self.redirectURL || !url) return NO;

    if ([url.scheme caseInsensitiveCompare:self.redirectURL.scheme] != NSOrderedSame) {
        return NO;
    }

    // Custom schemes (e.g. apollo://reddit-oauth) typically have no host/path beyond
    // the scheme itself — in that case scheme matching alone is already unambiguous.
    NSString *redirectHost = self.redirectURL.host;
    if (redirectHost.length > 0) {
        if ([url.host caseInsensitiveCompare:redirectHost] != NSOrderedSame) {
            return NO;
        }
        NSString *redirectPath = self.redirectURL.path ?: @"";
        NSString *urlPath = url.path ?: @"";
        if (![urlPath isEqualToString:redirectPath]) {
            return NO;
        }
    }

    return YES;
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    if ([self _isCallbackURL:url]) {
        // Reddit redirected to our callback URI — intercept before the OS tries to
        // dispatch it (which would fail for unregistered schemes) or the request
        // actually goes out over the network (for http/https redirect URIs).
        decisionHandler(WKNavigationActionPolicyCancel);
        ApolloLog(@"[WebAuth] Intercepted callback: %@", url);
        [self _harvestFeatureSessionThenFinishWithURL:url];
        return;
    }

    // On iOS < 16 the modern Reddit web app fails to render. After the user logs in on
    // old.reddit.com, Reddit's server redirects to www.reddit.com/api/v1/authorize (the
    // consent page) via the `dest` query param — which is also the modern app and also
    // fails. Intercept any mid-flow navigation to www.reddit.com and rewrite to
    // old.reddit.com so the entire OAuth flow stays on old Reddit.
    if (![self _isModernRedditSupported]) {
        NSURL *rewritten = [self _rewriteToOldReddit:url];
        if (![rewritten isEqual:url]) {
            decisionHandler(WKNavigationActionPolicyCancel);
            ApolloLog(@"[WebAuth] Rewriting mid-flow www.reddit.com → old.reddit.com: %@", rewritten);
            [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
            return;
        }
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

// A successful Accept never gets here: Reddit answers with a redirect to the
// callback URI, which decidePolicyForNavigationAction intercepts. Only error
// responses from the two consent endpoints are handled; every other response
// (including errors on login/challenge pages) loads exactly as before.
- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSHTTPURLResponse *http = [navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)navigationResponse.response : nil;
    NSInteger status = http.statusCode;
    if (!navigationResponse.isForMainFrame || status < 400) {
        decisionHandler(WKNavigationResponsePolicyAllow);
        return;
    }

    if ([self _isGrantEndpointURL:http.URL]) {
        // Keep the consent page on screen instead of committing the bare "{}"
        // body. The cancel surfaces as WebKitErrorDomain 102 in
        // didFailProvisionalNavigation, which already ignores it.
        ApolloLog(@"[WebAuth] Reddit rejected the consent grant (HTTP %ld)", (long)status);
        decisionHandler(WKNavigationResponsePolicyCancel);
        [self _explainRejectedSignInWithStatus:status offerOldReddit:YES];
        return;
    }

    if ([self _isAuthorizePageURL:http.URL]) {
        // Reddit's error page names the bad field itself; let it render and
        // add the saved-key context once, unless that was already explained.
        ApolloLog(@"[WebAuth] Reddit rejected the authorize request on %@ (HTTP %ld)", http.URL.host, (long)status);
        decisionHandler(WKNavigationResponsePolicyAllow);
        if (!self.explainedRejectedSignIn) {
            [self _explainRejectedSignInWithStatus:status offerOldReddit:NO];
        }
        return;
    }

    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    [self _rebuildOptionsMenu];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    // NSURLErrorCancelled (-999): fired by our own decisionHandler cancel.
    // WebKitErrorDomain 102 (WebKitErrorFrameLoadInterruptedByPolicyChange): also
    // fired when decidePolicyForNavigationAction cancels a navigation — expected.
    if (error.code == NSURLErrorCancelled) return;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return;
    ApolloLog(@"[WebAuth] Provisional navigation failed: %@", error);
    [self _finishWithURL:nil error:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[WebAuth] Navigation failed: %@", error);
    [self _finishWithURL:nil error:error];
}

@end
