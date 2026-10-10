#import "ApolloWebAuthPopupViewController.h"
#import "ApolloCommon.h"

@interface ApolloWebAuthPopupViewController () <WKUIDelegate, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation ApolloWebAuthPopupViewController

+ (WKWebView *)presentPopupFromViewController:(UIViewController *)presenter
                                configuration:(WKWebViewConfiguration *)configuration
                             navigationAction:(WKNavigationAction *)navigationAction {
    NSURL *url = navigationAction.request.URL;
    // The page can only be tapped while nothing covers the sign-in sheet, so a
    // window request with an alert or another popup already up is dropped.
    // ApolloWebAuthClosePopups relies on the popup sitting directly on the sheet.
    UIViewController *host = presenter.navigationController ?: presenter;
    if (!host.view.window || host.isBeingDismissed || host.presentedViewController) {
        ApolloLog(@"[WebAuthPopup] Dropped popup for %@: sign-in sheet isn't on screen or is covered", url.host ?: @"(no host)");
        return nil;
    }

    ApolloWebAuthPopupViewController *popup = [[self alloc] init];
    // WebKit requires the returned web view to use exactly this configuration
    // (same process pool and data store as the opener), so the popup shares
    // the sign-in sheet's cookies and keeps its window.opener.
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    // Google's sign-in can refuse an embedded web view, and WKWebView's default
    // UA announces one. The popup only shows the provider's page, so it gets
    // Safari's UA; the Reddit page that opened it keeps its own.
    webView.customUserAgent = ApolloMobileSafariUserAgent();
    webView.UIDelegate = popup;
    webView.navigationDelegate = popup;
    popup.webView = webView;
    popup.title = url.host.length > 0 ? url.host : @"Sign In";

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:popup];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    ApolloLog(@"[WebAuthPopup] Opening popup for %@", url.host ?: @"(no host)");
    [host presentViewController:nav animated:YES completion:nil];
    // WebKit loads navigationAction.request into the returned view itself.
    return webView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(_cancelTapped)];

    self.webView.frame = self.view.bounds;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                    UIViewAutoresizingFlexibleLeftMargin  | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.center = self.view.center;
    [self.view addSubview:self.spinner];
    if (self.webView.isLoading) [self.spinner startAnimating];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Cancel, swipe-down, window.close() and ApolloWebAuthClosePopups all end
    // here. Releasing the web view closes the popup's page, so the opener sees
    // window.closed and Reddit's button works again on the next tap.
    if (self.navigationController.isBeingDismissed || self.isBeingDismissed) {
        [self _tearDownWebView];
    }
}

- (void)dealloc {
    [self _tearDownWebView];
}

- (void)_tearDownWebView {
    if (!self.webView) return;
    self.webView.UIDelegate = nil;
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
    self.webView = nil;
}

- (void)_cancelTapped {
    ApolloLog(@"[WebAuthPopup] User cancelled the popup");
    [self _close];
}

- (void)_close {
    if (self.navigationController.isBeingDismissed) return;
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - WKUIDelegate

// Google and Apple close their popup with window.close() once the result is
// posted back to the opener.
- (void)webViewDidClose:(WKWebView *)webView {
    ApolloLog(@"[WebAuthPopup] Popup closed itself");
    [self _close];
}

// A link inside the popup asking for yet another window (help or privacy
// links on the provider's page). Loading it here would replace the sign-in
// page the opener is waiting on, so leave it.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    ApolloLog(@"[WebAuthPopup] Ignored a nested popup for %@", navigationAction.request.URL.host ?: @"(no host)");
    return nil;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.spinner startAnimating];
}

// The title shows the host the popup is on (accounts.google.com,
// appleid.apple.com), the same thing Safari's address bar would.
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    NSString *host = webView.URL.host;
    if (host.length > 0) self.title = host;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[WebAuthPopup] Provisional navigation failed: %@ %ld", error.domain, (long)error.code);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[WebAuthPopup] Navigation failed: %@ %ld", error.domain, (long)error.code);
}

@end

void ApolloWebAuthClosePopups(UIViewController *signInViewController, dispatch_block_t then) {
    UIViewController *sheet = signInViewController.navigationController ?: signInViewController;
    UIViewController *above = sheet.presentedViewController;
    BOOL isPopup = [above isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)above).viewControllers.firstObject isKindOfClass:[ApolloWebAuthPopupViewController class]];
    if (!isPopup) {
        then();
        return;
    }

    id<UIViewControllerTransitionCoordinator> coordinator = above.transitionCoordinator;
    if (above.isBeingDismissed && coordinator) {
        // Already closing (window.close() or Cancel). UIKit ignores a second
        // dismiss while the first is animating, so wait for it to finish.
        [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            dispatch_async(dispatch_get_main_queue(), then);
        }];
        return;
    }

    ApolloLog(@"[WebAuthPopup] Sign-in finished with a popup still open; closing it");
    [sheet dismissViewControllerAnimated:NO completion:then];
}
