#import <Foundation/Foundation.h>
#import <arpa/inet.h>

// Include production so the redirect delegate and exactly-once cleanup path
// are exercised without making a network request or adding test-only exports.
#import "../src/ApolloMediaSecurity.m"

static NSUInteger sChecks;
static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static BOOL IPv4(NSString *text) {
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    inet_pton(AF_INET, text.UTF8String, &address.sin_addr);
    return ApolloMediaSocketAddressIsPublic((const struct sockaddr *)&address);
}

static BOOL IPv6(NSString *text) {
    struct sockaddr_in6 address = {0};
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    inet_pton(AF_INET6, text.UTF8String, &address.sin6_addr);
    return ApolloMediaSocketAddressIsPublic((const struct sockaddr *)&address);
}

int main(void) {
    @autoreleasepool {
        Check(IPv4(@"8.8.8.8"), @"globally routed IPv4 is accepted");
        for (NSString *value in @[@"0.0.0.0", @"10.1.2.3", @"100.64.1.2", @"127.0.0.1",
                                    @"169.254.10.2", @"172.16.0.1", @"192.168.1.1", @"224.0.0.1"])
            Check(!IPv4(value), [@"private/local IPv4 rejected: " stringByAppendingString:value]);
        Check(IPv6(@"2606:4700:4700::1111"), @"globally routed IPv6 is accepted");
        for (NSString *value in @[@"::", @"::1", @"fe80::1", @"fc00::1", @"fd12::1",
                                    @"ff02::1", @"2001:db8::1", @"::ffff:127.0.0.1", @"::ffff:192.168.1.1",
                                    @"::127.0.0.1", @"64:ff9b::192.168.1.1"])
            Check(!IPv6(value), [@"private/local IPv6 rejected: " stringByAppendingString:value]);

        NSArray<NSString *> *allowed = @[@"https://reddit.com/a", @"https://oauth.reddit.com/a",
            @"https://i.redd.it/a", @"https://v.redd.it/a", @"https://preview.redd.it/a",
            @"https://cdn.redditmedia.com/a", @"https://x.reddituploads.com/a",
            @"https://imgur.com/a", @"https://i.imgur.com/a", @"https://imgchest.com/a",
            @"https://cdn.imgchest.com/a"];
        for (NSString *value in allowed) Check(ApolloMediaURLHasAllowedHTTPSHost([NSURL URLWithString:value]), [@"approved media host: " stringByAppendingString:value]);
        for (NSString *value in @[@"http://i.redd.it/a", @"https://redd.it.evil.test/a",
            @"https://evilreddit.com/a", @"https://imgur.com.evil.test/a", @"https://fakeimgchest.com/a",
            @"https://cdn.example/a", @"file:///tmp/media"])
            Check(!ApolloMediaURLHasAllowedHTTPSHost([NSURL URLWithString:value]), [@"unapproved/downgraded host: " stringByAppendingString:value]);

        Check(ApolloMediaExpectedLengthFits(100, 100, 200, 100), @"exact advertised limit succeeds");
        Check(!ApolloMediaExpectedLengthFits(101, 100, 1000, 100), @"oversize advertisement fails");
        Check(!ApolloMediaExpectedLengthFits(50, 100, 149, 100), @"free-space reserve includes advertised body");
        Check(ApolloMediaByteRangeFits(60, 40, 100), @"exact streamed limit succeeds");
        Check(!ApolloMediaByteRangeFits(60, 41, 100), @"streamed overrun fails");
        unsigned long long muxMaximum = 0;
        unsigned long long MiB = 1024ULL * 1024ULL;
        Check(ApolloMediaMuxOutputBudget(40 * MiB, 40 * MiB, 196 * MiB, 100 * MiB, &muxMaximum) && muxMaximum == 96 * MiB,
              @"mux budget retains inputs plus minimum overhead and exact reserve");
        Check(!ApolloMediaMuxOutputBudget(40 * MiB, 40 * MiB, 196 * MiB - 1, 100 * MiB, &muxMaximum), @"mux budget rejects one byte below reserve");
        Check(!ApolloMediaMuxOutputBudget(ULLONG_MAX, 1, ULLONG_MAX, 0, &muxMaximum), @"mux budget rejects overflow");
        NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [@"1234" writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
        Check(ApolloMediaOutputFileFits(outputURL, 4, 0), @"exact mux output limit succeeds");
        Check(!ApolloMediaOutputFileFits(outputURL, 3, 0), @"mux output overrun fails");
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

        ApolloBoundedMediaDownload *redirect = [ApolloBoundedMediaDownload new];
        NSURLSession *dummySession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        NSURLSessionTask *dummyTask = [dummySession dataTaskWithURL:[NSURL URLWithString:@"https://1.1.1.1/"]];
        NSHTTPURLResponse *redirectResponse = [[NSHTTPURLResponse alloc]
            initWithURL:[NSURL URLWithString:@"https://8.8.8.8/"] statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        __block NSURLRequest *accepted = nil;
        [redirect URLSession:dummySession task:dummyTask willPerformHTTPRedirection:redirectResponse
                  newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://cdn.example/video.mp4"]]
            completionHandler:^(NSURLRequest *request) { accepted = request; }];
        Check(accepted == nil, @"public-address redirect to unapproved CDN rejected");
        accepted = (id)[NSNull null];
        [redirect URLSession:dummySession task:dummyTask willPerformHTTPRedirection:redirectResponse
                  newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://i.redd.it/video.mp4"]]
            completionHandler:^(NSURLRequest *request) { accepted = request; }];
        Check(accepted == nil, @"HTTPS redirect downgrade rejected");
        [dummySession invalidateAndCancel];

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [@"partial" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSURL *partial = [NSURL fileURLWithPath:path];
        ApolloBoundedMediaDownload *finished = [ApolloBoundedMediaDownload new];
        dispatch_queue_t queue = dispatch_queue_create("media-security-test", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t landed = dispatch_semaphore_create(0);
        __block NSUInteger completions = 0;
        finished.completionQueue = queue;
        finished.completedFile = partial;
        finished.completion = ^(__unused NSURL *file, __unused NSHTTPURLResponse *response, __unused NSError *failure) {
            completions++;
            dispatch_semaphore_signal(landed);
        };
        NSError *cancelled = ApolloMediaSecurityError(NSURLErrorCancelled, @"cancelled");
        [finished finishWithFile:nil error:cancelled];
        [finished finishWithFile:nil error:cancelled];
        Check(dispatch_semaphore_wait(landed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"completion delivered");
        dispatch_sync(queue, ^{});
        Check(completions == 1, @"completion delivered exactly once");
        Check(![[NSFileManager defaultManager] fileExistsAtPath:path], @"failed transfer cleans partial file");

        printf("media_security_tests: all %lu checks passed\n", (unsigned long)sChecks);
    }
    return 0;
}
