// ApolloProfileEditorWebViewController.m
//
// Reddit's web profile editor (www.reddit.com/settings/profile), opened inside
// Apollo from Edit Profile in the own-profile "..." menu.
//
// The action used to hand that URL to -openURL:, which left Apollo for Safari
// (or the official Reddit app, through its universal link). Safari is rarely
// signed in to the same Reddit account, so the editor usually opened on a
// login wall.
//
// This screen is pushed onto the profile's own navigation stack and signs the
// page in as the active account with the Reddit web session the tweak already
// keeps for it (ApolloWebSessionStore: the API-Key-Free session, or the
// auxiliary one Chat, Modmail and Polls use next to an API key). Its cookies
// are seeded into a private, non-persistent data store that belongs to one
// web view, the same isolation the modern Chat/Modmail views use: the page
// can only be signed in as the account it was opened for, and the shared
// persistent jar the web sign-in keeps is never touched.
//
// No stored session: the same one-time "Reddit Web Sign-In" Chat and Modmail
// offer (ApolloWebSessionLoginViewController's username-matched auxiliary
// sign-in), after which the page loads. A stored session Reddit no longer
// accepts (a redirect to its login page, or a 401/403 refusal) takes the
// same path.
//
// The page is restyled to look like the rest of Apollo, the way modern Chat
// is: Reddit's site header and its "See Reddit in..." app sheet are removed,
// and its design tokens take the active Apollo theme's colors and font (see
// kApolloProfileEditorPageScript).
//
// Navigation: the settings tabs stay on the editor's screen. A tapped link to
// a post, subreddit or user opens Apollo's own screen for it; one to another
// reddit.com page opens as a signed-in page of its own on top (Back comes
// back here); anything off reddit.com opens in Apollo's in-app browser, so
// other sites never load into the cookie-seeded view.

#import "ApolloProfileEditorWebViewController.h"

#import <WebKit/WebKit.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"

static NSString *const kApolloProfileEditorURLString = @"https://www.reddit.com/settings/profile";

// The cover stays up until the page has had this long to paint after its
// document commits (Reddit renders the settings page server-side), or until
// it finishes loading, whichever comes first. The load event alone can trail
// by seconds while slow subresources finish.
static const NSTimeInterval kApolloProfileEditorRevealDelay = 0.5;

// A page that leaves a JavaScript ping unanswered this long has wedged its web
// content process. Seen in the iOS 26.5 simulator: WebKit's garbage collector
// deadlocks inside Reddit's ReadableStream releaseLock(), the page stops
// loading, and WebKit never reports it. A fresh web view (a fresh process) is
// the only way out, so the editor rebuilds one, up to twice per screen.
static const NSTimeInterval kApolloProfileEditorPingInterval = 2.0;
static const NSTimeInterval kApolloProfileEditorWedgeTimeout = 6.0;
static const NSUInteger kApolloProfileEditorMaxWedgeReloads = 2;

// Injected at document start. Apollo's navigation bar stands in for Reddit's
// site header: the header's links lead away from the editor, and its menu has
// Log Out, which would end the very session Apollo signs in with. Zeroing the
// header's two height variables drops the space the page keeps for it. Apollo
// is also the app the "See Reddit in..." sheet promotes. Opening that sheet
// freezes the page under it (pointer-events: none and overflow: hidden on
// <body>) until it is dismissed, so hiding it is not enough: it is dismissed
// through its own Continue button, which lifts the freeze.
//
// The page also wears Apollo's theme, the way modern Chat does: Reddit's
// design tokens are pointed at the active theme's palette
// (ApolloModernWebThemePalette) through __apolloProfileEditorTheme, which the
// editor calls with the palette at document start and again whenever the
// theme or appearance changes. The tokens are set on <html> and again on the
// .theme-* containers further down the page, so the overrides go on both.
static NSString *const kApolloProfileEditorPageScript = @""
"(() => {"
"  if (window.__apolloProfileEditor) return;"
"  window.__apolloProfileEditor = true;"
"  const chrome = document.createElement('style');"
"  chrome.textContent = 'reddit-header-small, reddit-header-large, #xpromo-bottom-sheet { display: none !important; }'"
"    + ':root, shreddit-app { --page-y-padding: 0px !important; --shreddit-header-height: 0px !important; }';"
"  const theme = document.createElement('style');"
"  const attach = () => {"
"    for (const style of [chrome, theme]) if (!style.isConnected) (document.head || document.documentElement).appendChild(style);"
"  };"
// Most of the page lives in shadow roots, which inherit the tokens but not
// document rules, and a few of them hardcode colors (see `fixed` below). One
// shared sheet is adopted into every shadow root, by a sweep shortly after
// each burst of DOM changes.
"  let shadowSheet = null;"
"  try { shadowSheet = new CSSStyleSheet(); } catch (e) {}"
"  const adopt = root => {"
"    if (shadowSheet && root && !root.adoptedStyleSheets.includes(shadowSheet))"
"      root.adoptedStyleSheets = [...root.adoptedStyleSheets, shadowSheet];"
"  };"
"  const sweepRoots = root => {"
"    for (const element of root.querySelectorAll('*')) if (element.shadowRoot) { adopt(element.shadowRoot); sweepRoots(element.shadowRoot); }"
"  };"
"  let sweepQueued = false;"
"  const queueSweep = () => {"
"    if (sweepQueued || !shadowSheet) return;"
"    sweepQueued = true;"
"    setTimeout(() => { sweepQueued = false; sweepRoots(document); }, 100);"
"  };"
"  const roles = {"
"    'neutral-background': 'primary', 'neutral-background-strong': 'primary', 'neutral-background-pinned': 'primary',"
"    'neutral-background-weak': 'tertiary', 'neutral-background-medium': 'tertiary', 'neutral-background-container': 'tertiary',"
"    'neutral-background-container-strong': 'tertiary', 'neutral-background-highlighted': 'tertiary',"
"    'neutral-background-hover': 'tertiary', 'neutral-background-weak-hover': 'tertiary', 'neutral-background-strong-hover': 'tertiary',"
"    'neutral-background-container-hover': 'tertiary', 'neutral-background-container-strong-hover': 'tertiary',"
"    'neutral-background-selected': 'secondary', 'neutral-background-canvas': 'secondary',"
"    'neutral-content': 'text', 'neutral-content-strong': 'text', 'input-text': 'text', 'input-secondary-text': 'text',"
"    'input-bordered-text': 'text', 'secondary': 'text', 'secondary-hover': 'text', 'secondary-plain': 'text',"
"    'secondary-plain-hover': 'text', 'button-secondary-text': 'text',"
"    'neutral-content-weak': 'secondaryText', 'label-default': 'secondaryText', 'input-helper-text': 'secondaryText',"
"    'secondary-weak': 'secondaryText', 'secondary-plain-weak': 'secondaryText',"
"    'input-default': 'tertiary', 'input-secondary': 'tertiary', 'input-secondary-hover': 'tertiary',"
"    'secondary-background': 'tertiary', 'secondary-background-hover': 'tertiary', 'secondary-background-selected': 'secondary',"
"    'button-secondary-background': 'tertiary', 'button-secondary-background-hover': 'tertiary',"
"    'button-secondary-background-focus': 'tertiary',"
"    'neutral-border': 'separator', 'neutral-border-weak': 'separator', 'neutral-border-divider': 'separator',"
"    'primary': 'accent', 'primary-hover': 'accent', 'primary-visited': 'accent', 'primary-plain': 'accent',"
"    'primary-plain-hover': 'accent', 'primary-plain-visited': 'accent', 'primarynext-plain': 'accent',"
"    'primary-background': 'accent', 'primary-background-hover': 'accent', 'primary-background-selected': 'accent',"
"    'primarynext-background': 'accent', 'primarynext-background-hover': 'accent', 'action-primary': 'accent',"
"    'button-primary-background-hover': 'accent', 'button-primary-background-activated': 'accent',"
"    'switch-input-background-checked': 'accent', 'switch-input-background-checked-hover': 'accent',"
"    'primary-switchBackground-selected': 'accent', 'primary-switchBackground-selected-hover': 'accent',"
"    'interactive-focused': 'accent',"
"    'switch-input-background-default': 'offTrack', 'switch-input-background-default-hover': 'offTrack',"
"    'primary-switchBackground': 'offTrack', 'primary-switchBackground-hover': 'offTrack',"
"    'primary-onBackground': 'onAccent', 'primarynext-onBackground': 'onAccent', 'button-primary-text-activated': 'onAccent'"
"  };"
"  window.__apolloProfileEditorTheme = palette => {"
"    const tokens = Object.entries(roles).map(([token, role]) => `--color-${token}:${palette[role]}!important;`).join('');"
// Colors Reddit hardcodes instead of taking from a token: its link blue, and
// the tab strip's scroll arrow, which keeps WebKit's default button blue.
"    const fixed = `[class*=\"text-alienblue\"],.horizontal-scroller-icon-button{color:${palette.accent}!important;}`;"
"    theme.textContent = `:root,.theme-beta,.theme-rpl{${tokens}--font-sans:${palette.font}!important;}`"
"      + `html,body,button,input,textarea,select{font-family:${palette.font}!important;}`"
"      + `html,body{background-color:${palette.primary}!important;color:${palette.text}!important;accent-color:${palette.accent}!important;}`"
"      + fixed"
"      + `input,textarea,[contenteditable=true]{caret-color:${palette.accent}!important;}`"
"      + `::selection{background:${palette.accent}!important;color:${palette.onAccent}!important;}`;"
"    if (shadowSheet) shadowSheet.replaceSync(fixed);"
"    attach();"
"  };"
"  const onMutation = () => {"
"    queueSweep();"
"    dismissAppSheet();"
"  };"
"  const dismissAppSheet = () => {"
"    attach();"
"    const sheet = document.getElementById('xpromo-bottom-sheet');"
"    if (!sheet || !sheet.hasAttribute('open')) return;"
"    const button = sheet.querySelector('button[title=\"Continue\"], [data-testid=\"secondary-button\"]');"
"    if (button) { button.click(); return; }"
"    sheet.removeAttribute('open');"
"    if (document.body) { document.body.style.removeProperty('pointer-events'); document.body.style.removeProperty('overflow'); }"
"  };"
"  attach();"
"  new MutationObserver(onMutation).observe(document.documentElement,"
"    { childList: true, subtree: true, attributes: true, attributeFilter: ['open'] });"
"})();";

#pragma mark - URLs

static NSURL *ApolloProfileEditorURL(void) {
    return [NSURL URLWithString:kApolloProfileEditorURLString];
}

static BOOL ApolloProfileEditorIsWebScheme(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

static BOOL ApolloProfileEditorIsRedditURL(NSURL *url) {
    if (!ApolloProfileEditorIsWebScheme(url)) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
}

static NSString *ApolloProfileEditorPath(NSURL *url) {
    return url.path.lowercaseString ?: @"";
}

// Reddit's settings tabs (Account, Profile, Privacy, Preferences,
// Notifications, Email) all live under /settings.
static BOOL ApolloProfileEditorIsSettingsURL(NSURL *url) {
    if (!ApolloProfileEditorIsRedditURL(url)) return NO;
    NSString *path = ApolloProfileEditorPath(url);
    return [path isEqualToString:@"/settings"] || [path hasPrefix:@"/settings/"];
}

// Where Reddit sends a settings load whose session it doesn't accept.
static BOOL ApolloProfileEditorIsLoginURL(NSURL *url) {
    if (!ApolloProfileEditorIsRedditURL(url)) return NO;
    NSString *path = ApolloProfileEditorPath(url);
    return [path isEqualToString:@"/login"] || [path hasPrefix:@"/login/"] ||
           [path isEqualToString:@"/account/login"] || [path hasPrefix:@"/account/login/"];
}

// Signing out on the web would end the session Apollo itself signs in with
// (for an API-Key-Free account, its only one).
static BOOL ApolloProfileEditorIsLogoutURL(NSURL *url) {
    if (!ApolloProfileEditorIsRedditURL(url)) return NO;
    NSString *path = ApolloProfileEditorPath(url);
    return [path isEqualToString:@"/logout"] || [path hasPrefix:@"/logout/"];
}

// A Reddit page this screen can show (and reload) as itself.
static BOOL ApolloProfileEditorIsPageURL(NSURL *url) {
    return ApolloProfileEditorIsRedditURL(url) && !ApolloProfileEditorIsLoginURL(url) &&
           !ApolloProfileEditorIsLogoutURL(url);
}

// Reddit content Apollo has its own screens for: a subreddit or profile, a
// post in one, and redd.it short links. Their settings pages (about/edit/...)
// and Reddit's other web-only pages are not.
static BOOL ApolloProfileEditorIsNativeContentURL(NSURL *url) {
    if (!ApolloProfileEditorIsWebScheme(url)) return NO;
    if ([url.host.lowercaseString isEqualToString:@"redd.it"]) return YES;
    if (!ApolloProfileEditorIsRedditURL(url)) return NO;
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in [ApolloProfileEditorPath(url) componentsSeparatedByString:@"/"]) {
        if (segment.length > 0) [segments addObject:segment];
    }
    if (segments.count == 0) return NO;
    if ([segments[0] isEqualToString:@"comments"]) return YES;
    if (![segments[0] isEqualToString:@"r"] && ![segments[0] isEqualToString:@"u"] &&
        ![segments[0] isEqualToString:@"user"]) return NO;
    return segments.count <= 2 || [segments[2] isEqualToString:@"comments"];
}

// "name=value; name2=value2" (ApolloWebSessionEntry.cookieHeader) as cookies
// for the private data store. A __Host- cookie must be host-only, so it is
// pinned to www.reddit.com; everything else gets the .reddit.com scope the
// sign-in harvested it under.
static NSArray<NSHTTPCookie *> *ApolloProfileEditorCookiesFromHeader(NSString *header) {
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSString *pair in [header componentsSeparatedByString:@";"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *name = [[pair substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[pair substringFromIndex:NSMaxRange(equals)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length == 0) continue;
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookieDomain: [name hasPrefix:@"__Host-"] ? @"www.reddit.com" : @".reddit.com",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
            NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:24.0 * 60.0 * 60.0],
        }];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

// Safari's application name for the user agent. WebKit fills in the rest
// (device, OS), so Reddit gets the same user agent Safari sent it before and
// serves the same page.
static NSString *ApolloProfileEditorSafariApplicationName(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    return [NSString stringWithFormat:@"Version/%ld.%ld Mobile/15E148 Safari/604.1",
            (long)version.majorVersion, (long)version.minorVersion];
}

// Who is signed in right now. At Apollo's account-change notification its
// in-memory selection has already moved, but the copy it persists (which
// ApolloActiveAccountUsername reads) may not have yet, so the live selection
// decides; the persisted one covers anything the live read can't make out.
static NSString *ApolloProfileEditorActiveUsername(void) {
    NSString *live = nil;
    switch (ApolloResolveLiveActiveAccountIdentity(&live)) {
        case ApolloPersistedAccountIdentitySignedIn: return live.lowercaseString ?: @"";
        case ApolloPersistedAccountIdentitySignedOut: return @"";
        case ApolloPersistedAccountIdentityUnknown: break;
    }
    return ApolloActiveAccountUsername().lowercaseString ?: @"";
}

static void ApolloProfileEditorOpenInSystem(NSURL *url) {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

#pragma mark - Theme

// The palette modern Chat is styled with, plus the text color that reads on
// an accent fill (stock monochromatic and chumbus accents are near-white) and
// the off track of an iOS switch, which Reddit's switches take too.
static NSDictionary<NSString *, NSString *> *ApolloProfileEditorPalette(UITraitCollection *traits) {
    NSMutableDictionary<NSString *, NSString *> *palette = [ApolloModernWebThemePalette(traits) mutableCopy];
    UIColor *accent = ApolloColorFromHexString(palette[@"accent"]);
    palette[@"onAccent"] = accent && ApolloColorIsLight(accent) ? @"#000000" : @"#FFFFFF";
    palette[@"offTrack"] = [palette[@"mode"] isEqualToString:@"dark"] ? @"#39393D" : @"#E9E9EA";
    return palette;
}

static NSString *ApolloProfileEditorThemeCall(NSDictionary<NSString *, NSString *> *palette) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:palette options:0 error:nil];
    NSString *argument = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (argument.length == 0) return nil;
    return [NSString stringWithFormat:@"window.__apolloProfileEditorTheme && window.__apolloProfileEditorTheme(%@);", argument];
}

static UIFont *ApolloProfileEditorFont(UIFontTextStyle style, CGFloat size, UIFontWeight weight) {
    UIFont *base = ApolloThemeRuntimeFont([UIFont systemFontOfSize:size weight:weight]);
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:base];
}

#pragma mark - Controller

typedef NS_ENUM(NSInteger, ApolloProfileEditorState) {
    ApolloProfileEditorStateLoading = 0,
    ApolloProfileEditorStateSignIn,
    ApolloProfileEditorStateFailed,
    ApolloProfileEditorStateReady,
};

@interface ApolloProfileEditorWebViewController : UIViewController <WKNavigationDelegate, WKUIDelegate>
- (instancetype)initWithUsername:(NSString *)username pageURL:(NSURL *)pageURL;
@end

@interface ApolloProfileEditorWebViewController ()
// The account this page signs in as, fixed when the screen opens.
@property (nonatomic, copy) NSString *username;
// Rebuilt for every load: a fresh web view brings a fresh data store (nothing
// left over from a session Reddit rejected) and a fresh web content process.
@property (nonatomic, strong) WKWebView *webView;
// The page the next load opens: the profile editor (or the Reddit page this
// screen was opened for), or wherever a reload or recovery should come back
// to.
@property (nonatomic, copy) NSURL *pageURL;
// NO for a Reddit page opened from the editor on a screen of its own.
@property (nonatomic) BOOL editorPage;
// Opaque cover over the web view until the page has loaded; it carries the
// loading, sign-in and error states.
@property (nonatomic, strong) UIView *coverView;
@property (nonatomic, strong) UIImageView *coverIconView;
@property (nonatomic, strong) UILabel *coverTitleLabel;
@property (nonatomic, strong) UILabel *coverDetailLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic) ApolloProfileEditorState state;
// Bumped by every load: a cookie-seeding completion, delayed reveal or ping
// that belongs to an older load is dropped.
@property (nonatomic) NSUInteger loadGeneration;
// The sign-in alert comes up by itself once per screen (and again when the
// stored session turns out to be expired); after that the cover's Sign In
// button offers it.
@property (nonatomic) BOOL signInPromptOffered;
@property (nonatomic) BOOL signInPresented;
// The stored session was there but Reddit turned it down.
@property (nonatomic) BOOL sessionExpired;
@property (nonatomic, strong) NSTimer *pingTimer;
// When the outstanding responsiveness ping was sent; 0 when none is out.
@property (nonatomic) CFTimeInterval pingSentAt;
@property (nonatomic) NSUInteger wedgeReloads;
// The page was released while off screen (popped, or a memory warning) and
// loads again when the screen comes back.
@property (nonatomic) BOOL pageReleased;
// Set once the active account changes away from `username`: the page stops
// for good and the screen leaves the stack.
@property (nonatomic) BOOL invalidated;
@end

#if APOLLO_SIM_BUILD
// The open editor, for the sim debug bridge's "profilejs" command.
static __weak ApolloProfileEditorWebViewController *sApolloProfileEditorLatest;
#endif

@implementation ApolloProfileEditorWebViewController

- (instancetype)initWithUsername:(NSString *)username pageURL:(NSURL *)pageURL {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _username = [username copy];
        _pageURL = [pageURL copy];
        _editorPage = ApolloProfileEditorIsSettingsURL(pageURL);
        // A full web page: Reddit's sheets and fixed controls sit at the
        // bottom edge, where the tab bar would cover them.
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)dealloc {
    [_pingTimer invalidate];
    [_webView stopLoading];
    ApolloLog(@"[ProfileEditor] Closed the editor for u/%@", _username);
}

- (void)viewDidLoad {
    [super viewDidLoad];
#if APOLLO_SIM_BUILD
    sApolloProfileEditorLatest = self;
#endif
    self.title = self.editorPage ? @"Edit Profile" : @"Reddit";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self apollo_buildCover];
    self.navigationItem.rightBarButtonItem = [self apollo_optionsItem];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    // A page signed in as one account must never stay up after the user
    // switches to another.
    for (NSString *name in @[@"com.christianselig.RedditCurrentAccountChanged",
                             @"com.christianselig.RedditAccountChanged"]) {
        [center addObserver:self selector:@selector(apollo_activeAccountChanged:) name:name object:nil];
    }
    // WebKit suspends the page in the background, which would read as a
    // wedge on return.
    [center addObserver:self selector:@selector(apollo_applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(apollo_applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];

    [self apollo_applyTheme];
    [self apollo_seedAndLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Back on screen after an account switch (Apollo's forward swipe
    // re-pushes popped screens): never show the old account's page. The
    // screen leaves once the transition is over (-viewDidAppear:).
    if ([self apollo_invalidateIfAccountChanged]) return;
    // The theme can change while this screen sits under another one.
    [self apollo_applyTheme];
    // The page was released while off screen (popped and now re-pushed by a
    // forward swipe, or a memory warning): load it again.
    if (self.pageReleased) {
        self.pageReleased = NO;
        [self apollo_seedAndLoad];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.invalidated) {
        [self apollo_leaveNavigationStack];
        return;
    }
    [self apollo_startPinging];
    if (self.state == ApolloProfileEditorStateSignIn && !self.signInPromptOffered) {
        [self apollo_presentSignInPrompt];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self apollo_stopPinging];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Popped. Apollo keeps popped screens for its forward swipe until the
    // next push, so release the page (and its web content process) now
    // rather than whenever that happens.
    if (self.isMovingFromParentViewController && self.webView) {
        ApolloLog(@"[ProfileEditor] Left the editor; releasing its page");
        self.loadGeneration += 1;
        [self apollo_removeWebView];
        self.pageReleased = YES;
    }
}

// Under memory pressure a page that isn't on screen (covered by a page opened
// from it, or held for Apollo's forward swipe) is given back. It reloads,
// at the page it was on, when the screen comes back.
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    if (!self.webView || self.viewIfLoaded.window) return;
    ApolloLog(@"[ProfileEditor] Memory warning; releasing the off-screen page for u/%@", self.username);
    NSURL *current = self.webView.URL;
    if (ApolloProfileEditorIsPageURL(current)) self.pageURL = current;
    self.loadGeneration += 1;
    [self apollo_removeWebView];
    self.pageReleased = YES;
}

#pragma mark Web view

- (void)apollo_removeWebView {
    WKWebView *webView = self.webView;
    if (!webView) return;
    self.webView = nil;
    self.pingSentAt = 0;
    [webView stopLoading];
    webView.navigationDelegate = nil;
    webView.UIDelegate = nil;
    [webView removeFromSuperview];
}

- (void)apollo_installWebView {
    [self apollo_removeWebView];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.applicationNameForUserAgent = ApolloProfileEditorSafariApplicationName();
    WKUserScript *pageScript = [[WKUserScript alloc] initWithSource:kApolloProfileEditorPageScript
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:YES];
    [configuration.userContentController addUserScript:pageScript];
    // Themed from the first paint; -apollo_applyTheme re-themes the live page.
    NSString *themeCall = ApolloProfileEditorThemeCall(ApolloProfileEditorPalette(self.traitCollection));
    if (themeCall) {
        [configuration.userContentController addUserScript:
            [[WKUserScript alloc] initWithSource:themeCall
                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                forMainFrameOnly:YES]];
    }

    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    webView.navigationDelegate = self;
    webView.UIDelegate = self;
    // A long-press preview would load the link in WebKit's own preview,
    // outside the routing below.
    webView.allowsLinkPreview = NO;
    // Transparent until the page paints, so a dark theme never flashes white.
    webView.opaque = NO;
    webView.backgroundColor = UIColor.clearColor;
    [self.view insertSubview:webView belowSubview:self.coverView];
    [NSLayoutConstraint activateConstraints:@[
        // Below the navigation bar: Reddit lays out its fixed elements
        // against the web view's own edges.
        [webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.webView = webView;
}

#pragma mark Cover

- (void)apollo_buildCover {
    self.coverView = [UIView new];
    self.coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.coverView];
    [NSLayoutConstraint activateConstraints:@[
        [self.coverView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.coverView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.coverView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.coverView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.coverIconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.crop.circle"]];
    self.coverIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.coverIconView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.coverIconView.widthAnchor constraintEqualToConstant:46.0],
        [self.coverIconView.heightAnchor constraintEqualToConstant:46.0],
    ]];

    self.coverTitleLabel = [UILabel new];
    self.coverTitleLabel.font = ApolloProfileEditorFont(UIFontTextStyleHeadline, 17.0, UIFontWeightSemibold);
    self.coverTitleLabel.adjustsFontForContentSizeCategory = YES;
    self.coverTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.coverTitleLabel.numberOfLines = 0;

    self.coverDetailLabel = [UILabel new];
    self.coverDetailLabel.font = ApolloProfileEditorFont(UIFontTextStyleSubheadline, 15.0, UIFontWeightRegular);
    self.coverDetailLabel.adjustsFontForContentSizeCategory = YES;
    self.coverDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.coverDetailLabel.numberOfLines = 0;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(10.0, 22.0, 10.0, 22.0);
        self.actionButton.configuration = configuration;
    }
    self.actionButton.titleLabel.font = ApolloProfileEditorFont(UIFontTextStyleHeadline, 17.0, UIFontWeightSemibold);
    [self.actionButton addTarget:self
                          action:@selector(apollo_actionButtonTapped)
                forControlEvents:UIControlEventTouchUpInside];
    self.actionButton.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.coverIconView, self.coverTitleLabel, self.coverDetailLabel, self.spinner, self.actionButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10.0;
    [stack setCustomSpacing:18.0 afterView:self.coverDetailLabel];
    [self.coverView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.coverView.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.coverView.safeAreaLayoutGuide.centerYAnchor constant:-24.0],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.coverView.leadingAnchor constant:32.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.coverView.trailingAnchor constant:-32.0],
    ]];
}

// One palette for the page and everything native around it, so the cover,
// the strip behind the navigation bar and Reddit's page are the same color.
- (void)apollo_applyTheme {
    NSDictionary<NSString *, NSString *> *palette = ApolloProfileEditorPalette(self.traitCollection);
    UIColor *background = ApolloColorFromHexString(palette[@"primary"]) ?: UIColor.systemBackgroundColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor;
    self.view.backgroundColor = background;
    self.coverView.backgroundColor = background;
    self.coverIconView.tintColor = accent;
    self.actionButton.tintColor = accent;
    self.coverTitleLabel.textColor = ApolloColorFromHexString(palette[@"text"]) ?: UIColor.labelColor;
    self.coverDetailLabel.textColor = ApolloColorFromHexString(palette[@"secondaryText"]) ?: UIColor.secondaryLabelColor;
    NSString *themeCall = ApolloProfileEditorThemeCall(palette);
    if (self.webView && themeCall) [self.webView evaluateJavaScript:themeCall completionHandler:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Light/dark flips the palette.
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) [self apollo_applyTheme];
}

- (void)apollo_showState:(ApolloProfileEditorState)state
                   title:(NSString *)title
                  detail:(NSString *)detail
             buttonTitle:(NSString *)buttonTitle {
    self.state = state;
    self.coverTitleLabel.text = title;
    self.coverDetailLabel.text = detail;
    if (state == ApolloProfileEditorStateLoading) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
    [self.actionButton setTitle:buttonTitle forState:UIControlStateNormal];
    self.actionButton.hidden = buttonTitle.length == 0;
    [self.coverView.layer removeAllAnimations];
    self.coverView.alpha = 1.0;
    self.coverView.hidden = NO;
}

- (void)apollo_showLoading {
    [self apollo_showState:ApolloProfileEditorStateLoading
                     title:self.editorPage ? @"Opening Profile Settings" : @"Opening Reddit"
                    detail:[NSString stringWithFormat:@"Signing in as u/%@…", self.username]
               buttonTitle:nil];
}

- (void)apollo_showSignInWithDetail:(NSString *)detail {
    self.loadGeneration += 1;
    [self apollo_removeWebView];
    [self apollo_showState:ApolloProfileEditorStateSignIn
                     title:@"Reddit Sign-In Needed"
                    detail:detail
               buttonTitle:@"Sign In"];
    if (!self.signInPromptOffered && self.viewIfLoaded.window) {
        [self apollo_presentSignInPrompt];
    }
}

- (void)apollo_showFailureWithDetail:(NSString *)detail {
    self.loadGeneration += 1;
    [self apollo_removeWebView];
    [self apollo_showState:ApolloProfileEditorStateFailed
                     title:self.editorPage ? @"Profile Settings Couldn’t Open" : @"Page Couldn’t Open"
                    detail:detail
               buttonTitle:@"Try Again"];
}

- (void)apollo_revealPage {
    if (self.state != ApolloProfileEditorStateLoading || !self.webView) return;
    self.state = ApolloProfileEditorStateReady;
    [self.spinner stopAnimating];
    [UIView animateWithDuration:0.2 animations:^{
        self.coverView.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (finished && self.state == ApolloProfileEditorStateReady) self.coverView.hidden = YES;
    }];
}

- (void)apollo_actionButtonTapped {
    if (self.state == ApolloProfileEditorStateSignIn) {
        [self apollo_presentSignInPrompt];
    } else if (self.state == ApolloProfileEditorStateFailed) {
        self.wedgeReloads = 0;
        [self apollo_seedAndLoad];
    }
}

#pragma mark Options

- (UIBarButtonItem *)apollo_optionsItem {
    __weak typeof(self) weakSelf = self;
    UIAction *reload = [UIAction actionWithTitle:@"Reload"
                                           image:[UIImage systemImageNamed:@"arrow.clockwise"]
                                      identifier:nil
                                         handler:^(__unused __kindof UIAction *action) {
        [weakSelf apollo_reload];
    }];
    // The old destination, one tap away: Safari, or the official Reddit app
    // when it claims the link.
    UIAction *safari = [UIAction actionWithTitle:@"Open in Safari"
                                           image:[UIImage systemImageNamed:@"safari"]
                                      identifier:nil
                                         handler:^(__unused __kindof UIAction *action) {
        typeof(self) strongSelf = weakSelf;
        NSURL *current = strongSelf.webView.URL;
        ApolloProfileEditorOpenInSystem(ApolloProfileEditorIsPageURL(current) ? current : strongSelf.pageURL);
    }];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                              menu:[UIMenu menuWithTitle:@"" children:@[reload, safari]]];
    item.accessibilityLabel = @"More Options";
    return item;
}

- (void)apollo_reload {
    if (self.invalidated) return;
    // Back to the page on screen, in a fresh web view: a plain reload would
    // queue behind a page that has stopped answering.
    NSURL *current = self.webView.URL;
    if (ApolloProfileEditorIsPageURL(current)) self.pageURL = current;
    self.wedgeReloads = 0;
    [self apollo_seedAndLoad];
}

#pragma mark Loading

- (void)apollo_seedAndLoad {
    if (self.invalidated) return;
    NSUInteger generation = ++self.loadGeneration;
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(self.username);
    NSString *cookieHeader = session.cookieHeader;
#if APOLLO_SIM_BUILD
    // Sim-only test knob for the rejected-session path:
    // APOLLOFIX_PROFILE_EDITOR_COOKIE="corrupt:<name>" garbles that one
    // cookie of the stored session (a session Reddit has since revoked); any
    // other value replaces the session outright.
    const char *cookieOverride = getenv("APOLLOFIX_PROFILE_EDITOR_COOKIE");
    if (cookieOverride && cookieOverride[0]) {
        NSString *override = @(cookieOverride);
        if ([override hasPrefix:@"corrupt:"]) {
            NSString *prefix = [[override substringFromIndex:8] stringByAppendingString:@"="];
            NSMutableArray<NSString *> *pairs = [NSMutableArray array];
            for (NSString *pair in [cookieHeader componentsSeparatedByString:@";"]) {
                NSString *trimmed = [pair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                [pairs addObject:[trimmed hasPrefix:prefix] ? [trimmed stringByAppendingString:@"x"] : trimmed];
            }
            cookieHeader = [pairs componentsJoinedByString:@"; "];
        } else {
            cookieHeader = override;
        }
        ApolloLog(@"[ProfileEditor] Sim cookie override: %@", [override hasPrefix:@"corrupt:"] ? override : @"(replaced)");
    }
#endif
    if (cookieHeader.length == 0) {
        ApolloLog(@"[ProfileEditor] No Reddit web session stored for u/%@; offering web sign-in", self.username);
        self.sessionExpired = NO;
        [self apollo_showSignInWithDetail:[NSString stringWithFormat:
            @"Sign in to Reddit as u/%@ to edit your profile here.", self.username]];
        return;
    }

    [self apollo_installWebView];
    [self apollo_showLoading];
    NSArray<NSHTTPCookie *> *cookies = ApolloProfileEditorCookiesFromHeader(cookieHeader);
    WKWebView *webView = self.webView;
    NSURL *pageURL = self.pageURL ?: ApolloProfileEditorURL();
    dispatch_group_t seeded = dispatch_group_create();
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(seeded);
        [webView.configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{
            dispatch_group_leave(seeded);
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(seeded, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.invalidated || generation != strongSelf.loadGeneration ||
            strongSelf.webView != webView) return;
        ApolloLog(@"[ProfileEditor] Seeded %lu cookies (%@ session) for u/%@; loading %@",
                  (unsigned long)cookies.count, session.pollOnly ? @"auxiliary" : @"API-Key-Free",
                  strongSelf.username, pageURL.path);
        [webView loadRequest:[NSURLRequest requestWithURL:pageURL]];
    });
}

#pragma mark Responsiveness

- (void)apollo_startPinging {
    if (self.pingTimer || self.invalidated) return;
    self.pingSentAt = 0;
    __weak typeof(self) weakSelf = self;
    self.pingTimer = [NSTimer scheduledTimerWithTimeInterval:kApolloProfileEditorPingInterval
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
        [weakSelf apollo_pingPage];
    }];
}

- (void)apollo_stopPinging {
    [self.pingTimer invalidate];
    self.pingTimer = nil;
    self.pingSentAt = 0;
}

- (void)apollo_pingPage {
    WKWebView *webView = self.webView;
    if (!webView || self.invalidated) return;
    if (self.pingSentAt > 0) {
        if (CACurrentMediaTime() - self.pingSentAt < kApolloProfileEditorWedgeTimeout) return;
        [self apollo_recoverPage:[NSString stringWithFormat:@"stopped responding for %.0fs",
                                  CACurrentMediaTime() - self.pingSentAt]];
        return;
    }
    self.pingSentAt = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:@"0" completionHandler:^(__unused id result, __unused NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.webView == webView) strongSelf.pingSentAt = 0;
    }];
}

// A page whose web content process wedged or ended (WebKit ends a background
// page's process under memory pressure, which leaves it blank on return) is
// reloaded in a fresh web view, at the page it was on.
- (void)apollo_recoverPage:(NSString *)reason {
    ApolloLog(@"[ProfileEditor] Reddit's page %@ (u/%@, reload %lu)",
              reason, self.username, (unsigned long)self.wedgeReloads + 1);
    if (self.wedgeReloads >= kApolloProfileEditorMaxWedgeReloads) {
        [self apollo_showFailureWithDetail:@"Reddit stopped responding. Try again to reload it."];
        return;
    }
    self.wedgeReloads += 1;
    NSURL *current = self.webView.URL;
    if (ApolloProfileEditorIsPageURL(current)) self.pageURL = current;
    [self apollo_seedAndLoad];
}

- (void)apollo_applicationWillResignActive:(__unused NSNotification *)notification {
    [self apollo_stopPinging];
}

- (void)apollo_applicationDidBecomeActive:(__unused NSNotification *)notification {
    if (self.viewIfLoaded.window) [self apollo_startPinging];
}

#pragma mark Sign-in

- (void)apollo_presentSignInPrompt {
    if (self.invalidated || self.signInPresented || self.presentedViewController || !self.viewIfLoaded.window) return;
    self.signInPromptOffered = YES;
    self.signInPresented = YES;
    UIAlertController *prompt = [UIAlertController
        alertControllerWithTitle:@"Reddit Web Sign-In"
                         message:[NSString stringWithFormat:
                             @"Sign in %@ as u/%@ to edit your profile in Apollo. Your API-key or API-Key-Free choice won’t change.",
                             self.sessionExpired ? @"again" : @"once", self.username]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                               style:UIAlertActionStyleCancel
                                             handler:^(__unused UIAlertAction *action) {
        weakSelf.signInPresented = NO;
    }]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Continue"
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        [weakSelf apollo_presentWebSignIn];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)apollo_presentWebSignIn {
    NSString *username = self.username;
    __weak typeof(self) weakSelf = self;
    // Matched to this account (a web login as anyone else is refused and
    // cleared) and stored as an auxiliary session, so an API-key account
    // keeps authenticating through its key.
    ApolloWebSessionLoginViewController *login =
        [ApolloWebSessionLoginViewController loginControllerForUsername:username completion:^(BOOL success) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.signInPresented = NO;
        if (strongSelf.invalidated || !success) return;
        if (ApolloWebSessionPollFor(username).cookieHeader.length > 0) {
            ApolloLog(@"[ProfileEditor] Web sign-in for u/%@ completed; loading the editor", username);
            strongSelf.wedgeReloads = 0;
            [strongSelf apollo_seedAndLoad];
            return;
        }
        ApolloLog(@"[ProfileEditor] Web sign-in finished without a session for u/%@", username);
        [strongSelf apollo_showSignInWithDetail:[NSString stringWithFormat:
            @"That sign-in wasn’t u/%@. Sign in with that account to edit its profile.", username]];
    }];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:login];
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)apollo_sessionRejected {
    ApolloLog(@"[ProfileEditor] Reddit didn't accept the stored web session for u/%@", self.username);
    // Offer the sign-in by itself again, even if this screen already did:
    // this is a different reason to need it.
    self.signInPromptOffered = NO;
    self.sessionExpired = YES;
    [self apollo_showSignInWithDetail:[NSString stringWithFormat:
        @"Your Reddit web session for u/%@ has expired. Sign in again to edit your profile.", self.username]];
}

#pragma mark Account switches

// YES once the active account is no longer the one this page signs in as.
// The first time, the page stops for good: no further loads, and its web view
// (the old account's session) is released at once, even while the screen is
// buried under another one or held for Apollo's forward swipe.
- (BOOL)apollo_invalidateIfAccountChanged {
    if (self.invalidated) return YES;
    NSString *active = ApolloProfileEditorActiveUsername();
    if ([active isEqualToString:self.username.lowercaseString]) return NO;
    self.invalidated = YES;
    ApolloLog(@"[ProfileEditor] Active account changed from u/%@ to u/%@; closing the editor",
              self.username, active.length ? active : @"(none)");
    self.loadGeneration += 1;
    [self apollo_stopPinging];
    [self apollo_removeWebView];
    // Nothing but the background if Apollo's forward swipe brings the screen
    // back before it leaves.
    [self apollo_showState:ApolloProfileEditorStateFailed title:nil detail:nil buttonTitle:nil];
    self.coverIconView.hidden = YES;
    self.navigationItem.rightBarButtonItem = nil;
    return YES;
}

- (void)apollo_activeAccountChanged:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self apollo_invalidateIfAccountChanged]) [self apollo_leaveNavigationStack];
    });
}

- (void)apollo_leaveNavigationStack {
    UINavigationController *navigationController = self.navigationController;
    if (!navigationController) return;
    if (navigationController.topViewController == self) {
        [navigationController popViewControllerAnimated:NO];
    } else if ([navigationController.viewControllers containsObject:self]) {
        NSMutableArray<UIViewController *> *stack = [navigationController.viewControllers mutableCopy];
        [stack removeObject:self];
        navigationController.viewControllers = stack;
    }
}

#pragma mark Leaving the editor

// Where a link the user tapped goes when it leads off the page: Reddit
// content to Apollo's own screen for it, Reddit's other web pages to a
// signed-in page of their own on top of this one (Back returns here), and
// anything else to Apollo's in-app browser.
- (void)apollo_openTappedURL:(NSURL *)url {
    if (ApolloProfileEditorIsNativeContentURL(url) && ApolloRouteResolvedURLViaApolloScheme(url)) {
        ApolloLog(@"[ProfileEditor] Opened %@ in Apollo", url.absoluteString);
        return;
    }
    UINavigationController *navigationController = self.navigationController;
    if (ApolloProfileEditorIsPageURL(url) && navigationController) {
        ApolloLog(@"[ProfileEditor] Opened %@ as a Reddit page for u/%@", url.path, self.username);
        [navigationController pushViewController:[[ApolloProfileEditorWebViewController alloc]
                                                     initWithUsername:self.username pageURL:url]
                                        animated:YES];
        return;
    }
    ApolloLog(@"[ProfileEditor] Opened %@ in Apollo's browser", url.absoluteString);
    ApolloPresentWebURLFromViewController(self, url);
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    WKFrameInfo *targetFrame = navigationAction.targetFrame;
    // A tapped link, or a link opening a new window (WebKit only opens one
    // for a user gesture).
    BOOL tapped = navigationAction.navigationType == WKNavigationTypeLinkActivated || !targetFrame;

    if (webView != self.webView || self.invalidated) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    if (!url) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    if (!ApolloProfileEditorIsWebScheme(url)) {
        NSString *scheme = url.scheme.lowercaseString ?: @"";
        // The page's own frames (about:blank, srcdoc, data/blob previews).
        if ([scheme isEqualToString:@"about"] || [scheme isEqualToString:@"data"] ||
            [scheme isEqualToString:@"blob"]) {
            decisionHandler(WKNavigationActionPolicyAllow);
            return;
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        // A tapped mailto: or app link goes to the system, as anywhere else in
        // Apollo; a script's attempt (Reddit nudging toward its own app) is
        // dropped.
        if (tapped) ApolloProfileEditorOpenInSystem(url);
        return;
    }

    // Subframes (Reddit's own embeds, captcha) load as the page asks.
    if (targetFrame && !targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    if (ApolloProfileEditorIsLoginURL(url)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [self apollo_sessionRejected];
        return;
    }
    if (ApolloProfileEditorIsLogoutURL(url)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        ApolloLog(@"[ProfileEditor] Blocked Reddit's web sign-out for u/%@", self.username);
        return;
    }

    if (!tapped) {
        // Reddit's own redirects and scripted moves between its pages stay
        // on this screen; nothing scripted leaves reddit.com.
        if (ApolloProfileEditorIsRedditURL(url)) {
            decisionHandler(WKNavigationActionPolicyAllow);
        } else {
            decisionHandler(WKNavigationActionPolicyCancel);
            ApolloLog(@"[ProfileEditor] Blocked a scripted navigation to %@", url.absoluteString);
        }
        return;
    }
    if (self.editorPage && ApolloProfileEditorIsSettingsURL(url)) {
        // The editor's own tabs.
        if (targetFrame) {
            decisionHandler(WKNavigationActionPolicyAllow);
        } else {
            decisionHandler(WKNavigationActionPolicyCancel);
            [webView loadRequest:navigationAction.request];
        }
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    [self apollo_openTappedURL:url];
}

// A session Reddit won't take can also come back as a refusal rather than a
// login redirect: a bad or revoked reddit_session gets a 403 "Your request
// has been blocked" page. While the editor is still opening, that means the
// same as the redirect.
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSHTTPURLResponse *response = [navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)navigationResponse.response : nil;
    if (webView == self.webView && navigationResponse.isForMainFrame &&
        self.state == ApolloProfileEditorStateLoading && ApolloProfileEditorIsRedditURL(response.URL) &&
        (response.statusCode == 401 || response.statusCode == 403)) {
        ApolloLog(@"[ProfileEditor] Reddit refused %@ with HTTP %ld", response.URL.path, (long)response.statusCode);
        decisionHandler(WKNavigationResponsePolicyCancel);
        [self apollo_sessionRejected];
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    if (webView != self.webView || self.state != ApolloProfileEditorStateLoading) return;
    ApolloLog(@"[ProfileEditor] Committed %@", webView.URL.path ?: @"(no path)");
    NSUInteger generation = self.loadGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloProfileEditorRevealDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.loadGeneration == generation) [strongSelf apollo_revealPage];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView != self.webView) return;
    ApolloLog(@"[ProfileEditor] Loaded %@", webView.URL.path ?: @"(no path)");
    [self apollo_revealPage];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    if (webView == self.webView) [self apollo_navigationFailed:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == self.webView) [self apollo_navigationFailed:error];
}

- (void)apollo_navigationFailed:(NSError *)error {
    if (self.invalidated) return;
    // -999: superseded by another load or stopped by our own cancel. 102
    // (frame load interrupted by a policy change): a navigation the policy
    // above cancelled. Neither is a failure.
    if (([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) ||
        ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102)) return;
    ApolloLog(@"[ProfileEditor] Load failed for u/%@: %@", self.username, error.localizedDescription);
    // A page that is already up keeps showing; only the first load turns
    // into an error screen.
    if (self.state != ApolloProfileEditorStateLoading) return;
    [self apollo_showFailureWithDetail:@"Check your connection, then try again."];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (webView != self.webView || self.invalidated) return;
    [self apollo_recoverPage:@"lost its web content process"];
}

#pragma mark WKUIDelegate

// target="_blank" links are routed in the policy callback above, which
// cancels them, so this only runs if WebKit ever skips it: never a second web
// view, the same routing as a tapped link.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    NSURL *url = navigationAction.request.URL;
    if (!url || webView != self.webView || self.invalidated || !ApolloProfileEditorIsWebScheme(url)) return nil;
    if (self.editorPage && ApolloProfileEditorIsSettingsURL(url)) {
        [webView loadRequest:navigationAction.request];
    } else if (!ApolloProfileEditorIsLoginURL(url) && !ApolloProfileEditorIsLogoutURL(url)) {
        [self apollo_openTappedURL:url];
    }
    return nil;
}

@end

#if APOLLO_SIM_BUILD
void ApolloProfileEditorDebugEvaluateJS(NSString *js) {
    dispatch_async(dispatch_get_main_queue(), ^{
        WKWebView *webView = sApolloProfileEditorLatest.webView;
        if (!webView) {
            ApolloLog(@"[ProfileEditor] profilejs: no editor web view");
            return;
        }
        [webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
            ApolloLog(@"[ProfileEditor] profilejs -> %@%@", result ?: @"(nil)",
                      error ? [NSString stringWithFormat:@" error: %@", error.localizedDescription] : @"");
        }];
    });
}
#endif

#pragma mark - Entry point

void ApolloProfileEditorOpenFromViewController(UIViewController *viewController) {
    NSURL *editorURL = ApolloProfileEditorURL();
    NSString *username = ApolloActiveAccountUsername();
    UINavigationController *navigationController = viewController.navigationController;
    BOOL modernWeb = NO;
    // iOS 14/15 WebKit can't render modern reddit.com (the floor Chat, Modmail
    // and the web sign-in keep too), so those keep the old hand-off, as do the
    // cases with nowhere to push or no account to sign in as.
    if (@available(iOS 16.0, *)) modernWeb = YES;
    if (!modernWeb || !navigationController || username.length == 0) {
        ApolloLog(@"[ProfileEditor] Handing %@ to the system (modern web=%d nav=%d account=%d)",
                  kApolloProfileEditorURLString, modernWeb, navigationController != nil, username.length > 0);
        ApolloProfileEditorOpenInSystem(editorURL);
        return;
    }
    ApolloLog(@"[ProfileEditor] Opening the profile editor in Apollo for u/%@", username);
    ApolloProfileEditorWebViewController *editor =
        [[ApolloProfileEditorWebViewController alloc] initWithUsername:username pageURL:editorURL];
    [navigationController pushViewController:editor animated:YES];
}
