// ApolloOfflineMode.xm
//
// Offline Mode ("offline mode similar to TikTok", r/ApolloReborn): pick a data
// limit and some feeds, download a batch while you have a connection, then
// scroll it on a flight or underground, comments and images included.
//
// How Apollo ends up showing saved content with no changes to its UI:
//   • ApolloOfflineURLProtocol is added to every NSURLSession as it's created
//     (RedditKit's archived AFNetworking client, PINRemoteImage, the media
//     helpers) and registered globally for the shared session.
//   • While serving (ApolloOfflineShouldServe: Automatic + no connection, or
//     Always), the protocol claims a GET only when the library has an entry
//     for its key (ApolloOfflineKeyForURL) and answers it from disk with a
//     200. Everything else, including every write, goes to the network as
//     usual, so a miss behaves exactly as it does today.
//   • When not serving, +canInitWithRequest: returns NO after one atomic
//     load, so online behaviour and cost are unchanged.
//
// Video: AVFoundation fetches HLS variants and segments with its own HTTP
// stack, which URL protocols never see, so streaming can't be answered from
// disk. Instead the download saves each Reddit video as one local mp4 with
// its sound (ApolloOfflineMuxVideo below: the DASH video and audio files
// remuxed, no re-encode), and while serving, -[AVURLAsset initWithURL:options:]
// swaps any URL naming that v.redd.it id (Apollo's player URL included) for
// the file. Apollo's player, controls and "has sound" check run unchanged.
// imgur, Streamable and RedGIFs clips are progressive mp4s: the download keeps
// the file and the API answers Apollo asks for first (Streamable's video info,
// RedGIFs' token and gif info), and the same swap finds the file by URL.
//
// Link posts: see ApolloOfflinePages.xm (saved web archives, read in place of
// Safari's view while serving).

#import <AVFoundation/AVFoundation.h>
#import <Network/Network.h>
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <netinet/in.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloOfflineMode.h"
#import "ApolloOfflineDownloader.h"
#import "UserDefaultConstants.h"
#import "ApolloPostReadState.h"
#import "ApolloAccountCredentials.h"
#import "ApolloOfflinePages.h"

NSNotificationName const ApolloOfflineModeDidChangeNotification = @"ApolloOfflineModeDidChangeNotification";

// Marks the downloader's own requests so the protocol never answers them.
static NSString *const kApolloOfflineBypassKey = @"ApolloOfflineBypass";

static atomic_bool sApolloOfflineServing = false;

BOOL ApolloOfflineModeIsServing(void) {
    return atomic_load_explicit(&sApolloOfflineServing, memory_order_relaxed);
}
#if APOLLO_SIM_BUILD
// Sim-only: APOLLO_OFFLINE_SIMULATE_NO_NETWORK=1 makes the app behave as if
// the device were in airplane mode (connectivity reads as down and every
// request the library can't answer fails with "not connected"), so the
// automatic path can be exercised on a Mac whose network stays up.
static BOOL sApolloOfflineSimulateNoNetwork = NO;
#endif

@interface ApolloOfflineModeController ()
- (void)recompute;
- (void)networkChangedWithFlags:(SCNetworkReachabilityFlags)flags;
- (void)startMonitoring;
@end

// MARK: - URL protocol

@interface ApolloOfflineURLProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@property (nonatomic, strong) NSThread *clientThread;
@property (nonatomic, copy) NSArray<NSString *> *clientModes;
@end

@implementation ApolloOfflineURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!atomic_load_explicit(&sApolloOfflineServing, memory_order_relaxed)) return NO;
    if (![request.HTTPMethod ?: @"GET" isEqualToString:@"GET"]) return NO;
    if ([NSURLProtocol propertyForKey:kApolloOfflineBypassKey inRequest:request]) return NO;
    NSString *key = ApolloOfflineKeyForURL(request.URL);
    ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
    if (key && [library hasEntryForKey:key]) return YES;
    // A saved article: Apollo reads the page itself to title its link card.
    if ([library hasPageForURL:request.URL]) return YES;
    // Profile pictures: author lookups answered from the saved records.
    if ([library hasUserDataForURL:request.URL]) return YES;
    if ([NSURLProtocol propertyForKey:ApolloOfflineProfileLookupProperty inRequest:request] && [library hasProfileForURL:request.URL]) return YES;
#if APOLLO_SIM_BUILD
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (sApolloOfflineSimulateNoNetwork && ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return YES;
#endif
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    self.clientThread = NSThread.currentThread;
    NSString *mode = NSRunLoop.currentRunLoop.currentMode;
    self.clientModes = mode ? @[ NSRunLoopCommonModes, mode ] : @[ NSRunLoopCommonModes ];
    NSURLRequest *request = self.request;
    NSString *key = ApolloOfflineKeyForURL(request.URL);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *type = nil;
        ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
        NSData *data = key ? [library dataForKey:key contentType:&type] : nil;
        if (!data) data = [library pageDocumentForURL:request.URL contentType:&type];
        if (!data && (data = [library userDataResponseForURL:request.URL])) type = @"application/json; charset=UTF-8";
        if (!data && [NSURLProtocol propertyForKey:ApolloOfflineProfileLookupProperty inRequest:request] &&
            (data = [library profileResponseForURL:request.URL])) {
            type = @"application/json; charset=UTF-8";
        }
        if (!data) {
            // Only the first two path segments: later ones can be usernames.
            NSArray *segments = [request.URL.path componentsSeparatedByString:@"/"];
            NSString *shortPath = segments.count > 3 ? [[segments subarrayWithRange:NSMakeRange(0, 3)] componentsJoinedByString:@"/"] : request.URL.path;
            ApolloLog(@"[Offline] miss %@ (%@://%@%@)", key ?: @"(no key)", request.URL.scheme ?: @"?", request.URL.host ?: @"?",
                      ApolloOfflineURLIsRedditAPI(request.URL) ? (shortPath ?: @"") : @"");
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:@{
                NSURLErrorFailingURLErrorKey: request.URL,
                NSLocalizedDescriptionKey: @"This isn't in your offline library.",
            }];
            [self onClientThread:^{ [self.client URLProtocol:self didFailWithError:error]; }];
            return;
        }
        ApolloLog(@"[Offline] served %@ (%lu bytes)", key ?: (ApolloOfflineUserDataIDsForURL(request.URL) ? @"user data"
                                                     : ApolloOfflineProfileUsernameForURL(request.URL) ? @"profile picture lookup" : @"page"),
                  (unsigned long)data.length);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{
            @"Content-Type": type ?: @"application/octet-stream",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
            @"Cache-Control": @"no-store",
            @"X-Apollo-Offline": @"1",
        }];
        [self onClientThread:^{
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:data];
            [self.client URLProtocolDidFinishLoading:self];
        }];
    });
}

- (void)stopLoading {
    self.stopped = YES;
}

// Client callbacks must run on the thread that called -startLoading.
- (void)onClientThread:(dispatch_block_t)block {
    [self performSelector:@selector(apollo_runClientBlock:) onThread:self.clientThread
               withObject:[block copy] waitUntilDone:NO modes:self.clientModes];
}

- (void)apollo_runClientBlock:(dispatch_block_t)block {
    if (!self.stopped) block();
}

@end

// MARK: - Video

// The saved mp4 for the video `url` names, while serving: a v.redd.it id
// anywhere in it (Apollo's player URL), or an imgur, Streamable or RedGIFs
// media URL saved under its own key.
static NSURL *ApolloOfflineLocalVideoURL(NSURL *url) {
    if (!url || url.isFileURL) return nil;
    if (!atomic_load_explicit(&sApolloOfflineServing, memory_order_relaxed)) return nil;
    NSURL *file = [[ApolloOfflineLibrary sharedLibrary] videoFileURLForURL:url];
    if (file || ApolloOfflineRedditVideoIDForURL(url)) {
        ApolloLog(@"[Offline] video %@%@: %@", url.host ?: @"?",
                  ApolloOfflineRedditVideoIDForURL(url) ? [@" " stringByAppendingString:ApolloOfflineRedditVideoIDForURL(url)] : @"",
                  file ? @"playing the saved copy" : @"not saved");
    }
    return file;
}

// Every AVURLAsset Apollo builds, whatever the entry point (AVPlayerItem
// +playerItemWithURL:, AVPlayer +playerWithURL: and Swift's AVURLAsset(url:)
// all end here). A file URL needs no resource loader, so Apollo's
// video-player:// loader simply never gets asked.
%hook AVURLAsset

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    NSURL *local = ApolloOfflineLocalVideoURL(URL);
    return local ? %orig(local, options) : %orig;
}

%end

// Remuxes Reddit's separate DASH video and audio files into one mp4
// (passthrough: no re-encode), trimmed to the shorter track. Without audio the
// video is still rewritten, so what's saved is a plain mp4, not a fragment.
static void ApolloOfflineMuxVideo(NSURL *videoFile, NSURL *audioFile, NSURL *output,
                                  void (^done)(BOOL ok, NSTimeInterval duration)) {
    NSDictionary *precise = @{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES };
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoFile options:precise];
    AVURLAsset *audioAsset = audioFile ? [AVURLAsset URLAssetWithURL:audioFile options:precise] : nil;
    AVAssetTrack *sourceVideo = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *sourceAudio = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!sourceVideo) {
        done(NO, 0);
        return;
    }
    CMTime duration = videoAsset.duration;
    if (sourceAudio && CMTIME_IS_NUMERIC(audioAsset.duration) && CMTimeGetSeconds(audioAsset.duration) > 0) {
        duration = CMTimeMinimum(duration, audioAsset.duration);
    }
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeGetSeconds(duration) <= 0) {
        done(NO, 0);
        return;
    }
    CMTimeRange range = CMTimeRangeMake(kCMTimeZero, duration);
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *videoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                     preferredTrackID:kCMPersistentTrackID_Invalid];
    if (![videoTrack insertTimeRange:range ofTrack:sourceVideo atTime:kCMTimeZero error:nil]) {
        done(NO, 0);
        return;
    }
    videoTrack.preferredTransform = sourceVideo.preferredTransform;
    if (sourceAudio) {
        AVMutableCompositionTrack *audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                         preferredTrackID:kCMPersistentTrackID_Invalid];
        if (![audioTrack insertTimeRange:range ofTrack:sourceAudio atTime:kCMTimeZero error:nil]) {
            // A video that has sound online must not be saved silent.
            done(NO, 0);
            return;
        }
    }
    [NSFileManager.defaultManager removeItemAtURL:output error:nil];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    if (!session) {
        done(NO, 0);
        return;
    }
    session.outputURL = output;
    session.outputFileType = AVFileTypeMPEG4;
    session.shouldOptimizeForNetworkUse = YES; // moov first: playback starts at once
    NSTimeInterval seconds = CMTimeGetSeconds(duration);
    [session exportAsynchronouslyWithCompletionHandler:^{
        BOOL ok = session.status == AVAssetExportSessionStatusCompleted;
        if (!ok) ApolloLog(@"[Offline] video remux failed: %@", session.error.localizedDescription ?: @"unknown");
        done(ok, seconds);
    }];
    // A stuck export must not stall the whole download.
    __weak AVAssetExportSession *weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVAssetExportSession *running = weakSession;
        if (running.status == AVAssetExportSessionStatusWaiting || running.status == AVAssetExportSessionStatusExporting) {
            [running cancelExport];
        }
    });
}

// The protocol is added to every session by ApolloOfflineSessionHook.xm,
// which loads first so sessions made in other modules' %ctors get it too.

// MARK: - Connectivity

static BOOL ApolloOfflineFlagsMeanOnline(SCNetworkReachabilityFlags flags) {
    if (!(flags & kSCNetworkReachabilityFlagsReachable)) return NO;
    // "Connection required" without on-demand/on-traffic means nothing is up yet.
    if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) &&
        !(flags & (kSCNetworkReachabilityFlagsConnectionOnDemand | kSCNetworkReachabilityFlagsConnectionOnTraffic))) {
        return NO;
    }
    return YES;
}

static void ApolloOfflineReachabilityChanged(__unused SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    ApolloOfflineModeController *controller = (__bridge ApolloOfflineModeController *)info;
    [controller networkChangedWithFlags:flags];
}

// Posts the user has read: Apollo's live tracker plus the "ReadPostIDs" copy it
// saves to defaults. The live snapshot is nil until Apollo's tracker exists,
// which is exactly when Keep Fresh runs (right at launch); verified in the sim,
// where a launch-time refresh with the live snapshot alone kept 7 read posts.
// A stale saved copy (after a history clear) only means skipping a few posts.
static NSSet<NSString *> *ApolloOfflineReadPostIDs(void) {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    NSArray *live = ApolloReadPostIDsSnapshot();
    if (live) [ids addObjectsFromArray:live];
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"ReadPostIDs"];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id postID in saved) {
            if ([postID isKindOfClass:[NSString class]]) [ids addObject:postID];
        }
    }
    return ids;
}

// MARK: - Controller

@implementation ApolloOfflineModeController {
    SCNetworkReachabilityRef _reachability;
    ApolloOfflineDownloader *_downloader;
    UIBackgroundTaskIdentifier _backgroundTask;
    NSTimer *_keepFreshTimer;
    nw_path_monitor_t _pathMonitor; // Low Data Mode, which reachability can't see
    BOOL _lowDataMode;
    CFAbsoluteTime _lastAutoAttempt;
    BOOL _restoreIdleTimer;
}

+ (instancetype)sharedController {
    static ApolloOfflineModeController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [ApolloOfflineModeController new]; });
    return controller;
}

- (instancetype)init {
    if ((self = [super init])) {
        _networkAvailable = YES;
        _progressText = @"";
        _backgroundTask = UIBackgroundTaskInvalid;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            UDKeyOfflineUseMode: @(ApolloOfflineUseModeAutomatic),
            UDKeyOfflineIncludeHome: @YES,
            UDKeyOfflineIncludePopular: @NO,
            UDKeyOfflineIncludeComments: @YES,
            UDKeyOfflineIncludeImages: @YES,
            UDKeyOfflineIncludeVideos: @YES,
            UDKeyOfflineIncludePages: @YES,
            UDKeyOfflineIncludeSaved: @YES,
            UDKeyOfflineBudgetMB: @100,
            UDKeyOfflineAutoRefresh: @YES,
            UDKeyOfflineAutoRefreshCellular: @NO,
            UDKeyOfflineSkipRead: @YES,
        }];
    }
    return self;
}

- (void)startMonitoring {
    if (_reachability) return;
    struct sockaddr_in zero;
    memset(&zero, 0, sizeof(zero));
    zero.sin_len = sizeof(zero);
    zero.sin_family = AF_INET;
    _reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zero);
    if (_reachability) {
        SCNetworkReachabilityContext context = { 0, (__bridge void *)self, NULL, NULL, NULL };
        SCNetworkReachabilitySetCallback(_reachability, ApolloOfflineReachabilityChanged, &context);
        SCNetworkReachabilitySetDispatchQueue(_reachability, dispatch_get_main_queue());
        SCNetworkReachabilityFlags flags = 0;
        if (SCNetworkReachabilityGetFlags(_reachability, &flags)) {
            _networkAvailable = ApolloOfflineFlagsMeanOnline(flags);
            _onWiFi = _networkAvailable && !(flags & kSCNetworkReachabilityFlagsIsWWAN);
        }
    }
#if APOLLO_SIM_BUILD
    if (sApolloOfflineSimulateNoNetwork) _networkAvailable = NO;
#endif
    [self recompute];

    // Keep Fresh checks: on launch, whenever Apollo comes back to the front,
    // when the connection or Low Power Mode changes, when posts get read (so a
    // mostly-read batch tops up right away), and every 5 minutes while Apollo
    // is open (a timer only fires while the app runs).
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak typeof(self) weakSelf = self;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) { [weakSelf considerKeepFresh:@"app active"]; }];
    [center addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        [weakSelf stopKeepFreshIfNotAllowed:@"power state"];
        [weakSelf considerKeepFresh:@"power state"];
    }];
    [center addObserverForName:ApolloPostReadStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) { [weakSelf considerKeepFresh:@"post read"]; }];
    _keepFreshTimer = [NSTimer scheduledTimerWithTimeInterval:5 * 60 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf considerKeepFresh:@"timer"];
    }];
    _keepFreshTimer.tolerance = 60;
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        [weakSelf lowDataModeChanged:nw_path_is_constrained(path)];
    });
    nw_path_monitor_start(_pathMonitor);
    [self considerKeepFresh:@"launch"];
}

- (void)networkChangedWithFlags:(SCNetworkReachabilityFlags)flags {
    BOOL available = ApolloOfflineFlagsMeanOnline(flags);
#if APOLLO_SIM_BUILD
    if (sApolloOfflineSimulateNoNetwork) available = NO;
#endif
    BOOL wifi = available && !(flags & kSCNetworkReachabilityFlagsIsWWAN);
    if (available == _networkAvailable && wifi == _onWiFi) return;
    _networkAvailable = available;
    _onWiFi = wifi;
    ApolloLog(@"[Offline] connectivity: %@", available ? (wifi ? @"Wi-Fi" : @"cellular") : @"offline");
    [self recompute];
    [self stopKeepFreshIfNotAllowed:@"connectivity"];
    [self considerKeepFresh:@"connectivity"];
}

- (void)lowDataModeChanged:(BOOL)constrained {
    if (constrained == _lowDataMode) return;
    _lowDataMode = constrained;
    ApolloLog(@"[Offline] Low Data Mode %@", constrained ? @"on" : @"off");
    [self stopKeepFreshIfNotAllowed:@"low data mode"];
    [self considerKeepFresh:@"low data mode"];
}

// MARK: Keep Fresh

- (void)considerKeepFresh:(NSString *)reason {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL allowCellular = [defaults boolForKey:UDKeyOfflineAutoRefreshCellular];
    // Cheap early outs before reading the read history.
    if (_downloading || !_networkAvailable || _lowDataMode || (!_onWiFi && !allowCellular)) return;
    ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
    NSArray<NSString *> *saved = library.savedPostIDs;
    double readFraction = 0;
    if (saved.count > 0) {
        NSMutableSet<NSString *> *readSaved = [NSMutableSet setWithArray:saved];
        [readSaved intersectSet:ApolloOfflineReadPostIDs()];
        readFraction = (double)readSaved.count / saved.count;
    }
    ApolloOfflineAutoRefreshState state = {
        .enabled = [defaults boolForKey:UDKeyOfflineAutoRefresh],
        .hasLibrary = library.hasContent,
        .libraryAge = library.downloadedAt ? -library.downloadedAt.timeIntervalSinceNow : DBL_MAX,
        .readFraction = readFraction,
        .networkAvailable = _networkAvailable,
        .onWiFi = _onWiFi,
        .allowCellular = allowCellular,
        .lowPowerMode = NSProcessInfo.processInfo.lowPowerModeEnabled,
        .lowDataMode = _lowDataMode,
        .serving = _serving,
        .downloading = _downloading,
        .sinceLastAttempt = _lastAutoAttempt > 0 ? CFAbsoluteTimeGetCurrent() - _lastAutoAttempt : DBL_MAX,
    };
    if (!ApolloOfflineShouldAutoRefresh(state)) return;
    _lastAutoAttempt = CFAbsoluteTimeGetCurrent();
    ApolloLog(@"[Offline] Keep Fresh: batch is %.0f min old, %.0f%% read, on %@ (%@); refreshing",
              state.libraryAge / 60, readFraction * 100, _onWiFi ? @"Wi-Fi" : @"cellular", reason);
    [self startDownloadAutomatically:YES completion:nil];
}

- (ApolloOfflineUseMode)useMode {
    NSInteger raw = [NSUserDefaults.standardUserDefaults integerForKey:UDKeyOfflineUseMode];
    return (raw >= ApolloOfflineUseModeAutomatic && raw <= ApolloOfflineUseModeNever) ? (ApolloOfflineUseMode)raw : ApolloOfflineUseModeAutomatic;
}

- (void)setUseMode:(ApolloOfflineUseMode)useMode {
    [NSUserDefaults.standardUserDefaults setInteger:useMode forKey:UDKeyOfflineUseMode];
    [self recompute];
}

- (void)recompute {
    BOOL serve = ApolloOfflineShouldServe(self.useMode, _networkAvailable,
                                          [ApolloOfflineLibrary sharedLibrary].hasContent, _downloading);
    BOOL was = atomic_exchange(&sApolloOfflineServing, serve);
    _serving = serve;
    if (was != serve) {
        ApolloLog(@"[Offline] %@ the offline library (mode=%ld, network=%d)", serve ? @"serving" : @"stopped serving",
                  (long)self.useMode, _networkAvailable);
    }
    [self postChange];
}

- (void)postChange {
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:ApolloOfflineModeDidChangeNotification object:self];
    };
    if (NSThread.isMainThread) post(); else dispatch_async(dispatch_get_main_queue(), post);
}

// MARK: Download

- (NSArray<ApolloOfflineFeedSource *> *)plannedSources {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<ApolloOfflineFeedSource *> *sources = [NSMutableArray array];
    // Saved first: it's the user's own archive, and usually small.
    NSString *username = ApolloActiveAccountUsername();
    if ([defaults boolForKey:UDKeyOfflineIncludeSaved] && username.length > 0) {
        ApolloOfflineFeedSource *saved = [ApolloOfflineFeedSource sourceWithPath:[NSString stringWithFormat:@"/user/%@/saved", username]
                                                                           title:@"Saved"];
        saved.keepsReadPosts = YES;
        // Posts only: Apollo's Saved list asks for everything, and the saved
        // pages must line up with the posts they were cut to.
        saved.queryItems = @[ [NSURLQueryItem queryItemWithName:@"type" value:@"links"] ];
        [sources addObject:saved];
    }
    if ([defaults boolForKey:UDKeyOfflineIncludeHome]) {
        [sources addObject:[ApolloOfflineFeedSource sourceWithPath:@"/best" title:@"Home"]];
    }
    if ([defaults boolForKey:UDKeyOfflineIncludePopular]) {
        [sources addObject:[ApolloOfflineFeedSource sourceWithPath:@"/r/popular/hot" title:@"r/popular"]];
    }
    id subs = [defaults objectForKey:UDKeyOfflineSubreddits];
    for (id sub in ([subs isKindOfClass:[NSArray class]] ? subs : @[])) {
        if (![sub isKindOfClass:[NSString class]] || [sub length] == 0) continue;
        [sources addObject:[ApolloOfflineFeedSource sourceWithPath:[NSString stringWithFormat:@"/r/%@/hot", sub]
                                                             title:[@"r/" stringByAppendingString:sub]]];
    }
    return sources;
}

- (NSArray<NSString *> *)plannedFeedTitles {
    return [[self plannedSources] valueForKey:@"title"];
}

- (unsigned long long)budgetBytes {
    // Decimal megabytes, matching how NSByteCountFormatter shows the result.
    NSInteger mb = MAX(10, [NSUserDefaults.standardUserDefaults integerForKey:UDKeyOfflineBudgetMB]);
    return (unsigned long long)mb * 1000 * 1000;
}

static NSURLSession *ApolloOfflineDownloadSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // From the hooked default configuration on purpose: the request
        // chokepoint (Tweak.xm) still stamps the User-Agent and applies the
        // Web JSON / API-key-free routing to these reads.
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30;
        // Several posts download at once; most of their images and videos
        // come from the same two or three Reddit media hosts.
        configuration.HTTPMaximumConnectionsPerHost = 8;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

- (void)endDownloadSideEffects {
    if (_restoreIdleTimer) UIApplication.sharedApplication.idleTimerDisabled = NO;
    _restoreIdleTimer = NO;
    if (_backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:_backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)startDownloadWithCompletion:(void (^)(BOOL, NSString *))completion {
    [self startDownloadAutomatically:NO completion:completion];
}

- (void)startDownloadAutomatically:(BOOL)automatic completion:(void (^)(BOOL, NSString *))completion {
    if (_downloading) return;
    NSArray<ApolloOfflineFeedSource *> *sources = [self plannedSources];
    if (sources.count == 0) {
        if (completion) completion(NO, @"Choose at least one feed to download.");
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    ApolloOfflineDownloadOptions *options = [ApolloOfflineDownloadOptions new];
    options.sources = sources;
    options.byteBudget = self.budgetBytes;
    options.includeComments = [defaults boolForKey:UDKeyOfflineIncludeComments];
    options.includeImages = [defaults boolForKey:UDKeyOfflineIncludeImages];
    options.includeVideos = [defaults boolForKey:UDKeyOfflineIncludeVideos];
    options.includePages = [defaults boolForKey:UDKeyOfflineIncludePages];
    // Your account, inbox, subscriptions and each subreddit's header, so
    // those screens load offline too (a few small reads per batch).
    NSMutableArray<NSString *> *accountPaths = [NSMutableArray arrayWithArray:@[
        @"/api/v1/me", @"/api/me", @"/subreddits/mine/subscriber", @"/api/multi/mine",
        @"/message/inbox", @"/message/messages", @"/message/unread", @"/prefs/friends", @"/prefs/blocked",
    ]];
    for (ApolloOfflineFeedSource *source in sources) {
        NSArray<NSString *> *parts = [source.path componentsSeparatedByString:@"/"];
        if (parts.count >= 3 && [parts[1] isEqualToString:@"r"] && ![parts[2] isEqualToString:@"popular"]) {
            [accountPaths addObject:[NSString stringWithFormat:@"/r/%@/about", parts[2]]];
        }
    }
    options.accountPaths = accountPaths;
    CGFloat screenPixels = UIScreen.mainScreen.nativeBounds.size.width;
    options.maxImageWidth = (NSInteger)MIN(1440, MAX(640, screenPixels));
    if ([defaults boolForKey:UDKeyOfflineSkipRead]) {
        options.skipPostIDs = ApolloOfflineReadPostIDs();
    }
    // Speed: several posts at once, and Reddit calls paced by the rate limit
    // Reddit reports, keeping a share of it for browsing. Keep Fresh runs while
    // the user is browsing, so it keeps more back and goes a little easier.
    options.postConcurrency = automatic ? 3 : 6;
    options.apiMinSpacing = automatic ? 0.5 : 0.25;
    options.apiReserveFraction = automatic ? 0.4 : 0.2;
    if (automatic) options.apiSpacing = 1.5;

    ApolloOfflineFetcher fetcher = ^(NSURLRequest *request, ApolloOfflineFetchCompletion done) {
        NSMutableURLRequest *marked = [request mutableCopy];
        [NSURLProtocol setProperty:@YES forKey:kApolloOfflineBypassKey inRequest:marked];
        [[ApolloOfflineDownloadSession() dataTaskWithRequest:marked completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            done(data, [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil, error);
        }] resume];
    };
    ApolloOfflineRequestBuilder builder = ^NSURLRequest *(NSString *path, NSArray<NSURLQueryItem *> *query) {
        // Same auth rule as the other tweak-authored reads: the active
        // account's bearer on oauth.reddit.com, else bearer-less to
        // www.reddit.com, where the chokepoint signs it with the web session.
        NSString *bearer = ApolloActiveAccountRedditBearerToken();
        NSString *base = bearer.length > 0 ? @"https://oauth.reddit.com" : @"https://www.reddit.com";
        NSString *suffix = bearer.length > 0 ? @"" : @".json";
        NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"%@%@%@", base, path, suffix]];
        components.queryItems = query;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
        if (bearer.length > 0) [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
        return request;
    };

    _downloader = [[ApolloOfflineDownloader alloc] initWithLibraryDirectory:[ApolloOfflineLibrary defaultDirectory]
                                                                    fetcher:fetcher requestBuilder:builder];
    _downloader.videoMuxer = ^(NSURL *video, NSURL *audio, NSURL *output, void (^done)(BOOL, NSTimeInterval)) {
        ApolloOfflineMuxVideo(video, audio, output, done);
    };
    _downloader.pageSaver = ^(NSURL *url, void (^done)(NSData *)) {
        ApolloOfflineSaveWebPage(url, done);
    };
    _downloading = YES;
    _downloadingAutomatically = automatic;
    _progressBytes = 0;
    _progressText = @"Starting…";
    // Downloads only run while Apollo is open: keep the screen on and ask for
    // a little background time if the user switches away.
    // (Keep Fresh leaves the screen timeout alone.)
    _restoreIdleTimer = !automatic && !UIApplication.sharedApplication.idleTimerDisabled;
    if (_restoreIdleTimer) UIApplication.sharedApplication.idleTimerDisabled = YES;
    __weak typeof(self) weakSelf = self;
    _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ApolloOfflineDownload" expirationHandler:^{
        ApolloLog(@"[Offline] background time ran out; cancelling download");
        [weakSelf cancelDownload];
    }];
    ApolloLog(@"[Offline] download start%@ on %@: %@, budget %llu MB, comments=%d images=%d videos=%d pages=%d, "
              "%lu posts at once, %lu read posts to skip",
              automatic ? @" (Keep Fresh)" : @"", _onWiFi ? @"Wi-Fi" : @"cellular",
              [[sources valueForKey:@"title"] componentsJoinedByString:@", "], options.byteBudget / (1000 * 1000),
              options.includeComments, options.includeImages, options.includeVideos, options.includePages,
              (unsigned long)options.postConcurrency, (unsigned long)options.skipPostIDs.count);
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    [self recompute];

    [_downloader startWithOptions:options progress:^(unsigned long long bytes, __unused NSUInteger posts, NSString *status) {
        ApolloOfflineModeController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_progressBytes = bytes;
        strongSelf->_progressText = [NSString stringWithFormat:@"%@ · %@", status,
                                     [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile]];
        [strongSelf postChange];
    } completion:^(BOOL committed, NSUInteger posts, unsigned long long bytes, NSError *error) {
        ApolloOfflineModeController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_downloading = NO;
        strongSelf->_downloadingAutomatically = NO;
        NSUInteger skipped = strongSelf->_downloader.skippedPostCount;
        NSUInteger avatarAuthors = strongSelf->_downloader.avatarAuthorCount, avatarImages = strongSelf->_downloader.avatarImageCount;
        strongSelf->_downloader = nil;
        strongSelf->_progressText = @"";
        [strongSelf endDownloadSideEffects];
        [[ApolloOfflineLibrary sharedLibrary] reload];
        NSString *message;
        if (committed) {
            message = [NSString stringWithFormat:@"Saved %lu posts (%@) for offline reading.", (unsigned long)posts,
                       [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile]];
            ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
            ApolloLog(@"[Offline] download done%@ in %.0f s: %lu posts, %lu videos (%.0f s), %lu pages, %lu authors / %lu profile pictures, "
                      "%llu bytes, %lu already-read posts skipped",
                      automatic ? @" (Keep Fresh)" : @"", CFAbsoluteTimeGetCurrent() - startedAt, (unsigned long)posts,
                      (unsigned long)library.videoCount, library.videoSeconds, (unsigned long)library.pageCount,
                      (unsigned long)avatarAuthors, (unsigned long)avatarImages, bytes, (unsigned long)skipped);
        } else {
            message = error.localizedDescription ?: @"The download didn't finish.";
            ApolloLog(@"[Offline] download ended without saving: %@ (%@ %ld)", message, error.domain, (long)error.code);
        }
        [strongSelf recompute];
        if (completion) completion(committed, message);
    }];
}

- (void)cancelDownload {
    if (!_downloading) return;
    [_downloader cancel];
    // Don't wait for what's in flight: stop page loads and drop open requests,
    // so the posts being worked on wind down right away.
    ApolloOfflineCancelWebPageSaves();
    [ApolloOfflineDownloadSession() getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        for (NSURLSessionTask *task in tasks) [task cancel];
    }];
}

// Keep Fresh only runs where it's allowed to start: a refresh that began on
// Wi-Fi stops if the phone moves to cellular (unless Use Cellular Data is on),
// or Low Data Mode or Low Power Mode turns on. The old batch stays.
- (void)stopKeepFreshIfNotAllowed:(NSString *)reason {
    if (!_downloading || !_downloadingAutomatically) return;
    BOOL allowCellular = [NSUserDefaults.standardUserDefaults boolForKey:UDKeyOfflineAutoRefreshCellular];
    BOOL allowed = _networkAvailable && (_onWiFi || allowCellular) && !_lowDataMode &&
                   !NSProcessInfo.processInfo.lowPowerModeEnabled &&
                   [NSUserDefaults.standardUserDefaults boolForKey:UDKeyOfflineAutoRefresh];
    if (allowed) return;
    ApolloLog(@"[Offline] Keep Fresh stopped (%@): %@", reason,
              !_networkAvailable ? @"no connection" : (!_onWiFi && !allowCellular) ? @"on cellular" : @"not allowed now");
    [self cancelDownload];
}

- (void)deleteLibrary {
    if (_downloading) return;
    NSError *error = nil;
    if (![[ApolloOfflineLibrary sharedLibrary] removeAll:&error]) {
        ApolloLogError(@"[Offline] couldn't delete the library: %@", error);
    }
    [self recompute];
}

// "45 min", "1 hr 20 min".
static NSString *ApolloOfflineDurationText(NSTimeInterval seconds) {
    NSInteger minutes = MAX(1, (NSInteger)lround(seconds / 60.0));
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    NSInteger hours = minutes / 60, rest = minutes % 60;
    return rest == 0 ? [NSString stringWithFormat:@"%ld hr", (long)hours]
                     : [NSString stringWithFormat:@"%ld hr %ld min", (long)hours, (long)rest];
}

- (NSString *)librarySummary {
    ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
    if (!library.hasContent) return @"Not downloaded";
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)library.totalBytes countStyle:NSByteCountFormatterCountStyleFile];
    NSString *when = @"";
    if (library.downloadedAt) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.doesRelativeDateFormatting = YES;
        when = [@" · " stringByAppendingString:[formatter stringFromDate:library.downloadedAt]];
    }
    NSString *videos = library.videoCount > 0
        ? [NSString stringWithFormat:@" · %lu video%@", (unsigned long)library.videoCount, library.videoCount == 1 ? @"" : @"s"] : @"";
    if (library.pageCount > 0) {
        videos = [videos stringByAppendingFormat:@" · %lu page%@", (unsigned long)library.pageCount, library.pageCount == 1 ? @"" : @"s"];
    }
    NSTimeInterval browse = ApolloOfflineEstimatedBrowseTime(library.postCount, library.videoSeconds);
    return [NSString stringWithFormat:@"%lu posts%@ · %@\nAbout %@ of scrolling%@", (unsigned long)library.postCount,
            videos, size, ApolloOfflineDurationText(browse), when];
}

@end

%ctor {
    %init;
#if APOLLO_SIM_BUILD
    sApolloOfflineSimulateNoNetwork = [NSProcessInfo.processInfo.environment[@"APOLLO_OFFLINE_SIMULATE_NO_NETWORK"] isEqualToString:@"1"];
#endif
    [NSURLProtocol registerClass:[ApolloOfflineURLProtocol class]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ApolloOfflineModeController sharedController] startMonitoring];
        ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
        ApolloLog(@"[Offline] ready: library %@, mode %ld",
                  library.hasContent ? [NSString stringWithFormat:@"%lu posts", (unsigned long)library.postCount] : @"empty",
                  (long)[ApolloOfflineModeController sharedController].useMode);
    });
}
