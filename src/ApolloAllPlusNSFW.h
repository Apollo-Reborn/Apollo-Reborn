#import <Foundation/Foundation.h>

// All+ r/all: blends NSFW posts into Apollo's r/all feed, the way old Reddit's
// r/all showed them. Called from the RDKResponseSerializer hook
// (ApolloWebJSONIdentity.xm). When the setting is on and `response` is an r/all
// listing, merges in candidates from Reddit's site-wide NSFW hot search by rank.
// The search runs in the background with the captured bearer; a page never
// waits for it. Never throws (callers wrap in @try regardless).

#ifdef __cplusplus
extern "C" {
#endif

// Rewrites the raw r/all listing JSON before Apollo parses it. Returns the
// merged NSData, or nil to leave the response untouched.
NSData *ApolloAllPlusRewriteData(NSURLResponse *response, NSData *data);

#ifdef __cplusplus
}
#endif
