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
    // 50 ids.
    ApolloGQLRequestKindPostsInfo = 1,
    // GET /r/<subreddit>[/<sort>]: a subreddit's feed. SubredditFeedSdui gives
    // the page's post ids (6 on a first page, 24 after), PostsByIds the posts.
    ApolloGQLRequestKindSubredditFeed,
    // GET /hot, /new, /top, /rising, /controversial: the account's Home.
    // HomeFeedSdui gives the page's post ids (7 on a first page, 25 after),
    // PostsByIds the posts. Not /best: GraphQL's Home "Best" is mostly posts
    // Reddit suggests from subreddits the account hasn't joined, in an order
    // that isn't the legacy one's.
    ApolloGQLRequestKindHomeFeed,
    // GET /r/popular[/<sort>]: Reddit's Popular feed. PopularFeedSdui gives the
    // page's post ids (7, then 25), PostsByIds the posts. (r/all has no query
    // here: SubredditFeedSdui answers it "Resource not found".)
    ApolloGQLRequestKindPopularFeed,
    // GET /comments/<id>[.json], /r/<subreddit>/comments/<id>[/<slug>]: a post
    // and its comments. PostComments gives the thread, PostsByIds the post.
    ApolloGQLRequestKindComments,
    // POST /api/morechildren: the replies behind a "load more" row of a thread
    // that came from PostComments (ApolloGQLMoreToken). One PostComments call.
    ApolloGQLRequestKindMoreComments,
};

@interface ApolloGQLRequest : NSObject
@property (nonatomic, readonly) ApolloGQLRequestKind kind;
// PostsInfo: the fullnames asked for, in order.
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *fullnames;
// SubredditFeed: the subreddit. Every feed: GraphQL's sort ("HOT") and range
// ("DAY", nil for sorts without one), the fullname the page starts after, and
// how many posts the legacy request wanted.
@property (nonatomic, copy, readonly, nullable) NSString *subreddit;
@property (nonatomic, copy, readonly, nullable) NSString *sort;
@property (nonatomic, copy, readonly, nullable) NSString *timeRange;
@property (nonatomic, copy, readonly, nullable) NSString *after;
@property (nonatomic, readonly) NSInteger limit;
// Comments and MoreComments: the post, and GraphQL's comment sort
// ("CONFIDENCE"). `limit` is how many comments a Comments request wanted, 0 for
// Reddit's own page size.
@property (nonatomic, copy, readonly, nullable) NSString *linkFullname;
@property (nonatomic, copy, readonly, nullable) NSString *commentSort;
// MoreComments: the row's cursor and its depth in the thread.
@property (nonatomic, copy, readonly, nullable) NSString *moreCursor;
@property (nonatomic, readonly) NSInteger moreDepth;
// Whether the legacy request carried raw_json=1 (ApolloGQLLegacyLinkData).
@property (nonatomic, readonly) BOOL rawJSON;
@end

// YES when a request to `path` is one of the kinds above, going by the method
// and path alone. The request itself may still not be answerable (an /api/info
// for comments, a feed page asked for by `before`, a thread opened at one
// comment, a "load more" row of a thread the legacy API sent).
BOOL ApolloGQLCanAnswerPath(NSString *method, NSString *path);

// The GraphQL request for a legacy one, or nil when GraphQL can't answer it and
// it should go by its other routes. `path` may be RedditKit's relative form
// ("r/apple/hot.json") or a URL path, with or without a query; `parameters` is
// RedditKit's parameter dictionary.
ApolloGQLRequest *_Nullable ApolloGQLRequestForLegacy(NSString *method, NSString *path, id _Nullable parameters);

#pragma mark - Operations

extern NSString *const ApolloGQLOperationPostsByIds;
extern NSString *const ApolloGQLOperationSubredditFeed;
extern NSString *const ApolloGQLOperationHomeFeed;
extern NSString *const ApolloGQLOperationPopularFeed;
extern NSString *const ApolloGQLOperationPostComments;

// The most post ids one PostsByIds call is given.
extern const NSUInteger ApolloGQLPostsByIdsBatch;

// The registered hash of an operation, or nil for a name that isn't in the list.
NSString *_Nullable ApolloGQLOperationHash(NSString *name);

// The JSON body that runs an operation: {"operationName", "variables",
// "extensions": {"persistedQuery": {"version": 1, "sha256Hash"}}}. nil for an
// unknown operation.
NSData *_Nullable ApolloGQLOperationBody(NSString *name, NSDictionary *variables);

NSDictionary *ApolloGQLPostsByIdsVariables(NSArray<NSString *> *fullnames);

// The operation that answers a feed request (SubredditFeed, HomeFeed,
// PopularFeed), and its
// variables. `after` is the fullname the page starts after (the request's own,
// or the one a previous page of the same request ended on), or nil for the
// first page.
NSString *ApolloGQLFeedOperation(ApolloGQLRequest *request);
NSDictionary *ApolloGQLFeedVariables(ApolloGQLRequest *request, NSString *_Nullable after);

// A thread's first page (Comments) or the replies behind one of its "load
// more" rows (MoreComments).
NSDictionary *ApolloGQLPostCommentsVariables(ApolloGQLRequest *request);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
