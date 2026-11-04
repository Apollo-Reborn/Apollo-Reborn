#import <Foundation/Foundation.h>

@interface UIView : NSObject
@property (nonatomic, strong) id window;
@end
@implementation UIView
@end
@interface UIBarButtonItem : NSObject
@property (nonatomic, strong) UIView *view;
@end
@implementation UIBarButtonItem
@end
@interface UINavigationItem : NSObject
@property (nonatomic, strong) id overflowPresentationSource;
@end
@implementation UINavigationItem
@end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UINavigationItem *navigationItem;
@end
@implementation UIViewController
@end
static UIView *sApolloNativeActionMenuSourceView;
static UIView *ApolloNativeActionMenuViewForObject(id object) {
    if ([object isKindOfClass:UIView.class]) return object;
    return [object respondsToSelector:@selector(view)] ? [object view] : nil;
}
// INCLUDE_PRODUCTION_SOURCE_RESOLVER
static unsigned checks;
static void Check(BOOL condition, const char *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        UIView *detached = [UIView new], *overflow = [UIView new], *page = [UIView new];
        overflow.window = [NSObject new]; page.window = overflow.window;
        UIBarButtonItem *item = [UIBarButtonItem new]; item.view = detached;
        UIViewController *owner = [UIViewController new]; owner.view = page;
        owner.navigationItem = [UINavigationItem new]; owner.navigationItem.overflowPresentationSource = overflow;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == overflow, "detached bar item must use its visible overflow control");
        item.view = overflow;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == overflow, "attached sender remains preferred");
        item.view = detached; owner.navigationItem.overflowPresentationSource = nil;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == page, "detached bar item falls back to its visible page");
        Check(ApolloNativeActionMenuResolveSourceView(detached, owner) == page, "detached view sender falls back to its visible owner");
        Check(ApolloNativeActionMenuResolveSourceView(overflow, nil) == overflow, "ordinary attached view retains its source");
        owner.view = detached; sApolloNativeActionMenuSourceView = overflow;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == overflow, "nested capture retains an attached primed source");
        sApolloNativeActionMenuSourceView = detached;
        Check(!ApolloNativeActionMenuResolveSourceView(item, owner), "fully detached capture must not claim a source");
        Check(!ApolloNativeActionMenuResolveSourceView(nil, nil), "nil inputs are safe");
        printf("PASS: %u native menu anchor checks\n", checks);
    }
}
