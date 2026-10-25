#import <Foundation/Foundation.h>

// All+ r/all: blends NSFW posts into Apollo's r/all feed, the way old Reddit's
// r/all showed them. Called from the RDKResponseSerializer hook
// (ApolloWebJSONIdentity.xm). When the setting is on and `response` is an r/all
// listing on a hot-ranked sort (hot, best, rising), merges in candidates from
// Reddit's site-wide NSFW hot search by rank; Top/New/Controversial are left
// stock. The search runs in the background as the active account (its bearer
// on oauth.reddit.com, or bearer-less on www.reddit.com for an API-Key-Free
// account); a page never waits for it. Everything cached is bound to that
// account and dropped when it changes. Never throws (callers wrap in @try
// regardless).

#ifdef __cplusplus
extern "C" {
#endif

// Rewrites the raw r/all listing JSON before Apollo parses it. Returns the
// merged NSData, or nil to leave the response untouched.
NSData *ApolloAllPlusRewriteData(NSURLResponse *response, NSData *data);

// Drops every cached candidate and cancels the in-flight search, so a search
// started before now can't publish or start another. Call when the setting is
// toggled (either way). Asynchronous; safe from any thread.
void ApolloAllPlusInvalidate(void);

#ifdef __cplusplus
}
#endif
