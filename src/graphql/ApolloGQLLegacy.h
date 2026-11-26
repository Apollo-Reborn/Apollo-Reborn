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

// A subreddit from a GraphQL answer (SubredditInfoByName's
// data.subredditInfoByName) as the `data` of a legacy t5 thing, and the body of
// /r/<sub>/about.json for the whole answer. nil when the answer has no
// subreddit (missing, banned, private to this account). GraphQL has no
// submit_text, so that key is absent; Apollo's composer then shows the sidebar.
NSDictionary<NSString *, id> *_Nullable ApolloGQLLegacySubredditData(NSDictionary *_Nullable subreddit, BOOL rawJSON);
NSDictionary *_Nullable ApolloGQLLegacySubredditAbout(NSDictionary *answer, BOOL rawJSON);

// The Listing of posts /search.json sends, for a SearchPosts answer (its whole
// JSON body; its posts are whole, as PostsByIds' are). The Listing's `after` is
// ApolloGQLSearchAfterToken of the answer's cursor, or null on the last page.
// nil when the answer has no results list.
NSDictionary *_Nullable ApolloGQLLegacySearchListing(NSDictionary *answer, BOOL rawJSON);

// The `after` a search page is given, and the cursor back out of one. nil for
// an `after` that isn't one of these (a real fullname).
NSString *ApolloGQLSearchAfterToken(NSString *cursor);
NSString *_Nullable ApolloGQLSearchAfterCursor(NSString *_Nullable token);

// The Listing of posts /user/<name>/upvoted.json (…/downvoted, …/hidden) sends,
// for an UpvotedPosts (DownvotedPosts, HiddenPosts) answer; `list` is that last
// path component. The posts are whole, as PostsByIds' are. The Listing's
// `after` is the last post's fullname, or null on the last page. nil when the
// answer has no such list.
NSDictionary *_Nullable ApolloGQLLegacyOwnPostsListing(NSDictionary *answer, NSString *list, BOOL rawJSON);

// The comment fullnames of a SubmittedComments answer (a profile's comments),
// in order. `nextAfter` gets the fullname the next page starts after, or nil
// when there's no further page. nil when the answer has no comment list (a
// missing or suspended account).
NSArray<NSString *> *_Nullable ApolloGQLUserCommentFullnames(NSDictionary *answer, NSString *_Nullable *_Nullable nextAfter);

// The Listing of comments /user/<name>/comments.json sends. `list` is the
// SubmittedComments answer, which names each comment and the post it is on;
// `comments` the LiveCommentsByIds answer for those ids, which has the comments
// themselves. A comment LiveCommentsByIds didn't return is left out. GraphQL
// doesn't say what a comment replies to or who wrote the post, so parent_id is
// the post's fullname and link_author is absent; Apollo's list shows the post's
// title and subreddit under each comment and opens the thread from its
// permalink. nil when `list` has no comment list.
NSDictionary *_Nullable ApolloGQLLegacyUserCommentsListing(NSDictionary *list, NSDictionary *comments, BOOL rawJSON);

// The fullnames of a SavedPostsFeedSdui answer (the account's saved list):
// posts and comments together, in the list's order. `hasMore` gets whether a
// further page follows. nil when the answer has no saved list, or has rows
// this doesn't know how to read.
NSArray<NSString *> *_Nullable ApolloGQLSavedFullnames(NSDictionary *answer, BOOL *_Nullable hasMore);

// The posts the comments of LiveCommentsByIds answers are on, each once, in
// order: a comment says so only in its permalink
// ("/r/<sub>/comments/<post id>/<slug>/<comment id>/").
NSArray<NSString *> *ApolloGQLCommentPostFullnames(NSArray<NSDictionary *> *commentAnswers);

// The Listing /user/<name>/saved.json sends: t3 and t1 things together, in the
// order of `fullnames` (ApolloGQLSavedFullnames, over as many pages as were
// read). `postAnswers` are the PostsByIds answers that have the saved posts and
// the posts the saved comments are on (ApolloGQLCommentPostFullnames);
// `commentAnswers` the LiveCommentsByIds answers that have the comments. Each
// comment carries its post's title, link, author and subreddit, which Apollo's
// list shows under it (a comment whose post the answers don't have keeps what
// its permalink says of it); as on a profile, parent_id is the post's fullname
// (GraphQL doesn't say what a comment replies to). `after` is the fullname the
// next page starts after, or nil for the last page. nil when the answers don't
// have one of the list's own posts or comments: every row of this list is one
// the account chose to keep, so a page isn't made with one missing.
NSDictionary *_Nullable ApolloGQLLegacySavedListing(NSArray<NSString *> *fullnames, NSArray<NSDictionary *> *postAnswers,
                                          NSArray<NSDictionary *> *commentAnswers, NSString *_Nullable after, BOOL rawJSON);

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

// The authors a GraphQL answer names, in the shape of the legacy
// /api/user_data_by_account_ids answer: t2_ fullname -> {"name",
// "profile_img"}. Every post and comment GraphQL sends comes with its author's
// account id, name and picture, so the avatar cache can take them from the
// answer (ApolloUserProfileCache's -ingestGraphQLAuthorRecords:) and a feed or
// thread this route loaded asks Reddit for no avatars afterwards. Deleted
// authors are left out. Empty when the answer names nobody.
NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ApolloGQLLegacyAuthorRecords(id _Nullable answer);

// Where to load an author's picture from, given the one GraphQL names
// (authorInfo.iconSmall.url, signed for 50 pixels; inline avatars draw up to
// 84). A snoo Reddit drew is a 256-pixel square at the same address without
// its query, which is what the legacy API's profile_img shows. A picture the
// person uploaded isn't: that address is the upload itself, uncropped and as
// large as 4000 pixels (2026-11-25), so it keeps the 50-pixel address. nil for
// no address.
NSString *_Nullable ApolloGQLLegacyAuthorIconURL(NSString *_Nullable iconSmallURL);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
