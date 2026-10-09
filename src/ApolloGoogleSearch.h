#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// Google search restricted to Reddit, for the Search tab's "Google" mode.
//
// Google has served its results page only to JavaScript-capable clients since
// early 2025: a plain NSURLSession fetch gets a JS "SearchGuard" bootstrap
// page with no results in it. So the search runs the way a browser does — in
// one of the tweak's hidden scrape web views (ApolloScrapeWebView: attached at
// alpha 0.011, media/ad blocker, real mobile Safari UA) — and the results are
// read out of the rendered DOM with a small extractor script.
//
// When Google decides to challenge the request (its "unusual traffic"
// reCAPTCHA page) or asks for cookie consent (EU), the session hands the same
// web view to the UI through -presentVerification so the USER can answer it;
// the search resumes by itself once Google redirects back to the results.
// Nothing here ever answers a challenge or a consent prompt automatically.
//
// Google hides each result's destination behind an encrypted google.com/goto
// link — a click-tracking redirect. The list is built from what the results
// page itself shows (title, snippet, subreddit, Google's "30+ comments · 2
// weeks ago" line), and a result's link is followed only when the user acts on
// that result (opens it, taps Read More, long-presses it): one click-through,
// sent with the search's own Google cookies, exactly like tapping a result in
// a browser. Following all of them up front would be ten automated "clicks"
// per search, which is the kind of traffic Google's bot checks react to.
//
// Read More then reads the post (or comment) from Reddit through the same
// auth path the rest of the tweak uses for tweak-authored Reddit reads (bearer
// in API-key mode, web session in API-key-free mode), which also swaps
// Google's line for Reddit's own score, comment count and age.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloGoogleSearchTimeRange) {
    ApolloGoogleSearchTimeRangeAny = 0,
    ApolloGoogleSearchTimeRangeDay,
    ApolloGoogleSearchTimeRangeWeek,
    ApolloGoogleSearchTimeRangeMonth,
    ApolloGoogleSearchTimeRangeYear,
};

typedef NS_ENUM(NSInteger, ApolloGoogleResultKind) {
    ApolloGoogleResultKindPost = 0,
    ApolloGoogleResultKindComment,
    ApolloGoogleResultKindSubreddit,
    ApolloGoogleResultKindUser,
    ApolloGoogleResultKindOther,
};

// What a post links to, from Reddit's own data (drives the card's footer label).
typedef NS_ENUM(NSInteger, ApolloGoogleResultMedia) {
    ApolloGoogleResultMediaNone = 0,   // text post, comment, or unknown
    ApolloGoogleResultMediaImage,
    ApolloGoogleResultMediaGallery,
    ApolloGoogleResultMediaVideo,
    ApolloGoogleResultMediaLink,       // external site: see linkDomain
};

typedef NS_ENUM(NSInteger, ApolloGoogleSearchErrorCode) {
    ApolloGoogleSearchErrorTimedOut = 1,
    ApolloGoogleSearchErrorNetwork = 2,
    ApolloGoogleSearchErrorVerificationCancelled = 3,
    ApolloGoogleSearchErrorUnreadable = 4,
    // Kagi: the saved Session Link was rejected (expired, revoked, or never
    // valid). The user has to paste a new one.
    ApolloGoogleSearchErrorSessionExpired = 5,
};

FOUNDATION_EXPORT NSString *const ApolloGoogleSearchErrorDomain;

@interface ApolloGoogleSearchOptions : NSObject <NSCopying>
@property (nonatomic) ApolloGoogleSearchTimeRange timeRange;
// Google's "Verbatim" mode (tbs=li:1): no synonyms, no spelling rewrites.
// The right tool for exact error messages and part/model numbers.
@property (nonatomic) BOOL exactWords;
@end

@interface ApolloGoogleSearchResult : NSObject
@property (nonatomic) ApolloGoogleResultKind kind;
// Canonical https://www.reddit.com/... URL (routes through Apollo's native
// views). nil until -resolveResult:… has followed googleLinkURL.
@property (nonatomic, strong, nullable) NSURL *URL;
// Google's own link for the result (its encrypted /goto redirect), followed
// only when the user acts on the result.
@property (nonatomic, strong, nullable) NSURL *googleLinkURL;
@property (nonatomic, copy, nullable) NSString *subreddit;   // without "r/"
@property (nonatomic, copy, nullable) NSString *username;    // user pages / profile posts
@property (nonatomic, copy, nullable) NSString *postID;      // base36, no "t3_"
@property (nonatomic, copy, nullable) NSString *commentID;   // base36, no "t1_"

// From the search engine's results page.
@property (nonatomic, copy) NSString *title;
// Plain snippet text; runs Google bolded (the query terms) are in snippetBoldRanges.
@property (nonatomic, copy) NSString *snippet;
@property (nonatomic, copy) NSArray<NSValue *> *snippetBoldRanges;
// The engine's own line for the result, shown until Reddit's numbers are in:
// Google's forum line ("30+ comments · 2 weeks ago"), Kagi's date
// ("Mar 27, 2025"). nil when absent.
@property (nonatomic, copy, nullable) NSString *engineMeta;

// From Reddit (/api/info.json), after -resolveResult:withRedditInfo:YES.
// hasRedditInfo stays NO when that read failed.
@property (nonatomic) BOOL hasRedditInfo;
@property (nonatomic, copy, nullable) NSString *redditTitle;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, copy, nullable) NSString *bodyText;     // selftext / comment body (markdown source)
@property (nonatomic, copy, nullable) NSString *linkDomain;   // external link posts ("youtube.com")
@property (nonatomic) ApolloGoogleResultMedia media;
@property (nonatomic) NSInteger score;
@property (nonatomic) NSInteger commentCount;
@property (nonatomic, strong, nullable) NSDate *created;
@property (nonatomic) BOOL over18;
@property (nonatomic) BOOL spoiler;

// The key used to drop duplicates (same post/comment reached through
// www/old/np hosts, trailing slugs, query strings, ...).
@property (nonatomic, copy, readonly) NSString *dedupeKey;
@end

// The query actually sent to Google. Bundles the "search Reddit with Google"
// habits so the user doesn't have to type them:
//   * restricts to reddit.com (site:reddit.com), unless the user wrote their own site:
//   * "r/name" tokens become site:reddit.com/r/name (several are OR-ed together)
//   * a habitual trailing "reddit" is dropped (the site: restriction replaces it)
// Everything else — quotes, -exclusions, OR, intitle:, ... — passes through.
FOUNDATION_EXPORT NSString *ApolloGoogleSearchComposeQuery(NSString *rawQuery);

// The results-page URL for `rawQuery`, `options` and zero-based `page`.
FOUNDATION_EXPORT NSURL *_Nullable ApolloGoogleSearchURL(NSString *rawQuery,
                                                        ApolloGoogleSearchOptions *_Nullable options,
                                                        NSUInteger page);

// Classify a Reddit URL from a Google result. nil for non-Reddit URLs and for
// Reddit pages Apollo can't show natively (Answers, media viewer, search, ...).
FOUNDATION_EXPORT ApolloGoogleSearchResult *_Nullable ApolloGoogleSearchResultForURL(NSURL *url);

// Markdown source → readable plain text for the "Read more" preview.
FOUNDATION_EXPORT NSString *ApolloGoogleSearchPlainTextFromMarkdown(NSString *markdown);

// Strips the site suffix search engines put on Reddit page titles
// ("Title : r/PTCGP", "Title - Reddit", "r/PTCGP - Title").
FOUNDATION_EXPORT NSString *ApolloGoogleSearchCleanTitle(NSString *title);

// One batched /api/info.json read for the results' posts and comments, applied
// onto them (hasRedditInfo, score, author, body, ...). Runs on the account's
// usual path for tweak-authored reads. Completion on main; nil task (and an
// async completion) when there is nothing to read.
FOUNDATION_EXPORT NSURLSessionDataTask *_Nullable ApolloGoogleSearchFetchRedditInfo(
    NSArray<ApolloGoogleSearchResult *> *results,
    void (^completion)(NSUInteger applied, NSInteger status, NSError *_Nullable error));

typedef void (^ApolloGoogleSearchCompletion)(NSArray<ApolloGoogleSearchResult *> *results,
                                             BOOL mayHaveMore,
                                             NSError *_Nullable error);

// What the Search tab's results list needs from an external engine (Google,
// Kagi). Results are ApolloGoogleSearchResult whichever engine found them.
@protocol ApolloExternalSearchSession <NSObject>
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
// One search at a time: starting a new one cancels the previous one silently
// (its completion is never called). Completion always runs on the main queue.
- (void)searchQuery:(NSString *)query
            options:(nullable ApolloGoogleSearchOptions *)options
               page:(NSUInteger)page
         completion:(ApolloGoogleSearchCompletion)completion;
// Makes sure result.URL is known and, with `withRedditInfo`, reads the post or
// comment from Reddit. Completion on the main queue; `error` only when the
// Reddit URL couldn't be recovered.
- (void)resolveResult:(ApolloGoogleSearchResult *)result
       withRedditInfo:(BOOL)withRedditInfo
           completion:(void (^)(NSError *_Nullable error))completion;
// Cancels silently (no completion).
- (void)cancel;
@end

@interface ApolloGoogleSearchSession : NSObject <ApolloExternalSearchSession>
// Called when Google shows a challenge or consent page. Present `webView`
// (reparent it into a visible view) so the user can answer it; the pending
// search completes on its own when Google returns to the results.
@property (nonatomic, copy, nullable) void (^presentVerification)(WKWebView *webView);
// Called when the verification page is gone (answered, or the search ended).
@property (nonatomic, copy, nullable) void (^dismissVerification)(void);
@property (nonatomic, readonly, getter=isLoading) BOOL loading;

// One search at a time: starting a new one cancels the previous one silently
// (its completion is never called). Completion always runs on the main queue.
- (void)searchQuery:(NSString *)query
            options:(nullable ApolloGoogleSearchOptions *)options
               page:(NSUInteger)page
         completion:(ApolloGoogleSearchCompletion)completion;

// Follows the result's Google link to its Reddit URL (when not known yet),
// then, with `withRedditInfo`, reads the post/comment from Reddit. Independent
// of any search in flight; calls for a result whose link is already being
// followed wait for that follow. Completion on the main queue; `error` only
// when the Reddit URL couldn't be recovered (the Reddit read failing is not an
// error: the result keeps Google's data and hasRedditInfo stays NO).
- (void)resolveResult:(ApolloGoogleSearchResult *)result
       withRedditInfo:(BOOL)withRedditInfo
           completion:(void (^)(NSError *_Nullable error))completion;
// Cancels silently (no completion).
- (void)cancel;
// The user closed the verification sheet: completes the pending search with
// ApolloGoogleSearchErrorVerificationCancelled.
- (void)verificationCancelledByUser;
@end

#if APOLLO_SIM_BUILD
// Simulator debug bridge ("gsearch <query>" / "gsearchjs <js>"): run a search
// and log every extracted result + dump the page HTML, or evaluate JS in the
// last results page (kept alive in sim builds for exactly this).
FOUNDATION_EXPORT void ApolloGoogleSearchDebugRun(NSString *query);
FOUNDATION_EXPORT void ApolloGoogleSearchDebugEvaluateJS(NSString *js);
// "gsearchdebug verify=consent|sorry|off info=0|1 fail fixture=<path>|off followdelay=<s> stall=0|1
// legacyjar=0|1 cookies": test knobs, see ApolloGoogleSearch.m.
FOUNDATION_EXPORT void ApolloGoogleSearchDebugConfigure(NSString *arguments);
#endif

NS_ASSUME_NONNULL_END
