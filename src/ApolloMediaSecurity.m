#import "ApolloMediaSecurity.h"

#import <arpa/inet.h>
#import <limits.h>
#import <netdb.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const ApolloMediaSecurityErrorDomain = @"ApolloMediaSecurity";

static NSError *ApolloMediaSecurityError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ApolloMediaSecurityErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL ApolloMediaIPv4IsPublic(const struct in_addr *address) {
    uint32_t value = ntohl(address->s_addr);
    uint8_t a = value >> 24;
    uint8_t b = value >> 16;
    if (a == 0 || a == 10 || a == 127 || a >= 224) return NO;
    if (a == 100 && (b & 0xc0) == 0x40) return NO;       // carrier-grade NAT
    if (a == 169 && b == 254) return NO;                 // link-local
    if (a == 172 && b >= 16 && b <= 31) return NO;
    if (a == 192 && (b == 0 || b == 168)) return NO;     // IETF/reserved + RFC1918
    if (a == 198 && (b == 18 || b == 19)) return NO;     // benchmark network
    if (a == 192 && b == 0 && ((value >> 8) & 0xff) == 2) return NO;
    if (a == 198 && b == 51 && ((value >> 8) & 0xff) == 100) return NO;
    if (a == 203 && b == 0 && ((value >> 8) & 0xff) == 113) return NO;
    return YES;
}

BOOL ApolloMediaSocketAddressIsPublic(const struct sockaddr *_Nullable address) {
    if (!address) return NO;
    if (address->sa_family == AF_INET) {
        return ApolloMediaIPv4IsPublic(&((const struct sockaddr_in *)address)->sin_addr);
    }
    if (address->sa_family != AF_INET6) return NO;
    const struct in6_addr *value = &((const struct sockaddr_in6 *)address)->sin6_addr;
    const uint8_t *bytes = value->s6_addr;
    if (IN6_IS_ADDR_UNSPECIFIED(value) || IN6_IS_ADDR_LOOPBACK(value) ||
        IN6_IS_ADDR_MULTICAST(value) || IN6_IS_ADDR_LINKLOCAL(value) ||
        IN6_IS_ADDR_SITELOCAL(value)) return NO;
    if ((bytes[0] & 0xfe) == 0xfc) return NO;             // unique-local fc00::/7
    if (IN6_IS_ADDR_V4MAPPED(value)) {
        struct in_addr mapped;
        memcpy(&mapped, bytes + 12, sizeof(mapped));
        return ApolloMediaIPv4IsPublic(&mapped);
    }
    static const uint8_t zero96[12] = {0};
    if (memcmp(bytes, zero96, sizeof(zero96)) == 0) {      // deprecated IPv4-compatible form
        struct in_addr compatible;
        memcpy(&compatible, bytes + 12, sizeof(compatible));
        return ApolloMediaIPv4IsPublic(&compatible);
    }
    static const uint8_t nat64[] = {0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0};
    if (memcmp(bytes, nat64, sizeof(nat64)) == 0) {
        struct in_addr embedded;
        memcpy(&embedded, bytes + 12, sizeof(embedded));
        return ApolloMediaIPv4IsPublic(&embedded);
    }
    static const uint8_t documentation[] = {0x20, 0x01, 0x0d, 0xb8};
    if (memcmp(bytes, documentation, sizeof(documentation)) == 0) return NO;
    static const uint8_t discardPrefix[] = {0x01, 0x00, 0, 0, 0, 0, 0, 0};
    if (memcmp(bytes, discardPrefix, sizeof(discardPrefix)) == 0) return NO; // 100::/64
    return YES;
}

BOOL ApolloMediaURLHasAllowedHTTPSHost(NSURL *_Nullable URL) {
    NSString *scheme = URL.scheme.lowercaseString;
    NSString *host = URL.host.lowercaseString;
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (![scheme isEqualToString:@"https"] || host.length == 0) return NO;
    // These are the exact product media families used by Apollo's Reddit,
    // Imgur and ImageChest sources. Dot-boundary matching permits their CDNs
    // without permitting lookalikes such as imgur.com.evil.example.
    NSArray<NSString *> *roots = @[
        @"reddit.com", @"redd.it", @"redditmedia.com", @"reddituploads.com",
        @"imgur.com", @"imgchest.com",
    ];
    for (NSString *root in roots) {
        if ([host isEqualToString:root] || [host hasSuffix:[@"." stringByAppendingString:root]]) return YES;
    }
    return NO;
}

BOOL ApolloMediaURLHasPublicDestination(NSURL *_Nullable URL, NSError **error) {
    if (error) *error = nil;
    if (!ApolloMediaURLHasAllowedHTTPSHost(URL)) {
        if (error) *error = ApolloMediaSecurityError(1, @"Media destination is not an approved HTTPS host");
        return NO;
    }
    NSString *host = URL.host.lowercaseString;
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];

    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *addresses = NULL;
    int result = getaddrinfo(host.UTF8String, NULL, &hints, &addresses);
    if (result != 0 || !addresses) {
        if (error) *error = ApolloMediaSecurityError(3, @"Media destination could not be resolved");
        if (addresses) freeaddrinfo(addresses);
        return NO;
    }
    BOOL found = NO;
    BOOL allPublic = YES;
    for (struct addrinfo *cursor = addresses; cursor; cursor = cursor->ai_next) {
        if (cursor->ai_family != AF_INET && cursor->ai_family != AF_INET6) continue;
        found = YES;
        if (!ApolloMediaSocketAddressIsPublic(cursor->ai_addr)) { allPublic = NO; break; }
    }
    freeaddrinfo(addresses);
    if (!found || !allPublic) {
        if (error) *error = ApolloMediaSecurityError(4, @"Private or local media destinations are not allowed");
        return NO;
    }
    return YES;
}

BOOL ApolloMediaExpectedLengthFits(long long expectedLength, unsigned long long maximumBytes,
                                   unsigned long long availableBytes, unsigned long long reserveBytes) {
    if (maximumBytes == 0 || availableBytes < reserveBytes) return NO;
    if (expectedLength < 0) return YES;
    unsigned long long expected = (unsigned long long)expectedLength;
    return expected <= maximumBytes && expected <= availableBytes - reserveBytes;
}

BOOL ApolloMediaByteRangeFits(unsigned long long receivedBytes, unsigned long long incomingBytes,
                              unsigned long long maximumBytes) {
    return maximumBytes > 0 && receivedBytes <= maximumBytes && incomingBytes <= maximumBytes - receivedBytes;
}

static unsigned long long ApolloMediaAvailableTemporaryBytes(void) {
    NSURL *temporary = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSNumber *capacity = nil;
    [temporary getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    if (capacity.unsignedLongLongValue > 0) return capacity.unsignedLongLongValue;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:temporary.path error:nil];
    return [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
}

BOOL ApolloMediaMuxOutputBudget(unsigned long long videoBytes, unsigned long long audioBytes,
                                unsigned long long availableBytes, unsigned long long reserveBytes,
                                unsigned long long *_Nullable maximumOutputBytes) {
    if (maximumOutputBytes) *maximumOutputBytes = 0;
    if (videoBytes == 0 || audioBytes == 0 || videoBytes > ULLONG_MAX - audioBytes) return NO;
    unsigned long long inputs = videoBytes + audioBytes;
    unsigned long long overhead = MAX(16ULL * 1024ULL * 1024ULL, inputs / 20ULL);
    if (inputs > ULLONG_MAX - overhead) return NO;
    unsigned long long output = inputs + overhead;
    if (availableBytes < reserveBytes || output > availableBytes - reserveBytes) return NO;
    if (maximumOutputBytes) *maximumOutputBytes = output;
    return YES;
}

BOOL ApolloMediaMuxFilesFit(NSURL *videoURL, NSURL *audioURL, unsigned long long reserveBytes,
                            unsigned long long *_Nullable maximumOutputBytes) {
    NSNumber *videoSize = nil;
    NSNumber *audioSize = nil;
    if (![videoURL getResourceValue:&videoSize forKey:NSURLFileSizeKey error:nil] ||
        ![audioURL getResourceValue:&audioSize forKey:NSURLFileSizeKey error:nil]) return NO;
    return ApolloMediaMuxOutputBudget(videoSize.unsignedLongLongValue,
                                      audioSize.unsignedLongLongValue,
                                      ApolloMediaAvailableTemporaryBytes(), reserveBytes,
                                      maximumOutputBytes);
}

BOOL ApolloMediaOutputFileFits(NSURL *_Nullable outputURL, unsigned long long maximumOutputBytes,
                               unsigned long long reserveBytes) {
    NSNumber *size = nil;
    if (outputURL && [[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
        if (![outputURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) return NO;
    }
    return size.unsignedLongLongValue <= maximumOutputBytes &&
        ApolloMediaAvailableTemporaryBytes() >= reserveBytes;
}

@interface ApolloBoundedMediaDownload : NSObject <ApolloBoundedMediaTransfer, NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic) unsigned long long maximumBytes;
@property (nonatomic) unsigned long long reserveBytes;
@property (nonatomic, copy, nullable) NSString *filenameExtension;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, copy, nullable) ApolloBoundedMediaDownloadCompletion completion;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *task;
@property (nonatomic, strong, nullable) NSHTTPURLResponse *response;
@property (nonatomic, strong, nullable) NSURL *completedFile;
@property (nonatomic, strong, nullable) NSError *failure;
@property (nonatomic) unsigned long long lastWrittenBytes;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL completed;
- (void)begin;
- (void)finishWithFile:(NSURL *_Nullable)file error:(NSError *_Nullable)error;
@end

@implementation ApolloBoundedMediaDownload

- (void)begin {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *destinationError = nil;
        if (!ApolloMediaURLHasPublicDestination(self.request.URL, &destinationError)) {
            [self finishWithFile:nil error:destinationError];
            return;
        }
        unsigned long long available = ApolloMediaAvailableTemporaryBytes();
        if (available == 0 || available < self.reserveBytes) {
            [self finishWithFile:nil error:ApolloMediaSecurityError(5, @"Not enough free space for media download")];
            return;
        }
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache = nil;
        configuration.timeoutIntervalForRequest = MAX(1.0, self.request.timeoutInterval);
        configuration.timeoutIntervalForResource = 300.0;
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
        NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:self.request];
        BOOL shouldStart = NO;
        @synchronized (self) {
            shouldStart = !self.cancelled && !self.completed;
            if (shouldStart) {
                self.session = session;
                self.task = task;
            }
        }
        if (shouldStart) [task resume];
        else [session invalidateAndCancel];
    });
}

- (void)cancel {
    BOOL finishBeforeStart = NO;
    @synchronized (self) {
        if (self.completed || self.cancelled) return;
        self.cancelled = YES;
        finishBeforeStart = self.task == nil;
    }
    [self.task cancel];
    if (finishBeforeStart) [self finishWithFile:nil error:ApolloMediaSecurityError(NSURLErrorCancelled, @"Media download cancelled")];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    NSError *error = nil;
    if (!ApolloMediaURLHasPublicDestination(request.URL, &error)) {
        self.failure = error;
        completionHandler(nil);
        [task cancel];
        return;
    }
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    unsigned long long total = totalBytesWritten < 0 ? ULLONG_MAX : (unsigned long long)totalBytesWritten;
    unsigned long long incoming = total >= self.lastWrittenBytes ? total - self.lastWrittenBytes : ULLONG_MAX;
    unsigned long long available = ApolloMediaAvailableTemporaryBytes();
    BOOL advertisedFits = totalBytesExpectedToWrite < 0 ||
        (unsigned long long)totalBytesExpectedToWrite <= self.maximumBytes;
    unsigned long long remaining = (totalBytesExpectedToWrite > totalBytesWritten)
        ? (unsigned long long)(totalBytesExpectedToWrite - totalBytesWritten) : 0;
    BOOL freeSpaceFits = available >= self.reserveBytes &&
        remaining <= available - self.reserveBytes;
    BOOL fits = ApolloMediaByteRangeFits(self.lastWrittenBytes, incoming, self.maximumBytes) &&
        advertisedFits && freeSpaceFits;
    if (!fits) {
        self.failure = ApolloMediaSecurityError(6, @"Media download exceeded its resource limit");
        [downloadTask cancel];
        return;
    }
    self.lastWrittenBytes = total;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {
    self.response = (NSHTTPURLResponse *)downloadTask.response;
    NSNumber *size = nil;
    [location getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    unsigned long long length = size.unsignedLongLongValue;
    long long advertised = self.response.expectedContentLength;
    NSError *destinationError = nil;
    BOOL finalDestinationPublic = ApolloMediaURLHasPublicDestination(self.response.URL, &destinationError);
    if (self.failure || !finalDestinationPublic ||
        (advertised >= 0 && (unsigned long long)advertised > self.maximumBytes) ||
        length > self.maximumBytes || ApolloMediaAvailableTemporaryBytes() < self.reserveBytes) {
        self.failure = self.failure ?: destinationError;
        self.failure = self.failure ?: ApolloMediaSecurityError(6, @"Media download exceeded its resource limit");
        return;
    }
    NSString *name = NSUUID.UUID.UUIDString;
    if (self.filenameExtension.length) name = [name stringByAppendingPathExtension:self.filenameExtension];
    NSURL *destination = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:name];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&moveError]) {
        self.failure = moveError;
        return;
    }
    self.completedFile = destination;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *_Nullable)error {
    NSError *finalError = self.failure ?: error;
    NSHTTPURLResponse *response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
    if (!finalError && (response.statusCode < 200 || response.statusCode >= 300)) {
        finalError = ApolloMediaSecurityError(7, @"Media server returned an HTTP error");
    }
    [self finishWithFile:finalError ? nil : self.completedFile error:finalError];
}

- (void)finishWithFile:(NSURL *_Nullable)file error:(NSError *_Nullable)error {
    ApolloBoundedMediaDownloadCompletion completion = nil;
    @synchronized (self) {
        if (self.completed) return;
        self.completed = YES;
        completion = self.completion;
        self.completion = nil;
    }
    if (!file && self.completedFile) [[NSFileManager defaultManager] removeItemAtURL:self.completedFile error:nil];
    [self.session finishTasksAndInvalidate];
    dispatch_async(self.completionQueue ?: dispatch_get_main_queue(), ^{ completion(file, self.response, error); });
}

@end

id<ApolloBoundedMediaTransfer> ApolloStartBoundedMediaDownload(
    NSURLRequest *request, unsigned long long maximumBytes, unsigned long long reserveBytes,
    NSString *_Nullable filenameExtension, dispatch_queue_t _Nullable completionQueue,
    ApolloBoundedMediaDownloadCompletion completion) {
    ApolloBoundedMediaDownload *transfer = [ApolloBoundedMediaDownload new];
    transfer.request = request;
    transfer.maximumBytes = maximumBytes;
    transfer.reserveBytes = reserveBytes;
    transfer.filenameExtension = filenameExtension;
    transfer.completionQueue = completionQueue ?: dispatch_get_main_queue();
    transfer.completion = completion;
    [transfer begin];
    return transfer;
}

NS_ASSUME_NONNULL_END
