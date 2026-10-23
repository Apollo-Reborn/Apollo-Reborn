#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import "ApolloGalleryFeed.h"
#import "ApolloSaveAllMediaItems.h"

static NSUInteger checks;
static NSUInteger saveCount;
static NSUInteger imageShareCount;
static NSURL *savedURL;
static NSURL *sharedURL;
static NSURL *routedURL;
static BOOL savedVideo;
static NSData *cachedOriginalData;
static NSData *exportedData;
static NSUInteger decodedLoadCount;
static NSUInteger networkRequestCount;
static NSUInteger errorToastCount;
static NSString *sUserAgent = @"GalleryTest/1.0";

static void Check(BOOL condition, NSString *description) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", description.UTF8String);
        exit(1);
    }
}

static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
    Check(drained, @"main queue drains");
}

@class UIWindow, UINavigationController;
@interface UIView : NSObject
@property (nonatomic, weak) UIWindow *window;
@end
@implementation UIView
@end
@interface UIWindow : UIView
@end
@implementation UIWindow
@end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *viewIfLoaded;
@property (nonatomic, strong) UIViewController *presentedViewController;
@property (nonatomic, weak) UIViewController *parentViewController;
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic) BOOL isBeingDismissed;
@property (nonatomic) BOOL isMovingFromParentViewController;
@end
@implementation UIViewController
@end
@interface UINavigationController : UIViewController
@property (nonatomic, strong) UIViewController *topViewController;
@end
@implementation UINavigationController
@end
@interface UIImage : NSObject
+ (instancetype)systemImageNamed:(NSString *)name;
@end
@implementation UIImage
+ (instancetype)systemImageNamed:(__unused NSString *)name { return nil; }
@end
@interface UIMenuElement : NSObject
@property (nonatomic, copy) NSString *title;
@end
@implementation UIMenuElement
@end
@interface UIAction : UIMenuElement
@property (nonatomic, copy) void (^handler)(UIAction *action);
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(id)identifier handler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(__unused UIImage *)image identifier:(__unused id)identifier handler:(void (^)(UIAction *))handler {
    UIAction *action = [self new]; action.title = title; action.handler = handler; return action;
}
@end
@interface UIMenu : UIMenuElement
@property (nonatomic, copy) NSArray<UIAction *> *children;
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children;
@end
@implementation UIMenu
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children {
    UIMenu *menu = [self new]; menu.title = title; menu.children = children; return menu;
}
@end
@interface TestDataTask : NSObject
@property (nonatomic, copy) void (^completion)(NSData *, NSURLResponse *, NSError *);
@property (nonatomic, copy) NSURLRequest *request;
- (void)cancel;
- (void)resume;
@end
@implementation TestDataTask
- (void)cancel {}
- (void)resume { networkRequestCount++; }
@end
@interface TestURLSession : NSObject
@property (nonatomic, strong) TestDataTask *task;
+ (instancetype)sharedSession;
- (TestDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
@end
@implementation TestURLSession
+ (instancetype)sharedSession { static TestURLSession *session; if (!session) session = [self new]; return session; }
- (TestDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    self.task = [TestDataTask new]; self.task.request = request; self.task.completion = completion; return self.task;
}
@end
@interface ApolloGalleryImageLoader : NSObject
+ (instancetype)sharedLoader;
- (NSData *)cachedDataForURL:(NSURL *)URL;
- (id)loadImageAtURL:(NSURL *)URL progress:(id)progress completion:(void (^)(id, NSData *))completion;
@end
@implementation ApolloGalleryImageLoader
+ (instancetype)sharedLoader { static ApolloGalleryImageLoader *loader; if (!loader) loader = [self new]; return loader; }
- (NSData *)cachedDataForURL:(__unused NSURL *)URL { return cachedOriginalData; }
// Reproduce the problematic independent cache state: a decoded hit survives
// while its original bytes have been evicted. This must never be the share path.
- (id)loadImageAtURL:(__unused NSURL *)URL progress:(__unused id)progress completion:(void (^)(id, NSData *))completion {
    decodedLoadCount++; completion([NSObject new], nil); return nil;
}
@end

static void FinishNetwork(NSData *data, NSInteger status) {
    TestDataTask *task = TestURLSession.sharedSession.task;
    void (^completion)(NSData *, NSURLResponse *, NSError *) = task.completion;
    task.completion = nil;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
    completion(data, response, nil);
}

// Model doubles deliberately retain mutable URL/title fields. The production
// snapshot must isolate a menu from the feed's subsequent edits/resolution.
@implementation ApolloGalleryItem
- (BOOL)playsAsVideo { return self.videoURL != nil || self.hostedVideoPageURL != nil; }
- (NSURL *)postURL { return self.permalink.length ? [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:self.permalink]] : nil; }
- (void)resolveHostedVideoWithCompletion:(void (^)(BOOL))completion { if (completion) completion(NO); }
- (void)resolveHostedVideoForGridWithCompletion:(void (^)(BOOL))completion { if (completion) completion(NO); }
@end
@implementation ApolloSaveAllMediaItem
- (instancetype)initWithURL:(NSURL *)URL isVideo:(BOOL)isVideo {
    self = [super init]; if (self) { _URL = [URL copy]; _isVideo = isVideo; } return self;
}
@end
static void ApolloSaveAllMedia(NSArray<ApolloSaveAllMediaItem *> *items, __unused UIViewController *presenter) {
    saveCount++; savedURL = items.firstObject.URL; savedVideo = items.firstObject.isVideo;
}
static BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *URL) { routedURL = URL; return YES; }
static BOOL ApolloRouteURLThroughApp(__unused NSURL *URL) { return NO; }
typedef NS_ENUM(NSInteger, ApolloToastStyle) { ApolloToastStyleInfo, ApolloToastStyleError };
static void ApolloShowToastWithStyle(__unused NSString *message, __unused NSString *detail, ApolloToastStyle style, __unused NSString *symbol) { if (style == ApolloToastStyleError) errorToastCount++; }

#include "GalleryMediaActionsAPI.inc"
#include "GalleryMediaActionsSnapshot.inc"
#define NSURLSessionDataTask TestDataTask
#include "GalleryMediaActionsPrivate.inc"
#undef NSURLSessionDataTask
@interface ApolloGalleryMediaActions (TestIO)
- (void)shareOriginalImageData:(NSData *)data;
- (void)presentActivityWithItems:(NSArray *)items temporaryDirectory:(NSURL *)directory;
@end
@implementation ApolloGalleryMediaActions
#define NSURLSession TestURLSession
#include "GalleryMediaActionsMethods.inc"
#undef NSURLSession
- (void)shareOriginalImageData:(NSData *)data { imageShareCount++; sharedURL = self.imageURL; exportedData = data; }
- (void)presentActivityWithItems:(NSArray *)items temporaryDirectory:(__unused NSURL *)directory { sharedURL = items.firstObject; }
@end

static UIAction *Action(UIMenu *menu, NSString *title) {
    for (UIAction *action in menu.children) if ([action.title isEqualToString:title]) return action;
    return nil;
}
static void Select(UIMenu *menu, NSString *title) {
    UIAction *action = Action(menu, title);
    Check(action != nil, [@"menu contains " stringByAppendingString:title]);
    action.handler(action);
}

int main(void) {
    @autoreleasepool {
        NSData *originalGIF = [[NSData alloc] initWithBase64EncodedString:@"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" options:0];
        cachedOriginalData = originalGIF;
        UIWindow *window = [UIWindow new];
        UIViewController *presenter = [UIViewController new];
        presenter.viewIfLoaded = [UIView new]; presenter.viewIfLoaded.window = window;
        ApolloGalleryItem *item = [ApolloGalleryItem new];
        item.imageURL = [NSURL URLWithString:@"https://example.test/original.gif"];
        item.thumbnailURL = [NSURL URLWithString:@"https://example.test/thumbnail.jpg"];
        item.postTitle = @"Original post"; item.permalink = @"/r/test/comments/original";
        NSURL *original = item.imageURL; NSURL *originalPost = item.postURL;

        ApolloGalleryMediaActions *session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:presenter.viewIfLoaded];
        UIMenu *menu = [session menu];
        Check(menu.children.count == 4 && saveCount == 0 && imageShareCount == 0, @"building menu has no media side effects");
        item.imageURL = [NSURL URLWithString:@"https://example.test/later.jpg"];
        item.postTitle = @"Later post"; item.permalink = @"/r/test/comments/later";
        Check(session.item != item && [session.item.imageURL isEqual:original] && [session.item.postTitle isEqualToString:@"Original post"] && menu.title.length == 0, @"menu snapshots the item without displaying its title");
        Select(menu, @"Save Image");
        DrainMainQueue();
        Check(saveCount == 0, @"selection waits for dismissal completion");
        Select(menu, @"Share Image");
        [session menuDidEnd]; [session menuDidEnd];
        Check(saveCount == 0, @"completion runs selection on next main turn");
        DrainMainQueue();
        Check(saveCount == 1 && [savedURL isEqual:original] && !savedVideo && imageShareCount == 0, @"exactly one selection saves snapshotted original, never thumbnail");

        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        menu = [session menu];
        [session menuDidEnd]; DrainMainQueue();
        Select(menu, @"Share Image"); DrainMainQueue();
        Check(imageShareCount == 1 && [sharedURL isEqual:item.imageURL], @"late handler after dismissal still runs");

        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        [session menu]; [session menuDidEnd]; DrainMainQueue();
        Check(saveCount == 1 && imageShareCount == 1, @"cancelling menu performs no action");

        __block NSUInteger runs = 0;
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        [session performAfterMenu:^{ runs++; }]; [session menuDidEnd];
        presenter.viewIfLoaded.window = nil; DrainMainQueue();
        Check(runs == 0, @"offscreen presenter is checked when queued action runs");
        presenter.viewIfLoaded.window = window;
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        [session performAfterMenu:^{ runs++; }]; [session menuDidEnd];
        presenter.presentedViewController = [UIViewController new]; DrainMainQueue();
        Check(runs == 0, @"competing modal blocks selection"); presenter.presentedViewController = nil;
        UINavigationController *navigation = [UINavigationController new]; presenter.navigationController = navigation;
        navigation.topViewController = [UIViewController new];
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        [session performAfterMenu:^{ runs++; }]; [session menuDidEnd]; DrainMainQueue();
        Check(runs == 0, @"covered navigation controller blocks selection"); presenter.navigationController = nil;

        item.permalink = @"/r/test/comments/original";
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        menu = [session menu]; item.permalink = @"/r/test/comments/replaced";
        Select(menu, @"Open Post"); [session menuDidEnd]; DrainMainQueue();
        Check([routedURL isEqual:originalPost], @"default open routes snapshotted post");

        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
        session.openPostHandler = ^{ runs++; }; menu = [session menu];
        Select(menu, @"Open Post"); [session menuDidEnd]; DrainMainQueue();
        Check(runs == 1, @"fullscreen custom open handler runs after dismissal");

        item.videoURL = [NSURL URLWithString:@"https://example.test/video.m3u8"];
        item.videoDownloadURL = [NSURL URLWithString:@"https://example.test/original.mp4"];
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil]; menu = [session menu];
        NSURL *originalVideo = item.videoDownloadURL; item.videoDownloadURL = nil;
        Check(Action(menu, @"Save Video") && Action(menu, @"Share Video Link") && !Action(menu, @"Save Image"), @"video menu uses video actions");
        Select(menu, @"Save Video"); [session menuDidEnd]; DrainMainQueue();
        Check(saveCount == 2 && savedVideo && [savedURL isEqual:originalVideo], @"video saver receives original download snapshot");

        cachedOriginalData = nil;
        item.videoURL = nil;
        item.imageURL = original;
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil]; menu = [session menu];
        Select(menu, @"Share Image"); [session menuDidEnd]; DrainMainQueue();
        TestDataTask *download = TestURLSession.sharedSession.task;
        Check(networkRequestCount == 1 && decodedLoadCount == 0 && imageShareCount == 1, @"decoded hit with evicted bytes starts original-byte download");
        Check([download.request.URL isEqual:original] && download.request.timeoutInterval == 30 &&
              [[download.request valueForHTTPHeaderField:@"User-Agent"] isEqualToString:sUserAgent], @"download uses snapshotted original and bounded request timeout");
        FinishNetwork(originalGIF, 200); DrainMainQueue();
        Check(imageShareCount == 2 && [exportedData isEqual:originalGIF] && !session.imageTask, @"successful byte download shares exact animated original and releases task");

        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil]; menu = [session menu];
        Select(menu, @"Share Image"); [session menuDidEnd]; DrainMainQueue();
        FinishNetwork(originalGIF, 404); DrainMainQueue();
        Check(imageShareCount == 2 && errorToastCount == 1, @"HTTP failure cannot export an error response");
        session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil]; menu = [session menu];
        Select(menu, @"Share Image"); [session menuDidEnd]; DrainMainQueue();
        FinishNetwork([@"<html>Rate limited</html>" dataUsingEncoding:NSUTF8StringEncoding], 200); DrainMainQueue();
        Check(imageShareCount == 2 && errorToastCount == 2, @"successful HTTP status with non-image bytes cannot export HTML");

        __weak ApolloGalleryMediaActions *weakSession;
        @autoreleasepool {
            ApolloGalleryMediaActions *owned = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:presenter sourceView:nil];
            weakSession = owned; menu = [owned menu]; owned = nil;
            Check(weakSession != nil, @"menu retains session for late handlers");
            [weakSession menuDidEnd]; menu = nil;
        }
        Check(weakSession == nil, @"cancelled menu has no menu-session retain cycle");
        __weak UIViewController *weakPresenter;
        @autoreleasepool {
            UIViewController *temporary = [UIViewController new]; weakPresenter = temporary;
            session = [[ApolloGalleryMediaActions alloc] initWithItem:item presenter:temporary sourceView:nil]; temporary = nil;
        }
        Check(weakPresenter == nil, @"session does not retain presenter");
        printf("Gallery media actions: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
