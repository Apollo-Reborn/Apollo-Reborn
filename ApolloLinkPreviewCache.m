#import "ApolloLinkPreviewCache.h"

#import <CommonCrypto/CommonDigest.h>

#import "ApolloCommon.h"

static const NSUInteger ApolloLinkPreviewCacheMaxEntries = 500;
static const NSTimeInterval ApolloLinkPreviewNegativeTTL = 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewDefaultTTL = 7.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewRedditTTL = 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewYouTubeTTL = 30.0 * 24.0 * 60.0 * 60.0;

@interface ApolloLinkPreviewCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *entries;
@property (nonatomic, strong) NSCache<NSString *, ApolloLinkPreview *> *memoryCache;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *cachePath;
@end

@implementation ApolloLinkPreviewCache

+ (instancetype)sharedCache {
    static ApolloLinkPreviewCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [ApolloLinkPreviewCache new];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollo.linkpreviews.cache", DISPATCH_QUEUE_SERIAL);
        _memoryCache = [NSCache new];
        _memoryCache.countLimit = ApolloLinkPreviewCacheMaxEntries;

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDirectory = paths.firstObject ?: NSTemporaryDirectory();
        _cachePath = [cacheDirectory stringByAppendingPathComponent:@"com.apollo.linkpreviews.json"];
        _entries = [[self loadEntriesFromDisk] mutableCopy] ?: [NSMutableDictionary dictionary];
        ApolloLog(@"[LinkPreviews] cache init: %lu entries loaded", (unsigned long)_entries.count);
    }
    return self;
}

- (NSDictionary *)loadEntriesFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:self.cachePath];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (void)writeEntriesToDiskLocked {
    NSDictionary *snapshot = [self.entries copy];
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!data) return;
    [data writeToFile:self.cachePath atomically:YES];
}

- (NSString *)cacheKeyForURL:(NSURL *)url {
    NSString *absoluteString = url.absoluteString ?: @"";
    NSData *data = [absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", hash[index]];
    }
    return result;
}

- (NSTimeInterval)ttlForURL:(NSURL *)url preview:(ApolloLinkPreview *)preview {
    if (preview.noMetadata) return ApolloLinkPreviewNegativeTTL;

    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"redd.it"] || [host hasSuffix:@".redd.it"] || [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) {
        return ApolloLinkPreviewRedditTTL;
    }
    if ([host isEqualToString:@"youtu.be"] || [host hasSuffix:@".youtube.com"] || [host isEqualToString:@"youtube.com"]) {
        return ApolloLinkPreviewYouTubeTTL;
    }
    return ApolloLinkPreviewDefaultTTL;
}

- (BOOL)previewIsFresh:(ApolloLinkPreview *)preview forURL:(NSURL *)url {
    if (!preview.fetchedAt) return NO;
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:preview.fetchedAt];
    return age >= 0.0 && age < [self ttlForURL:url preview:preview];
}

- (ApolloLinkPreview *)cachedPreviewForURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSString *key = [self cacheKeyForURL:url];

    ApolloLinkPreview *memoryPreview = [self.memoryCache objectForKey:key];
    if (memoryPreview && [self previewIsFresh:memoryPreview forURL:url]) return memoryPreview;

    __block ApolloLinkPreview *preview = nil;
    dispatch_sync(self.queue, ^{
        NSDictionary *entry = self.entries[key];
        preview = [ApolloLinkPreview previewFromDictionary:entry];
        if (preview && [self previewIsFresh:preview forURL:url]) {
            [self.memoryCache setObject:preview forKey:key];
            NSMutableDictionary *updated = [entry mutableCopy];
            updated[@"lastAccess"] = @([[NSDate date] timeIntervalSince1970]);
            self.entries[key] = updated;
        } else if (entry) {
            [self.entries removeObjectForKey:key];
            [self writeEntriesToDiskLocked];
            preview = nil;
        }
    });
    return preview;
}

- (BOOL)cachedPreviewIsRichForURL:(NSURL *)url {
    ApolloLinkPreview *preview = [self cachedPreviewForURL:url];
    if (![preview hasUsefulMetadata]) return NO;

    BOOL hasRealImage = preview.imageURL.absoluteString.length > 0 && !preview.imageIsFallbackIcon;
    BOOL hasTextMetadata = preview.title.length > 0 || preview.desc.length > 0;
    return hasRealImage && hasTextMetadata;
}

- (void)storePreview:(ApolloLinkPreview *)preview forURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]] || !preview) return;
    if (!preview.fetchedAt) preview.fetchedAt = [NSDate date];
    NSString *key = [self cacheKeyForURL:url];
    NSMutableDictionary *entry = [[preview dictionaryRepresentation] mutableCopy];
    entry[@"url"] = url.absoluteString ?: @"";
    entry[@"lastAccess"] = @([[NSDate date] timeIntervalSince1970]);

    [self.memoryCache setObject:preview forKey:key];
    dispatch_async(self.queue, ^{
        self.entries[key] = entry;
        [self evictIfNeededLocked];
        [self writeEntriesToDiskLocked];
    });
}

- (void)markNoMetadataForURL:(NSURL *)url {
    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.noMetadata = YES;
    preview.fetchedAt = [NSDate date];
    [self storePreview:preview forURL:url];
}

- (void)flushCache {
    [self.memoryCache removeAllObjects];
    dispatch_async(self.queue, ^{
        NSUInteger removed = self.entries.count;
        [self.entries removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:self.cachePath error:nil];
        ApolloLog(@"[LinkPreviews] cache flushed by user (%lu entries cleared, disk file removed)", (unsigned long)removed);
    });
}

- (void)evictIfNeededLocked {
    if (self.entries.count <= ApolloLinkPreviewCacheMaxEntries) return;

    NSArray<NSString *> *sortedKeys = [self.entries keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        NSTimeInterval firstAccess = [first[@"lastAccess"] respondsToSelector:@selector(doubleValue)] ? [first[@"lastAccess"] doubleValue] : 0.0;
        NSTimeInterval secondAccess = [second[@"lastAccess"] respondsToSelector:@selector(doubleValue)] ? [second[@"lastAccess"] doubleValue] : 0.0;
        if (firstAccess < secondAccess) return NSOrderedAscending;
        if (firstAccess > secondAccess) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSUInteger removeCount = self.entries.count - ApolloLinkPreviewCacheMaxEntries;
    for (NSUInteger index = 0; index < removeCount && index < sortedKeys.count; index++) {
        [self.entries removeObjectForKey:sortedKeys[index]];
    }
    ApolloLog(@"[LinkPreviews] evicted %lu cached previews", (unsigned long)removeCount);
}

@end
