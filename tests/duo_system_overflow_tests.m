#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
typedef NSUInteger UIControlEvents;
static const NSUInteger UIControlEventTouchUpInside = 64, UIControlStateNormal = 0;
@interface UIImage : NSObject
+ (id)imageNamed:(NSString *)name;
@end
@implementation UIImage
+ (id)imageNamed:(__unused NSString *)name { return [self new]; }
@end
@interface UIMenuElement : NSObject @end
@implementation UIMenuElement @end
@interface UIMenu : UIMenuElement
@property(copy) NSArray *children;
@end
@implementation UIMenu @end
@interface UIDeferredMenuElement : UIMenuElement
@property(copy) void (^provider)(void (^)(NSArray *));
+ (id)elementWithUncachedProvider:(void (^)(void (^)(NSArray *)))provider;
@end
@implementation UIDeferredMenuElement
+ (id)elementWithUncachedProvider:(void (^)(void (^)(NSArray *)))provider {
    UIDeferredMenuElement *result = [self new]; result.provider = provider; return result;
}
@end
@interface UIView : NSObject
@property(strong) id window;
@end
@implementation UIView @end
@interface UIViewController : NSObject
@property(strong) UIView *view;
@property BOOL isViewLoaded;
@end
@implementation UIViewController @end
@interface UINavigationItem : NSObject
@property(strong) UIDeferredMenuElement *additionalOverflowItems;
@property(strong) id overflowPresentationSource;
@end
@implementation UINavigationItem @end
@interface UIButton : NSObject
@property(strong) UIMenu *menu;
@property BOOL showsMenuAsPrimaryAction;
@property(strong) UIImage *currentImage;
@property(strong) NSSet *allTargets;
- (id)imageForState:(NSUInteger)state;
- (NSArray *)actionsForTarget:(id)target forControlEvent:(NSUInteger)event;
- (void)sendActionsForControlEvents:(NSUInteger)events;
@end
@implementation UIButton
- (id)imageForState:(__unused NSUInteger)state { return self.currentImage; }
- (NSArray *)actionsForTarget:(__unused id)target forControlEvent:(__unused NSUInteger)event { return @[]; }
- (void)sendActionsForControlEvents:(__unused NSUInteger)events {}
@end
@interface UIApplication : NSObject
@property(class,readonly) UIApplication *sharedApplication;
- (void)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(id)event;
@end
@implementation UIApplication
+ (UIApplication *)sharedApplication { return [self new]; }
- (void)sendAction:(__unused SEL)a to:(__unused id)t from:(__unused id)s forEvent:(__unused id)e {}
@end
@interface Box : NSObject
@property(weak) UIViewController *controller;
@end
@implementation Box @end
static char kActionsControllerKey;
static BOOL isDuo = YES;
static BOOL ApolloDeviceIsDuo(void) { return isDuo; }
static id ApolloActionsTemplateImage(id image) { return image; }
static id ApolloNativeActionMenuCaptureMenuController(__unused UIView *source, dispatch_block_t build) { build(); return nil; }
static UIMenu *ApolloNativeActionMenuBuildCaptured(__unused id captured) { return nil; }
#define ApolloLog(...) ((void)0)
@interface UIBarButtonItem : NSObject
@property(copy) NSString *accessibilityIdentifier;
@property BOOL sharesBackground;
@property BOOL hidesSharedBackground;
@end
@implementation UIBarButtonItem @end
static char kNSBDuoTrailingControlsKey;
// INCLUDE_PRODUCTION_HELPERS
// INCLUDE_TRAILING_ITEMS_HELPER
static unsigned checks;
static void Check(BOOL ok) { checks++; if (!ok) { fprintf(stderr,"check %u failed\n", checks); exit(1); } }
int main(void) { @autoreleasepool {
    __weak id weakItem, weakButton, weakPage;
    UIDeferredMenuElement *provider;
    UIDeferredMenuElement *replacement;
    @autoreleasepool {
    UINavigationItem *item = [UINavigationItem new]; UIButton *button = [UIButton new];
    UIViewController *page = [UIViewController new]; page.view = [UIView new]; page.view.window = [NSObject new]; page.isViewLoaded = YES;
    Box *box = [Box new]; box.controller = page;
    objc_setAssociatedObject(item, &kActionsControllerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIDeferredMenuElement *previous = [UIDeferredMenuElement new]; item.additionalOverflowItems = previous;
    isDuo = NO; Check(!ApolloActionsInstallSystemOverflow(item, button)); Check(item.additionalOverflowItems == previous);
    isDuo = YES; Check(ApolloActionsInstallSystemOverflow(item, button));
    provider = item.additionalOverflowItems;
    Check(ApolloActionsInstallSystemOverflow(item, button)); Check(provider == item.additionalOverflowItems);
    button.menu = [UIMenu new]; button.showsMenuAsPrimaryAction = YES;
    button.menu.children = @[[UIMenuElement new]];
    provider.provider(^(NSArray *elements) { Check(elements.count == 2); Check(elements.lastObject == previous); });
    button.menu.children = @[[UIMenuElement new], [UIMenuElement new]];
    provider.provider(^(NSArray *elements) { Check(elements.count == 3); }); // Fresh state each opening.
    ApolloActionsRemoveSystemOverflow(item); Check(item.additionalOverflowItems == previous);
    Check(ApolloActionsInstallSystemOverflow(item, button));
    replacement = [UIDeferredMenuElement new]; item.additionalOverflowItems = replacement;
    ApolloActionsRemoveSystemOverflow(item); Check(item.additionalOverflowItems == replacement); // Don't overwrite another owner.
    Check(ApolloActionsInstallSystemOverflow(item, button)); provider = item.additionalOverflowItems;
    weakItem = item; weakButton = button; weakPage = page;
    item = nil; button = nil; page = nil;
    }
    Check(!weakItem && !weakButton && !weakPage); // Retained provider cannot keep a popped page alive.
    provider.provider(^(NSArray *elements) { Check(elements.count == 1 && elements.firstObject == replacement); });
    UINavigationItem *nav = [UINavigationItem new];
    UIBarButtonItem *sort = [UIBarButtonItem new], *translate = [UIBarButtonItem new], *layout = [UIBarButtonItem new];
    layout.accessibilityIdentifier = @"ApolloDuoFeedControl";
    NSArray *actions = @[sort, translate];
    Check(ApolloNativeFeedSearchDuoTrailingItems(nav, actions) == actions); // No registered controls: preserve caller's array.
    objc_setAssociatedObject(nav, &kNSBDuoTrailingControlsKey, @[layout], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *ordered = ApolloNativeFeedSearchDuoTrailingItems(nav, @[layout, sort, translate]);
    Check([ordered isEqualToArray:@[sort, translate, layout]]); // Horizontal section cannot split actions from More.
    Check([ApolloNativeFeedSearchDuoTrailingItems(nav, ordered) isEqualToArray:ordered]); // Repeated layout does not duplicate controls.
    UIBarButtonItem *replacementLayout = [UIBarButtonItem new];
    replacementLayout.accessibilityIdentifier = @"ApolloDuoFeedControl";
    objc_setAssociatedObject(nav, &kNSBDuoTrailingControlsKey, @[replacementLayout], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Check([ApolloNativeFeedSearchDuoTrailingItems(nav, ordered) isEqualToArray:@[sort, translate, replacementLayout]]);
    objc_setAssociatedObject(nav, &kNSBDuoTrailingControlsKey, @[], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Check([ApolloNativeFeedSearchDuoTrailingItems(nav, ordered) isEqualToArray:actions]); // Folding removes the host control.
    printf("Duo system overflow: %u checks passed\n", checks);
} }
