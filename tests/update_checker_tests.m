#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ApolloUpdateManifest.h"
#import "ApolloUpdateManifestCache.h"
#import "ApolloUpdateChecker.h"

// The production coordinator is inserted below. Doubles capture only external
// effects so the assertions exercise the actual fetch/prompt/throttle code.
static int sFailures;
static NSTimeInterval sNow = 1800000000;
static NSUserDefaults *sDefaults;
static NSString *sFixtureDirectory;

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        sFailures++; \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
    } \
} while (0)

@interface NSDate (CheckerFixture)
+ (NSDate *)checkerFixtureDate;
- (NSTimeInterval)checkerFixtureTimeIntervalSinceNow;
@end
@implementation NSDate (CheckerFixture)
+ (NSDate *)checkerFixtureDate { return [NSDate dateWithTimeIntervalSince1970:sNow]; }
- (NSTimeInterval)checkerFixtureTimeIntervalSinceNow { return self.timeIntervalSince1970 - sNow; }
@end

@interface NSUserDefaults (CheckerFixture)
+ (NSUserDefaults *)checkerFixtureDefaults;
@end
@implementation NSUserDefaults (CheckerFixture)
+ (NSUserDefaults *)checkerFixtureDefaults { return sDefaults; }
@end

@interface ApolloUpdateManifestCache (CheckerFixture)
- (instancetype)initCheckerFixture;
@end
@implementation ApolloUpdateManifestCache (CheckerFixture)
- (instancetype)initCheckerFixture {
    return [self initWithFileURL:[NSURL fileURLWithPath:[sFixtureDirectory stringByAppendingPathComponent:@"manifest.plist"]]];
}
@end

@interface FixtureEvent : NSObject
@property NSTimeInterval due;
@property (copy) dispatch_block_t block;
@end
@implementation FixtureEvent
@end
static NSMutableArray<FixtureEvent *> *sEvents;

static void FixtureEnqueue(NSTimeInterval due, dispatch_block_t block) {
    FixtureEvent *event = [FixtureEvent new];
    event.due = due;
    event.block = block;
    [sEvents addObject:event];
}

static void Advance(NSTimeInterval seconds) {
    NSTimeInterval destination = sNow + seconds;
    NSUInteger count = 0;
    while (YES) {
        FixtureEvent *next = nil;
        for (FixtureEvent *event in sEvents) {
            if (event.due <= destination && (!next || event.due < next.due)) next = event;
        }
        if (!next) break;
        NSCAssert(++count < 1000, @"runaway fixture scheduling");
        [sEvents removeObjectIdenticalTo:next];
        sNow = next.due;
        next.block();
    }
    sNow = destination;
}

static void FixtureDispatchAsync(dispatch_queue_t queue, dispatch_block_t block) {
    (void)queue;
    block();
}
static dispatch_time_t FixtureDispatchTime(dispatch_time_t when, int64_t delta) {
    (void)when;
    return (dispatch_time_t)(sNow * NSEC_PER_SEC) + delta;
}
static void FixtureDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)queue;
    FixtureEnqueue((NSTimeInterval)when / NSEC_PER_SEC, block);
}

@interface FixtureTimer : NSObject
@property NSTimeInterval interval;
@property NSTimeInterval tolerance;
@property BOOL repeats;
@property BOOL valid;
@property (copy) void (^callback)(FixtureTimer *);
+ (instancetype)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(FixtureTimer *))block;
- (void)invalidate;
- (void)fixtureSchedule;
@end
@implementation FixtureTimer
+ (instancetype)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(FixtureTimer *))block {
    FixtureTimer *timer = [self new];
    timer.interval = interval;
    timer.repeats = repeats;
    timer.callback = block;
    timer.valid = YES;
    return timer;
}
- (void)invalidate { self.valid = NO; }
- (void)fixtureSchedule {
    FixtureEnqueue(sNow + self.interval, ^{
        if (!self.valid) return;
        if (!self.repeats) self.valid = NO;
        self.callback(self);
        if (self.repeats && self.valid) [self fixtureSchedule];
    });
}
@end

@interface FixtureRunLoop : NSObject
+ (instancetype)mainRunLoop;
- (void)addTimer:(FixtureTimer *)timer forMode:(NSRunLoopMode)mode;
@end
@implementation FixtureRunLoop
+ (instancetype)mainRunLoop { static FixtureRunLoop *loop; if (!loop) loop = [self new]; return loop; }
- (void)addTimer:(FixtureTimer *)timer forMode:(NSRunLoopMode)mode { (void)mode; [timer fixtureSchedule]; }
@end

typedef NS_ENUM(NSInteger, UIApplicationState) { UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground };
static NSString *const UIApplicationWillResignActiveNotification = @"FixtureWillResignActive";
static NSString *const UIApplicationDidEnterBackgroundNotification = @"FixtureDidEnterBackground";
static NSString *const UIApplicationDidBecomeActiveNotification = @"FixtureDidBecomeActive";
@interface UIApplication : NSObject
@property UIApplicationState applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
@end

@interface UIViewController : NSObject
@property BOOL isBeingPresented;
@property BOOL isBeingDismissed;
@property (strong) UIViewController *presentedViewController;
@property (strong) UIViewController *presentingViewController;
@property (strong) UIViewController *parentViewController;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(dispatch_block_t)completion;
@end
static NSUInteger sAlerts;
@implementation UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(dispatch_block_t)completion {
    (void)controller; (void)animated;
    sAlerts++;
    if (completion) completion();
}
@end

@interface UIWindow : NSObject
@property BOOL isKeyWindow;
@property (strong) UIViewController *fixtureController;
- (UIViewController *)visibleViewController;
@end
@implementation UIWindow
- (UIViewController *)visibleViewController { return self.fixtureController; }
@end
static UIWindow *sWindow;
static NSArray<UIWindow *> *ApolloAllWindows(void) { return @[sWindow]; }

enum { UIAlertControllerStyleAlert, UIAlertActionStyleDefault };
@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler {
    (void)title; (void)style; (void)handler; return [self new];
}
@end
@interface UIAlertController : UIViewController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style {
    (void)title; (void)message; (void)style; return [self new];
}
- (void)addAction:(UIAlertAction *)action { (void)action; }
@end

@interface ApolloUpdatePromptViewController : UIViewController
@property (copy) dispatch_block_t onSkip;
@property (copy) dispatch_block_t onLater;
@property (strong) ApolloUpdateInfo *info;
@property BOOL offerSkip;
- (instancetype)initWithInfo:(ApolloUpdateInfo *)info installedVersion:(NSString *)installedVersion offerSkip:(BOOL)offerSkip;
- (void)presentOverViewController:(UIViewController *)presenter;
@end
static NSMutableArray<ApolloUpdatePromptViewController *> *sSheets;
@implementation ApolloUpdatePromptViewController
- (instancetype)initWithInfo:(ApolloUpdateInfo *)info installedVersion:(NSString *)installedVersion offerSkip:(BOOL)offerSkip {
    (void)installedVersion;
    if ((self = [super init])) { self.info = info; self.offerSkip = offerSkip; }
    return self;
}
- (void)presentOverViewController:(UIViewController *)presenter { (void)presenter; [sSheets addObject:self]; }
@end

typedef void (^FixtureResponse)(NSData *, NSURLResponse *, NSError *);
@interface FixtureDataTask : NSObject
@property (strong) NSURLRequest *request;
@property (copy) FixtureResponse completion;
- (void)resume;
@end
static NSMutableArray<FixtureDataTask *> *sRequests;
static NSMutableArray<FixtureDataTask *> *sInFlight;
@implementation FixtureDataTask
- (void)resume { [sRequests addObject:self]; [sInFlight addObject:self]; }
@end
@interface FixtureSession : NSObject
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (FixtureDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureResponse)completion;
- (FixtureDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(FixtureResponse)completion;
- (void)finishTasksAndInvalidate;
@end
@implementation FixtureSession
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration { (void)configuration; return [self new]; }
- (FixtureDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureResponse)completion {
    FixtureDataTask *task = [FixtureDataTask new]; task.request = request; task.completion = completion; return task;
}
- (FixtureDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(FixtureResponse)completion {
    return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:completion];
}
- (void)finishTasksAndInvalidate {}
@end

static NSString *ApolloBuildVariant(void) { return @"ipa"; }
static NSString *ApolloBundledResourcePath(NSString *name, NSString *extension) { (void)name; (void)extension; return nil; }
static void ApolloLog(NSString *format, ...) { (void)format; }
static NSString *const UDKeyAutomaticUpdateChecks = @"AutomaticUpdateChecks";
static NSString *const UDKeyUpdateLastCheck = @"UpdateLastCheck";
static NSString *const UDKeyUpdateLastFailure = @"UpdateLastFailure";
static NSString *const UDKeyUpdateSkippedVersion = @"UpdateSkippedVersion";
static NSString *const UDKeyUpdateDeferredReminder = @"UpdateDeferredReminder";
static NSString *const UDKeyLastSeenWhatsNewVersion = @"LastSeenWhatsNewVersion";
#define TWEAK_VERSION "3.9.0"
#define APOLLO_SIM_BUILD 0
#define NSURLSession FixtureSession
#define NSTimer FixtureTimer
#define NSRunLoop FixtureRunLoop
#define dispatch_async FixtureDispatchAsync
#define dispatch_time FixtureDispatchTime
#define dispatch_after FixtureDispatchAfter
// INSERT_PRODUCTION_CHECKER
#undef NSURLSession
#undef NSTimer
#undef NSRunLoop
#undef dispatch_async
#undef dispatch_time
#undef dispatch_after

static NSDictionary *Manifest(NSString *version) {
    return @{
        @"release": @{@"tweakVersion": version, @"url": @"https://example.com/release"},
        @"variants": @{@"standard": @{@"sourceURL": @"https://example.com/apps.json", @"directDownloadURL": @"https://example.com/Apollo.ipa"}},
    };
}

static void Complete(NSString *version) {
    CHECK(sInFlight.count == 1, @"one request expected, got %lu", (unsigned long)sInFlight.count);
    FixtureDataTask *task = sInFlight.firstObject;
    if (!task) return;
    [sInFlight removeObjectAtIndex:0];
    NSData *data = version ? [NSJSONSerialization dataWithJSONObject:Manifest(version) options:0 error:NULL] : nil;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:version ? 200 : 503 HTTPVersion:@"HTTP/1.1" headerFields:@{@"ETag": @"\"fixture-release\""}];
    task.completion(data, response, nil);
    Advance(0);
}

static void SetActive(BOOL active) {
    UIApplication.sharedApplication.applicationState = active ? UIApplicationStateActive : UIApplicationStateInactive;
    [[NSNotificationCenter defaultCenter] postNotificationName:active ? UIApplicationDidBecomeActiveNotification : UIApplicationWillResignActiveNotification object:nil];
    if (active) ApolloUpdateCheckIfNeeded();
}

static void TestCadence(void) {
    [sDefaults setObject:[NSDate dateWithTimeIntervalSince1970:sNow - 12 * 3600] forKey:UDKeyUpdateLastCheck];
    ApolloUpdateCheckIfNeeded();
    CHECK(sRequests.count == 1, @"9pm success must not suppress next 9am check");
    Complete(@"3.9.0");
    Advance(899);
    ApolloUpdateCheckIfNeeded();
    CHECK(sRequests.count == 1, @"repeated foreground within 15 minutes stays throttled");
    Advance(1);
    CHECK(sRequests.count == 2, @"check becomes due at 15 minutes");
}

static void TestActiveTimer(void) {
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.0");
    Advance(900);
    CHECK(sRequests.count == 2, @"active use polls again without foreground transition");
    Complete(@"3.9.0");
    Advance(900);
    CHECK(sRequests.count == 3, @"active polling reschedules after each result");
    Complete(@"3.9.0");
    SetActive(NO);
    CHECK(sCheckTimer == nil, @"resigning active invalidates the polling timer immediately");
    Advance(2 * 3600);
    CHECK(sRequests.count == 3, @"inactive app never polls");
    SetActive(YES);
    CHECK(sRequests.count == 4, @"overdue check resumes immediately on foreground");
}

static void TestFailureBackoff(void) {
    ApolloUpdateCheckIfNeeded();
    Complete(nil);
    NSDate *failed = [sDefaults objectForKey:UDKeyUpdateLastFailure];
    CHECK(failed != nil, @"failed request records retry time");
    CHECK([sDefaults objectForKey:UDKeyUpdateLastCheck] == nil, @"failure cannot claim successful check");
    for (NSUInteger n = 0; n < 3; n++) ApolloUpdateCheckIfNeeded();
    Advance(299);
    CHECK(sRequests.count == 1, @"repeated foreground and timer respect five minute failure backoff");
    Advance(1);
    CHECK(sRequests.count == 2, @"failed request retries after five minutes");
    Complete(@"3.9.0");
    CHECK([sDefaults objectForKey:UDKeyUpdateLastFailure] == nil, @"success clears failure backoff");
    Advance(899);
    CHECK(sRequests.count == 2, @"successful retry restores normal interval");
}

static void TestManualSharing(void) {
    [sDefaults setObject:[NSDate date] forKey:UDKeyUpdateLastCheck];
    __block NSUInteger firstCallbacks = 0;
    __block NSUInteger secondCallbacks = 0;
    ApolloUpdateCheckNow(^{ firstCallbacks++; });
    CHECK(sRequests.count == 1, @"manual check bypasses successful-check cooldown");
    ApolloUpdateCheckNow(^{ secondCallbacks++; });
    ApolloUpdateCheckIfNeeded();
    CHECK(sRequests.count == 1, @"concurrent checks share one manifest request");
    Complete(@"3.9.1");
    CHECK(firstCallbacks == 2 && secondCallbacks == 2, @"each manual caller receives start and finish");
    CHECK(sSheets.count == 1 && !sSheets.lastObject.offerSkip, @"shared request produces one manual update sheet");
    Advance(900);
    Complete(nil);
    ApolloUpdateCheckNow(nil);
    CHECK(sRequests.count == 3, @"manual check also bypasses failure backoff");
}

static void TestManualJoinsAutomatic(void) {
    ApolloUpdateCheckIfNeeded();
    __block NSUInteger callbacks = 0;
    ApolloUpdateCheckNow(^{ callbacks++; });
    CHECK(sRequests.count == 1, @"manual check joins an automatic request already in flight");
    Complete(@"3.9.1");
    CHECK(callbacks == 2 && sSheets.count == 1 && !sSheets.lastObject.offerSkip, @"joined request reports exactly one manual result");
}

static void TestManualInactive(void) {
    __block NSUInteger callbacks = 0;
    ApolloUpdateCheckNow(^{ callbacks++; });
    SetActive(NO);
    Complete(@"3.9.1");
    CHECK(callbacks == 2 && sSheets.count == 0, @"background manual completion finishes status without presenting UI");
    SetActive(YES);
    Advance(0);
    CHECK(sRequests.count == 1, @"foreground reuses completed manual request");
    CHECK(sSheets.count == 1, @"background manual completion cannot consume the automatic reminder");
}

static void TestDeferredPrompt(void) {
    sWindow.fixtureController.presentedViewController = [UIViewController new];
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    NSDate *success = [sDefaults objectForKey:UDKeyUpdateLastCheck];
    Advance(30);
    CHECK(sSheets.count == 0, @"automatic prompt waits for unobstructed UI");
    CHECK([[sDefaults objectForKey:UDKeyUpdateLastCheck] isEqual:success], @"exhausted prompt retries preserve successful check timestamp");
    sWindow.fixtureController.presentedViewController = nil;
    ApolloUpdateCheckIfNeeded();
    Advance(0);
    CHECK(sRequests.count == 1, @"retrying deferred prompt uses already fetched update");
    CHECK(sSheets.count == 1, @"available update prompts once base UI becomes available");
    ApolloUpdateCheckIfNeeded();
    Advance(30);
    CHECK(sSheets.count == 1, @"same version prompts at most once per launch");
}

static void TestInactive(void) {
    ApolloUpdateCheckIfNeeded();
    SetActive(NO);
    Complete(@"3.9.1");
    Advance(1800);
    CHECK(sRequests.count == 1 && sSheets.count == 0, @"background completion cannot schedule polling or present a sheet");
    SetActive(YES);
    Complete(@"3.9.1");
    CHECK(sSheets.count == 1, @"available update presents after returning active");
}

static void TestOptOut(void) {
    ApolloUpdateCheckIfNeeded();
    CHECK(sCheckTimer == nil, @"opting out cancels polling timer immediately");
    [sDefaults setBool:NO forKey:UDKeyAutomaticUpdateChecks];
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    Advance(1800);
    CHECK(sRequests.count == 1 && sSheets.count == 0, @"opt-out during request prevents auto prompt and future polling");
    ApolloUpdateCheckNow(nil);
    Complete(@"3.9.1");
    CHECK(sSheets.count == 1 && !sSheets.lastObject.offerSkip, @"manual checks still work with automatic checks disabled");
}

static void TestPendingPromptCancellation(void) {
    [sDefaults removeObjectForKey:UDKeyLastSeenWhatsNewVersion];
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    CHECK(sPromptPending && sSheets.count == 0, @"What's New schedules a delayed prompt");
    SetActive(NO);
    Advance(30);
    CHECK(sSheets.count == 0, @"resigning active cancels the pending prompt");
    SetActive(YES);
    CHECK(sPromptPending, @"foreground starts a replacement prompt chain");
    [sDefaults setBool:NO forKey:UDKeyAutomaticUpdateChecks];
    ApolloUpdateCheckIfNeeded();
    Advance(30);
    CHECK(sSheets.count == 0, @"opting out cancels a delayed prompt before presentation");
}

static void TestSkip(void) {
    [sDefaults setObject:@"3.9.1" forKey:UDKeyUpdateSkippedVersion];
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    CHECK(sSheets.count == 0, @"exact skipped release remains quiet");
    Advance(900);
    Complete(@"3.9.2");
    CHECK(sSheets.count == 1 && [sSheets.lastObject.info.version isEqual:@"3.9.2"], @"a newer release is not hidden by Skip This Version");
}

static void TestCachedRelaunch(void) {
    NSURL *url = [NSURL URLWithString:kUpdateManifestURL];
    NSData *data = [NSJSONSerialization dataWithJSONObject:Manifest(@"3.9.1") options:0 error:NULL];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"ETag": @"\"saved-release\""}];
    // Separate instance writes exactly the entry a previous process would leave.
    ApolloUpdateManifestCache *previousLaunchCache = [[ApolloUpdateManifestCache alloc] init];
    CHECK([previousLaunchCache infoForResponse:response data:data request:[NSURLRequest requestWithURL:url] variantKey:@"standard"] != nil, @"prime persisted cache");
    NSDate *success = [NSDate dateWithTimeIntervalSince1970:sNow - 60];
    [sDefaults setObject:success forKey:UDKeyUpdateLastCheck];
    ApolloUpdateCheckIfNeeded();
    Advance(0);
    CHECK(sRequests.count == 0, @"a relaunch reuses a recent cached manifest");
    CHECK(sSheets.count == 1, @"cached newer release still prompts after relaunch");
    CHECK([[sDefaults objectForKey:UDKeyUpdateLastCheck] isEqual:success], @"cache restoration does not extend request cooldown");
    Advance(840);
    CHECK(sRequests.count == 1, @"restored request becomes due at original successful-check deadline");
    CHECK([[sRequests.lastObject.request valueForHTTPHeaderField:@"If-None-Match"] isEqual:@"\"saved-release\""], @"persisted validator is used on next request");
}

static void TestLater(void) {
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    CHECK(sSheets.count == 1, @"first discovery prompts");
    NSDate *lastCheck = [sDefaults objectForKey:UDKeyUpdateLastCheck];
    sSheets.lastObject.onLater();
    NSDictionary *reminder = [sDefaults objectForKey:UDKeyUpdateDeferredReminder];
    CHECK([reminder[@"version"] isEqual:@"3.9.1"] && [reminder[@"date"] isEqual:[NSDate date]], @"Later persists version and time");
    CHECK([[sDefaults objectForKey:UDKeyUpdateLastCheck] isEqual:lastCheck], @"Later does not change network freshness");
    NSTimeInterval deferredAt = sNow;
    Advance(900);
    Complete(@"3.9.1");
    CHECK(sSheets.count == 1, @"polling continues without repeating a deferred reminder");
    SetActive(NO);
    sNow = deferredAt + 24 * 3600 - 1;
    SetActive(YES);
    Complete(@"3.9.1");
    CHECK(sSheets.count == 1, @"same version stays quiet for the full 24 hours");
    SetActive(NO);
    sNow = deferredAt + 24 * 3600;
    SetActive(YES);
    Advance(0);
    CHECK(sSheets.count == 2, @"Later reminder expires at 24 hours in the same process");
}

static void TestLaterRelaunch(void) {
    [sDefaults setObject:@{@"version": @"3.9.1", @"date": [NSDate dateWithTimeIntervalSince1970:sNow - 3600]} forKey:UDKeyUpdateDeferredReminder];
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    CHECK(sSheets.count == 0, @"saved Later state suppresses reminder in a fresh process");
    ApolloUpdateCheckNow(nil);
    Complete(@"3.9.1");
    CHECK(sSheets.count == 1 && !sSheets.lastObject.offerSkip, @"explicit manual check bypasses saved Later reminder");
}

static void TestLaterNewer(void) {
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    sSheets.lastObject.onLater();
    Advance(900);
    Complete(@"3.9.2");
    CHECK(sSheets.count == 2 && [sSheets.lastObject.info.version isEqual:@"3.9.2"], @"a different newer release bypasses the previous version's Later delay");
}

static void TestLaterOffline(void) {
    ApolloUpdateCheckIfNeeded();
    Complete(@"3.9.1");
    sSheets.lastObject.onLater();
    // Simulate an already expired persisted reminder while keeping the app
    // continuously active, so only its polling timer can discover the expiry.
    [sDefaults setObject:@{@"version": @"3.9.1", @"date": [NSDate dateWithTimeIntervalSince1970:sNow - 24 * 3600]} forKey:UDKeyUpdateDeferredReminder];
    Advance(900);
    Complete(nil);
    CHECK(sSheets.count == 2, @"failed refresh still reminds about the already validated cached update once Later expires");
    CHECK([sDefaults objectForKey:UDKeyUpdateLastFailure] != nil, @"showing a known update does not bypass failure backoff");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *suite = [@"ApolloUpdateCheckerTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        sDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        sFixtureDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:suite];
        [[NSFileManager defaultManager] createDirectoryAtPath:sFixtureDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        method_exchangeImplementations(class_getClassMethod(NSDate.class, @selector(date)), class_getClassMethod(NSDate.class, @selector(checkerFixtureDate)));
        method_exchangeImplementations(class_getInstanceMethod(NSDate.class, @selector(timeIntervalSinceNow)), class_getInstanceMethod(NSDate.class, @selector(checkerFixtureTimeIntervalSinceNow)));
        method_exchangeImplementations(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), class_getClassMethod(NSUserDefaults.class, @selector(checkerFixtureDefaults)));
        method_exchangeImplementations(class_getInstanceMethod(ApolloUpdateManifestCache.class, @selector(init)), class_getInstanceMethod(ApolloUpdateManifestCache.class, @selector(initCheckerFixture)));
        sEvents = [NSMutableArray array];
        sSheets = [NSMutableArray array];
        sRequests = [NSMutableArray array];
        sInFlight = [NSMutableArray array];
        sWindow = [UIWindow new];
        sWindow.isKeyWindow = YES;
        sWindow.fixtureController = [UIViewController new];
        [sDefaults setBool:YES forKey:UDKeyAutomaticUpdateChecks];
        [sDefaults setObject:@"3.9.0" forKey:UDKeyLastSeenWhatsNewVersion];
        NSDictionary<NSString *, dispatch_block_t> *scenarios = @{
            @"cadence": ^{ TestCadence(); }, @"active-timer": ^{ TestActiveTimer(); },
            @"failure-backoff": ^{ TestFailureBackoff(); }, @"manual-share": ^{ TestManualSharing(); },
            @"manual-joins-auto": ^{ TestManualJoinsAutomatic(); }, @"manual-inactive": ^{ TestManualInactive(); },
            @"prompt-deferred": ^{ TestDeferredPrompt(); }, @"inactive": ^{ TestInactive(); },
            @"opt-out": ^{ TestOptOut(); }, @"skip": ^{ TestSkip(); }, @"cached-relaunch": ^{ TestCachedRelaunch(); },
            @"later": ^{ TestLater(); }, @"later-relaunch": ^{ TestLaterRelaunch(); }, @"later-newer": ^{ TestLaterNewer(); },
            @"pending-cancel": ^{ TestPendingPromptCancellation(); }, @"later-offline": ^{ TestLaterOffline(); },
        };
        dispatch_block_t test = scenarios[@(argv[1])];
        if (!test) return 2;
        test();
        [sDefaults removePersistentDomainForName:suite];
        [[NSFileManager defaultManager] removeItemAtPath:sFixtureDirectory error:NULL];
        printf("update checker %s: %s\n", argv[1], sFailures ? "FAILED" : "passed");
    }
    return sFailures ? 1 : 0;
}
