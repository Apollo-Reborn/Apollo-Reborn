#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The GraphQL route for API-Key-Free accounts reads Reddit through
// gql-fed.reddit.com, the API Reddit's own apps use, and hands Apollo the
// answer in the shape of the legacy JSON it asked for (/api/info.json,
// /r/<sub>/hot.json, …), so nothing downstream knows the difference:
// RedditKit parses it, and the tweak's own readers of listing JSON see the keys
// they expect. This file is that conversion. It has no networking and nothing
// of Apollo's in it. Foundation-only: tests/run_gql_legacy_tests.sh checks it
// against answers captured through both routes for the same posts.
//
// Field sources were taken from captures of both routes (2026-11-23/24); the
// keys Apollo's RedditKit reads are in tests/gql_legacy_tests.m.

// A post from a GraphQL answer (PostsByIds' data.postsInfoByIds[]) as the
// `data` of a legacy t3 thing. `rawJSON` is whether the legacy request carried
// raw_json=1: without it Reddit escapes &, < and > in every string, Apollo
// unescapes them, and so this does the same. nil when `post` has no id.
NSDictionary<NSString *, id> *_Nullable ApolloGQLLegacyLinkData(NSDictionary *post, BOOL rawJSON);

// {"kind": <kind>, "data": <data>}.
NSDictionary<NSString *, id> *ApolloGQLLegacyThing(NSString *kind, NSDictionary *data);

// A legacy Listing of `children` (things). `after` is the fullname the next
// page starts after, or nil for the last page.
NSDictionary<NSString *, id> *ApolloGQLLegacyListing(NSArray<NSDictionary *> *children, NSString *_Nullable after);

// The posts of a PostsByIds answer (its whole JSON body), as t3 things in the
// order of `fullnames`; ones the answer doesn't have are left out. nil when the
// answer isn't a PostsByIds result at all.
NSArray<NSDictionary *> *_Nullable ApolloGQLLegacyLinksFromPostsByIds(NSDictionary *answer, NSArray<NSString *> *fullnames, BOOL rawJSON);

// The body of /comments/<id>.json for a PostComments answer (its whole JSON
// body): [the post's Listing, the comments' Listing], each comment's replies
// nested inside it. `linkThing` is the post as a t3 thing (PostsByIds has it;
// PostComments only names it). A thread's "load more" rows become legacy `more`
// things whose one child id is ApolloGQLMoreToken's, which Apollo hands back
// through /api/morechildren. nil when the answer has no comment list.
NSArray *_Nullable ApolloGQLLegacyCommentsPage(NSDictionary *answer, NSDictionary *linkThing, BOOL rawJSON);

// The body of /api/morechildren for a PostComments answer that continued a
// "load more" row: {"json": {"errors": [], "data": {"things": […]}}}, the things
// flat and each naming its parent, which is how Apollo places them
// (sub_1005256fc). `depth` is the row's own depth (the answer counts from 0
// again). nil when the answer has no comment list.
NSDictionary *_Nullable ApolloGQLLegacyMoreChildren(NSDictionary *answer, NSInteger depth, BOOL rawJSON);

// The child id a "load more" row is given, and the cursor and depth back out of
// one. nil for an id that isn't one of these (a real comment's).
NSString *ApolloGQLMoreToken(NSString *cursor, NSInteger depth);
NSString *_Nullable ApolloGQLMoreTokenCursor(NSString *_Nullable token, NSInteger *_Nullable depth);

// The post fullnames of a feed answer (SubredditFeedSdui, HomeFeedSdui), in
// order, without the cells that aren't posts (sort bar, community suggestions,
// ads). `joinedOnly` also leaves out the posts Reddit suggests from subreddits
// the account hasn't joined, which its Home can mix in ("Because you've shown
// interest in…", "Suggested for you"; the "Best" sort is mostly these). The
// legacy Home never had them.
// `nextAfter` gets the fullname the next page starts after (the answer's
// endCursor, which is the base64 of that fullname; it may be a post that was
// left out), or nil when there's no further page. nil when the answer has no
// feed in it.
NSArray<NSString *> *_Nullable ApolloGQLFeedPostFullnames(NSDictionary *answer, BOOL joinedOnly, NSString *_Nullable *_Nullable nextAfter);

// A feed query's `after` variable for a legacy `after` fullname.
NSString *_Nullable ApolloGQLFeedCursorForFullname(NSString *_Nullable fullname);

// A GraphQL answer's first error message ("persisted query not found", …), or
// nil when it has no `errors`.
NSString *_Nullable ApolloGQLAnswerErrorMessage(id _Nullable answer);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
