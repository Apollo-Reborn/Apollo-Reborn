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

NSNotificationName const UISceneWillDeactivateNotification = @"ApolloVFTestSceneWillDeactivate";
NSNotificationName const UISceneDidActivateNotification = @"ApolloVFTestSceneDidActivate";
NSNotificationName const UIApplicationWillResignActiveNotification = @"ApolloVFTestWillResignActive";
NSNotificationName const UIApplicationDidBecomeActiveNotification = @"ApolloVFTestDidBecomeActive";
NSNotificationName const UIWindowDidResignKeyNotification = @"ApolloVFTestWindowDidResignKey";
NSNotificationName const UIWindowDidBecomeKeyNotification = @"ApolloVFTestWindowDidBecomeKey";

@interface UIScene : NSObject @end
@implementation UIScene @end

@interface UIWindowScene : UIScene @end
@implementation UIWindowScene @end

@class UIWindow;

@interface UIView : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) CGRect bounds;
@property (nonatomic) CGRect convertedFrame;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
@end
@implementation UIView
- (instancetype)init {
    self = [super init];
    if (self) {
        _alpha = 1.0;
        _bounds = CGRectMake(0, 0, 10, 10);
        _convertedFrame = _bounds;
    }
    return self;
}
- (CGRect)convertRect:(__unused CGRect)rect toView:(__unused UIView *)view {
    return self.convertedFrame;
}
@end

@interface UIWindow : UIView
@property (nonatomic, strong) UIWindowScene *windowScene;
@end
@implementation UIWindow @end

@interface ASDisplayNode : NSObject {
    BOOL _displaysAsynchronously;
    BOOL _nodeLoaded;
    NSUInteger _synchronousFlushCount;
    UIView *_view;
}
@property (nonatomic) BOOL displaysAsynchronously;
@property (nonatomic, getter=isNodeLoaded) BOOL nodeLoaded;
@property (nonatomic) NSUInteger synchronousFlushCount;
@property (nonatomic, strong) UIView *view;
- (void)didEnterHierarchy;
- (void)didExitHierarchy;
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)synchronous;
@end

@implementation ASDisplayNode
- (instancetype)init {
    self = [super init];
    if (self) {
        _displaysAsynchronously = YES;
        _nodeLoaded = YES;
        _view = [UIView new];
    }
    return self;
}
- (void)didEnterHierarchy {}
- (void)didExitHierarchy {}
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)synchronous {
    if (synchronous) self.synchronousFlushCount++;
}
@synthesize displaysAsynchronously = _displaysAsynchronously;
@synthesize nodeLoaded = _nodeLoaded;
@synthesize synchronousFlushCount = _synchronousFlushCount;
@synthesize view = _view;
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

static Class ApolloClassASTextNode, ApolloClassASTextNode2, ApolloClassASImageNode;
__attribute__((constructor)) static void TextureSyncTestResolveClasses(void) {
    ApolloClassASTextNode = objc_getClass("ASTextNode");
    ApolloClassASTextNode2 = objc_getClass("ASTextNode2");
    ApolloClassASImageNode = objc_getClass("ASImageNode");
}
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
        Require([@[ @"ios", @"native", @"catalyst" ] containsObject:mode],
                @"platform mode is recognized");
        BOOL runsOnMac = [mode isEqualToString:@"native"] || [mode isEqualToString:@"catalyst"];
        ApolloVFSetTestPlatform(mode);

        UIWindowScene *primaryScene = [UIWindowScene new];
        UIWindow *primaryWindow = [UIWindow new];
        primaryWindow.windowScene = primaryScene;
        primaryWindow.bounds = CGRectMake(0, 0, 100, 100);
        UIWindowScene *secondaryScene = [UIWindowScene new];
        UIWindow *secondaryWindow = [UIWindow new];
        secondaryWindow.windowScene = secondaryScene;
        secondaryWindow.bounds = CGRectMake(0, 0, 100, 100);

        ASTextNode *text = [ASTextNode new];
        ASTextNode2 *text2 = [ASTextNode2 new];
        ASImageNode *image = [ASImageNode new];
        ASTextNode *departed = [ASTextNode new];
        ASTextNode *offscreen = [ASTextNode new];
        ASTextNode *preloadedOffscreen = [ASTextNode new];
        ASTextNode *unloaded = [ASTextNode new];
        ASTextNode *otherScene = [ASTextNode new];
        ApolloVFPlainNode *plain = [ApolloVFPlainNode new];
        for (ASDisplayNode *node in @[ text, text2, image, departed, plain ]) {
            node.view.window = primaryWindow;
        }
        preloadedOffscreen.view.window = primaryWindow;
        preloadedOffscreen.view.convertedFrame = CGRectMake(200, 200, 10, 10);
        unloaded.nodeLoaded = NO;
        otherScene.view.window = secondaryWindow;

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
        [offscreen didEnterHierarchy];
        [preloadedOffscreen didEnterHierarchy];
        [unloaded didEnterHierarchy];
        [otherScene didEnterHierarchy];
        [plain didEnterHierarchy];

        NSArray<NSArray *> *focusNotifications = @[
            @[ UISceneWillDeactivateNotification, primaryScene ],
            @[ UISceneDidActivateNotification, primaryScene ],
            @[ UIApplicationWillResignActiveNotification, [NSNull null] ],
            @[ UIApplicationDidBecomeActiveNotification, [NSNull null] ],
            @[ UIWindowDidResignKeyNotification, primaryWindow ],
            @[ UIWindowDidBecomeKeyNotification, primaryWindow ],
        ];
        for (NSArray *entry in focusNotifications) {
            NSNotificationName notificationName = entry[0];
            id object = entry[1] == [NSNull null] ? nil : entry[1];
            NSUInteger before = text.synchronousFlushCount;
            [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:object];
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
            Require(text.synchronousFlushCount == 18, @"Mac ASTextNode is tracked and flushed");
            Require(text2.synchronousFlushCount == 18, @"Mac ASTextNode2 is tracked and flushed");
            Require(image.synchronousFlushCount == 18, @"Mac ASImageNode is tracked and flushed");
            Require(departed.synchronousFlushCount == 0,
                    @"Mac target leaf is removed when it exits the hierarchy");
            Require(offscreen.synchronousFlushCount == 0,
                    @"Mac detached target leaf is never forced to display");
            Require(preloadedOffscreen.synchronousFlushCount == 0,
                    @"Mac attached off-screen preload leaf is never forced to display");
            Require(unloaded.synchronousFlushCount == 0,
                    @"Mac unloaded target leaf is never forced to display");
            Require(otherScene.synchronousFlushCount == 6,
                    @"Mac scene/window focus events do not flush another scene");
            Require(plain.synchronousFlushCount == 0, @"Mac non-target node is excluded");
            Require(sDiagnosticCount == 1, @"Mac installation emits one diagnostic");
        } else {
            Require(text.synchronousFlushCount == 0 && text2.synchronousFlushCount == 0 &&
                    image.synchronousFlushCount == 0 && departed.synchronousFlushCount == 0 &&
                    offscreen.synchronousFlushCount == 0 &&
                    preloadedOffscreen.synchronousFlushCount == 0 && unloaded.synchronousFlushCount == 0 &&
                    otherScene.synchronousFlushCount == 0 && plain.synchronousFlushCount == 0,
                    @"iOS path installs no tracker and performs no focus flushes");
            Require(sDiagnosticCount == 0, @"non-Mac path emits no Mac diagnostic");
        }

        if (runsOnMac) {
            NSUInteger before = text.synchronousFlushCount;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UISceneWillDeactivateNotification object:primaryScene];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIApplicationWillResignActiveNotification object:nil];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIWindowDidResignKeyNotification object:primaryWindow];
            DrainFocusFlushes();
            Require(text.synchronousFlushCount == before + 3,
                    @"duplicate notifications coalesce into one staged focus sequence");
        }
    }
    return 0;
}
