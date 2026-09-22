#import <Foundation/Foundation.h>
#import <objc/message.h>

// Only UIKit containers/presentation are doubled. The shipping menu builder,
// action deferral, selection ownership and recursive filter run unchanged.
@interface UIView : NSObject
@property (nonatomic, strong) id window;
@end
@implementation UIView
@end
static NSUInteger singleShareCount;
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *viewIfLoaded;
@end
@implementation UIViewController
- (void)shareButtonTappedWithSender:(__unused id)sender { singleShareCount++; }
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
@implementation UIMenuElement @end
@interface UIAction : UIMenuElement
@property (nonatomic, copy) void (^handler)(UIAction *);
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(id)identifier handler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(__unused UIImage *)image identifier:(__unused id)identifier handler:(void (^)(UIAction *))handler {
    UIAction *action = [self new]; action.title = title; action.handler = handler; return action;
}
@end
@interface UIMenu : UIMenuElement
@property (nonatomic, copy) NSArray *children;
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children;
- (instancetype)menuByReplacingChildren:(NSArray *)children;
@end
@implementation UIMenu
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children {
    UIMenu *menu = [self new]; menu.title = title; menu.children = children; return menu;
}
- (instancetype)menuByReplacingChildren:(NSArray *)children { return [UIMenu menuWithTitle:self.title children:children]; }
@end
@interface ApolloSaveAllMenuContext : NSObject @end
@implementation ApolloSaveAllMenuContext @end
static NSUInteger bulkCount, checks;
static NSUInteger sApolloFullScreenNativeMenuBuild;
static BOOL nativeMenuActive;
static dispatch_block_t nativePending;
static NSNumber *invoked;
static id invokedController;
static NSString *const kApolloSaveAllTitle = @"Save All Media";
static UIViewController *ApolloFullScreenCurrentViewer(UIViewController *page) { return page; }
static BOOL ApolloNativeActionMenuHasAction(id controller, uint16_t kind) { return [controller containsObject:@(kind)]; }
static void ApolloNativeActionMenuInvokeAction(id controller, uint16_t kind) { invoked = @(kind); invokedController = controller; }
static void ApolloSaveAllBegin(ApolloSaveAllMenuContext *context) { if (context) bulkCount++; }
static BOOL ApolloNativeActionMenuPerformAfterDismissal(__unused id context, dispatch_block_t action) {
    if (!nativeMenuActive) return NO;
    nativePending = action;
    return YES;
}
#import "FullscreenMenu.inc"

static void Check(BOOL yes, NSString *message) {
    checks++;
    if (!yes) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void Drain(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    while (!done) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}
static ApolloFullScreenImageMenu *Context(UIViewController *owner, BOOL album) NS_RETURNS_RETAINED;
static ApolloFullScreenImageMenu *Context(UIViewController *owner, BOOL album) {
    ApolloFullScreenImageMenu *context = [ApolloFullScreenImageMenu new];
    context.page = owner; context.viewer = owner;
    context.imageActions = @[@26, @100];
    if (album) { context.album = [ApolloSaveAllMenuContext new]; context.shareActions = @[@27, @19]; }
    return context;
}
static void Select(UIMenu *menu, NSUInteger index) {
    UIAction *action = menu.children[index]; action.handler(action);
}
int main(void) {
    @autoreleasepool {
        UIViewController *owner = [UIViewController new];
        owner.viewIfLoaded = [UIView new]; owner.viewIfLoaded.window = [NSObject new];
        ApolloFullScreenImageMenu *album = Context(owner, YES);
        UIMenu *hold = ApolloFullScreenImageMenuBuild(album, NO);
        UIMenu *share = ApolloFullScreenImageMenuBuild(album, YES);
        Check([[hold.children valueForKey:@"title"] isEqual:@[@"Copy Image", @"Save Image", @"Save All Media", @"Share"]], @"album hold actions/order");
        Check([[share.children valueForKey:@"title"] isEqual:@[@"Share Image", @"Save Image", @"Save All Media", @"Share Album Link"]], @"album share actions/order");
        ApolloFullScreenImageMenu *single = Context(owner, NO);
        Check([[ApolloFullScreenImageMenuBuild(single, NO).children valueForKey:@"title"] isEqual:@[@"Copy Image", @"Save Image", @"Share"]], @"single hold omits bulk action");
        Check([[ApolloFullScreenImageMenuBuild(single, YES).children valueForKey:@"title"] isEqual:@[@"Share Image", @"Save Image"]], @"single share omits album actions");
        Select(hold, 3);
        Check(invoked == nil && album.pending != nil, @"hold Share waits for dismissal");
        dispatch_block_t pending = album.pending; album.pending = nil; album.ended = YES; pending();
        Check([invoked isEqual:@27] && invokedController == album.shareActions, @"album hold Share opens native image share sheet directly");
        single.ended = YES;
        Select(ApolloFullScreenImageMenuBuild(single, NO), 2); Drain();
        Check(singleShareCount == 1 && sApolloFullScreenNativeMenuBuild == 0, @"single hold Share opens native image share sheet directly and restores interception");
        Select(ApolloFullScreenImageMenuBuild(single, YES), 0); Drain();
        Check(singleShareCount == 2, @"single chooser Share Image uses the same system share sheet");
        Select(hold, 0); Drain();
        Check([invoked isEqual:@100] && invokedController == album.imageActions, @"copy uses captured image handler");
        Select(share, 1); Drain();
        Check([invoked isEqual:@26] && invokedController == album.imageActions, @"save uses captured image handler");
        Select(share, 0); Drain();
        Check([invoked isEqual:@27] && invokedController == album.shareActions, @"Share Image uses native image sharing");
        Select(share, 3); Drain();
        Check([invoked isEqual:@19], @"Share Album Link uses native link sharing");
        Select(share, 2); Drain(); Check(bulkCount == 1, @"bulk save receives album context");

        // UIKit may release the menu and configuration before a late handler
        // runs. The queued operation must still own its captured selection.
        __weak ApolloFullScreenImageMenu *weakContext;
        @autoreleasepool {
            ApolloFullScreenImageMenu *late = Context(owner, YES); weakContext = late; late.ended = YES;
            UIAction *action = ApolloFullScreenImageAction(@"Test", @"", late, ^{ Check(weakContext != nil, @"late operation retains selection"); });
            late = nil; action.handler(action); action = nil;
            Check(weakContext != nil, @"selection survives action teardown"); Drain();
        }
        Check(weakContext == nil, @"late operation releases selection");
        @autoreleasepool {
            ApolloFullScreenImageMenu *early = Context(owner, YES); weakContext = early;
            nativeMenuActive = YES;
            UIAction *action = ApolloFullScreenImageAction(@"Test", @"", early, ^{ Check(weakContext != nil, @"native dismissal retains selection"); });
            early = nil; action.handler(action); action = nil;
            Check(nativePending != nil, @"native menu defers selected action");
            nativeMenuActive = NO; dispatch_block_t run = nativePending; nativePending = nil; run();
        }
        Check(weakContext == nil, @"native callback releases selection");

        UIAction *keep = [UIAction actionWithTitle:@"Save Image" image:nil identifier:nil handler:^(__unused UIAction *a) {}];
        UIAction *remove = [UIAction actionWithTitle:@"Share" image:nil identifier:nil handler:^(__unused UIAction *a) {}];
        UIAction *removeLink = [UIAction actionWithTitle:@"Share Album Link" image:nil identifier:nil handler:^(__unused UIAction *a) {}];
        UIMenu *more = [UIMenu menuWithTitle:@"" children:@[remove, keep, [UIMenu menuWithTitle:@"" children:@[removeLink]]]];
        UIMenu *filtered = ApolloFullScreenWithoutSharing(more);
        Check([filtered.children isEqual:@[keep]], @"More removes both share actions and empty groups");
        Check(filtered.children.firstObject == keep, @"More preserves other native handlers");
    }
    printf("fullscreen_media_menu_tests: all %lu checks passed\n", (unsigned long)checks);
}
