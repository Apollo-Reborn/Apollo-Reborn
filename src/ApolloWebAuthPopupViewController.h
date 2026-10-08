#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// Hosts a window.open() popup for the Reddit sign-in web views
// (ApolloWebAuthViewController and ApolloWebSessionLoginViewController).
//
// Reddit's login page runs "Continue with Google" (Google Identity Services)
// and "Continue with Apple" (Sign in with Apple JS) in popup mode: the button
// opens accounts.google.com / appleid.apple.com with window.open(), waits for
// that window to post the result back to window.opener, and the popup then
// closes itself. WKWebView only opens a new window when its WKUIDelegate
// returns one from -webView:createWebViewWithConfiguration:forNavigationAction:
// windowFeatures:. With no UI delegate the call is dropped, so tapping either
// button only left a focus ring around it (#1342).
@interface ApolloWebAuthPopupViewController : UIViewController

// Builds the popup's web view from the configuration WebKit passed in (it must
// be used as-is: that keeps window.opener connected), presents it as a sheet
// above `presenter`'s sign-in sheet, and returns it for WebKit to load the
// request into. Returns nil when the popup can't be shown.
+ (nullable WKWebView *)presentPopupFromViewController:(UIViewController *)presenter
                                         configuration:(WKWebViewConfiguration *)configuration
                                      navigationAction:(WKNavigationAction *)navigationAction;

@end

// Closes a popup still open above `signInViewController`'s sheet, then runs
// `then`. Call it before a sign-in sheet dismisses itself or presents an
// alert: with a popup on top, dismissing the sheet's navigation controller
// would only dismiss the popup (leaving the finished sheet on screen), and an
// alert presented from the sheet wouldn't show at all. Runs `then` right away
// when no popup is open.
FOUNDATION_EXPORT void ApolloWebAuthClosePopups(UIViewController *signInViewController, dispatch_block_t then);

NS_ASSUME_NONNULL_END
