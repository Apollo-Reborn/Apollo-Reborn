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
    // GET /user/<name>/submitted: the posts on someone's profile.
    // SubmittedPostsFeedSdui gives the page's post ids (26), PostsByIds the
    // posts. (The profile's summary and its mixed overview stay on their
    // routes: GraphQL's summary has one karma total where Apollo shows post
    // and comment karma, and it has no list of posts and comments together.)
    ApolloGQLRequestKindUserPosts,
    // GET /search and /r/<subreddit>/search, for posts: one SearchPosts call a
    // page, whole posts in the answer. (A search for subreddits keeps its
    // routes: CommunityPickerSearchPaginated gives the legacy search's 25
    // results in the same order, but without the day each subreddit was
    // created, which Apollo's results show as its age.) The same 25 posts in the same order as
    // the legacy search for relevance, top of the week and one subreddit's
    // newest (2026-11-24).
    ApolloGQLRequestKindSearchPosts,
    // GET /r/<subreddit>/about: a subreddit's details. One SubredditInfoByName
    // call.
    ApolloGQLRequestKindSubredditAbout,
    // GET /comments/<id>[.json], /r/<subreddit>/comments/<id>[/<slug>]: a post
    // and its comments. PostComments gives the thread, PostsByIds the post.
    ApolloGQLRequestKindComments,
    // POST /api/morechildren: the replies behind a "load more" row of a thread
    // that came from PostComments (ApolloGQLMoreToken). One PostComments call.
    ApolloGQLRequestKindMoreComments,
    // GET /user/<name>/upvoted, /downvoted and /hidden: the account's own lists.
    // One call a page (UpvotedPosts, DownvotedPosts, HiddenPosts), whole posts
    // in the answer, in the legacy list's order (2026-11-25). GraphQL only has
    // them for the account that asks, so ApolloGQLRoute passes on a request
    // for anyone else's.
    ApolloGQLRequestKindOwnPosts,
    // GET /user/<name>/comments: the comments on someone's profile.
    // SubmittedComments gives the page's comment ids and the post each is on
    // (25, the legacy list's in the same order for New and for Top of all
    // time, 2026-11-25), LiveCommentsByIds the comments themselves.
    ApolloGQLRequestKindUserComments,
};

@interface ApolloGQLRequest : NSObject
@property (nonatomic, readonly) ApolloGQLRequestKind kind;
// PostsInfo: the fullnames asked for, in order.
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *fullnames;
// SubredditFeed and SubredditAbout: the subreddit. UserPosts: the account.
// Every feed: GraphQL's sort ("HOT") and range
// ("DAY", nil for sorts without one), the fullname the page starts after, and
// how many posts the legacy request wanted.
@property (nonatomic, copy, readonly, nullable) NSString *subreddit;
@property (nonatomic, copy, readonly, nullable) NSString *username;
@property (nonatomic, copy, readonly, nullable) NSString *sort;
@property (nonatomic, copy, readonly, nullable) NSString *timeRange;
@property (nonatomic, copy, readonly, nullable) NSString *after;
@property (nonatomic, readonly) NSInteger limit;
// SearchPosts: the search text (with "subreddit:<name>" added for a search of
// one subreddit), GraphQL's sort ("RELEVANCE"), the range as the legacy API
// names it ("week", nil for all time), whether NSFW results were asked for, and
// the cursor of the page before (nil for the first).
@property (nonatomic, copy, readonly, nullable) NSString *searchQuery;
@property (nonatomic, copy, readonly, nullable) NSString *searchSort;
@property (nonatomic, copy, readonly, nullable) NSString *searchRange;
@property (nonatomic, readonly) BOOL searchIncludesNSFW;
@property (nonatomic, copy, readonly, nullable) NSString *searchCursor;
// Comments and MoreComments: the post, and GraphQL's comment sort
// ("CONFIDENCE"). `limit` is how many comments a Comments request wanted, 0 for
// Reddit's own page size.
@property (nonatomic, copy, readonly, nullable) NSString *linkFullname;
@property (nonatomic, copy, readonly, nullable) NSString *commentSort;
// OwnPosts: which of the account's lists, "upvoted", "downvoted" or "hidden"
// (`username` is whose the request asked for). UserComments uses `username`,
// `sort`, `timeRange`, `after` (a comment's fullname) and `limit` as the feeds
// do.
@property (nonatomic, copy, readonly, nullable) NSString *ownList;
// MoreComments: the row's cursor and its depth in the thread.
@property (nonatomic, copy, readonly, nullable) NSString *moreCursor;
@property (nonatomic, readonly) NSInteger moreDepth;
// Whether the legacy request carried raw_json=1 (ApolloGQLLegacyLinkData).
@property (nonatomic, readonly) BOOL rawJSON;
@end

// YES when a request to `path` is one of the kinds above, going by the method
// and path alone. `path` may also be one of the route table's endpoint patterns
// ("/r/*/hot"). The request itself may still not be answerable (an /api/info
// for comments, a feed page asked for by `before`, a thread opened at one
// comment, a "load more" row of a thread the legacy API sent).
BOOL ApolloGQLCanAnswerPath(NSString *method, NSString *path);

// The GraphQL request for a legacy one, or nil when GraphQL can't answer it and
// it should go by its other routes. `path` may be RedditKit's relative form
// ("r/apple/hot.json") or a URL path, with or without a query; `parameters` is
// RedditKit's parameter dictionary.
ApolloGQLRequest *_Nullable ApolloGQLRequestForLegacy(NSString *method, NSString *path, id _Nullable parameters);

// NO when `request` is one GraphQL only answers for the account it's about and
// `account` isn't that account: the upvoted, downvoted and hidden lists exist
// for whoever asks, and Apollo asks for the upvoted list of every profile it
// opens. Such a request keeps its other routes.
BOOL ApolloGQLRequestIsForAccount(ApolloGQLRequest *request, NSString *_Nullable account);

#pragma mark - Operations

extern NSString *const ApolloGQLOperationPostsByIds;
extern NSString *const ApolloGQLOperationSubredditFeed;
extern NSString *const ApolloGQLOperationHomeFeed;
extern NSString *const ApolloGQLOperationPopularFeed;
extern NSString *const ApolloGQLOperationUserPosts;
extern NSString *const ApolloGQLOperationSearchPosts;
extern NSString *const ApolloGQLOperationSubredditInfo;
extern NSString *const ApolloGQLOperationPostComments;
extern NSString *const ApolloGQLOperationUserComments;
extern NSString *const ApolloGQLOperationCommentsByIds;

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
// PopularFeed, UserPosts), and its
// variables. `after` is the fullname the page starts after (the request's own,
// or the one a previous page of the same request ended on), or nil for the
// first page.
NSString *ApolloGQLFeedOperation(ApolloGQLRequest *request);
NSDictionary *ApolloGQLFeedVariables(ApolloGQLRequest *request, NSString *_Nullable after);

NSDictionary *ApolloGQLSubredditInfoVariables(ApolloGQLRequest *request);

NSDictionary *ApolloGQLSearchPostsVariables(ApolloGQLRequest *request);

// A thread's first page (Comments) or the replies behind one of its "load
// more" rows (MoreComments).
NSDictionary *ApolloGQLPostCommentsVariables(ApolloGQLRequest *request);

// The operation and variables for one of the account's own lists (OwnPosts).
NSString *ApolloGQLOwnPostsOperation(ApolloGQLRequest *request);
NSDictionary *ApolloGQLOwnPostsVariables(ApolloGQLRequest *request);

// A profile's comments (UserComments): the page of ids, then those comments.
NSDictionary *ApolloGQLUserCommentsVariables(ApolloGQLRequest *request);
NSDictionary *ApolloGQLCommentsByIdsVariables(NSArray<NSString *> *fullnames);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
