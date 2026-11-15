#import <Foundation/Foundation.h>
#import "ApolloRandomSubreddit.h"

// Tweak-side half of the Random / Random NSFW feed fix. ApolloRandomFeed.xm owns
// the pull-to-refresh roll and the feed title guard; Tweak.xm owns the
// configured community lists and the NSURLSession hooks that call in here.

#ifdef __cplusplus
extern "C" {
#endif

// The cached community list for `kind`. An empty array when no list source is
// configured for it (known to hold nothing); nil when it is configured but not
// loaded or evicted (unknown; the call then starts a background refresh for
// next time). Any thread. Defined in Tweak.xm, next to the list cache.
NSArray<NSString *> *ApolloRandomCachedSubreddits(ApolloRandomFeedKind kind);

// Nil when `request` should be sent unchanged. Otherwise a copy addressed at the
// community a random feed should load. Any thread. Defined in ApolloRandomFeed.xm.
// `allowFeedRoutes` is YES only for Apollo's own feed requests (its AFNetworking
// path, -[NSURLSession dataTaskWithRequest:]). With NO, only an explicit
// /r/random or /r/randnsfw request is rewritten, to a stateless pick: the
// tweak's own fetches (e.g. ApolloSubredditInfoCache's about.json, which is
// cached under the name it asked for) must never be redirected by a roll.
// Inside a Begin/End pair on the current thread, `allowFeedRoutes` is ignored
// (treated as NO).
NSURLRequest *ApolloRandomRequestByRolling(NSURLRequest *request, BOOL allowFeedRoutes);

// Marks the current thread as running a tweak-owned fetch. Use around a call
// that sends a Reddit /r/<name> request through Apollo's own RDKClient (or any
// path that reaches -[NSURLSession dataTaskWithRequest:]), so the random
// feed's roll and sticky routes cannot redirect it. Prefer
// ApolloRandomTweakFetchScope in Objective-C++ (.xm). Nesting is allowed.
void ApolloRandomTweakFetchBegin(void);
void ApolloRandomTweakFetchEnd(void);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
// RAII form of ApolloRandomTweakFetchBegin/End for .xm files.
//
// It covers only work done synchronously on this thread inside the scope.
// RDKClient is an AFHTTPSessionManager subclass whose request methods
// (getPath:, taskWithMethod:..., subredditWithName:...) return the created
// task, so AFNetworking creates it on the calling thread before returning.
// Not covered: a request RDKClient defers and creates later, e.g. while it is
// refreshing the access token (its `refreshingToken` /
// refreshTokenWithInitialOperation:), which cannot be confirmed without
// Hopper.
struct ApolloRandomTweakFetchScope {
    ApolloRandomTweakFetchScope() { ApolloRandomTweakFetchBegin(); }
    ~ApolloRandomTweakFetchScope() { ApolloRandomTweakFetchEnd(); }
    ApolloRandomTweakFetchScope(const ApolloRandomTweakFetchScope &) = delete;
    ApolloRandomTweakFetchScope &operator=(const ApolloRandomTweakFetchScope &) = delete;
};
#endif
