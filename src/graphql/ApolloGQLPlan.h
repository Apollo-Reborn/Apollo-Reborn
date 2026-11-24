#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// What a legacy request asks for, in the terms of Reddit's GraphQL API, and the
// saved queries ("persisted queries") that answer it. gql-fed.reddit.com only
// runs queries Reddit has registered, each named and addressed by the SHA-256
// of its text, so there's a fixed list of them here rather than query text.
// Foundation-only: tests/run_gql_legacy_tests.sh.

typedef NS_ENUM(NSInteger, ApolloGQLRequestKind) {
    // GET /api/info?id=t3_a,t3_b: posts by fullname. One PostsByIds call per
    // 30 ids.
    ApolloGQLRequestKindPostsInfo = 1,
    // GET /r/<subreddit>[/<sort>]: a subreddit's feed. SubredditFeedSdui gives
    // the page's post ids (6 on a first page, 24 after), PostsByIds the posts.
    ApolloGQLRequestKindSubredditFeed,
};

@interface ApolloGQLRequest : NSObject
@property (nonatomic, readonly) ApolloGQLRequestKind kind;
// PostsInfo: the fullnames asked for, in order.
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *fullnames;
// SubredditFeed: the subreddit, GraphQL's sort ("HOT") and range ("DAY", nil
// for sorts without one), the fullname the page starts after, and how many
// posts the legacy request wanted.
@property (nonatomic, copy, readonly, nullable) NSString *subreddit;
@property (nonatomic, copy, readonly, nullable) NSString *sort;
@property (nonatomic, copy, readonly, nullable) NSString *timeRange;
@property (nonatomic, copy, readonly, nullable) NSString *after;
@property (nonatomic, readonly) NSInteger limit;
// Whether the legacy request carried raw_json=1 (ApolloGQLLegacyLinkData).
@property (nonatomic, readonly) BOOL rawJSON;
@end

// YES when a request to `path` is one of the kinds above, going by the method
// and path alone. The request itself may still not be answerable (an /api/info
// for comments, a feed page asked for by `before`).
BOOL ApolloGQLCanAnswerPath(NSString *method, NSString *path);

// The GraphQL request for a legacy one, or nil when GraphQL can't answer it and
// it should go by its other routes. `path` may be RedditKit's relative form
// ("r/apple/hot.json") or a URL path, with or without a query; `parameters` is
// RedditKit's parameter dictionary.
ApolloGQLRequest *_Nullable ApolloGQLRequestForLegacy(NSString *method, NSString *path, id _Nullable parameters);

#pragma mark - Operations

extern NSString *const ApolloGQLOperationPostsByIds;
extern NSString *const ApolloGQLOperationSubredditFeed;

// The most post ids one PostsByIds call is given.
extern const NSUInteger ApolloGQLPostsByIdsBatch;

// The registered hash of an operation, or nil for a name that isn't in the list.
NSString *_Nullable ApolloGQLOperationHash(NSString *name);

// The JSON body that runs an operation: {"operationName", "variables",
// "extensions": {"persistedQuery": {"version": 1, "sha256Hash"}}}. nil for an
// unknown operation.
NSData *_Nullable ApolloGQLOperationBody(NSString *name, NSDictionary *variables);

NSDictionary *ApolloGQLPostsByIdsVariables(NSArray<NSString *> *fullnames);

// `after` is the fullname the page starts after (the request's own, or the one
// a previous page of the same request ended on), or nil for the first page.
NSDictionary *ApolloGQLSubredditFeedVariables(ApolloGQLRequest *request, NSString *_Nullable after);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
