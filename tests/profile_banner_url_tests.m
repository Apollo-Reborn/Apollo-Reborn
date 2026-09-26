#import <Foundation/Foundation.h>
#import "ApolloProfileBannerURL.h"

static NSUInteger checks;
static void Check(BOOL ok, NSString *label) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
    checks++;
}
// Download/decode doubles exercise the production cache method without UIKit/network.
@interface UIImage : NSObject
+ (instancetype)imageWithData:(NSData *)data;
@end
@implementation UIImage
+ (instancetype)imageWithData:(NSData *)data {
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqual:@"image"] ? [self new] : nil;
}
@end
static UIImage *ApolloDownscaledBannerImage(UIImage *image) { return image; }
static BOOL ApolloImageHasAlphaChannel(UIImage *image) { return NO; }
static NSData *UIImagePNGRepresentation(UIImage *image) { return [@"image" dataUsingEncoding:NSUTF8StringEncoding]; }
static NSData *UIImageJPEGRepresentation(UIImage *image, double quality) { return UIImagePNGRepresentation(image); }
static BOOL ApolloUserProfileErrorIsTransient(NSError *error) { return error.code == NSURLErrorCancelled || error.code == NSURLErrorTimedOut; }
#define ApolloLog(...) do {} while (0)
@interface BannerTask : NSObject
@property(copy) void (^run)(void);
- (void)resume;
@end
@implementation BannerTask
- (void)resume { self.run(); }
@end
@interface BannerSession : NSObject
@property NSArray<NSDictionary *> *results;
@property NSMutableArray<NSURL *> *urls;
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
@end
@implementation BannerSession
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    NSUInteger i = self.urls.count;
    Check(i < self.results.count, @"bounded request count");
    [self.urls addObject:url];
    NSDictionary *result = self.results[i];
    BannerTask *task = [BannerTask new];
    task.run = ^{
        NSData *data = [result[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *http = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:[result[@"status"] integerValue] HTTPVersion:@"HTTP/1.1" headerFields:nil];
        completion(data, http, result[@"error"]);
    };
    return (id)task;
}
@end
@interface BannerCache : NSObject
@property BannerSession *imageSession;
@property dispatch_queue_t queue;
@property dispatch_queue_t imageIOQueue;
@property NSMutableDictionary *imageNotFoundDates;
@property NSUInteger finishes;
@property BOOL succeeded;
- (void)downloadBannerImageForURL:(NSURL *)url fallbackURL:(NSURL *)fallbackURL key:(NSString *)key;
@end
@implementation BannerCache
- (void)persistImageData:(NSData *)data forKey:(NSString *)key {}
- (void)finishBannerImageRequestForKey:(NSString *)key image:(UIImage *)image { self.finishes++; self.succeeded = image != nil; }
// INSERT_PRODUCTION_DOWNLOAD_METHOD
@end

static void Download(NSArray *results, BOOL fallback, NSUInteger requests, BOOL success, BOOL negativeCache) {
    BannerCache *cache = [BannerCache new];
    cache.queue = dispatch_queue_create("banner-test-state", DISPATCH_QUEUE_SERIAL);
    cache.imageIOQueue = dispatch_queue_create("banner-test-io", DISPATCH_QUEUE_SERIAL);
    cache.imageNotFoundDates = [NSMutableDictionary dictionary];
    cache.imageSession = [BannerSession new]; cache.imageSession.results = results; cache.imageSession.urls = [NSMutableArray array];
    NSURL *candidate = [NSURL URLWithString:@"https://styles.redditmedia.com/t5_demo/styles/profileBanner_a.jpg"];
    NSURL *supplied = [NSURL URLWithString:[candidate.absoluteString stringByAppendingString:@"?width=1280&height=384&crop=smart&s=abc"]];
    [cache downloadBannerImageForURL:candidate fallbackURL:fallback ? supplied : nil key:@"key"];
    dispatch_sync(cache.queue, ^{}); dispatch_sync(cache.imageIOQueue, ^{});
    Check(cache.imageSession.urls.count == requests, @"request count");
    Check(cache.finishes == 1 && cache.succeeded == success, @"exactly one final completion");
    Check((cache.imageNotFoundDates[@"key"] != nil) == negativeCache, @"negative cache only for final permanent failure");
    if (requests == 2) Check([cache.imageSession.urls.lastObject isEqual:supplied], @"fallback preserves supplied query");
}
int main(void) { @autoreleasepool {
    NSString *base = @"https://styles.redditmedia.com/t5_demo/styles/profileBanner_a.jpg";
    for (NSString *query in @[@"width=1280&height=384&crop=smart&s=abc", @"width=1280&auto=webp&format=pjpg&s=abc", @"height=384", @"crop=smart"]) {
        NSURL *url = [NSURL URLWithString:[base stringByAppendingFormat:@"?%@", query]];
        Check([ApolloProfileBannerOriginalCandidate(url).absoluteString isEqual:base], @"known crop candidate");
    }
    for (NSString *suffix in @[@"", @"?token=secret&width=1280", @"?v=2&width=1280", @"?s=abc", @"?auto=webp", @"?width=1280&expires=42", @"?Width=1280"]) {
        NSURL *url = [NSURL URLWithString:[base stringByAppendingString:suffix]];
        Check([ApolloProfileBannerOriginalCandidate(url) isEqual:url], @"unknown or non-crop query unchanged");
    }
    for (NSString *text in @[@"https://example.com/t5_demo/styles/profileBanner_a.jpg?width=1280", @"http://styles.redditmedia.com/t5_demo/styles/profileBanner_a.jpg?width=1280", @"https://styles.redditmedia.com/t5_demo/styles/communityIcon_a.jpg?width=1280", @"https://styles.redditmedia.com:8443/t5_demo/styles/profileBanner_a.jpg?width=1280", @"https://user:pass@styles.redditmedia.com/t5_demo/styles/profileBanner_a.jpg?width=1280"]) {
        NSURL *url = [NSURL URLWithString:text]; Check([ApolloProfileBannerOriginalCandidate(url) isEqual:url], @"other URL unchanged");
    }
    NSDictionary *ok = @{@"status":@200, @"body":@"image"};
    NSDictionary *missing = @{@"status":@404, @"body":@"image"};
    NSDictionary *invalid = @{@"status":@200, @"body":@"html"};
    Download(@[ok], YES, 1, YES, NO);
    Download(@[missing, ok], YES, 2, YES, NO);
    Download(@[invalid, ok], YES, 2, YES, NO);
    Download(@[missing, missing], YES, 2, NO, YES);
    Download(@[missing], NO, 1, NO, YES);
    Download(@[@{@"status":@0, @"error":[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]}], YES, 1, NO, NO);
    Download(@[missing, @{@"status":@503}], YES, 2, NO, NO);
    printf("PASS: %lu profile banner checks\n", (unsigned long)checks);
} }
