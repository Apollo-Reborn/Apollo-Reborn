#import <Foundation/Foundation.h>

@class NSURLSessionUploadTask;

#ifdef __cplusplus
extern "C" {
#endif

// Bearer token capture (from outgoing Reddit API requests).
BOOL ApolloIsAuthorizationHeader(NSString *field);
void ApolloRedditCaptureBearerTokenFromAuthorization(NSString *authorization, NSString *source);
void ApolloRedditCaptureBearerTokenFromHeaderDictionary(NSDictionary *headers, NSString *source);
void ApolloRedditCaptureBearerTokenFromRequest(NSURLRequest *request, NSString *source);

// Request rewriting. Returns nil if the request should be passed through unchanged.
NSURLRequest *ApolloRedditMaybeRewriteSubmitRequest(NSURLRequest *request);
NSURLRequest *ApolloRedditMaybeRewriteCommentRequest(NSURLRequest *request);

// Task identification (matches against original/current request).
BOOL ApolloRedditIsSubmitTask(NSURLSessionTask *task);
BOOL ApolloRedditIsCommentTask(NSURLSessionTask *task);

// Async response transformation.
// - For /api/submit: resolves the real Reddit linkID (websocket race vs listing fallback)
//   and synthesizes a complete Reddit-style success JSON (id/name/url) so Apollo's
//   native PostSubmitWatcher path runs (native banner + dismiss + navigation).
// - For /api/comment: async-hydrates media_metadata and rewrites the comment body to
//   carry the resolved i.redd.it URL.
// completion is always invoked exactly once (on a background queue).
typedef void (^ApolloRedditResponseDataCompletion)(NSData *transformedData);
void ApolloRedditTransformSubmitResponseAsync(NSData *originalData, NSURLRequest *originalRequest, ApolloRedditResponseDataCompletion completion);
void ApolloRedditTransformCommentResponseAsync(NSData *originalData, ApolloRedditResponseDataCompletion completion);

// Installs a one-time class-level swizzle on the URLSession delegate to capture
// responses from Reddit submit/comment tasks and re-deliver them transformed.
// Idempotent per delegate class.
void ApolloRedditInstallResponseTransformerForDelegate(id delegate);

#ifdef __cplusplus
}
#endif
