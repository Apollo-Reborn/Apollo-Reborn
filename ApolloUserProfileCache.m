#import "ApolloUserProfileCache.h"
#import "ApolloCommon.h"
#import "ApolloState.h"

NSString * const ApolloUserProfileInfoUpdatedNotification = @"ApolloUserProfileInfoUpdatedNotification";
NSString * const ApolloUserProfileUsernameKey = @"username";

static NSTimeInterval const ApolloUserProfileCacheTTL = 7.0 * 24.0 * 60.0 * 60.0;
static NSUInteger const ApolloUserProfileDiskCacheMaxEntries = 2000;

static UIImage *ApolloDecodedAvatarImage(UIImage *image) {
    if (!image || image.images.count > 0 || image.size.width <= 0.0 || image.size.height <= 0.0) return image;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = image.scale > 0.0 ? image.scale : [UIScreen mainScreen].scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0.0, 0.0, image.size.width, image.size.height)];
    }] ?: image;
}

@implementation ApolloUserProfileInfo

- (instancetype)initWithUsername:(NSString *)username
                          iconURL:(NSURL *)iconURL
                        bannerURL:(NSURL *)bannerURL
                       defaultSnoo:(BOOL)defaultSnoo
                        fetchedAt:(NSDate *)fetchedAt {
    self = [super init];
    if (self) {
        _username = [username copy];
        _iconURL = iconURL;
        _bannerURL = bannerURL;
        _defaultSnoo = defaultSnoo;
        _fetchedAt = fetchedAt ?: [NSDate date];
    }
    return self;
}

@end

@interface ApolloUserProfileCache ()
@property(nonatomic, strong) NSCache<NSString *, ApolloUserProfileInfo *> *infoCache;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ApolloUserProfileInfo *> *diskInfo;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(ApolloUserProfileInfo *)> *> *infoCompletions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage *)> *> *imageCompletions;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation ApolloUserProfileCache

+ (instancetype)sharedCache {
    static ApolloUserProfileCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ApolloUserProfileCache alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollofix.userProfileCache", DISPATCH_QUEUE_SERIAL);

        _infoCache = [[NSCache alloc] init];
        _infoCache.countLimit = 2000;

        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 800;
        _imageCache.totalCostLimit = 40 * 1024 * 1024;

        _diskInfo = [NSMutableDictionary dictionary];
        _infoCompletions = [NSMutableDictionary dictionary];
        _imageCompletions = [NSMutableDictionary dictionary];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:configuration];

        [self loadDiskCache];
    }
    return self;
}

- (NSString *)normalizedUsername:(NSString *)username {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean.lowercaseString;
}

- (NSString *)cachePath {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheRoot = paths.firstObject ?: NSTemporaryDirectory();
    NSString *directory = [cacheRoot stringByAppendingPathComponent:@"ApolloFix"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"ApolloUserProfiles.json"];
}

- (NSURL *)URLFromString:(id)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (string.length == 0) return nil;
    string = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    if ([string hasPrefix:@"//"]) string = [@"https:" stringByAppendingString:string];
    NSURL *url = [NSURL URLWithString:string];
    if (!url.scheme.length || !url.host.length) return nil;
    return url;
}

- (NSURL *)decoratorURLFromProfileDictionary:(NSDictionary *)dataDict {
    NSArray<NSString *> *keys = @[@"avatar_decoration_data", @"avatar_decoration"];
    for (NSString *key in keys) {
        NSDictionary *decoration = [dataDict[key] isKindOfClass:[NSDictionary class]] ? dataDict[key] : nil;
        if (!decoration) continue;
        NSURL *url = [self URLFromString:decoration[@"asset_url"]] ?:
            [self URLFromString:decoration[@"static_asset_url"]] ?:
            [self URLFromString:decoration[@"url"]] ?:
            [self URLFromString:decoration[@"image_url"]];
        if (url) return url;
    }
    return nil;
}

- (NSString *)avatarFrameKindForIconURL:(NSURL *)iconURL snoovatarURL:(NSURL *)snoovatarURL {
    NSString *combined = [NSString stringWithFormat:@"%@ %@", iconURL.absoluteString ?: @"", snoovatarURL.absoluteString ?: @""].lowercaseString;
    if (![combined containsString:@"nftv2"] && ![combined containsString:@"snoo-nft"]) return nil;
    if ([combined containsString:@"_legendary_"]) return @"collectible-legendary";
    if ([combined containsString:@"_epic_"]) return @"collectible-epic";
    if ([combined containsString:@"_rare_"]) return @"collectible-rare";
    if ([combined containsString:@"_common_"]) return @"collectible-common";
    return @"collectible";
}

- (BOOL)isFreshInfo:(ApolloUserProfileInfo *)info {
    if (!info.fetchedAt) return NO;
    return fabs([info.fetchedAt timeIntervalSinceNow]) < ApolloUserProfileCacheTTL;
}

- (NSDictionary *)dictionaryForInfo:(ApolloUserProfileInfo *)info {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (info.username) dict[@"username"] = info.username;
    if (info.iconURL.absoluteString) dict[@"iconURL"] = info.iconURL.absoluteString;
    if (info.bannerURL.absoluteString) dict[@"bannerURL"] = info.bannerURL.absoluteString;
    if (info.snoovatarURL.absoluteString) dict[@"snoovatarURL"] = info.snoovatarURL.absoluteString;
    dict[@"decoratorURL"] = info.decoratorURL.absoluteString ?: @"";
    dict[@"avatarFrameKind"] = info.avatarFrameKind ?: @"";
    dict[@"defaultSnoo"] = @(info.defaultSnoo);
    dict[@"hasSnoovatar"] = @(info.hasSnoovatar);
    dict[@"fetchedAt"] = @([info.fetchedAt timeIntervalSince1970]);
    return dict;
}

- (ApolloUserProfileInfo *)infoFromDictionary:(NSDictionary *)dict fallbackUsername:(NSString *)fallbackUsername {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *username = [dict[@"username"] isKindOfClass:[NSString class]] ? dict[@"username"] : fallbackUsername;
    NSURL *iconURL = [self URLFromString:dict[@"iconURL"]];
    NSURL *bannerURL = [self URLFromString:dict[@"bannerURL"]];
    NSURL *snoovatarURL = [self URLFromString:dict[@"snoovatarURL"]];
    NSURL *decoratorURL = [self URLFromString:dict[@"decoratorURL"]];
    NSString *avatarFrameKind = [dict[@"avatarFrameKind"] isKindOfClass:[NSString class]] ? dict[@"avatarFrameKind"] : nil;
    if (avatarFrameKind.length == 0) avatarFrameKind = nil;
    BOOL defaultSnoo = [dict[@"defaultSnoo"] boolValue];
    BOOL hasSnoovatar = snoovatarURL || [dict[@"hasSnoovatar"] boolValue];
    NSTimeInterval timestamp = [dict[@"fetchedAt"] doubleValue];
    NSDate *fetchedAt = timestamp > 0 ? [NSDate dateWithTimeIntervalSince1970:timestamp] : [NSDate distantPast];
    if (!dict[@"hasSnoovatar"] && !dict[@"snoovatarURL"]) fetchedAt = [NSDate distantPast];
    if (!dict[@"decoratorURL"] && !dict[@"avatarFrameKind"]) fetchedAt = [NSDate distantPast];
    ApolloUserProfileInfo *info = [[ApolloUserProfileInfo alloc] initWithUsername:username iconURL:iconURL bannerURL:bannerURL defaultSnoo:defaultSnoo fetchedAt:fetchedAt];
    info.snoovatarURL = snoovatarURL;
    info.decoratorURL = decoratorURL;
    info.avatarFrameKind = avatarFrameKind;
    info.hasSnoovatar = hasSnoovatar;
    return info;
}

- (void)pruneDiskInfoLocked {
    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    for (NSString *key in self.diskInfo) {
        if (![self isFreshInfo:self.diskInfo[key]]) [staleKeys addObject:key];
    }
    for (NSString *key in staleKeys) [self.diskInfo removeObjectForKey:key];

    if (self.diskInfo.count <= ApolloUserProfileDiskCacheMaxEntries) return;

    NSArray<NSString *> *sorted = [self.diskInfo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = self.diskInfo[a].fetchedAt ?: [NSDate distantPast];
        NSDate *db = self.diskInfo[b].fetchedAt ?: [NSDate distantPast];
        return [db compare:da];
    }];
    for (NSUInteger i = ApolloUserProfileDiskCacheMaxEntries; i < sorted.count; i++) {
        [self.diskInfo removeObjectForKey:sorted[i]];
    }
}

- (void)loadDiskCache {
    NSData *data = [NSData dataWithContentsOfFile:[self cachePath]];
    if (!data.length) return;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *root = (NSDictionary *)json;
    for (NSString *key in root) {
        if (![key isKindOfClass:[NSString class]]) continue;
        ApolloUserProfileInfo *info = [self infoFromDictionary:root[key] fallbackUsername:key];
        if (!info) continue;
        self.diskInfo[key] = info;
    }

    [self pruneDiskInfoLocked];

    for (NSString *key in self.diskInfo) {
        [self.infoCache setObject:self.diskInfo[key] forKey:key];
    }
}

- (void)saveDiskCacheLocked {
    [self pruneDiskInfoLocked];

    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    for (NSString *key in self.diskInfo) {
        root[key] = [self dictionaryForInfo:self.diskInfo[key]];
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (data.length) {
        [data writeToFile:[self cachePath] atomically:YES];
    }
}

- (ApolloUserProfileInfo *)cachedInfoForUsername:(NSString *)username {
    NSString *key = [self normalizedUsername:username];
    if (!key) return nil;
    ApolloUserProfileInfo *info = [self.infoCache objectForKey:key];
    if (info) return info;

    __block ApolloUserProfileInfo *diskInfo = nil;
    dispatch_sync(self.queue, ^{
        diskInfo = self.diskInfo[key];
        if (diskInfo) [self.infoCache setObject:diskInfo forKey:key];
    });
    return diskInfo;
}

- (NSString *)escapedUsernameForPath:(NSString *)username {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-" ];
    return [username stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: username;
}

- (NSURLRequest *)profileRequestForUsername:(NSString *)username {
    NSString *escaped = [self escapedUsernameForPath:username];
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/user/%@/about.json?raw_json=1", escaped]
        : [NSString stringWithFormat:@"https://www.reddit.com/user/%@/about.json?raw_json=1", escaped];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15.0;
    if (token.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : @"ApolloProfileAvatars/1.0";
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (ApolloUserProfileInfo *)profileInfoFromResponseData:(NSData *)data fallbackUsername:(NSString *)fallbackUsername {
    if (!data.length) return nil;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *root = (NSDictionary *)json;
    NSDictionary *dataDict = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    if (!dataDict) return nil;

    NSDictionary *subreddit = [dataDict[@"subreddit"] isKindOfClass:[NSDictionary class]] ? dataDict[@"subreddit"] : nil;
    NSURL *snoovatarURL = [self URLFromString:dataDict[@"snoovatar_img"]];
    NSURL *subredditIconURL = [self URLFromString:subreddit[@"icon_img"]] ?: [self URLFromString:subreddit[@"community_icon"]];
    NSURL *accountIconURL = [self URLFromString:dataDict[@"icon_img"]];
    NSURL *iconURL = subredditIconURL ?: snoovatarURL ?: accountIconURL;
    NSURL *decoratorURL = [self decoratorURLFromProfileDictionary:dataDict];
    NSString *avatarFrameKind = [self avatarFrameKindForIconURL:iconURL snoovatarURL:snoovatarURL];

    NSURL *bannerURL = [self URLFromString:subreddit[@"banner_img"]] ?:
        [self URLFromString:subreddit[@"mobile_banner_image"]] ?:
        [self URLFromString:subreddit[@"banner_background_image"]];

    NSString *username = [dataDict[@"name"] isKindOfClass:[NSString class]] ? dataDict[@"name"] : fallbackUsername;
    BOOL defaultSnoo = NO;
    if (!snoovatarURL && iconURL.host.length > 0) {
        NSString *host = iconURL.host.lowercaseString;
        NSString *path = iconURL.path.lowercaseString;
        defaultSnoo = ([host containsString:@"redditstatic.com"] && [path containsString:@"avatar_default"]);
    }

    ApolloUserProfileInfo *info = [[ApolloUserProfileInfo alloc] initWithUsername:username iconURL:iconURL bannerURL:bannerURL defaultSnoo:defaultSnoo fetchedAt:[NSDate date]];
    info.snoovatarURL = snoovatarURL;
    info.decoratorURL = decoratorURL;
    info.avatarFrameKind = avatarFrameKind;
    info.hasSnoovatar = snoovatarURL != nil;
    return info;
}

- (void)finishInfoRequestForKey:(NSString *)key info:(ApolloUserProfileInfo *)info {
    dispatch_async(self.queue, ^{
        if (info) {
            self.diskInfo[key] = info;
            [self.infoCache setObject:info forKey:key];
            [self saveDiskCacheLocked];
            if (info.iconURL) [self requestImageForURL:info.iconURL completion:nil];
            if (info.decoratorURL) [self requestImageForURL:info.decoratorURL completion:nil];
        }

        NSArray<void (^)(ApolloUserProfileInfo *)> *callbacks = [self.infoCompletions[key] copy];
        [self.infoCompletions removeObjectForKey:key];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (info) {
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloUserProfileInfoUpdatedNotification
                                                                    object:self
                                                                  userInfo:@{ApolloUserProfileUsernameKey: key}];
            }
            for (void (^callback)(ApolloUserProfileInfo *) in callbacks) {
                callback(info);
            }
        });
    });
}

- (void)startInfoFetchForKey:(NSString *)key {
    NSURLRequest *request = [self profileRequestForUsername:key];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            ApolloLog(@"[UserAvatars] Failed to fetch u/%@: %@", key, error.localizedDescription);
            [self finishInfoRequestForKey:key info:nil];
            return;
        }

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            ApolloLog(@"[UserAvatars] Profile fetch for u/%@ returned HTTP %ld", key, (long)http.statusCode);
            [self finishInfoRequestForKey:key info:nil];
            return;
        }

        ApolloUserProfileInfo *info = [self profileInfoFromResponseData:data fallbackUsername:key];
        if (info.iconURL || info.bannerURL) {
            ApolloLog(@"[UserAvatars] Fetched profile info for u/%@ icon=%@ banner=%@ decorator=%@ frame=%@", key, info.iconURL.absoluteString ?: @"nil", info.bannerURL.absoluteString ?: @"nil", info.decoratorURL.absoluteString ?: @"nil", info.avatarFrameKind ?: @"nil");
        } else {
            ApolloLog(@"[UserAvatars] Fetched profile info for u/%@ but no avatar/banner URLs were present", key);
        }
        [self finishInfoRequestForKey:key info:info];
    }];
    [task resume];
}

- (void)requestInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion {
    NSString *key = [self normalizedUsername:username];
    if (!key) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    dispatch_async(self.queue, ^{
        ApolloUserProfileInfo *info = [self.infoCache objectForKey:key] ?: self.diskInfo[key];
        if (info) [self.infoCache setObject:info forKey:key];

        if (info && completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(info); });
        }
        if (info && [self isFreshInfo:info]) return;

        NSMutableArray<void (^)(ApolloUserProfileInfo *)> *callbacks = self.infoCompletions[key];
        if (callbacks) {
            if (completion) [callbacks addObject:[completion copy]];
            return;
        }

        callbacks = [NSMutableArray array];
        if (completion) [callbacks addObject:[completion copy]];
        self.infoCompletions[key] = callbacks;
        [self startInfoFetchForKey:key];
    });
}

- (UIImage *)cachedImageForURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    return [self.imageCache objectForKey:url.absoluteString];
}

- (void)finishImageRequestForKey:(NSString *)key image:(UIImage *)image {
    dispatch_async(self.queue, ^{
        if (image) {
            NSUInteger cost = (NSUInteger)MAX(1.0, image.size.width * image.size.height * image.scale * image.scale * 4.0);
            [self.imageCache setObject:image forKey:key cost:cost];
        }

        NSArray<void (^)(UIImage *)> *callbacks = [self.imageCompletions[key] copy];
        [self.imageCompletions removeObjectForKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^callback)(UIImage *) in callbacks) {
                callback(image);
            }
        });
    });
}

- (void)requestImageForURL:(NSURL *)url completion:(void (^)(UIImage *image))completion {
    if (![url isKindOfClass:[NSURL class]]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSString *key = url.absoluteString;
    UIImage *cached = [self.imageCache objectForKey:key];
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    dispatch_async(self.queue, ^{
        NSMutableArray<void (^)(UIImage *)> *callbacks = self.imageCompletions[key];
        if (callbacks) {
            if (completion) [callbacks addObject:[completion copy]];
            return;
        }

        callbacks = [NSMutableArray array];
        if (completion) [callbacks addObject:[completion copy]];
        self.imageCompletions[key] = callbacks;

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *image = nil;
            if (!error && data.length > 0) {
                @autoreleasepool {
                    image = ApolloDecodedAvatarImage([UIImage imageWithData:data scale:[UIScreen mainScreen].scale]);
                }
            }
            if (!image && error) {
                ApolloLog(@"[UserAvatars] Failed to load image %@: %@", key, error.localizedDescription);
            }
            [self finishImageRequestForKey:key image:image];
        }];
        [task resume];
    });
}

@end