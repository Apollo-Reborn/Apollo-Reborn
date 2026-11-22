#import <Foundation/Foundation.h>

// Offline Mode: a pre-downloaded batch of feed posts, their comments and their
// images that Apollo can browse with no connection (a flight, the subway).
// Suggested on r/ApolloReborn as "offline mode similar to TikTok": you choose
// how much data to spend, it downloads a batch, and you scroll it offline.
//
// This file is the Foundation-only half (host-tested in
// tests/offline_library_tests.m):
//   • request keys: maps the URLs Apollo itself asks for to the entries the
//     downloader stored, so the library serves Apollo's own requests even
//     though they carry different sort/limit/raw_json/host details;
//   • the on-disk library (index + one file per entry) and its staged writer;
//   • the policy that decides when the library answers instead of the network.
//
// ApolloOfflineDownloader fills the library; ApolloOfflineMode.xm serves it
// through an NSURLProtocol and owns the settings-facing controller.

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// "home", "r/<sub>", "m/<user>/<multi>" or "saved/<user>" for a Reddit
// listing path such as "/", "/best", "/r/Pics/top", "/user/x/m/y/new",
// "/user/x/saved" (".json" and a trailing slash
// are ignored, names are lowercased). nil for any other path. Sort is
// deliberately dropped: offline, a feed shows the batch that was downloaded
// whatever sort Apollo asks for.
NSString * _Nullable ApolloOfflineFeedKeyForPath(NSString *path);

// The library key for a request URL, or nil when the URL is never served
// offline:
//   feed:<feed>|<after>   Reddit listing page (<after> empty on page one)
//   comments:<id>         a post's comments (/comments/<id>, /r/x/comments/<id>/slug)
//   reddimg:<stem>        i.redd.it / preview.redd.it image (any resolution)
//   extimg:<stem>         external-preview.redd.it image (any resolution)
//   api:<path>|<after>    account reads Apollo makes on most screens (me,
//                         subscriptions, multis, inbox, messages, friends,
//                         blocked) and about:<sub> for a subreddit's info
//   favicon:<domain>      Google's site-icon service, by domain
//   url:<host><path>      any other host (query dropped)
NSString * _Nullable ApolloOfflineKeyForURL(NSURL *url);

// YES for the hosts Apollo's Reddit API reads go to (oauth/www/old reddit.com).
BOOL ApolloOfflineURLIsRedditAPI(NSURL *url);

// The image URLs worth saving for one post's `data` dictionary (a t3 child):
// the preview at the largest resolution no wider than maxWidth (or the
// source), every gallery image, the thumbnail, a direct i.redd.it/i.imgur.com
// image, and the same for a crosspost's parent. Duplicates by library key are
// removed. Videos are saved separately (below); this covers their posters.
NSArray<NSURL *> *ApolloOfflineImageURLsForPost(NSDictionary *post, NSInteger maxWidth);

// MARK: Video
//
// A Reddit-hosted video (v.redd.it, including the silent clips Apollo labels
// "GIF") is saved as ONE local mp4 with its sound: the downloader picks a
// video and an audio rendition from the post's DASH manifest, fetches both
// files and remuxes them (no re-encode). Offline, ApolloOfflineMode.xm hands
// Apollo's player that file in place of the streaming URL, so playback never
// touches the network. The master playlist is saved as well, because Apollo
// reads it to decide whether a post has sound (no sound = "GIF" pill).

// The v.redd.it id in any URL that names one: the https master/variant/media
// URLs and Apollo's own player URLs, whatever their scheme. nil otherwise.
NSString * _Nullable ApolloOfflineRedditVideoIDForURL(NSURL * _Nullable url);
// "video:<id>", the library key for a saved video file.
NSString *ApolloOfflineVideoKey(NSString *videoID);

// The post's Reddit-hosted video (its own, else its crosspost parent's):
// @{ "id", "dash" (NSURL), "hls" (NSURL), "duration" (NSNumber, seconds),
//    "hasAudio" (NSNumber BOOL) }. nil when it has none.
NSDictionary * _Nullable ApolloOfflineRedditVideoForPost(NSDictionary *post);

// The renditions to save from a DASH manifest: the tallest video no taller
// than maxHeight (else the shortest one) and the highest-bandwidth audio:
// @{ "video" (NSURL), "videoBandwidth", "height", optional "audio" (NSURL),
//    "audioBandwidth" }. Only self-contained files (a BaseURL per
// Representation) qualify; nil when there's no usable video.
NSDictionary * _Nullable ApolloOfflineRedditVideoRenditions(NSData *manifest, NSURL *manifestURL, NSInteger maxHeight);

// Rough time it takes to get through a batch: ~12 s per post plus the running
// time of its saved videos. Shown next to the size so "how much is this?" can
// be read in minutes as well as megabytes.
NSTimeInterval ApolloOfflineEstimatedBrowseTime(NSUInteger posts, NSTimeInterval videoSeconds);

// Videos on the outside hosts Apollo plays in its own player, where the link
// is the post's URL: @{ "host": "imgur" | "streamable" | "redgifs", "id" }.
// Apollo resolves these itself (redgifs and Streamable through their APIs),
// so the downloader saves those API answers plus the mp4 they point at, and
// the player swap finds the file by its URL. nil for anything else.
NSDictionary * _Nullable ApolloOfflineHostedVideoForPost(NSDictionary *post);

// The web page a link post points at (an article, a blog, a store page), or
// nil for self posts and anything that's media Apollo shows itself. Saved as a
// complete web archive so it opens offline.
NSURL * _Nullable ApolloOfflineArticleURLForPost(NSDictionary *post);
// "page:<host><path>[?query]", the key for a saved web page (fragment, a
// trailing slash and a leading "www." ignored, host lowercased): Apollo asks
// for "bbc.com/…" when the post links "www.bbc.com/…".
NSString * _Nullable ApolloOfflinePageKey(NSURL * _Nullable url);

// From a web archive: the main document's bytes, MIME type and encoding.
// Apollo fetches a link post's page itself to title its link card, so the
// saved page answers that request too.
NSData * _Nullable ApolloOfflineWebArchiveMainResource(NSData *archive, NSString * _Nullable * _Nullable mimeType,
                                                       NSString * _Nullable * _Nullable encoding);
// The page's share image (og:image, else twitter:image), resolved against
// the page URL: what Apollo's link card shows.
NSURL * _Nullable ApolloOfflineWebArchiveShareImageURL(NSData *archive, NSURL *pageURL);
// Google's favicon URL for a page's site (what Apollo shows on link cards).
NSURL * _Nullable ApolloOfflineFaviconURL(NSURL *pageURL);
// A tiny stand-in page for a link post whose page couldn't be saved (a bot
// wall, too big, Linked Web Pages off): the post's title and its saved
// preview image as og:image, so Apollo's link card still has both.
NSData * _Nullable ApolloOfflineLinkCardHTML(NSDictionary *post, NSInteger maxWidth);

// The listing JSON with only its first `keep` children and, when `endHere`,
// data.after set to null so Apollo treats it as the last page. nil when the
// data isn't a listing.
NSData * _Nullable ApolloOfflineTruncatedListing(NSData *listing, NSUInteger keep, BOOL endHere);

typedef NS_ENUM(NSInteger, ApolloOfflineUseMode) {
    ApolloOfflineUseModeAutomatic = 0,  // only while the device has no connection
    ApolloOfflineUseModeAlways = 1,     // always, even online (captive Wi-Fi, saving data)
    ApolloOfflineUseModeNever = 2,      // keep the library but never use it
};

// Whether saved entries should answer requests right now.
BOOL ApolloOfflineShouldServe(ApolloOfflineUseMode mode, BOOL networkAvailable, BOOL hasLibrary, BOOL downloading);

// The listing JSON without the posts whose bare id ("abc123") is in `postIDs`.
// data.after is kept, so the page still chains to the same next page. Sets
// *removed to how many were dropped. nil when the data isn't a listing.
NSData * _Nullable ApolloOfflineListingRemovingPosts(NSData *listing, NSSet<NSString *> *postIDs, NSUInteger * _Nullable removed);

// Inputs for "Keep fresh": refresh the batch on its own while Apollo is open.
typedef struct {
    BOOL enabled;                   // the user's setting
    BOOL hasLibrary;                // only after a first manual download (an opt-in)
    NSTimeInterval libraryAge;      // seconds since the last batch
    double readFraction;            // share of the batch's posts already read (0...1)
    BOOL networkAvailable;
    BOOL onWiFi;
    BOOL allowCellular;             // the user's "Use Cellular Data" setting
    BOOL lowPowerMode;
    BOOL lowDataMode;               // the current network is in Low Data Mode
    BOOL serving;                   // the library is answering requests
    BOOL downloading;
    NSTimeInterval sinceLastAttempt; // seconds since the last automatic try
} ApolloOfflineAutoRefreshState;

// Refresh when the batch is this old...
extern const NSTimeInterval ApolloOfflineAutoRefreshMaxAge;        // 1 hour
// ...or sooner, once this share of it has been read (TikTok-style top-up)...
extern const double ApolloOfflineAutoRefreshReadFraction;          // 0.5
// ...but never for a batch younger than this.
extern const NSTimeInterval ApolloOfflineAutoRefreshMinAge;        // 10 minutes
extern const NSTimeInterval ApolloOfflineAutoRefreshRetryInterval; // 15 minutes

BOOL ApolloOfflineShouldAutoRefresh(ApolloOfflineAutoRefreshState state);

// Profile pictures. Apollo and Reborn's avatars look authors up in batches with
// /api/user_data_by_account_ids?ids=t2_a,t2_b (any mix of ids, so no fixed
// key). Downloads save Reddit's answers under "users:<n>"; offline the library
// answers any such request with the saved records it has.
// Reborn's own avatar lookups (/user/<name>/about, see ApolloUserProfileCache)
// carry this NSURLProtocol property; offline, the library answers them from the
// same saved records with a small profile ("apollo_offline_lightweight": just
// the name, picture and karma). Apollo's own profile reads don't carry it and
// are never answered that way.
static NSString *const ApolloOfflineProfileLookupProperty = @"ApolloOfflineProfileLookup";
// The lowercased username a /user/<name>/about URL is for, or nil.
NSString * _Nullable ApolloOfflineProfileUsernameForURL(NSURL *url);
// The t2_ ids a user_data_by_account_ids URL asks for, or nil for any other URL.
NSArray<NSString *> * _Nullable ApolloOfflineUserDataIDsForURL(NSURL *url);
// Authors to look up for a post: its own author, then the first `limit`
// distinct commenters in reading order (from the comments response).
NSArray<NSString *> *ApolloOfflineAuthorFullNames(NSDictionary *post, NSData * _Nullable comments, NSUInteger limit);

// Seconds to wait before the next Reddit API call, from the rate-limit headers
// Reddit sends with every reply (x-ratelimit-remaining / -used / -reset; pass
// -1 for a missing one). While more than `reserveFraction` of the window's
// allowance is left, calls go `minSpacing` apart; past that, at most half of
// what's left is spread over the rest of the window, so browsing always keeps
// some. Without the headers, `fallback`.
NSTimeInterval ApolloOfflineAPISpacing(double remaining, double used, double reset, double reserveFraction,
                                       NSTimeInterval minSpacing, NSTimeInterval fallback);

#ifdef __cplusplus
}
#endif

// A committed library on disk. Lookups are thread-safe and cheap (an in-memory
// key set), because the URL protocol asks for every request the app makes.
@interface ApolloOfflineLibrary : NSObject

// <Application Support>/ApolloReborn/OfflineLibrary (excluded from backups).
+ (NSURL *)defaultDirectory;
+ (instancetype)sharedLibrary;

- (instancetype)initWithDirectory:(NSURL *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *directory;
@property (nonatomic, readonly) BOOL hasContent;
@property (nonatomic, readonly) NSUInteger postCount;
@property (nonatomic, readonly) unsigned long long totalBytes;
@property (nonatomic, readonly, nullable) NSDate *downloadedAt;
// Human titles of the feeds in this batch, in download order ("Home", "r/pics").
@property (nonatomic, readonly) NSArray<NSString *> *feedTitles;

// Feed keys also resolve through any saved post's fullname (see
// -[ApolloOfflineLibraryWriter storeFeedPage:forKey:postNames:]): the answer
// is the rest of that post's page, or the next saved page when it was last.
- (BOOL)hasEntryForKey:(NSString *)key;
- (nullable NSData *)dataForKey:(NSString *)key contentType:(NSString * _Nullable * _Nullable)contentType;

// Bare ids ("abc123") of every post saved in feed pages.
@property (nonatomic, readonly) NSArray<NSString *> *savedPostIDs;

// Videos saved in this batch and their total running time.
@property (nonatomic, readonly) NSUInteger videoCount;
@property (nonatomic, readonly) NSTimeInterval videoSeconds;

// The file behind a stored entry (videos are played straight from disk).
- (nullable NSURL *)fileURLForKey:(NSString *)key;
// The saved video for a player URL: a v.redd.it id anywhere in it, or an
// outside host's media URL saved under its own key.
- (nullable NSURL *)videoFileURLForURL:(NSURL *)url;
// The saved web archive for a page URL, if any.
- (nullable NSData *)pageArchiveForURL:(NSURL *)url;
- (BOOL)hasPageForURL:(NSURL *)url;
// The saved page's own HTML (or its stand-in card), for a plain GET of its
// URL (Apollo's link card).
- (nullable NSData *)pageDocumentForURL:(NSURL *)url contentType:(NSString * _Nullable * _Nullable)contentType;
// Pages saved in this batch.
@property (nonatomic, readonly) NSUInteger pageCount;
// Saved author records for a user_data_by_account_ids request: YES when any of
// its ids was saved, and the answer (only the saved ones) as Reddit's JSON.
- (BOOL)hasUserDataForURL:(NSURL *)url;
- (nullable NSData *)userDataResponseForURL:(NSURL *)url;
// A small /user/<name>/about answer for a saved author, for Reborn's avatar lookups.
- (BOOL)hasProfileForURL:(NSURL *)url;
- (nullable NSData *)profileResponseForURL:(NSURL *)url;

// Re-reads the index from disk (after a download commits).
- (void)reload;
// Deletes the library from disk.
- (BOOL)removeAll:(NSError **)error;

@end

// Writes a new batch into a staging folder next to the library and swaps it in
// atomically on commit, so the old batch keeps working until the new one is
// complete and a cancelled download leaves nothing behind.
@interface ApolloOfflineLibraryWriter : NSObject

- (nullable instancetype)initWithLibraryDirectory:(NSURL *)directory error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) unsigned long long bytesWritten;
@property (nonatomic, readonly) NSUInteger postCount;

- (BOOL)hasKey:(NSString *)key;
- (BOOL)storeData:(NSData *)data contentType:(nullable NSString *)contentType forKey:(NSString *)key;
// A feed page ("feed:<feed>|<after>") plus the fullnames of its posts, in
// order. The library uses them to answer `after=<any saved post>`: Apollo
// often loaded page one online with its own page size, so its next-page
// cursor is a post in the middle of a saved page, not a saved page's key.
- (BOOL)storeFeedPage:(NSData *)data forKey:(NSString *)key postNames:(NSArray<NSString *> *)names;
// Moves `file` into the batch (keeping `pathExtension`, which AVFoundation
// uses to recognise a local mp4) and counts it as one saved video.
- (BOOL)storeVideoFile:(NSURL *)file forKey:(NSString *)key pathExtension:(NSString *)pathExtension
              duration:(NSTimeInterval)duration;
// A fresh scratch file path inside the staging folder (gone after commit).
- (NSURL *)scratchFileURLWithExtension:(NSString *)pathExtension;
// Another key for an already-stored entry, sharing its file (no extra bytes):
// redgifs and Streamable each offer an HD and a mobile URL for one saved mp4.
- (BOOL)storeAlias:(NSString *)alias forKey:(NSString *)key;
// A web archive of the page at `url` (counted as one saved page).
- (BOOL)storePageArchive:(NSData *)archive forURL:(NSURL *)url;
// The stand-in from ApolloOfflineLinkCardHTML, when there's no archive.
- (BOOL)storeLinkCard:(NSData *)html forURL:(NSURL *)url;
- (void)noteFeedTitle:(NSString *)title posts:(NSUInteger)posts;
- (BOOL)commit:(NSError **)error;
- (void)discard;

@end

NS_ASSUME_NONNULL_END
