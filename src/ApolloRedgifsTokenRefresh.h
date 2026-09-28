// ApolloRedgifsTokenRefresh.h
//
// Keeps Apollo's inline RedGIFs player working after the device's IP address
// changes (Wi-Fi <-> cellular, a VPN switching on or off, iOS rotating its
// private IPv6 address, a connection going out over IPv4 instead of IPv6).
//
// RedGIFs' temporary API token only works from the exact IP address and
// User-Agent that minted it: the JWT carries `valid_addr` / `valid_agent`, and
// the same token sent from any other address gets HTTP 401 "Could not
// authenticate your request.". Apollo's RedGIFsClient (1.15.11) keeps the token
// until the expiry the /v2/oauth/client rewrite in Tweak.xm reports (23 h), and
// nothing in it reacts to the 401: the /v2/gifs response handler never reads
// the status, the error body fails to decode as a gif, and the post shows
// "Redgifs error :(". Every RedGIFs post keeps failing that way until the app
// is killed.
//
// Wired into Tweak.xm's -[NSURLSession dataTaskWithRequest:completionHandler:]
// hook, which every RedGIFsClient request goes through:
//   * the /v2/oauth/client rewrite records each token it hands Apollo;
//   * a request carrying one of those that comes back 401 gets one fresh token
//     minted on the same session (shared by every request rejected at the same
//     time) and is retried once with it; Apollo gets the retry's response;
//   * later requests still carrying Apollo's cached copy are sent with the
//     fresh token instead, since Apollo keeps its copy until the 23 h expiry,
//     or until Apollo mints a new token of its own.
// Requests carrying any other token are left alone (ApolloHostedVideo, used by
// Share as Video, Share as Image and Gallery View, mints its own per lookup).

#import <Foundation/Foundation.h>

// Plain Objective-C (.m, C linkage) called from Tweak.xm, which is compiled as
// Objective-C++; keep the declarations in C linkage so the symbols match.
#ifdef __cplusplus
extern "C" {
#endif

typedef void (^ApolloRedgifsTaskCompletion)(NSData *data, NSURLResponse *response, NSError *error);

// Creates a data task through the hooked session's ORIGINAL
// -dataTaskWithRequest:completionHandler: (the caller's %orig), so the refresh
// mint and the retry run on Apollo's own RedGIFs session without re-entering
// the hook.
typedef NSURLSessionDataTask *(^ApolloRedgifsTaskFactory)(NSURLRequest *request, ApolloRedgifsTaskCompletion completion);

// Records a token the /v2/oauth/client -> /v2/auth/temporary rewrite hands
// Apollo. A token Apollo just minted replaces any earlier refreshed one.
void ApolloRedgifsNoteTokenIssuedToApollo(NSString *token);

// For an api.redgifs.com request: returns the (not yet resumed) task to hand
// back to Apollo, or nil when the request doesn't carry Apollo's token and the
// caller should take its normal path.
NSURLSessionDataTask *ApolloRedgifsDataTaskWithTokenRefresh(NSURLRequest *request,
                                                           ApolloRedgifsTaskCompletion completion,
                                                           ApolloRedgifsTaskFactory factory);

#ifdef __cplusplus
}
#endif
