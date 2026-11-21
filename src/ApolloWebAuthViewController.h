#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

// WKWebView-based OAuth sign-in flow used when the configured redirect URI
// can't be caught by ASWebAuthenticationSession: an http/https URI (Reddit
// "Web app" API clients), which iOS can only route back to the app via
// Associated Domains universal links (which Apollo Reborn has no entitlement
// for). It also stands in for Apollo's Safari sign-in fallback when that page
// can't finish: its redirect scheme isn't registered, or the redirect is
// http/https.
//
// WKNavigationDelegate fires decidePolicyForNavigationAction for ALL URLs —
// including unregistered custom schemes and ordinary http/https navigations —
// before iOS URL routing or the network load happens, so we can intercept the
// callback and call the completion handler directly. The full redirect URI
// (scheme + host + path) is matched, not just the scheme, so an http/https
// redirect is only recognized at the user's actual callback page rather than
// on every Reddit page navigation.
@interface ApolloWebAuthViewController : UIViewController

- (instancetype)initWithURL:(NSURL *)url
                redirectURI:(NSString *)redirectURI
          completionHandler:(ASWebAuthenticationSessionCompletionHandler)completion;

// Set before presenting when the person just closed this same sheet and then
// picked Apollo's "Issue Signing In" (the sheet stands in for its Safari
// page): once it appears, the sheet offers Manual Sign-In alongside a plain
// retry instead of reopening the same page silently.
@property (nonatomic) BOOL offersSignInAlternatives;

@end
