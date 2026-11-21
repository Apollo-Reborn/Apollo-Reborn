#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// ApolloForYouFeedModel — the Foundation-only half of Home's "For You" feed
// (ApolloForYouFeed.xm is the runtime half). Host harness:
// tests/run_for_you_feed_tests.sh.
//
// Reddit's For You feed (launched 2026-10-28) has no Data API endpoint. The
// website loads it as server-rendered HTML fragments (captured 2026-11-01 from
// a signed-in desktop Safari session):
//
//   GET https://www.reddit.com/svc/shreddit/feeds/interest-home-feed
//       ?feed=for-you&render-mode=partial[&after=<base64("t3_<id>")>]
//
//   * No `after`: ~113 KB, only 3 posts. With `after`: 25 posts, ~700 KB
//     (`render-mode=partial` trims about 30% off the full markup).
//   * Each post is a `<shreddit-post ... id="t3_xxx" ...>` element. Ads are a
//     different tag (`<shreddit-ad-post>`) and never match.
//   * The next page's `after` is base64 of the last post's fullname; the other
//     parameters the website adds (distance, adDistance, navigationSessionId,
//     ad_posts_served) are optional.
//   * It counts against the session's WEBSITE budget, reported on every
//     response as x-ratelimit-remaining/-used/-reset (2000 per 10 minutes),
//     not the far smaller budget API-key-free JSON reads get.
//
// The HTML is used ONLY for the ordered list of post IDs. Full post data comes
// from one /api/info call per batch of up to 100 IDs, through Apollo's own
// RDKClient, so posts render exactly like every other feed (votes, saved state,
// previews, galleries). Per post that is far fewer JSON-budget requests than
// Home (1 per 12 posts).

// The website fragment URL for one page. `afterFullname` nil/empty = first page.
// `feed` is "for-you" (or "following").
NSURL *_Nullable ApolloForYouFeedPageURL(NSString *feed, NSString *_Nullable afterFullname);

// Post fullnames ("t3_xxx") in document order, de-duplicated within the page.
// Matches only `<shreddit-post` start tags (never ads, flairs or other
// `shreddit-post-*` elements) and skips any carrying a `promoted` attribute.
NSArray<NSString *> *ApolloForYouFeedParsePostIDs(NSString *_Nullable html);

// YES when the fragment's markup links a following page
// (`interest-home-feed?after=`). The last page of the feed doesn't.
BOOL ApolloForYouFeedHTMLHasNextPage(NSString *_Nullable html);

// NO when the fragment has posts but was rendered for a signed-out viewer: a
// signed-in render marks every post `user-logged-in`. Reddit still answers a
// dead cookie with a (generic, unpersonalized) feed, so this is how an expired
// web session shows up. YES for markup with no posts (nothing to judge).
BOOL ApolloForYouFeedHTMLIsSignedIn(NSString *_Nullable html);

// x-ratelimit-remaining / -reset from a response's headers (case-insensitive
// keys). -1 when absent or unparsable.
double ApolloForYouFeedRateLimitRemaining(NSDictionary *_Nullable headers);
double ApolloForYouFeedRateLimitReset(NSDictionary *_Nullable headers);

// The `data.children` of an /api/info response (NSDictionary listing, or an
// NSArray whose last element is one — RDKClient accepts both), reordered to
// `orderedIDs`, dropping anything that isn't a t3 the user hasn't hidden.
// Children the response lacks are skipped.
NSArray<NSDictionary *> *ApolloForYouFeedOrderedChildren(id _Nullable infoResponse,
                                                         NSArray<NSString *> *orderedIDs);

// A listing response RDKClient parses like any other: {kind: Listing, data:
// {children, after, before: null, dist}}. `after` nil = no next page.
NSDictionary *ApolloForYouFeedListing(NSArray<NSDictionary *> *children, NSString *_Nullable after);

// Page cursor tokens handed to Apollo as `pagination.after`, so its next-page
// request comes back to the For You engine instead of the network:
// "foryou:<session>:<index>". Can't collide with a real Reddit cursor (t3_…).
NSString *ApolloForYouFeedToken(NSString *sessionID, NSUInteger index);
BOOL ApolloForYouFeedParseToken(NSString *_Nullable token, NSString *_Nullable *_Nullable outSessionID,
                                NSUInteger *_Nullable outIndex);

// Home's front-page listing paths as RDKClient builds them ("best.json",
// "hot.json", ...: -[RDKClient frontPageLinksWithCategory:...] formats
// "%@.json" with no prefix). Every other feed has a prefix (r/…, user/…).
BOOL ApolloForYouFeedIsHomeListingPath(NSString *_Nullable path);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
