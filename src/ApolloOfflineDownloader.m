#import "ApolloOfflineDownloader.h"
#import "ApolloOfflineLibrary.h"

// Foundation-only (host-tested). Every piece of run state lives on _queue;
// fetch completions hop back onto it before touching anything.

NSErrorDomain const ApolloOfflineErrorDomain = @"ApolloOfflineErrorDomain";

@implementation ApolloOfflineFeedSource
+ (instancetype)sourceWithPath:(NSString *)path title:(NSString *)title {
    ApolloOfflineFeedSource *source = [self new];
    source->_path = [path copy];
    source->_title = [title copy];
    return source;
}
@end

@implementation ApolloOfflineDownloadOptions
- (instancetype)init {
    if ((self = [super init])) {
        _sources = @[];
        _byteBudget = 100ull * 1024 * 1024;
        _includeComments = YES;
        _includeImages = YES;
        _pageSize = 50;
        _maxPostsPerFeed = 300;
        _maxImageWidth = 1080;
        _maxImageBytes = 12ull * 1024 * 1024;
        _apiSpacing = 0.75;
        _apiMinSpacing = 0.25;
        _apiReserveFraction = 0.2;
        _postConcurrency = 4;
        _includeVideos = YES;
        _maxVideoHeight = 720;
        _maxVideoBytes = 60ull * 1000 * 1000;
        _maxVideoDuration = 5 * 60;
        _includePages = YES;
        _accountPaths = @[];
        _maxPageBytes = 5ull * 1000 * 1000;
        _includeAvatars = YES;
        _avatarAuthorsPerPost = 30;
        _avatarShare = 0.12;
        _maxAvatarBytes = 20ull * 1000 * 1000;
        _maxAvatarAuthors = 3000;
    }
    return self;
}
@end

// A fetched listing page waiting for the next page to decide whether it ends the feed.
@interface ApolloOfflinePendingPage : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSData *data;
@property (nonatomic) NSUInteger childCount;
@property (nonatomic) NSUInteger kept;
@property (nonatomic, copy) NSArray<NSString *> *keptNames;
@end
@implementation ApolloOfflinePendingPage
@end

static NSDictionary *ApolloOfflineDictValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static BOOL ApolloOfflineIsSuccess(NSHTTPURLResponse *response, NSData *data, NSError *error) {
    if (error || data.length == 0) return NO;
    return response == nil || (response.statusCode >= 200 && response.statusCode < 300);
}

@implementation ApolloOfflineDownloader {
    NSURL *_directory;
    ApolloOfflineFetcher _fetcher;
    ApolloOfflineRequestBuilder _requestBuilder;
    dispatch_queue_t _queue;

    // Run state (on _queue).
    ApolloOfflineDownloadOptions *_options;
    ApolloOfflineProgress _progress;
    ApolloOfflineCompletion _completion;
    ApolloOfflineLibraryWriter *_writer;
    BOOL _cancelled;
    NSError *_lastError;
    CFAbsoluteTime _lastAPICall;
    NSTimeInterval _apiGap;             // current gap between Reddit calls
    unsigned long long _reservedBytes;  // videos being fetched, counted toward the limit
    NSMutableSet<NSString *> *_claimedKeys; // videos and pages being fetched by some post

    // Posts of the current page being worked on (see -pumpPosts).
    NSUInteger _nextPost;
    NSUInteger _postsInFlight;
    BOOL _pageStopped;
    BOOL _pageEndsFeed;

    NSUInteger _feedIndex;
    unsigned long long _feedBudgetEnd;
    NSUInteger _keptInFeed;
    NSString *_after;
    ApolloOfflinePendingPage *_pending;
    NSArray<NSDictionary *> *_pagePosts;
    NSString *_pageKey;
    NSData *_pageData;
    NSString *_nextAfter;
    NSString *_pageKeyOverride;
    NSUInteger _emptyPagesSkipped;
    NSUInteger _skippedRead;
    NSString *_redgifsToken;
    BOOL _accountDone;
    NSMutableArray<NSArray<NSString *> *> *_avatarLists; // each saved post's authors, in reading order
    NSMutableOrderedSet<NSString *> *_avatarIDs;          // all of them, interleaved (see -startFeed)
    BOOL _avatarsDone;
    unsigned long long _avatarBudgetEnd;
    NSUInteger _avatarAuthors;
    NSUInteger _avatarImages;
}

- (instancetype)initWithLibraryDirectory:(NSURL *)directory fetcher:(ApolloOfflineFetcher)fetcher requestBuilder:(ApolloOfflineRequestBuilder)requestBuilder {
    if ((self = [super init])) {
        _directory = directory;
        _fetcher = [fetcher copy];
        _requestBuilder = [requestBuilder copy];
        _queue = dispatch_queue_create("app.apolloreborn.offline-download", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startWithOptions:(ApolloOfflineDownloadOptions *)options progress:(ApolloOfflineProgress)progress completion:(ApolloOfflineCompletion)completion {
    dispatch_async(_queue, ^{
        if (self->_running) return;
        NSError *error = nil;
        ApolloOfflineLibraryWriter *writer = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:self->_directory error:&error];
        if (!writer) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0, 0, error); });
            return;
        }
        self->_running = YES;
        self->_options = options;
        self->_progress = [progress copy];
        self->_completion = [completion copy];
        self->_writer = writer;
        self->_cancelled = NO;
        self->_lastError = nil;
        self->_lastAPICall = 0;
        self->_apiGap = options.apiSpacing;
        self->_reservedBytes = 0;
        self->_claimedKeys = [NSMutableSet set];
        self->_skippedRead = 0;
        self->_redgifsToken = nil;
        self->_accountDone = NO;
        self->_avatarLists = [NSMutableArray array];
        self->_avatarIDs = [NSMutableOrderedSet orderedSet];
        self->_avatarsDone = NO;
        self->_avatarAuthors = 0;
        self->_avatarImages = 0;
        self->_feedIndex = 0;
        [self startFeed];
    });
}

- (NSUInteger)avatarAuthorCount {
    __block NSUInteger count = 0;
    dispatch_sync(_queue, ^{ count = self->_avatarAuthors; });
    return count;
}

- (NSUInteger)avatarImageCount {
    __block NSUInteger count = 0;
    dispatch_sync(_queue, ^{ count = self->_avatarImages; });
    return count;
}

- (BOOL)savesAvatars {
    return _options.includeAvatars && _options.includeImages && _options.avatarShare > 0;
}

// What profile pictures may use, set aside from the feeds' share.
- (unsigned long long)avatarAllowance {
    if (![self savesAvatars]) return 0;
    return MIN(_options.maxAvatarBytes, (unsigned long long)(_options.byteBudget * _options.avatarShare));
}

- (NSUInteger)skippedPostCount {
    __block NSUInteger count = 0;
    dispatch_sync(_queue, ^{ count = self->_skippedRead; });
    return count;
}

- (void)cancel {
    dispatch_async(_queue, ^{ self->_cancelled = YES; });
}

// MARK: - Reporting

- (void)report:(NSString *)status {
    ApolloOfflineProgress progress = _progress;
    if (!progress) return;
    unsigned long long bytes = _writer.bytesWritten;
    NSUInteger posts = _writer.postCount + _keptInFeed;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(bytes, posts, status); });
}

- (void)finishWithCommit:(BOOL)commit error:(NSError *)error {
    ApolloOfflineCompletion completion = _completion;
    NSUInteger posts = _writer.postCount;
    unsigned long long bytes = _writer.bytesWritten;
    BOOL committed = NO;
    NSError *finalError = error;
    if (commit) {
        NSError *commitError = nil;
        committed = [_writer commit:&commitError];
        if (!committed) {
            NSMutableDictionary *info = [@{ NSLocalizedDescriptionKey: @"Couldn't save the offline library." } mutableCopy];
            if (commitError) info[NSUnderlyingErrorKey] = commitError;
            finalError = [NSError errorWithDomain:ApolloOfflineErrorDomain code:ApolloOfflineErrorStorage userInfo:info];
        }
    } else {
        [_writer discard];
    }
    _writer = nil;
    _progress = nil;
    _completion = nil;
    _pending = nil;
    _pagePosts = nil;
    _pageData = nil;
    _running = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(committed, committed ? posts : 0, committed ? bytes : 0, finalError);
    });
}

- (BOOL)stopIfCancelled {
    if (!_cancelled) return NO;
    [self finishWithCommit:NO error:[NSError errorWithDomain:ApolloOfflineErrorDomain code:ApolloOfflineErrorCancelled
                                                    userInfo:@{ NSLocalizedDescriptionKey: @"Download cancelled." }]];
    return YES;
}

// MARK: - Transport

static double ApolloOfflineHeaderNumber(NSHTTPURLResponse *response, NSString *name) {
    NSString *value = [response valueForHTTPHeaderField:name];
    return value.length > 0 ? value.doubleValue : -1;
}

// Reddit API reads are paced by Reddit's own rate-limit headers; CDN fetches aren't paced.
- (void)fetchAPI:(NSString *)path query:(NSArray<NSURLQueryItem *> *)query completion:(void (^)(NSURLRequest *request, NSData *data, NSHTTPURLResponse *response, NSError *error))completion {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval wait = MAX(0, _apiGap - (now - _lastAPICall));
    _lastAPICall = now + wait;
    NSURLRequest *request = _requestBuilder(path, query);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), _queue, ^{
        if (self->_cancelled) {
            completion(request, nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
            return;
        }
        self->_fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(self->_queue, ^{
                if (response) {
                    ApolloOfflineDownloadOptions *options = self->_options;
                    self->_apiGap = ApolloOfflineAPISpacing(ApolloOfflineHeaderNumber(response, @"x-ratelimit-remaining"),
                                                            ApolloOfflineHeaderNumber(response, @"x-ratelimit-used"),
                                                            ApolloOfflineHeaderNumber(response, @"x-ratelimit-reset"),
                                                            options.apiReserveFraction, options.apiMinSpacing, options.apiSpacing);
                }
                completion(request, data, response, error);
            });
        });
    });
}

// MARK: - Feeds

- (void)startFeed {
    if ([self stopIfCancelled]) return;
    NSArray<ApolloOfflineFeedSource *> *sources = _options.sources;
    if (_feedIndex >= sources.count && !_avatarsDone) {
        _avatarsDone = YES;
        // Every post's author first, then each thread's first commenter, then
        // its second, and so on: if the allowance runs out, it's the deep
        // replies that go without pictures, not whole threads.
        for (NSUInteger depth = 0;; depth++) {
            BOOL any = NO;
            for (NSArray<NSString *> *list in _avatarLists) {
                if (depth < list.count) {
                    [_avatarIDs addObject:list[depth]];
                    any = YES;
                }
            }
            if (!any) break;
        }
        if (_writer.postCount > 0 && _avatarIDs.count > 0 && [self savesAvatars]) {
            _avatarBudgetEnd = MIN(_options.byteBudget, _writer.bytesWritten + [self avatarAllowance]);
            [self saveAvatarChunkAtIndex:0];
            return;
        }
    }
    if (_feedIndex >= sources.count && !_accountDone) {
        _accountDone = YES;
        if (_writer.postCount > 0) {
            [self saveAccountPathAtIndex:0 after:nil page:0];
            return;
        }
    }
    if (_feedIndex >= sources.count) {
        if (_writer.postCount == 0) {
            NSMutableDictionary *info = [@{
                NSLocalizedDescriptionKey: @"Nothing could be downloaded. Check your connection and that you're signed in, then try again.",
            } mutableCopy];
            if (_lastError) info[NSUnderlyingErrorKey] = _lastError;
            [self finishWithCommit:NO error:[NSError errorWithDomain:ApolloOfflineErrorDomain code:ApolloOfflineErrorNothingDownloaded userInfo:info]];
        } else {
            [self finishWithCommit:YES error:nil];
        }
        return;
    }
    // Each feed gets an equal share of what's left, so a later feed still
    // gets its turn when an earlier one runs out of posts early.
    unsigned long long used = _writer.bytesWritten;
    unsigned long long feedsBudget = _options.byteBudget - MIN(_options.byteBudget, [self avatarAllowance]);
    unsigned long long left = feedsBudget > used ? feedsBudget - used : 0;
    _feedBudgetEnd = used + left / (sources.count - _feedIndex);
    _keptInFeed = 0;
    _after = nil;
    _pending = nil;
    _pageKeyOverride = nil;
    _emptyPagesSkipped = 0;
    [self fetchPage];
}

- (void)finishFeed {
    ApolloOfflineFeedSource *source = _options.sources[_feedIndex];
    [_writer noteFeedTitle:source.title posts:_keptInFeed];
    _keptInFeed = 0;
    _feedIndex++;
    [self startFeed];
}

- (void)fetchPage {
    if ([self stopIfCancelled]) return;
    ApolloOfflineFeedSource *source = _options.sources[_feedIndex];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)_options.pageSize]],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"], nil];
    if (_after.length > 0) [query addObject:[NSURLQueryItem queryItemWithName:@"after" value:_after]];
    if (source.queryItems.count > 0) [query addObjectsFromArray:source.queryItems];
    [self report:[NSString stringWithFormat:@"Loading %@…", source.title]];

    [self fetchAPI:source.path query:query completion:^(NSURLRequest *request, NSData *fetched, NSHTTPURLResponse *response, NSError *error) {
        if ([self stopIfCancelled]) return;
        // Leave out posts the user has already read before anything else sees the page.
        NSData *data = fetched;
        if (ApolloOfflineIsSuccess(response, fetched, error) && self->_options.skipPostIDs.count > 0 && !source.keepsReadPosts) {
            NSUInteger removed = 0;
            data = ApolloOfflineListingRemovingPosts(fetched, self->_options.skipPostIDs, &removed) ?: fetched;
            self->_skippedRead += removed;
        }
        NSDictionary *root = ApolloOfflineIsSuccess(response, data, error)
            ? ApolloOfflineDictValue([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSDictionary *listing = ApolloOfflineDictValue(root[@"data"]);
        NSArray *children = [listing[@"children"] isKindOfClass:[NSArray class]] ? listing[@"children"] : nil;
        // A page that came back all-read is stood in for by the next one under
        // the key Apollo will ask for (see skipPostIDs).
        NSString *key = self->_pageKeyOverride ?: ApolloOfflineKeyForURL(request.URL);
        id nextAfterValue = listing[@"after"];
        NSString *nextAfter = [nextAfterValue isKindOfClass:[NSString class]] ? nextAfterValue : nil;
        if (children && key && children.count == 0 && nextAfter.length > 0 && self->_emptyPagesSkipped < 10) {
            self->_pageKeyOverride = key;
            self->_emptyPagesSkipped++;
            self->_after = nextAfter;
            [self fetchPage];
            return;
        }
        self->_pageKeyOverride = nil;
        self->_emptyPagesSkipped = 0;
        if (!children || !key) {
            self->_lastError = error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Reddit answered %ld for %@.", (long)response.statusCode, source.title],
            }];
            self->_pagePosts = @[];
            [self completePageKeeping:0 endFeed:YES];
            return;
        }
        NSMutableArray<NSDictionary *> *posts = [NSMutableArray array];
        for (id child in children) {
            NSDictionary *post = ApolloOfflineDictValue(ApolloOfflineDictValue(child)[@"data"]);
            if ([ApolloOfflineDictValue(child)[@"kind"] isEqual:@"t3"] && post) [posts addObject:post];
        }
        self->_pageKey = key;
        self->_pageData = data;
        self->_pagePosts = posts;
        self->_nextAfter = nextAfter;
        [self startPosts];
    }];
}

// MARK: - Posts

// Posts run side by side and can share a video or an article (crossposts,
// the same link twice): the first one to ask fetches it, the others skip it.
- (BOOL)claimKey:(NSString *)key {
    if (key.length == 0 || [_writer hasKey:key] || [_claimedKeys containsObject:key]) return NO;
    [_claimedKeys addObject:key];
    return YES;
}

// Posts still being saved will add about as much as the average post so far,
// so new ones stop starting a little before the line instead of all the posts
// in flight running past it.
- (BOOL)budgetSpent {
    NSUInteger postsDone = _writer.postCount + _keptInFeed;
    unsigned long long perPost = postsDone > 0 ? _writer.bytesWritten / postsDone : 0;
    return _writer.bytesWritten + _reservedBytes + perPost * _postsInFlight >= _feedBudgetEnd ||
           _keptInFeed + _postsInFlight >= _options.maxPostsPerFeed;
}

- (void)startPosts {
    _nextPost = 0;
    _postsInFlight = 0;
    _pageStopped = NO;
    _pageEndsFeed = NO;
    [self pumpPosts];
}

// Keeps up to postConcurrency posts of the page going. Posts start in order,
// so the ones started are always the page's first `_nextPost`, which is what
// the saved page is cut to. The page completes once they've all finished.
- (void)pumpPosts {
    if (_cancelled) {
        // Let the posts already going wind down (each step skips once
        // cancelled), then stop.
        if (_postsInFlight == 0) [self stopIfCancelled];
        return;
    }
    NSUInteger limit = MAX((NSUInteger)1, _options.postConcurrency);
    while (!_pageStopped && _postsInFlight < limit) {
        if (_nextPost >= _pagePosts.count) {
            _pageStopped = YES;
        } else if ([self budgetSpent]) {
            _pageStopped = YES;
            _pageEndsFeed = YES;
        } else {
            NSDictionary *post = _pagePosts[_nextPost++];
            _postsInFlight++;
            [self savePost:post then:^{
                self->_postsInFlight--;
                self->_keptInFeed++;
                [self report:[NSString stringWithFormat:@"Saved %lu posts", (unsigned long)(self->_writer.postCount + self->_keptInFeed)]];
                [self pumpPosts];
            }];
        }
    }
    if (_pageStopped && _postsInFlight == 0) [self completePageKeeping:_nextPost endFeed:_pageEndsFeed];
}

- (void)savePost:(NSDictionary *)post then:(void (^)(void))then {
    // Each step is skipped once the download is cancelled.
    void (^step)(void (^)(void (^)(void)), void (^)(void)) = ^(void (^work)(void (^)(void)), void (^next)(void)) {
        if (self->_cancelled) next();
        else work(next);
    };
    step(^(void (^done)(void)) { [self saveCommentsForPost:post then:done]; }, ^{
        step(^(void (^done)(void)) { [self saveImagesForPost:post then:done]; }, ^{
            step(^(void (^done)(void)) { [self saveVideoForPost:post then:done]; }, ^{
                step(^(void (^done)(void)) { [self saveHostedVideoForPost:post then:done]; }, ^{
                    step(^(void (^done)(void)) { [self savePageForPost:post then:done]; }, then);
                });
            });
        });
    });
}

- (void)saveCommentsForPost:(NSDictionary *)post then:(void (^)(void))then {
    NSString *postID = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
    if (!_options.includeComments || postID.length == 0) {
        if ([self savesAvatars]) [_avatarLists addObject:ApolloOfflineAuthorFullNames(post, nil, 0)];
        then();
        return;
    }
    NSString *path = [@"/comments/" stringByAppendingString:postID];
    NSArray *query = @[
        [NSURLQueryItem queryItemWithName:@"limit" value:@"100"],
        [NSURLQueryItem queryItemWithName:@"depth" value:@"6"],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
    ];
    [self fetchAPI:path query:query completion:^(NSURLRequest *request, NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSString *key = ApolloOfflineKeyForURL(request.URL);
        id root = ApolloOfflineIsSuccess(response, data, error) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // Apollo indexes the comments response as an array; never store anything else.
        if (key && [root isKindOfClass:[NSArray class]]) {
            [self->_writer storeData:data contentType:@"application/json; charset=UTF-8" forKey:key];
            if ([self savesAvatars]) {
                [self->_avatarLists addObject:ApolloOfflineAuthorFullNames(post, data, self->_options.avatarAuthorsPerPost)];
            }
        } else {
            if (error) self->_lastError = error;
            // No comments saved: the post's author still gets a picture.
            if ([self savesAvatars]) [self->_avatarLists addObject:ApolloOfflineAuthorFullNames(post, nil, 0)];
        }
        then();
    }];
}

- (void)saveImagesForPost:(NSDictionary *)post then:(void (^)(void))then {
    if (!_options.includeImages) {
        then();
        return;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *url in ApolloOfflineImageURLsForPost(post, _options.maxImageWidth)) {
        NSString *key = ApolloOfflineKeyForURL(url);
        if (key && ![_writer hasKey:key]) [urls addObject:url];
    }
    if (urls.count == 0) {
        then();
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    unsigned long long maxBytes = _options.maxImageBytes;
    for (NSURL *url in urls) {
        dispatch_group_enter(group);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 30;
        _fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(self->_queue, ^{
                NSString *key = ApolloOfflineKeyForURL(url);
                if (key && ApolloOfflineIsSuccess(response, data, error) && data.length <= maxBytes && self->_writer) {
                    NSString *type = response.MIMEType.length > 0 ? response.MIMEType : @"image/jpeg";
                    if ([type hasPrefix:@"image/"]) {
                        [self->_writer storeData:data contentType:type forKey:key];
                    }
                }
                dispatch_group_leave(group);
            });
        });
    }
    dispatch_group_notify(group, _queue, then);
}

// MARK: - Video

// Fetches one file for a video; nil on failure or when it's over `maxBytes`.
- (void)fetchMedia:(NSURL *)url maxBytes:(unsigned long long)maxBytes then:(void (^)(NSData *data))then {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    _fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        BOOL ok = ApolloOfflineIsSuccess(response, data, error) && data.length <= maxBytes;
        dispatch_async(self->_queue, ^{ then(ok ? data : nil); });
    });
}

- (void)saveVideoForPost:(NSDictionary *)post then:(void (^)(void))then {
    NSDictionary *video = ApolloOfflineRedditVideoForPost(post);
    ApolloOfflineVideoMuxer muxer = self.videoMuxer;
    if (!_options.includeVideos || !video || !muxer || !_writer) {
        then();
        return;
    }
    NSString *videoID = video[@"id"];
    NSString *key = ApolloOfflineVideoKey(videoID);
    NSTimeInterval duration = [video[@"duration"] doubleValue];
    if (duration > _options.maxVideoDuration || ![self claimKey:key]) {
        then();
        return;
    }
    NSURL *manifestURL = video[@"dash"];
    [self fetchMedia:manifestURL maxBytes:1024 * 1024 then:^(NSData *manifest) {
        NSDictionary *renditions = ApolloOfflineRedditVideoRenditions(manifest, manifestURL, self->_options.maxVideoHeight);
        if (!renditions || [self stopIfCancelledQuietly]) {
            then();
            return;
        }
        NSURL *audioURL = [video[@"hasAudio"] boolValue] ? renditions[@"audio"] : nil;
        // Skip a video that would overrun this feed's share of the limit
        // (bitrates from the manifest; 30 s assumed when Reddit omits the length).
        double seconds = duration > 0 ? duration : 30;
        unsigned long long estimate = (unsigned long long)(([renditions[@"videoBandwidth"] doubleValue] +
                                                            (audioURL ? [renditions[@"audioBandwidth"] doubleValue] : 0)) * seconds / 8.0);
        // Videos still downloading count toward the limit, so posts saving
        // at the same time can't all squeeze in a video that won't fit.
        if (estimate > self->_options.maxVideoBytes ||
            self->_writer.bytesWritten + self->_reservedBytes + estimate > self->_feedBudgetEnd) {
            then();
            return;
        }
        self->_reservedBytes += estimate;
        void (^release)(void) = ^{
            self->_reservedBytes -= MIN(self->_reservedBytes, estimate);
            then();
        };
        [self report:@"Saving videos"];
        // Video, audio and Apollo's master playlist (it reads that to tell a
        // video with sound from a silent "GIF") download side by side.
        unsigned long long maxBytes = self->_options.maxVideoBytes;
        NSURL *masterURL = video[@"hls"];
        __block NSData *videoData = nil, *audioData = nil, *master = nil;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        [self fetchMedia:renditions[@"video"] maxBytes:maxBytes then:^(NSData *data) { videoData = data; dispatch_group_leave(group); }];
        if (audioURL) {
            dispatch_group_enter(group);
            [self fetchMedia:audioURL maxBytes:maxBytes then:^(NSData *data) { audioData = data; dispatch_group_leave(group); }];
        }
        dispatch_group_enter(group);
        [self fetchMedia:masterURL maxBytes:256 * 1024 then:^(NSData *data) { master = data; dispatch_group_leave(group); }];
        dispatch_group_notify(group, self->_queue, ^{
            ApolloOfflineLibraryWriter *writer = self->_writer;
            if (!videoData || !writer || [self stopIfCancelledQuietly] || (audioURL && !audioData)) {
                release();
                return;
            }
            NSURL *videoFile = [writer scratchFileURLWithExtension:@"mp4"];
            NSURL *audioFile = audioData ? [writer scratchFileURLWithExtension:@"mp4"] : nil;
            NSURL *output = [writer scratchFileURLWithExtension:@"mp4"];
            if (![videoData writeToURL:videoFile atomically:NO] || (audioFile && ![audioData writeToURL:audioFile atomically:NO])) {
                release();
                return;
            }
            muxer(videoFile, audioFile, output, ^(BOOL ok, NSTimeInterval muxedDuration) {
                dispatch_async(self->_queue, ^{
                    NSFileManager *fm = NSFileManager.defaultManager;
                    [fm removeItemAtURL:videoFile error:nil];
                    if (audioFile) [fm removeItemAtURL:audioFile error:nil];
                    ApolloOfflineLibraryWriter *current = self->_writer;
                    if (ok && current == writer) {
                        NSString *masterKey = ApolloOfflineKeyForURL(masterURL);
                        if (master && masterKey) {
                            [current storeData:master contentType:@"application/vnd.apple.mpegurl" forKey:masterKey];
                        }
                        [current storeVideoFile:output forKey:key pathExtension:@"mp4"
                                       duration:muxedDuration > 0 ? muxedDuration : duration];
                    }
                    [fm removeItemAtURL:output error:nil];
                    release();
                });
            });
        });
    }];
}

// MARK: - Outside videos

static NSDictionary *ApolloOfflineJSONObject(NSData *data) {
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [root isKindOfClass:[NSDictionary class]] ? root : nil;
}

static NSURL *ApolloOfflineHTTPSURL(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return nil;
    NSString *string = value;
    if ([string hasPrefix:@"//"]) string = [@"https:" stringByAppendingString:string];
    NSURL *url = [NSURL URLWithString:string];
    return [url.scheme.lowercaseString hasPrefix:@"http"] ? url : nil;
}

// Saves an API answer under the key Apollo's own request will have.
- (void)storeAPIAnswer:(NSData *)data forURL:(NSURL *)url {
    NSString *key = ApolloOfflineKeyForURL(url);
    if (key && data.length > 0) [_writer storeData:data contentType:@"application/json; charset=utf-8" forKey:key];
}

// Downloads a progressive mp4 and stores it under its URL's key, plus aliases
// for the other URLs Apollo might ask for. Skipped when it won't fit.
- (void)saveProgressiveVideo:(NSURL *)url aliases:(NSArray<NSURL *> *)aliases duration:(NSTimeInterval)duration
                        then:(void (^)(void))then {
    NSString *key = ApolloOfflineKeyForURL(url);
    if (!key || duration > _options.maxVideoDuration || ![self claimKey:key]) {
        then();
        return;
    }
    [self report:@"Saving videos"];
    [self fetchMedia:url maxBytes:_options.maxVideoBytes then:^(NSData *data) {
        ApolloOfflineLibraryWriter *writer = self->_writer;
        if (data.length > 0 && writer && writer.bytesWritten + data.length <= self->_feedBudgetEnd) {
            NSURL *file = [writer scratchFileURLWithExtension:@"mp4"];
            if ([data writeToURL:file atomically:NO] &&
                [writer storeVideoFile:file forKey:key pathExtension:@"mp4" duration:duration]) {
                for (NSURL *alias in aliases) {
                    NSString *aliasKey = ApolloOfflineKeyForURL(alias);
                    if (aliasKey) [writer storeAlias:aliasKey forKey:key];
                }
            }
            [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        }
        then();
    }];
}

- (void)saveHostedVideoForPost:(NSDictionary *)post then:(void (^)(void))then {
    NSDictionary *video = ApolloOfflineHostedVideoForPost(post);
    if (!_options.includeVideos || !video || !_writer) {
        then();
        return;
    }
    NSString *host = video[@"host"], *videoID = video[@"id"];
    if ([host isEqualToString:@"imgur"]) {
        NSURL *mp4 = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.imgur.com/%@.mp4", videoID]];
        NSURL *gifv = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.imgur.com/%@.gifv", videoID]];
        [self saveProgressiveVideo:mp4 aliases:@[ gifv ] duration:0 then:then];
    } else if ([host isEqualToString:@"streamable"]) {
        [self saveStreamable:videoID then:then];
    } else if ([host isEqualToString:@"redgifs"]) {
        [self saveRedgifs:videoID then:then];
    } else {
        then();
    }
}

// Apollo: GET api.streamable.com/videos/<code> (no auth), then plays files.mp4.url.
- (void)saveStreamable:(NSString *)code then:(void (^)(void))then {
    NSURL *api = [NSURL URLWithString:[@"https://api.streamable.com/videos/" stringByAppendingString:code]];
    if ([_writer hasKey:ApolloOfflineKeyForURL(api)]) {
        then();
        return;
    }
    [self fetchMedia:api maxBytes:256 * 1024 then:^(NSData *data) {
        NSDictionary *files = ApolloOfflineJSONObject(data)[@"files"];
        if (![files isKindOfClass:[NSDictionary class]]) {
            then();
            return;
        }
        NSDictionary *full = [files[@"mp4"] isKindOfClass:[NSDictionary class]] ? files[@"mp4"] : nil;
        NSDictionary *mobile = [files[@"mp4-mobile"] isKindOfClass:[NSDictionary class]] ? files[@"mp4-mobile"] : nil;
        NSURL *fullURL = ApolloOfflineHTTPSURL(full[@"url"]), *mobileURL = ApolloOfflineHTTPSURL(mobile[@"url"]);
        // The full file only when it's within the video height cap.
        BOOL fullFits = fullURL && [full[@"height"] integerValue] <= self->_options.maxVideoHeight;
        NSURL *chosen = (fullFits || !mobileURL) ? fullURL : mobileURL;
        if (!chosen) {
            then();
            return;
        }
        NSDictionary *picked = chosen == fullURL ? full : mobile;
        NSMutableArray<NSURL *> *aliases = [NSMutableArray array];
        for (NSURL *other in @[ fullURL ?: chosen, mobileURL ?: chosen ]) if (other != chosen) [aliases addObject:other];
        [self saveProgressiveVideo:chosen aliases:aliases duration:[picked[@"duration"] doubleValue] then:^{
            if ([self->_writer hasKey:ApolloOfflineKeyForURL(chosen)]) [self storeAPIAnswer:data forURL:api];
            then();
        }];
    }];
}

// Apollo: a temporary token (the tweak turns its /v2/oauth/client call into
// GET /v2/auth/temporary), then GET /v2/gifs/<id> with it, then plays urls.hd
// or urls.sd. All three are saved, so the same calls succeed offline.
- (void)saveRedgifs:(NSString *)gifID then:(void (^)(void))then {
    NSURL *tokenURL = [NSURL URLWithString:@"https://api.redgifs.com/v2/auth/temporary"];
    NSURL *gifURL = [NSURL URLWithString:[@"https://api.redgifs.com/v2/gifs/" stringByAppendingString:gifID]];
    if ([_writer hasKey:ApolloOfflineKeyForURL(gifURL)]) {
        then();
        return;
    }
    void (^lookup)(void) = ^{
        if (self->_redgifsToken.length == 0) {
            then();
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:gifURL];
        request.timeoutInterval = 30;
        [request setValue:[@"Bearer " stringByAppendingString:self->_redgifsToken] forHTTPHeaderField:@"Authorization"];
        self->_fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(self->_queue, ^{
                NSDictionary *gif = ApolloOfflineIsSuccess(response, data, error) ? ApolloOfflineJSONObject(data)[@"gif"] : nil;
                NSDictionary *urls = [gif isKindOfClass:[NSDictionary class]] && [gif[@"urls"] isKindOfClass:[NSDictionary class]] ? gif[@"urls"] : nil;
                NSURL *sd = ApolloOfflineHTTPSURL(urls[@"sd"]), *hd = ApolloOfflineHTTPSURL(urls[@"hd"]);
                NSURL *chosen = sd ?: hd;
                if (!chosen) {
                    then();
                    return;
                }
                NSArray *aliases = (hd && chosen != hd) ? @[ hd ] : @[];
                [self saveProgressiveVideo:chosen aliases:aliases duration:[gif[@"duration"] doubleValue] then:^{
                    if ([self->_writer hasKey:ApolloOfflineKeyForURL(chosen)]) [self storeAPIAnswer:data forURL:gifURL];
                    then();
                }];
            });
        });
    };
    if (_redgifsToken.length > 0) {
        lookup();
        return;
    }
    [self fetchMedia:tokenURL maxBytes:64 * 1024 then:^(NSData *data) {
        NSString *token = ApolloOfflineJSONObject(data)[@"token"];
        if ([token isKindOfClass:[NSString class]] && token.length > 0) {
            self->_redgifsToken = token;
            // Apollo mints its own token offline: answer it from here too.
            [self storeAPIAnswer:data forURL:tokenURL];
        }
        lookup();
    }];
}

// MARK: - Profile pictures

- (void)saveAvatarChunkAtIndex:(NSUInteger)index {
    if ([self stopIfCancelled]) return;
    NSUInteger start = index * 100;
    // Lookups go on after the picture allowance is used: a record is a few
    // hundred bytes, and default-avatar users need no new picture.
    if (start >= MIN(_avatarIDs.count, _options.maxAvatarAuthors) || _writer.bytesWritten >= _options.byteBudget) {
        [self startFeed];
        return;
    }
    if (index == 0) [self report:@"Saving profile pictures"];
    NSUInteger end = MIN(_avatarIDs.count, _options.maxAvatarAuthors);
    NSArray<NSString *> *chunk = [_avatarIDs.array subarrayWithRange:NSMakeRange(start, MIN((NSUInteger)100, end - start))];
    NSArray *query = @[
        [NSURLQueryItem queryItemWithName:@"ids" value:[chunk componentsJoinedByString:@","]],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
    ];
    [self fetchAPI:@"/api/user_data_by_account_ids" query:query completion:^(__unused NSURLRequest *request, NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if ([self stopIfCancelled]) return;
        NSDictionary *root = ApolloOfflineIsSuccess(response, data, error) ? ApolloOfflineJSONObject(data) : nil;
        NSMutableArray<NSURL *> *pictures = [NSMutableArray array];
        if (root.count > 0) {
            [self->_writer storeData:data contentType:@"application/json; charset=UTF-8"
                              forKey:[NSString stringWithFormat:@"users:%lu", (unsigned long)index]];
            for (NSString *fullName in chunk) {
                NSDictionary *record = [root[fullName] isKindOfClass:[NSDictionary class]] ? root[fullName] : nil;
                if (!record) continue;
                self->_avatarAuthors++;
                NSURL *picture = ApolloOfflineHTTPSURL(record[@"profile_img"]);
                if (picture) [pictures addObject:picture];
            }
        } else if (error) {
            self->_lastError = error;
        }
        [self saveAvatarPictures:pictures then:^{ [self saveAvatarChunkAtIndex:index + 1]; }];
    }];
}

// Reddit's default avatars (a handful of shared files on redditstatic.com).
static BOOL ApolloOfflineIsDefaultAvatar(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"redditstatic.com"] || [host hasSuffix:@".redditstatic.com"];
}

// Several pictures at a time (CDN, not the Reddit API). Custom pictures stop
// at the allowance; the shared default ones are always kept (while the data
// limit has room), since one file covers everyone who has it. A picture is
// claimed only when it's actually fetched, so one first met after the
// allowance ran out isn't lost for a later author who'd get it free.
- (void)saveAvatarPictures:(NSArray<NSURL *> *)urls then:(void (^)(void))then {
    __block NSUInteger next = 0, active = 0;
    __block BOOL finished = NO;
    __block void (^pump)(void) = nil;
    pump = ^{
        while (active < 8 && next < urls.count && !self->_cancelled) {
            NSURL *url = urls[next++];
            BOOL shared = ApolloOfflineIsDefaultAvatar(url);
            unsigned long long written = self->_writer.bytesWritten;
            BOOL room = shared ? written < self->_options.byteBudget : written < self->_avatarBudgetEnd;
            NSString *key = ApolloOfflineKeyForURL(url);
            if (!room || ![self claimKey:key]) continue;
            active++;
            [self saveImage:url then:^{
                if ([self->_writer hasKey:key]) self->_avatarImages++;
                active--;
                pump();
            }];
        }
        if (active == 0 && !finished) {
            finished = YES;
            // Let the block go once this call returns (it refers to itself).
            dispatch_async(self->_queue, ^{ pump = nil; });
            then();
        }
    };
    pump();
}

// MARK: - Account reads

- (void)saveAccountPathAtIndex:(NSUInteger)index after:(NSString *)after page:(NSUInteger)page {
    if ([self stopIfCancelled]) return;
    NSArray<NSString *> *paths = _options.accountPaths;
    if (index >= paths.count) {
        [self startFeed];
        return;
    }
    if (page == 0) [self report:@"Saving your inbox and subscriptions"];
    NSMutableArray *query = [NSMutableArray arrayWithObjects:[NSURLQueryItem queryItemWithName:@"limit" value:@"100"],
                                                             [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"], nil];
    if (after.length > 0) [query addObject:[NSURLQueryItem queryItemWithName:@"after" value:after]];
    [self fetchAPI:paths[index] query:query completion:^(NSURLRequest *request, NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSString *key = ApolloOfflineKeyForURL(request.URL);
        NSDictionary *root = ApolloOfflineIsSuccess(response, data, error) ? ApolloOfflineJSONObject(data) : nil;
        BOOL ok = ApolloOfflineIsSuccess(response, data, error) && key;
        if (ok) [self->_writer storeData:data contentType:@"application/json; charset=UTF-8" forKey:key];
        void (^nextPath)(void) = ^{ [self saveAccountPathAtIndex:index + 1 after:nil page:0]; };
        // A subreddit's icon, for its header and the Subreddits list.
        if (ok && [root[@"kind"] isEqual:@"t5"]) {
            NSDictionary *about = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
            NSString *icon = [about[@"community_icon"] isKindOfClass:[NSString class]] && [about[@"community_icon"] length] > 0
                ? about[@"community_icon"] : about[@"icon_img"];
            NSURL *iconURL = ApolloOfflineHTTPSURL([icon isKindOfClass:[NSString class]] ? [icon stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"] : nil);
            if (iconURL) {
                [self saveImage:iconURL then:nextPath];
                return;
            }
        }
        NSDictionary *listing = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
        NSString *nextAfter = [listing[@"after"] isKindOfClass:[NSString class]] ? listing[@"after"] : nil;
        if (ok && nextAfter.length > 0 && page + 1 < 10) {
            [self saveAccountPathAtIndex:index after:nextAfter page:page + 1];
            return;
        }
        nextPath();
    }];
}

// One image under its own key (skipped if already saved or too big).
- (void)saveImage:(NSURL *)url then:(void (^)(void))then {
    NSString *key = ApolloOfflineKeyForURL(url);
    if (!key || [_writer hasKey:key]) {
        then();
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    unsigned long long maxBytes = _options.maxImageBytes;
    _fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        dispatch_async(self->_queue, ^{
            NSString *type = response.MIMEType.length > 0 ? response.MIMEType : @"image/png";
            if (self->_writer && ApolloOfflineIsSuccess(response, data, error) && data.length <= maxBytes && [type hasPrefix:@"image/"]) {
                [self->_writer storeData:data contentType:type forKey:key];
            }
            then();
        });
    });
}

// MARK: - Web pages

- (void)savePageForPost:(NSDictionary *)post then:(void (^)(void))then {
    NSURL *url = ApolloOfflineArticleURLForPost(post);
    ApolloOfflinePageSaver saver = self.pageSaver;
    NSString *key = ApolloOfflinePageKey(url);
    if (!url || !key || ![self claimKey:key]) {
        then();
        return;
    }
    // Whatever happens to the page, the link card gets the site's icon and,
    // failing the real page, a stand-in with the post's title and image.
    NSInteger maxWidth = _options.maxImageWidth;
    NSURL *favicon = ApolloOfflineFaviconURL(url);
    void (^finish)(void) = ^{
        if (![self->_writer hasKey:key]) [self->_writer storeLinkCard:ApolloOfflineLinkCardHTML(post, maxWidth) forURL:url];
        if (favicon) [self saveImage:favicon then:then];
        else then();
    };
    // Pages are the last thing a post saves; leave room for what follows.
    BOOL roomLeft = _writer.bytesWritten + 512 * 1000 < _feedBudgetEnd;
    if (!_options.includePages || !saver || !roomLeft) {
        finish();
        return;
    }
    [self report:@"Saving web pages"];
    unsigned long long maxBytes = _options.maxPageBytes;
    saver(url, ^(NSData *archive) {
        dispatch_async(self->_queue, ^{
            ApolloOfflineLibraryWriter *writer = self->_writer;
            // Under 10 KB is a bot wall or an error page, not the article;
            // and the page's own HTML has to be there, not just its images.
            BOOL hasDocument = ApolloOfflineWebArchiveMainResource(archive, NULL, NULL).length >= 2048;
            if (archive.length >= 10 * 1024 && hasDocument && archive.length <= maxBytes && writer &&
                writer.bytesWritten + archive.length <= self->_feedBudgetEnd &&
                [writer storePageArchive:archive forURL:url]) {
                // Apollo's link card for this post: the page's share image.
                NSURL *shareImage = ApolloOfflineWebArchiveShareImageURL(archive, url);
                if (shareImage) [self saveImage:shareImage then:finish];
                else finish();
                return;
            }
            finish();
        });
    });
}

// Like -stopIfCancelled, for the middle of a post: lets the post finish its
// chain (the next -processPostAtIndex: does the actual stop).
- (BOOL)stopIfCancelledQuietly {
    return _cancelled;
}

// MARK: - Pages

- (void)flushPending:(BOOL)endHere {
    ApolloOfflinePendingPage *page = _pending;
    _pending = nil;
    if (!page || page.kept == 0) return;
    NSData *data = page.data;
    if (endHere || page.kept < page.childCount) {
        data = ApolloOfflineTruncatedListing(page.data, page.kept, YES) ?: page.data;
    }
    [_writer storeFeedPage:data forKey:page.key postNames:page.keptNames];
}

// `kept` counts posts of _pagePosts. A page is held back until the next one
// shows whether it was the feed's last, so the final page can say so.
- (void)completePageKeeping:(NSUInteger)kept endFeed:(BOOL)endFeed {
    if (kept == 0) {
        [self flushPending:YES];
        [self finishFeed];
        return;
    }
    [self flushPending:NO];
    ApolloOfflinePendingPage *page = [ApolloOfflinePendingPage new];
    page.key = _pageKey;
    page.data = _pageData;
    // Feed listings only return t3 children, so post counts and listing
    // child counts line up for truncation.
    page.childCount = _pagePosts.count;
    page.kept = kept;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *post in [_pagePosts subarrayWithRange:NSMakeRange(0, kept)]) {
        if ([post[@"name"] isKindOfClass:[NSString class]]) [names addObject:post[@"name"]];
    }
    page.keptNames = names;
    _pending = page;
    _pagePosts = nil;
    _pageData = nil;

    if (endFeed || kept < page.childCount || _nextAfter.length == 0 || [self budgetSpent]) {
        [self flushPending:YES];
        [self finishFeed];
        return;
    }
    _after = _nextAfter;
    [self fetchPage];
}

@end
