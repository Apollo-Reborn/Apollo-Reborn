#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL sTestRunsAsIOSAppOnMac = NO;
static BOOL sTestRunsAsMacCatalystApp = NO;

static BOOL ApolloVFTestPlatformSelector(__unused id self, SEL selector) {
    if (selector == NSSelectorFromString(@"isiOSAppOnMac")) return sTestRunsAsIOSAppOnMac;
    if (selector == NSSelectorFromString(@"isMacCatalystApp")) return sTestRunsAsMacCatalystApp;
    return NO;
}

static void ApolloVFSetTestPlatform(NSString *mode) {
    sTestRunsAsIOSAppOnMac = [mode isEqualToString:@"native"];
    sTestRunsAsMacCatalystApp = [mode isEqualToString:@"catalyst"];
    id processInfo = [NSProcessInfo processInfo];
    Class concreteClass = object_getClass(processInfo);
    for (NSString *selectorName in @[ @"isiOSAppOnMac", @"isMacCatalystApp" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        Method method = class_getInstanceMethod(concreteClass, selector);
        if (method) {
            method_setImplementation(method, (IMP)ApolloVFTestPlatformSelector);
        } else {
            class_addMethod(concreteClass, selector, (IMP)ApolloVFTestPlatformSelector, "c@:");
        }
    }
}

NSNotificationName const UIApplicationWillResignActiveNotification = @"ApolloVFTestWillResignActive";
NSNotificationName const UIApplicationDidBecomeActiveNotification = @"ApolloVFTestDidBecomeActive";
NSNotificationName const UIWindowDidResignKeyNotification = @"ApolloVFTestWindowDidResignKey";
NSNotificationName const UIWindowDidBecomeKeyNotification = @"ApolloVFTestWindowDidBecomeKey";

@interface ASDisplayNode : NSObject {
    BOOL _displaysAsynchronously;
    NSUInteger _synchronousFlushCount;
}
@property (nonatomic) BOOL displaysAsynchronously;
@property (nonatomic) NSUInteger synchronousFlushCount;
- (void)didEnterHierarchy;
- (void)didExitHierarchy;
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)synchronous;
@end

@implementation ASDisplayNode
- (instancetype)init {
    self = [super init];
    if (self) _displaysAsynchronously = YES;
    return self;
}
- (void)didEnterHierarchy {}
- (void)didExitHierarchy {}
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)synchronous {
    if (synchronous) self.synchronousFlushCount++;
}
@synthesize displaysAsynchronously = _displaysAsynchronously;
@synthesize synchronousFlushCount = _synchronousFlushCount;
@end

@interface ASTextNode : ASDisplayNode @end
@implementation ASTextNode @end

@interface ASTextNode2 : ASDisplayNode @end
@implementation ASTextNode2 @end

@interface ASImageNode : ASDisplayNode @end
@implementation ASImageNode @end

@interface ApolloVFPlainNode : ASDisplayNode @end
@implementation ApolloVFPlainNode @end

static NSUInteger sDiagnosticCount = 0;
#define ApolloLog(...) do { sDiagnosticCount++; } while (0)

#if APOLLO_VF_TEST_SUBSTRATE
void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    NSCAssert(method != NULL, @"test hook target must exist");
    if (original) *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}
#endif

// PRODUCTION_MAC_TEXTURE_SYNC

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
    NSLog(@"PASS: %@", message);
}

static void DrainFocusFlushes(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.22];
    while ([deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Require(argc == 2, @"runner supplies exactly one platform mode");
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        BOOL runsOnMac = [mode isEqualToString:@"native"] || [mode isEqualToString:@"catalyst"];
        ApolloVFSetTestPlatform(mode);

        ASTextNode *text = [ASTextNode new];
        ASTextNode2 *text2 = [ASTextNode2 new];
        ASImageNode *image = [ASImageNode new];
        ASTextNode *departed = [ASTextNode new];
        ApolloVFPlainNode *plain = [ApolloVFPlainNode new];

        Require(text.displaysAsynchronously && text2.displaysAsynchronously &&
                image.displaysAsynchronously && departed.displaysAsynchronously &&
                plain.displaysAsynchronously,
                @"baseline Texture doubles default every node to asynchronous display");

        ApolloVFInstallMacTextureSyncIfNeeded();
        [text didEnterHierarchy];
        [text2 didEnterHierarchy];
        [image didEnterHierarchy];
        [departed didEnterHierarchy];
        [departed didExitHierarchy];
        [plain didEnterHierarchy];

        NSArray<NSNotificationName> *focusNotifications = @[
            UIApplicationWillResignActiveNotification,
            UIApplicationDidBecomeActiveNotification,
            UIWindowDidResignKeyNotification,
            UIWindowDidBecomeKeyNotification,
        ];
        for (NSNotificationName notificationName in focusNotifications) {
            NSUInteger before = text.synchronousFlushCount;
            [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:nil];
            DrainFocusFlushes();
            NSUInteger expected = runsOnMac ? before + 3 : before;
            Require(text.synchronousFlushCount == expected,
                    [NSString stringWithFormat:runsOnMac
                        ? @"%@ schedules exactly now/next/late Mac flushes"
                        : @"%@ causes no iOS flush", notificationName]);
        }

        Require(text.displaysAsynchronously && text2.displaysAsynchronously &&
                image.displaysAsynchronously && departed.displaysAsynchronously &&
                plain.displaysAsynchronously,
                @"focus guard never changes normal asynchronous display policy");

        if (runsOnMac) {
            Require(text.synchronousFlushCount == 12, @"Mac ASTextNode is tracked and flushed");
            Require(text2.synchronousFlushCount == 12, @"Mac ASTextNode2 is tracked and flushed");
            Require(image.synchronousFlushCount == 12, @"Mac ASImageNode is tracked and flushed");
            Require(departed.synchronousFlushCount == 0,
                    @"Mac target leaf is removed when it exits the hierarchy");
            Require(plain.synchronousFlushCount == 0, @"Mac non-target node is excluded");
            Require(sDiagnosticCount == 1, @"Mac installation emits one diagnostic");
        } else {
            Require(text.synchronousFlushCount == 0 && text2.synchronousFlushCount == 0 &&
                    image.synchronousFlushCount == 0 && departed.synchronousFlushCount == 0 &&
                    plain.synchronousFlushCount == 0,
                    @"iOS path installs no tracker and performs no focus flushes");
            Require(sDiagnosticCount == 0, @"non-Mac path emits no Mac diagnostic");
        }
    }
    return 0;
}
