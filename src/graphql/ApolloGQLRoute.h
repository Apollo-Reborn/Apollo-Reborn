#import <Foundation/Foundation.h>
#import "ApolloGQLPlan.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The GraphQL route for API-Key-Free accounts (ApolloWebJSONRouteGraphQL): the
// part that talks to gql-fed.reddit.com. The RedditKit request hook
// (ApolloWebJSONIdentity.xm) asks it for a legacy request's answer before any
// request exists, and sends the request by its other routes when it has none.
//
// Why: cookie-authenticated .json reads are on Reddit's smallest request budget
// (100 per ten minutes for new accounts, 4 units a request for suspended ones),
// and Reddit has been closing those endpoints one at a time. GraphQL is what
// Reddit's own apps read through, and its budget is counted apart from the
// cookie's (750 per ten minutes on the same accounts, measured 2026-11-23).
//
// On by default (UDKeyWebJSONGraphQLEnabled, sWebJSONGraphQLEnabled; the switch
// is on the Routes screen). keyless-routes.json can switch it off for every
// install (ApolloWebJSONRouteSetRemoteGraphQLOff).

// YES while the route may answer requests for `account`: the switch is on, the
// account has a web session, and Reddit hasn't just rate-limited its GraphQL
// calls. Any thread.
BOOL ApolloGQLRouteAvailable(NSString *account);

// Answers `request` for `account`. `completion` runs on a background queue with
// the body the legacy endpoint would have sent (a Listing of posts, a thread's
// two Listings, /api/morechildren's things), or nil when the request should go
// by its other routes. `refused` says Reddit turned the route
// down (a block page, a token it won't take, a query it no longer knows), which
// counts toward the route's cooldown; a network error or a rate limit doesn't.
// `summary` is for the log.
typedef void (^ApolloGQLRouteCompletion)(NSData *_Nullable legacyJSON, BOOL refused, NSString *summary);
void ApolloGQLRouteAnswer(NSString *account, ApolloGQLRequest *request, ApolloGQLRouteCompletion completion);

// The Routes screen's switch. Takes effect with the next request: nothing of
// the route outlives a request but the token ApolloWebJSON caches. Main thread.
void ApolloGQLRouteSetEnabled(BOOL enabled);

// For the Routes screen and its summary: "state" (NSString, one line: on, off,
// switched off by the file, paused after a rate limit) and "lines" (NSArray of
// NSString, one per kind of request the route answered or was refused for
// `account` since launch).
NSDictionary<NSString *, id> *ApolloGQLRouteStatus(NSString *_Nullable account);

#if APOLLO_SIM_BUILD
// Sim debug bridge ("gqlblock on|off"): send every call with a hash Reddit
// doesn't know, so its real "persisted query not found" answer exercises the
// fallback to the other routes.
void ApolloGQLRouteSimSetBlocked(BOOL blocked);
#endif

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
