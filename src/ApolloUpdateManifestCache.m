#import "ApolloUpdateManifestCache.h"

@interface ApolloUpdateManifestCache ()
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, copy) NSString *manifestURL;
@property (nonatomic, copy) NSData *manifestData;
@property (nonatomic, copy) NSString *etag;
@end

// The manifest is only a few KB. Reject a corrupt/accidentally replaced cache
// before loading or retaining an arbitrarily large object on the main queue.
static const NSUInteger kUpdateManifestMaximumBytes = 256 * 1024;

static ApolloUpdateInfo *ApolloUpdateInfoFromData(NSData *data, NSString *variantKey) {
    if (!data.length || data.length > kUpdateManifestMaximumBytes) return nil;
    return ApolloUpdateInfoFromManifest([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL], variantKey);
}

static NSString *ApolloUpdateETag(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    // An ETag is a single header value; never replay a corrupt persisted header.
    if ([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return nil;
    return value;
}

@implementation ApolloUpdateManifestCache

- (instancetype)init {
    NSURL *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [self initWithFileURL:[[caches URLByAppendingPathComponent:@"ApolloReborn" isDirectory:YES]
                                 URLByAppendingPathComponent:@"UpdateManifest.plist"]];
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (!self) return nil;
    _fileURL = fileURL;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path error:NULL];
    // The binary plist has a little overhead beyond its raw JSON body.
    if ([attributes[NSFileSize] unsignedLongLongValue] > kUpdateManifestMaximumBytes + 4096) return self;
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    id stored = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    if (![stored isKindOfClass:NSDictionary.class]) return self;
    NSString *url = [stored[@"url"] isKindOfClass:NSString.class] ? stored[@"url"] : nil;
    NSData *manifest = [stored[@"manifest"] isKindOfClass:NSData.class] ? stored[@"manifest"] : nil;
    if (!url.length || !ApolloUpdateInfoFromData(manifest, nil)) return self;
    _manifestURL = [url copy];
    _manifestData = [manifest copy];
    _etag = [ApolloUpdateETag(stored[@"etag"]) copy];
    return self;
}

- (ApolloUpdateInfo *)cachedInfoForURL:(NSURL *)url variantKey:(NSString *)variantKey {
    if (url.isFileURL || ![self.manifestURL isEqualToString:url.absoluteString]) return nil;
    return ApolloUpdateInfoFromData(self.manifestData, variantKey);
}

- (NSURLRequest *)requestForURL:(NSURL *)url variantKey:(NSString *)variantKey {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                    timeoutInterval:15];
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (self.etag && [self cachedInfoForURL:url variantKey:variantKey]) {
        [request setValue:self.etag forHTTPHeaderField:@"If-None-Match"];
    }
    return request;
}

- (void)save {
    if (!self.manifestURL || !self.manifestData) return;
    NSMutableDictionary *stored = [@{@"url": self.manifestURL, @"manifest": self.manifestData} mutableCopy];
    if (self.etag) stored[@"etag"] = self.etag;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:stored format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    [[NSFileManager defaultManager] createDirectoryAtURL:self.fileURL.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToURL:self.fileURL options:NSDataWritingAtomic error:NULL];
}

- (ApolloUpdateInfo *)infoForResponse:(NSURLResponse *)response
                               data:(NSData *)data
                            request:(NSURLRequest *)request
                         variantKey:(NSString *)variantKey {
    NSURL *url = request.URL;
    if (url.isFileURL) return ApolloUpdateInfoFromData(data, variantKey);
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return nil;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (http.statusCode == 304) {
        ApolloUpdateInfo *cached = [self cachedInfoForURL:url variantKey:variantKey];
        NSString *sentETag = [request valueForHTTPHeaderField:@"If-None-Match"];
        if (cached && self.etag.length && [sentETag isEqualToString:self.etag]) return cached;
        // Recover from an unsolicited 304 or a lost/replaced body without ever
        // treating an empty response as success or retrying the same bad pair.
        if ([self.manifestURL isEqualToString:url.absoluteString] && self.etag) {
            self.etag = nil;
            [self save];
        }
        return nil;
    }
    if (http.statusCode != 200) return nil;
    ApolloUpdateInfo *latest = ApolloUpdateInfoFromData(data, variantKey);
    if (!latest) return nil;
    self.manifestURL = url.absoluteString;
    self.manifestData = data;
    // A body with no validator must clear the old one: it belonged to the
    // previous body, even when the request URL and release version are unchanged.
    self.etag = ApolloUpdateETag([http valueForHTTPHeaderField:@"ETag"]);
    [self save];
    return latest;
}

@end
