#import "ApolloWebAuthViewController.h"
#import "ApolloManualSignInViewController.h"
#import "ApolloWebAuthPopupViewController.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloState.h"
#import "ApolloCommon.h"

#import <WebKit/WebKit.h>

@interface ApolloWebAuthViewController () <WKNavigationDelegate, WKUIDelegate>
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
// Old Reddit turned this sign-in away (see _noteOldRedditUnavailable:): Reddit
// limits it to accounts with recent Old Reddit use and is expected to retire
// it. The iOS < 16 rewrite stops and the flow carries on at www.reddit.com.
@property (nonatomic) BOOL oldRedditUnavailable;
// The user chose "Switch to New Reddit" from the options menu.
@property (nonatomic) BOOL prefersNewReddit;
// A main-frame load of an old.reddit.com page that hasn't committed yet. A
// www navigation meanwhile is Old Reddit redirecting there, which another
// rewrite would only repeat.
@property (nonatomic) BOOL oldRedditLoadPending;
// Rewrites the iOS < 16 path made this sign-in.
@property (nonatomic) NSUInteger oldRedditRewriteCount;
// HTTP status of the last main-frame response, for the Old Reddit page check.
@property (nonatomic) NSInteger lastMainFrameStatus;
// The in-app consent prompt (iOS < 16) was offered, and whether Apollo has
// already sent an answer with it.
@property (nonatomic) BOOL offeredInAppConsent;
@property (nonatomic) BOOL sentInAppConsent;
@end

// Old Reddit's host, the one place it's named. A method (below) reads it so
// the simulator probes can point the rewrite at a host that redirects to www.
static NSString *const kApolloWebAuthOldRedditHost = @"old.reddit.com";

// Most rewrites a sign-in may make before giving up on Old Reddit, in case it
// keeps redirecting to new URLs rather than the same one.
static const NSUInteger kApolloWebAuthMaxOldRedditRewrites = 8;

// YES when Reddit's new consent form is on the page.
static NSString *const kApolloWebAuthHasConsentFormJS =
    @"!!document.querySelector('form[action*=\"oauth-grant\"]')";

// Answers the consent form the way its Accept / Decline buttons do, without
// the page's own scripts. Those add the csrf_token field the grant endpoint
// requires: it has to match the csrf_token cookie, and a submit without it gets
// HTTP 400 (checked against reddit.com 2026-10-27). Plain ES5 for iOS 14/15
// WebKit. Returns "submitted", "no-form" or "no-csrf".
static NSString *ApolloWebAuthConsentSubmitJS(BOOL accept) {
    return [NSString stringWithFormat:
        @"(function(){"
        @"var f=document.querySelector('form[action*=\"oauth-grant\"]');"
        @"if(!f)return 'no-form';"
        @"var m=document.cookie.match(/(?:^|;\\s*)csrf_token=([^;]*)/);"
        @"if(!m)return 'no-csrf';"
        @"function put(n,v){var i=f.querySelector('input[name=\"'+n+'\"]');"
        @"if(!i){i=document.createElement('input');i.type='hidden';i.name=n;f.appendChild(i);}i.value=v;}"
        @"put('csrf_token',decodeURIComponent(m[1]));put('authorize','%@');"
        @"f.submit();return 'submitted';})()", accept ? @"ALLOW" : @"DENY"];
}

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

    // Options menu — "Switch to Old Reddit" / "Switch to New Reddit" (rewrite
    // mid-flow to or from old.reddit.com, useful on any iOS) and "Manual Sign-In
    // (Reynard)" (external-browser fallback for devices where neither the modern
    // nor old login page renders, e.g. iOS 15.3.1). On iOS 15 and earlier we
    // also auto-rewrite to old.reddit below, while Old Reddit still serves it.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                 menu:nil];
    [self _rebuildOptionsMenu];

    // iOS 15 and earlier can't use Reddit's new consent page, so the consent
    // step goes to Old Reddit's. Rewrite www.reddit.com → old.reddit.com before
    // the first load (Apollo's authorize URL is on ssl.reddit.com, which
    // redirects to www, so in practice the mid-flow rewrite below does it).
    if ([self _usesOldRedditAutomatically]) {
        ApolloLog(@"[WebAuth] iOS < 16 detected — auto-switching to old.reddit.com");
        self.authURL = [self _rewriteToOldReddit:self.authURL];
    }

    // Non-persistent data store mirrors Apollo's prefersEphemeralWebBrowserSession = YES
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                    UIViewAutoresizingFlexibleLeftMargin  | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.center = self.view.center;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    ApolloLog(@"[WebAuth] Loading auth URL: %@", ApolloLogURL(self.authURL));
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

// The iOS < 16 path: every www.reddit.com page goes to Old Reddit's version,
// until Old Reddit turns the sign-in away or the user picks New Reddit.
- (BOOL)_usesOldRedditAutomatically {
    return ![self _isModernRedditSupported] && !self.oldRedditUnavailable && !self.prefersNewReddit;
}

- (NSString *)_oldRedditHost {
    return kApolloWebAuthOldRedditHost;
}

- (BOOL)_isOldRedditURL:(NSURL *)url {
    return [url.host.lowercaseString isEqualToString:[self _oldRedditHost]];
}

- (NSURL *)_rewriteToOldReddit:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([c.host isEqualToString:@"www.reddit.com"] || [c.host isEqualToString:@"reddit.com"]) {
        c.host = [self _oldRedditHost];
    }
    return c.URL ?: url;
}

- (NSURL *)_rewriteToNewReddit:(NSURL *)url {
    if (![self _isOldRedditURL:url]) return url;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.host = @"www.reddit.com";
    return c.URL ?: url;
}

// Old Reddit's sign-in gate, where Reddit sends visitors it won't show Old
// Reddit to: old.reddit.com/login/?reason=lor2&dest=<the page> (seen
// 2026-10-27). A signed-out visitor gets it for every old.reddit.com page.
- (BOOL)_isOldRedditGateURL:(NSURL *)url {
    return [self _isOldRedditURL:url] && [url.path.lowercaseString hasPrefix:@"/login"];
}

// The gate's dest, when it's a Reddit page.
- (NSURL *)_gateDestinationOfURL:(NSURL *)url {
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if (![item.name isEqualToString:@"dest"] || item.value.length == 0) continue;
        NSURL *dest = [NSURL URLWithString:item.value];
        return [dest.scheme.lowercaseString isEqualToString:@"https"] && [self _isRedditHost:dest.host] ? dest : nil;
    }
    return nil;
}

// Records that Old Reddit turned this sign-in away, once: the iOS < 16 rewrite
// stops, "Switch to Old Reddit" is disabled and alerts stop suggesting it.
// The caller decides where the web view goes next.
- (void)_noteOldRedditUnavailable:(NSString *)reason {
    if (self.oldRedditUnavailable) return;
    self.oldRedditUnavailable = YES;
    ApolloLog(@"[WebAuth] Old Reddit %@; continuing this sign-in on www.reddit.com", reason);
    [self _rebuildOptionsMenu];
}

// Loads `url` on www.reddit.com. The grant endpoint can't be loaded on its
// own, so restart from the authorize request if that's where the view is.
- (void)_loadOnNewReddit:(NSURL *)url {
    NSURL *base = (url && ![self _isGrantEndpointURL:url]) ? url : self.authURL;
    NSURL *rewritten = [self _rewriteToNewReddit:base];
    ApolloLog(@"[WebAuth] Loading on new Reddit: %@", ApolloLogURL(rewritten));
    [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
}

- (void)_switchToOldReddit {
    self.prefersNewReddit = NO;
    // The grant endpoint has no Old Reddit equivalent, so restart from the
    // authorize request if the web view ever ends up sitting on it.
    NSURL *current = self.webView.URL;
    NSURL *base = (current && ![self _isGrantEndpointURL:current]) ? current : self.authURL;
    NSURL *rewritten = [self _rewriteToOldReddit:base];
    ApolloLog(@"[WebAuth] Switching to old Reddit: %@", ApolloLogURL(rewritten));
    [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
    // didFinishNavigation rebuilds the menu, offering New Reddit once loaded.
}

- (void)_switchToNewReddit {
    self.prefersNewReddit = YES;
    ApolloLog(@"[WebAuth] Switching to new Reddit");
    [self _loadOnNewReddit:self.webView.URL];
}

// Rebuilds the right-bar options menu: "Switch to New Reddit" while the web
// view is on old.reddit.com, otherwise "Switch to Old Reddit" (disabled once
// Old Reddit turned this sign-in away). Keeping it a menu (rather than
// toggling the bar button's enabled state) means the manual fallback stays
// reachable.
- (void)_rebuildOptionsMenu {
    BOOL onOldReddit = [self _isOldRedditURL:self.webView.URL];
    __weak typeof(self) weakSelf = self;

    UIAction *switchHost = [UIAction actionWithTitle:(onOldReddit ? @"Switch to New Reddit" : @"Switch to Old Reddit")
                                               image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        if (onOldReddit) [weakSelf _switchToNewReddit];
        else [weakSelf _switchToOldReddit];
    }];
    if (!onOldReddit && self.oldRedditUnavailable) switchHost.attributes = UIMenuElementAttributesDisabled;

    UIAction *manual = [UIAction actionWithTitle:@"Manual Sign-In (Reynard)"
                                           image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        [weakSelf _showManualSignIn];
    }];

    UIMenu *menu = [UIMenu menuWithTitle:@"Sign-In Options" children:@[switchHost, manual]];
    self.navigationItem.rightBarButtonItem.menu = menu;
}

- (void)_showManualSignIn {
    __weak typeof(self) weakSelf = self;
    ApolloManualSignInViewController *vc = [[ApolloManualSignInViewController alloc]
        initWithAuthURL:self.authURL
            redirectURI:self.redirectURIString
             onComplete:^(NSURL *callbackURL) {
        ApolloLog(@"[WebAuth] manual sign-in produced callback: %@", ApolloLogURL(callbackURL));
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

- (void)_explainRejectedSignInWithStatus:(NSInteger)status offerOldReddit:(BOOL)offerOldReddit {
    if (self.finished || self.presentedViewController) return;
    self.explainedRejectedSignIn = YES;

    // A sign-in sends the default key from Settings, whichever account is
    // active (ApolloAccountCredentialsBeginInteractiveSignIn, #1237). Only with
    // no default set does it fall back to the active account's saved key, or to
    // Apollo's own client id, so point at Settings either way.
    BOOL hasDefaultKey = sRedditClientId.length > 0;
    ApolloLog(@"[WebAuth] Sign-in failed (HTTP %ld); its key came from %@", (long)status,
              hasDefaultKey ? @"the default in Settings" : @"a fallback, no default API key is set");
    NSString *settingsFix = hasDefaultKey
        ? @"check the Reddit API Key and Redirect URI in Settings → Apollo Reborn → Accounts & API Keys"
        : @"add your Reddit API Key in Settings → Apollo Reborn → Accounts & API Keys (none is set there)";

    NSString *title = nil;
    NSString *message = nil;
    if (status == 400) {
        title = @"Reddit Didn't Accept This API Key";
        message = [NSString stringWithFormat:@"The Reddit API Key and Redirect URI used for this sign-in don't match a Reddit app, so Reddit won't connect your account. Both have to match the app exactly (for Dystopia, the Redirect URI is dystopia://response).\n\nTo fix it, %@, or sign in without an API key instead.", settingsFix];
    } else {
        // Can be an outage, but Old Reddit also answers some malformed client
        // ids with a 500 "you broke reddit" page instead of its 400 one: any id
        // whose length is one more than a multiple of 4, e.g. a 14- or
        // 22-character key missing its last character (checked 2026-09-28).
        // Only mention Old Reddit when the alert offers it: the authorize page
        // path may already be on Old Reddit.
        title = @"Reddit Couldn't Finish Signing In";
        NSString *retry = offerOldReddit
            ? @"Wait a few minutes and try again, or switch to Old Reddit and accept there."
            : @"Wait a few minutes and try again.";
        message = [NSString stringWithFormat:@"Reddit returned an error (HTTP %ld). %@\n\nIf it keeps happening, %@.", (long)status, retry, settingsFix];
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

#pragma mark - In-app consent (iOS < 16)

// Without Old Reddit, iOS 14/15 get Reddit's new consent page, which they
// can't use (#377). Its form is plain server-rendered HTML, so Apollo can ask
// natively and send the answer itself (ApolloWebAuthConsentSubmitJS); Reddit
// then redirects to the callback like a tap on the page would.
// `afterRejection`: the page's own answer just came back HTTP 400, as it does
// when the page's scripts didn't add the csrf field.
- (void)_offerInAppConsentAfterRejection:(BOOL)afterRejection {
    if (self.finished || self.presentedViewController) return;
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:kApolloWebAuthHasConsentFormJS completionHandler:^(id hasForm, NSError *error) {
        typeof(self) s = weakSelf;
        if (!s || s.finished || s.presentedViewController) return;
        // Signed out, www's authorize page has no form and sends the visitor
        // on to /login itself; the offer waits for the page that has one.
        if (error || ![hasForm respondsToSelector:@selector(boolValue)] || ![hasForm boolValue]) {
            ApolloLog(@"[WebAuth] No consent form on the page, not offering an in-app answer (%@)",
                      error ? error.localizedDescription : @"not found");
            // After a 400 the explanation still has to show.
            if (afterRejection) [s _explainRejectedSignInWithStatus:400 offerOldReddit:!s.oldRedditUnavailable];
            return;
        }
        s.offeredInAppConsent = YES;
        ApolloLog(@"[WebAuth] Offering an in-app answer to Reddit's consent page%@", afterRejection ? @" after HTTP 400" : @"");
        NSString *message = afterRejection
            ? @"Reddit's page couldn't send your answer on this version of iOS. Apollo can send it instead."
            : @"Reddit's permission page may not work on this version of iOS. Answer here to connect your account.";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow Access to Your Account?"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *accept = [UIAlertAction actionWithTitle:@"Accept" style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *action) {
            [weakSelf _sendInAppConsent:YES];
        }];
        [alert addAction:accept];
        [alert addAction:[UIAlertAction actionWithTitle:@"Decline" style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [weakSelf _sendInAppConsent:NO];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Show Reddit's Page" style:UIAlertActionStyleCancel handler:nil]];
        alert.preferredAction = accept;
        [s presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)_sendInAppConsent:(BOOL)accept {
    if (self.finished) return;
    ApolloLog(@"[WebAuth] Sending %@ to Reddit's consent form from Apollo", accept ? @"Accept" : @"Decline");
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:ApolloWebAuthConsentSubmitJS(accept) completionHandler:^(id result, NSError *error) {
        typeof(self) s = weakSelf;
        NSString *outcome = [result isKindOfClass:[NSString class]] ? result : nil;
        // Only an answer that went out counts: a later 400 then means the key.
        if ([outcome isEqualToString:@"submitted"]) s.sentInAppConsent = YES;
        if (!s || [outcome isEqualToString:@"submitted"]) return;
        ApolloLog(@"[WebAuth] In-app consent answer not sent: %@", outcome ?: error.localizedDescription ?: @"no result");
        if (s.finished || s.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Send Your Answer"
                                                                       message:@"Use Reddit's page, or Manual Sign-In in the ••• menu."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [s presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)_finishWithURL:(NSURL *)url error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    ASWebAuthenticationSessionCompletionHandler completion = self.completion;
    ApolloWebAuthClosePopups(self, ^{
        [self.navigationController dismissViewControllerAnimated:YES completion:^{
            if (completion) completion(url, error);
        }];
    });
}

#pragma mark - WKUIDelegate

// "Continue with Google" and "Continue with Apple" open their sign-in page in a
// popup window (#1342); see ApolloWebAuthPopupViewController.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (self.finished) return nil;
    return [ApolloWebAuthPopupViewController presentPopupFromViewController:self
                                                              configuration:configuration
                                                           navigationAction:navigationAction];
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
        ApolloLog(@"[WebAuth] Intercepted callback: %@", ApolloLogURL(url));
        [self _harvestFeatureSessionThenFinishWithURL:url];
        return;
    }

    // On iOS < 16 the modern Reddit web app fails to render. After the user logs in on
    // old.reddit.com, Reddit's server redirects to www.reddit.com/api/v1/authorize (the
    // consent page) via the `dest` query param — which is also the modern app and also
    // fails. Intercept any mid-flow navigation to www.reddit.com and rewrite to
    // old.reddit.com so the entire OAuth flow stays on old Reddit.
    BOOL mainFrame = navigationAction.targetFrame.isMainFrame;
    if ([self _usesOldRedditAutomatically]) {
        NSURL *rewritten = [self _rewriteToOldReddit:url];
        if (![rewritten isEqual:url]) {
            // A host Reddit retires redirects to the same page on www (new., np.
            // and i.reddit.com all 301 there today, path kept; checked
            // 2026-10-27). Rewriting that again would bounce between the two
            // hosts forever, so a redirect off Old Reddit ends its part.
            if (mainFrame && (self.oldRedditLoadPending ||
                              self.oldRedditRewriteCount >= kApolloWebAuthMaxOldRedditRewrites)) {
                self.oldRedditLoadPending = NO;
                [self _noteOldRedditUnavailable:@"sent the sign-in back to www.reddit.com"];
                decisionHandler(WKNavigationActionPolicyAllow);
                return;
            }
            self.oldRedditRewriteCount += 1;
            decisionHandler(WKNavigationActionPolicyCancel);
            ApolloLog(@"[WebAuth] Rewriting mid-flow www.reddit.com → old.reddit.com: %@", ApolloLogURL(rewritten));
            [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
            return;
        }
    }

    if (mainFrame) self.oldRedditLoadPending = [self _isOldRedditURL:url];
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
    if (navigationResponse.isForMainFrame) self.lastMainFrameStatus = status;
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
        // On iOS < 16 the page's own answer can go out without the csrf field
        // its scripts add, which gets this same 400. Let Apollo send it once
        // before blaming the API key; a second 400 then does mean the key.
        if (status == 400 && ![self _isModernRedditSupported] && !self.sentInAppConsent) {
            [self _offerInAppConsentAfterRejection:YES];
            return;
        }
        [self _explainRejectedSignInWithStatus:status offerOldReddit:!self.oldRedditUnavailable];
        return;
    }

    if ([self _isAuthorizePageURL:http.URL]) {
        // Reddit's error page names the bad field itself; let it render and
        // add where to fix it once, unless that was already explained.
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

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    self.oldRedditLoadPending = NO;
    NSURL *url = webView.URL;
    if (self.oldRedditUnavailable || ![self _isOldRedditGateURL:url]) return;
    // Signed out, the gate is just the sign-in step (it shows Reddit's new
    // sign-in page). Signed in, it means Old Reddit won't serve this account,
    // so go on to the same page on www. This web view's store is fresh for
    // the sign-in and only has a reddit_session cookie once the user has
    // signed in (anonymous visitors get token_v2 but no reddit_session;
    // checked 2026-10-27).
    __weak typeof(self) weakSelf = self;
    [webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        typeof(self) s = weakSelf;
        if (!s || s.finished || s.oldRedditUnavailable || ![s.webView.URL isEqual:url]) return;
        BOOL signedIn = NO;
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.name isEqualToString:@"reddit_session"] && cookie.value.length > 0 &&
                [cookie.domain.lowercaseString hasSuffix:@"reddit.com"]) {
                signedIn = YES;
                break;
            }
        }
        ApolloLog(@"[WebAuth] Old Reddit's sign-in gate (%@)", signedIn ? @"signed in" : @"signed out");
        if (!signedIn) return;
        [s _noteOldRedditUnavailable:@"won't serve this account"];
        [s _loadOnNewReddit:[s _gateDestinationOfURL:url]];
    }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    [self _rebuildOptionsMenu];

    NSURL *url = webView.URL;
    BOOL pageOK = self.lastMainFrameStatus < 400;
    if (pageOK && !self.oldRedditUnavailable && [self _isOldRedditURL:url] && ![self _isOldRedditGateURL:url]) {
        // Any Old Reddit page has its header. Without it, old.reddit.com
        // answered with something else (Reddit's new site, or a notice), so
        // carry on with the same page on www.
        __weak typeof(self) weakSelf = self;
        [webView evaluateJavaScript:@"!!document.getElementById('header-bottom-left')"
                  completionHandler:^(id isOldReddit, NSError *error) {
            typeof(self) s = weakSelf;
            if (!s || s.finished || error || ![isOldReddit respondsToSelector:@selector(boolValue)] || [isOldReddit boolValue]) return;
            if (![s.webView.URL isEqual:url]) return; // moved on meanwhile
            [s _noteOldRedditUnavailable:@"answered with a page that isn't Old Reddit"];
            [s _loadOnNewReddit:url];
        }];
        return;
    }

    // The consent page on www with no Old Reddit to fall back to: iOS < 16
    // gets the in-app answer (once per sign-in; Reddit's 400 offers it again).
    if (pageOK && ![self _usesOldRedditAutomatically] && ![self _isModernRedditSupported] &&
        !self.offeredInAppConsent && [self _isAuthorizePageURL:url] && ![self _isOldRedditURL:url]) {
        [self _offerInAppConsentAfterRejection:NO];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    // (oldRedditLoadPending stays: these cancels can land after the rewritten
    // Old Reddit load started, and a real failure ends the sign-in below.)
    // NSURLErrorCancelled (-999): fired by our own decisionHandler cancel.
    // WebKitErrorDomain 102 (WebKitErrorFrameLoadInterruptedByPolicyChange): also
    // fired when decidePolicyForNavigationAction cancels a navigation — expected.
    if (error.code == NSURLErrorCancelled) return;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return;
    // Domain + code only: the error's userInfo carries the failing authorize URL.
    ApolloLogError(@"[WebAuth] Provisional navigation failed: %@ %ld (%@)", error.domain, (long)error.code, error.localizedDescription);
    [self _finishWithURL:nil error:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    ApolloLogError(@"[WebAuth] Navigation failed: %@ %ld (%@)", error.domain, (long)error.code, error.localizedDescription);
    [self _finishWithURL:nil error:error];
}

@end
