// ApolloRedditVideoPlaylistProtocol.xm
//
// GIFs and videos that never load, show a "GIF" pill instead of a mute button,
// open to a black viewer, or freeze the app when tapped (issues #1698, #1714,
// #1716, #1720, #1721; likely #1530 and #1637 too).
//
// Root cause (reproduced 2026-11-15 in the simulator on 4.1.0, see
// ApolloRedditVideoPlaylist.h for the measurements): Reddit's origin answers
// https://v.redd.it/<id>/HLSPlaylist.m3u8 with an S3 "AccessDenied" 403 about
// half the time for an affected video, and the CDN caches that 403 for 10
// minutes. Apollo fetches that master playlist twice per post, both through
// sessions built from +[NSURLSessionConfiguration defaultSessionConfiguration]:
//
//   1. RedditVideoIdentifier (Ghidra FUN_1006c8038 / FUN_1006c8320) reads it
//      with -dataTaskWithURL:completionHandler: and looks for an audio
//      rendition. The 403 body has none, so the post is labelled "GIF" and
//      that verdict is cached for the session.
//   2. VideoResourceLoader (the video-player:// AVAssetResourceLoader, via its
//      private DataDelegate session) feeds the master to AVFoundation. On an
//      HTTP error *response* it never finishes the AVAssetResourceLoadingRequest
//      (the task is left suspended), so the AVPlayerItem stays "unknown"
//      forever: the poster never starts, the viewer is black with a pause
//      button. Worse, opening that post runs Apollo's
//      MediaViewerAnimationController -animateTransition:, which calls
//      -[AVAsset tracksWithMediaType:] synchronously on the main thread
//      (sampled: Apollo+0x209e2c → AVURLAsset tracks → ObtainPropertySync); with
//      the master stuck that blocks until AVFoundation gives up (13 s measured)
//      — the reported freeze. A transport *error* is handled fine: the item
//      fails at once and the viewer opens without blocking.
//
// Fix: an NSURLProtocol for exactly https://v.redd.it/<id>/HLSPlaylist.m3u8,
// added to every default session configuration (and registered globally for
// the shared session). It fetches the real master; when that is
// anything but an HLS playlist it rebuilds the master from the video's
// DASHPlaylist.mpd (reliable) — same variants, same layout — and, failing
// that, retries the master once. When nothing works it reports an NSError
// instead of the 403 response, so Apollo fails the item immediately instead
// of hanging (no freeze). Healthy masters pass through byte for byte.
// The variant playlists and media segments are fetched by AVFoundation's own
// HTTP stack and are not touched.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloRedditVideoPlaylist.h"

static NSString *const kApolloVideoPlaylistHandledKey = @"ApolloRedditVideoPlaylistHandled";
// A rebuilt master is reused for this long (the CDN keeps a 403 for 600 s), so
// the identifier and the player — and re-opens — don't each pay a fetch.
static const NSTimeInterval kApolloVideoPlaylistRecoveredTTL = 600;

@interface ApolloRedditVideoPlaylistProtocol : NSURLProtocol
@end

// MARK: - Shared state

static NSURLSession *ApolloVideoPlaylistSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Built from the hooked default configuration, then with this protocol
        // removed so inner fetches go straight to the network (the handled
        // marker on each request is a second guard against recursion).
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSMutableArray *protocols = [NSMutableArray arrayWithArray:configuration.protocolClasses ?: @[]];
        [protocols removeObject:[ApolloRedditVideoPlaylistProtocol class]];
        configuration.protocolClasses = protocols;
        configuration.timeoutIntervalForRequest = 20;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.name = @"app.apolloreborn.video-playlist";
        queue.maxConcurrentOperationCount = 1;
        session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:queue];
    });
    return session;
}

static NSMutableDictionary<NSString *, NSArray *> *ApolloVideoPlaylistRecovered(void) {
    static NSMutableDictionary *recovered;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ recovered = [NSMutableDictionary dictionary]; });
    return recovered;
}

static NSData *ApolloVideoPlaylistCachedRecovery(NSString *videoID) {
    NSMutableDictionary *recovered = ApolloVideoPlaylistRecovered();
    @synchronized (recovered) {
        NSArray *entry = recovered[videoID];
        if (!entry) return nil;
        if (CFAbsoluteTimeGetCurrent() - [entry[1] doubleValue] > kApolloVideoPlaylistRecoveredTTL) {
            [recovered removeObjectForKey:videoID];
            return nil;
        }
        return entry[0];
    }
}

static void ApolloVideoPlaylistRememberRecovery(NSString *videoID, NSData *playlist) {
    NSMutableDictionary *recovered = ApolloVideoPlaylistRecovered();
    @synchronized (recovered) {
        if (recovered.count > 64) [recovered removeAllObjects];
        recovered[videoID] = @[playlist, @(CFAbsoluteTimeGetCurrent())];
    }
}

static NSInteger ApolloVideoPlaylistStatus(NSURLResponse *response) {
    return [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
}

static BOOL ApolloVideoPlaylistIsGood(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = ApolloVideoPlaylistStatus(response);
    return !error && status >= 200 && status < 300 && ApolloRedditVideoDataIsHLSPlaylist(data);
}

// MARK: - Protocol

@interface ApolloRedditVideoPlaylistProtocol ()
@property (nonatomic, strong) NSThread *clientThread;
@property (nonatomic, copy) NSArray<NSString *> *clientModes;
@property (atomic, strong) NSURLSessionDataTask *innerTask;
@property (atomic) BOOL stopped;
@property (nonatomic, copy) NSString *videoID;
@end

@implementation ApolloRedditVideoPlaylistProtocol

// Asked for every request of every default-configuration session in the
// process, so the first test is an allocation-free host compare that rejects
// everything but v.redd.it before any other work.
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    if (!host || [host caseInsensitiveCompare:@"v.redd.it"] != NSOrderedSame) return NO;
    NSString *method = request.HTTPMethod;
    if (method && [method caseInsensitiveCompare:@"GET"] != NSOrderedSame) return NO;
    if ([NSURLProtocol propertyForKey:kApolloVideoPlaylistHandledKey inRequest:request]) return NO;
    return ApolloRedditVideoIDFromMasterPlaylistURL(request.URL) != nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    self.clientThread = [NSThread currentThread];
    NSString *mode = [[NSRunLoop currentRunLoop] currentMode];
    self.clientModes = (mode && ![mode isEqualToString:NSDefaultRunLoopMode])
        ? @[NSDefaultRunLoopMode, mode] : @[NSDefaultRunLoopMode];
    self.videoID = ApolloRedditVideoIDFromMasterPlaylistURL(self.request.URL);

    NSData *cached = ApolloVideoPlaylistCachedRecovery(self.videoID);
    if (cached) {
        os_log_debug(ApolloFixLog(), "[ApolloFix] [VideoPlaylist] %{public}@: serving the rebuilt master (CDN 403 window)", self.videoID);
        [self deliverPlaylist:cached response:nil];
        return;
    }
    [self fetchMasterAttempt:1 ignoringCache:NO];
}

- (void)stopLoading {
    self.stopped = YES;
    [self.innerTask cancel];
    self.innerTask = nil;
}

- (NSMutableURLRequest *)innerRequestForURL:(NSURL *)url ignoringCache:(BOOL)ignoringCache {
    NSMutableURLRequest *request = [self.request mutableCopy];
    request.URL = url;
    if (ignoringCache) request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [NSURLProtocol setProperty:@YES forKey:kApolloVideoPlaylistHandledKey inRequest:request];
    return request;
}

- (void)fetchMasterAttempt:(NSInteger)attempt ignoringCache:(BOOL)ignoringCache {
    if (self.stopped) return;
    NSMutableURLRequest *request = [self innerRequestForURL:self.request.URL ignoringCache:ignoringCache];
    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [ApolloVideoPlaylistSession() dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.stopped) return;
        if (ApolloVideoPlaylistIsGood(data, response, error)) {
            if (attempt > 1) ApolloLog(@"[VideoPlaylist] %@: master recovered on retry %ld", strongSelf.videoID, (long)attempt);
            [strongSelf deliverPlaylist:data response:response];
            return;
        }
        if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
        NSInteger status = ApolloVideoPlaylistStatus(response);
        if (error) {
            // Offline, timed out, TLS…: not Reddit's bad-playlist answer, and
            // Apollo already handles a transport error correctly. Pass it on.
            ApolloLog(@"[VideoPlaylist] %@: master fetch %ld transport error %@ %ld", strongSelf.videoID, (long)attempt,
                      error.domain, (long)error.code);
            [strongSelf failWithError:error status:status];
            return;
        }
        ApolloLog(@"[VideoPlaylist] %@: master fetch %ld unusable (status=%ld bytes=%lu)", strongSelf.videoID, (long)attempt,
                  (long)status, (unsigned long)data.length);
        if (attempt == 1) {
            [strongSelf rebuildFromDASHWithMasterStatus:status];
        } else {
            [strongSelf failWithError:nil status:status];
        }
    }];
    self.innerTask = task;
    [task resume];
}

- (void)rebuildFromDASHWithMasterStatus:(NSInteger)masterStatus {
    if (self.stopped) return;
    NSURL *mpdURL = ApolloRedditVideoDASHManifestURL(self.videoID);
    NSMutableURLRequest *request = [self innerRequestForURL:mpdURL ignoringCache:NO];
    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [ApolloVideoPlaylistSession() dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.stopped) return;
        NSInteger status = ApolloVideoPlaylistStatus(response);
        NSData *playlist = (!error && status >= 200 && status < 300) ? ApolloRedditVideoMasterPlaylistFromDASH(data) : nil;
        if (playlist) {
            ApolloLog(@"[VideoPlaylist] %@: master (HTTP %ld) rebuilt from DASHPlaylist.mpd (%lu bytes)", strongSelf.videoID,
                      (long)masterStatus, (unsigned long)playlist.length);
            ApolloVideoPlaylistRememberRecovery(strongSelf.videoID, playlist);
            [strongSelf deliverPlaylist:playlist response:nil];
            return;
        }
        if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
        ApolloLog(@"[VideoPlaylist] %@: DASH manifest unusable (status=%ld bytes=%lu err=%@ %ld), retrying the master",
                  strongSelf.videoID, (long)status, (unsigned long)data.length, error.domain ?: @"-", (long)error.code);
        // A short pause lets a different CDN node / origin replica answer.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [strongSelf fetchMasterAttempt:2 ignoringCache:YES];
        });
    }];
    self.innerTask = task;
    [task resume];
}

// MARK: Client callbacks (always on the thread that called -startLoading)

- (void)onClientThread:(dispatch_block_t)block {
    if (!block) return;
    [self performSelector:@selector(apollo_runClientBlock:) onThread:self.clientThread
               withObject:[block copy] waitUntilDone:NO modes:self.clientModes];
}

- (void)apollo_runClientBlock:(dispatch_block_t)block {
    if (!self.stopped) block();
}

- (void)deliverPlaylist:(NSData *)data response:(NSURLResponse *)realResponse {
    NSURLResponse *response = realResponse;
    if (!response) {
        response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                             headerFields:@{
            @"Content-Type": @"application/x-mpegURL",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
            @"Cache-Control": @"no-store",
        }];
    }
    [self onClientThread:^{
        [self.client URLProtocol:self didReceiveResponse:response
              cacheStoragePolicy:realResponse ? NSURLCacheStorageAllowed : NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
    }];
}

- (void)failWithError:(NSError *)error status:(NSInteger)status {
    // Never hand Apollo the HTTP error response: its resource loader leaves the
    // loading request open on one (endless spinner, main-thread freeze on
    // open). A transport error makes it fail the item right away.
    NSError *reported = error;
    if (!reported) {
        reported = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorResourceUnavailable userInfo:@{
            NSURLErrorFailingURLErrorKey: self.request.URL,
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Reddit returned HTTP %ld for this video's playlist.", (long)status],
        }];
    }
    ApolloLog(@"[VideoPlaylist] %@: giving up, reporting %@ %ld to Apollo", self.videoID, reported.domain, (long)reported.code);
    [self onClientThread:^{
        [self.client URLProtocol:self didFailWithError:reported];
    }];
}

@end

// MARK: - Installation

static void ApolloVideoPlaylistAddProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration) return;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:[ApolloRedditVideoPlaylistProtocol class]]) return;
    NSMutableArray *protocols = [NSMutableArray arrayWithArray:existing];
    [protocols insertObject:[ApolloRedditVideoPlaylistProtocol class] atIndex:0];
    configuration.protocolClasses = protocols;
}

// Both Apollo fetchers (RedditVideoIdentifier's session and VideoResourceLoader's
// DataDelegate session) are built from the default configuration — confirmed
// in the sim by logging each task's session.configuration.protocolClasses.
// ApolloTweetBuddy.xm hooks the same class method to add its own protocol; the
// two hooks chain (each only prepends its class when missing), order-free.
%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    ApolloVideoPlaylistAddProtocol(configuration);
    return configuration;
}

%end

%ctor {
    %init;
    // NSURLSession.sharedSession and NSURLConnection consult the global list.
    [NSURLProtocol registerClass:[ApolloRedditVideoPlaylistProtocol class]];
    ApolloLog(@"[VideoPlaylist] hook installed (v.redd.it master playlist: 403 → rebuilt from DASH, or a fast error)");
}
