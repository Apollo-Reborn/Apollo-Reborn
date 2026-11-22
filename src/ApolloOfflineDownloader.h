#import <Foundation/Foundation.h>

// Fills an ApolloOfflineLibrary with one batch: for each chosen feed, listing
// pages and, per post, its comments and images, until the data budget is
// spent. Foundation-only and transport-agnostic (the fetcher and the Reddit
// request builder are injected) so tests/offline_library_tests.m can drive it
// with fixtures; ApolloOfflineMode.xm supplies the real session and auth.
//
// What Apollo later sees offline:
//   • each feed's pages chain exactly as downloaded (page N's `after` is the
//     key of page N+1) and the last kept page has `after: null`, so the feed
//     ends cleanly instead of failing on a page that was never fetched;
//   • a page is cut to the posts whose comments and images were saved, so
//     every post you can scroll to opens offline;
//   • a post's video plays offline with sound when it fit the limits: Reddit's
//     own (v.redd.it) and imgur, Streamable and RedGIFs clips;
//   • a link post's web page opens offline from a saved web archive.

NS_ASSUME_NONNULL_BEGIN

typedef void (^ApolloOfflineFetchCompletion)(NSData * _Nullable data, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error);
typedef void (^ApolloOfflineFetcher)(NSURLRequest *request, ApolloOfflineFetchCompletion completion);
// Builds an authenticated Reddit read for `path` ("/r/pics/hot", "/comments/abc").
typedef NSURLRequest * _Nonnull (^ApolloOfflineRequestBuilder)(NSString *path, NSArray<NSURLQueryItem *> *query);

@interface ApolloOfflineFeedSource : NSObject
@property (nonatomic, copy, readonly) NSString *path;   // "/best", "/r/popular/hot", "/r/pics/hot"
@property (nonatomic, copy, readonly) NSString *title;  // "Home", "r/pics"
// Keep posts the user has read (Saved Posts: they were saved on purpose).
@property (nonatomic) BOOL keepsReadPosts;
// Extra query items for every page of this feed (Saved: type=links).
@property (nonatomic, copy, nullable) NSArray<NSURLQueryItem *> *queryItems;
+ (instancetype)sourceWithPath:(NSString *)path title:(NSString *)title;
@end

@interface ApolloOfflineDownloadOptions : NSObject
@property (nonatomic, copy) NSArray<ApolloOfflineFeedSource *> *sources;
@property (nonatomic) unsigned long long byteBudget;
@property (nonatomic) BOOL includeComments;            // default YES
@property (nonatomic) BOOL includeImages;              // default YES
@property (nonatomic) NSUInteger pageSize;             // default 50
@property (nonatomic) NSUInteger maxPostsPerFeed;      // default 300
@property (nonatomic) NSInteger maxImageWidth;         // default 1080 px
@property (nonatomic) unsigned long long maxImageBytes; // default 12 MB (skips huge GIFs)
// Reddit-hosted videos, saved as one mp4 with sound (needs a videoMuxer).
@property (nonatomic) BOOL includeVideos;              // default YES
@property (nonatomic) NSInteger maxVideoHeight;        // default 720 px
@property (nonatomic) unsigned long long maxVideoBytes; // default 60 MB per video
@property (nonatomic) NSTimeInterval maxVideoDuration; // default 5 minutes
// The web page behind each link post, as a complete web archive (needs a pageSaver).
@property (nonatomic) BOOL includePages;               // default YES
@property (nonatomic) unsigned long long maxPageBytes; // default 5 MB per page
// Profile pictures for the people in each saved thread: the post's author and
// its first `avatarAuthorsPerPost` commenters, looked up 100 at a time
// (/api/user_data_by_account_ids) after the feeds, with their pictures. Needs
// includeImages. Pictures get `avatarShare` of the data limit (at most
// maxAvatarBytes), set aside from what the feeds use. Lookups keep going after
// that runs out (up to maxAvatarAuthors): they're tiny, and everyone with one
// of Reddit's default avatars shares a picture that's already saved.
@property (nonatomic) BOOL includeAvatars;             // default YES
@property (nonatomic) NSUInteger avatarAuthorsPerPost; // default 30
@property (nonatomic) double avatarShare;              // default 0.12
@property (nonatomic) unsigned long long maxAvatarBytes; // default 20 MB
@property (nonatomic) NSUInteger maxAvatarAuthors;     // default 3000
// Account reads saved once per batch after the feeds ("/api/me",
// "/message/inbox", "/r/pics/about", ...), so profile, inbox, Subreddits and
// subreddit headers load offline. Listings follow `after` up to 10 pages.
@property (nonatomic, copy) NSArray<NSString *> *accountPaths;
// Reddit API pacing. Reddit reports its rate limit on every reply; while more
// than `apiReserveFraction` of the window's allowance is left (kept for normal
// browsing), calls go `apiMinSpacing` apart, then slow down to spread the rest
// (ApolloOfflineAPISpacing). `apiSpacing` is the gap when Reddit doesn't say.
@property (nonatomic) NSTimeInterval apiSpacing;       // default 0.75 s
@property (nonatomic) NSTimeInterval apiMinSpacing;    // default 0.25 s
@property (nonatomic) double apiReserveFraction;       // default 0.2
// Posts worked on at once. A post's comments, images, video and page are
// fetched while the next posts' start, so one slow page doesn't hold up the
// rest. Feeds are still saved in order.
@property (nonatomic) NSUInteger postConcurrency;      // default 4
// Bare post ids ("abc123") to leave out: posts the user has already read.
// They're removed from the saved pages too, so offline feeds only show new
// posts. A page that's entirely read is replaced by the next one under the
// same key, so the feed doesn't end early.
@property (nonatomic, copy) NSSet<NSString *> *skipPostIDs;
@end

// Combines a video-only file and an optional audio-only file into one mp4 at
// `output` without re-encoding, then calls `done` (any queue) with the
// result's running time. Supplied by the app (AVFoundation); tests fake it.
typedef void (^ApolloOfflineVideoMuxer)(NSURL *video, NSURL * _Nullable audio, NSURL *output,
                                        void (^done)(BOOL ok, NSTimeInterval duration));

// Loads `url` in a browser and calls `done` (any queue) with a web archive of
// the finished page, or nil. Supplied by the app (WebKit); tests fake it.
typedef void (^ApolloOfflinePageSaver)(NSURL *url, void (^done)(NSData * _Nullable archive));

typedef void (^ApolloOfflineProgress)(unsigned long long bytes, NSUInteger posts, NSString *status);
typedef void (^ApolloOfflineCompletion)(BOOL committed, NSUInteger posts, unsigned long long bytes, NSError * _Nullable error);

extern NSErrorDomain const ApolloOfflineErrorDomain;
typedef NS_ENUM(NSInteger, ApolloOfflineErrorCode) {
    ApolloOfflineErrorCancelled = 1,
    ApolloOfflineErrorNothingDownloaded = 2,
    ApolloOfflineErrorStorage = 3,
};

@interface ApolloOfflineDownloader : NSObject

- (instancetype)initWithLibraryDirectory:(NSURL *)directory
                                 fetcher:(ApolloOfflineFetcher)fetcher
                          requestBuilder:(ApolloOfflineRequestBuilder)requestBuilder NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) BOOL running;
// Set before starting; without it videos are skipped (posters still save).
@property (nonatomic, copy, nullable) ApolloOfflineVideoMuxer videoMuxer;
// Set before starting; without it link posts keep only their preview image.
@property (nonatomic, copy, nullable) ApolloOfflinePageSaver pageSaver;
// Posts left out of the last run because they were already read.
@property (nonatomic, readonly) NSUInteger skippedPostCount;
// Authors looked up and profile pictures saved in the last run.
@property (nonatomic, readonly) NSUInteger avatarAuthorCount;
@property (nonatomic, readonly) NSUInteger avatarImageCount;

// Callbacks arrive on the main queue. The library on disk is replaced only
// when the batch commits; a failed or cancelled run leaves the old one.
- (void)startWithOptions:(ApolloOfflineDownloadOptions *)options
                progress:(nullable ApolloOfflineProgress)progress
              completion:(ApolloOfflineCompletion)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
