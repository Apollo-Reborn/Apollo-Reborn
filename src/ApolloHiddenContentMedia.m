#import "ApolloHiddenContentMedia.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>
#import <dlfcn.h>

extern void *ApolloHiddenMediaPrepareURL(const void *);
extern void ApolloHiddenMediaFreeURL(void *);
extern void ApolloHiddenMediaAssignURLs(void *, const void *);

// Forward page transitions to Apollo before updating the archive count.
@interface ApolloHiddenMediaPageDelegate : NSObject <UIPageViewControllerDelegate>
@property (nonatomic, weak) id<UIPageViewControllerDelegate> nativeDelegate;
@property (nonatomic, strong) UILabel *counter;
@property (nonatomic) NSUInteger count;
@end
@implementation ApolloHiddenMediaPageDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.nativeDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector { return self.nativeDelegate; }
- (void)pageViewController:(UIPageViewController *)page didFinishAnimating:(BOOL)finished previousViewControllers:(NSArray<UIViewController *> *)previous transitionCompleted:(BOOL)completed {
    [self.nativeDelegate pageViewController:page didFinishAnimating:finished previousViewControllers:previous transitionCompleted:completed];
    if (!completed) return;
    id child = page.viewControllers.firstObject;
    Ivar index = class_getInstanceVariable([child class], "index");
    Ivar url = class_getInstanceVariable([child class], "url");
    if (!index || !url || ivar_getOffset(url) - ivar_getOffset(index) != sizeof(NSInteger)) return;
    NSInteger value = *(NSInteger *)((uint8_t *)(__bridge void *)child + ivar_getOffset(index));
    if (value < 0 || (NSUInteger)value >= self.count) return;
    self.counter.text = [NSString stringWithFormat:@"%ld / %lu", (long)value + 1, (unsigned long)self.count];
}
@end
static char kApolloHiddenMediaDelegate;

BOOL ApolloHiddenContentPresentMedia(NSArray<NSURL *> *urls, NSUInteger initialIndex, UIViewController *presenter) {
    if (!urls.count || !presenter.viewIfLoaded.window || presenter.presentedViewController) return NO;
    initialIndex = MIN(initialIndex, urls.count - 1);
    Class pageClass = NSClassFromString(@"_TtC6Apollo23MediaPageViewController");
    Method coder = class_getInstanceMethod(pageClass, @selector(initWithCoder:));
    Ivar foundURLs = class_getInstanceVariable(pageClass, "foundURLs");
    Ivar afterURLs = class_getInstanceVariable(pageClass, "contentTypeHints");
    void *emptyDictionary = dlsym(RTLD_DEFAULT, "_swiftEmptyDictionarySingleton");
    if (!coder || !foundURLs || !afterURLs || !emptyDictionary ||
        ivar_getOffset(afterURLs) - ivar_getOffset(foundURLs) != sizeof(void *)) return NO;

    // Apollo 1.15.11's Swift designated initializer immediately precedes the
    // ObjC coder thunk. The public ObjC initializers deliberately trap. Verify
    // both function prologues before using this version-specific entry point;
    // unsupported binaries fail closed rather than guessing a Swift ABI.
    const uint8_t *coderIMP = (const uint8_t *)method_getImplementation(coder);
    Dl_info binary;
    if (!dladdr(coderIMP, &binary) || !binary.dli_fbase ||
        coderIMP - (const uint8_t *)binary.dli_fbase != 0x25b570) return NO;
    const uint8_t *entry = coderIMP - 0x774;
    const uint32_t expected[] = {0xd10443ff, 0xa90b6ffc, 0xa90c67fa, 0xa90d5ff8};
    if (memcmp(entry, expected, sizeof(expected)) != 0) return NO;

    // URL (consumed), thumbnails, selected index?, link?, GIF offset?, origin
    // view?, SPCA/Goodbye flags, wallpapers?, and Swift self in x20. No live
    // post is attached: voting on an archived snapshot would be misleading.
    typedef void * __attribute__((swiftcall)) (*NativeInit)(
        void *, void *, uintptr_t, unsigned char, void *, uintptr_t, unsigned char,
        void *, unsigned char, unsigned char, void *, void * __attribute__((swift_context)));
    void *urlStorage = ApolloHiddenMediaPrepareURL((__bridge void *)urls[initialIndex]);
    void *allocated = (__bridge_retained void *)[pageClass alloc];
    void *result = ((NativeInit)entry)(urlStorage, emptyDictionary, initialIndex, 1, NULL, 0, 1, NULL, 0, 0, NULL, allocated);
    ApolloHiddenMediaFreeURL(urlStorage);
    UIViewController *page = CFBridgingRelease(result);
    if (!page) return NO;
    [page loadViewIfNeeded];
    ApolloHiddenMediaAssignURLs((uint8_t *)(__bridge void *)page + ivar_getOffset(foundURLs), (__bridge void *)urls);
    // Loading the first direct URL primes UIKit's neighbor cache as a
    // single-image pager. Invalidate that cache after supplying the archive's
    // full album, otherwise native swipe gestures still see no next page.
    UIPageViewController *pager = (UIPageViewController *)page;
    id<UIPageViewControllerDataSource> dataSource = pager.dataSource;
    NSArray<UIViewController *> *initialPages = pager.viewControllers;
    // The initializer receives the selected URL, but its first child still
    // starts with index 0. Apollo's data source derives the next/previous page
    // from that child index, so opening image 3 would otherwise swipe to image
    // 2 as if the viewer had started on image 1. Synchronize the child before
    // invalidating the page-controller cache.
    id initialChild = initialPages.firstObject;
    Ivar childIndex = initialChild ? class_getInstanceVariable([initialChild class], "index") : NULL;
    Ivar childURL = initialChild ? class_getInstanceVariable([initialChild class], "url") : NULL;
    if (childIndex && childURL && ivar_getOffset(childURL) - ivar_getOffset(childIndex) == sizeof(NSInteger)) {
        *(NSInteger *)((uint8_t *)(__bridge void *)initialChild + ivar_getOffset(childIndex)) = (NSInteger)initialIndex;
    } else {
        ApolloLog(@"[HiddenContent] Native media child index layout unavailable; album paging may start from zero");
    }
    pager.dataSource = nil;
    pager.dataSource = dataSource;
    if (initialPages.count) [pager setViewControllers:initialPages direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
    // This screen has no Texture source node for Apollo's zoom transition.
    // Use UIKit presentation while retaining the native pager and gestures.
    page.transitioningDelegate = nil;
    page.modalPresentationStyle = UIModalPresentationFullScreen;
    if (urls.count > 1) {
        ApolloHiddenMediaPageDelegate *delegate = [ApolloHiddenMediaPageDelegate new];
        delegate.nativeDelegate = ((UIPageViewController *)page).delegate;
        delegate.count = urls.count;
        delegate.counter = [UILabel new];
        delegate.counter.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        delegate.counter.textColor = UIColor.whiteColor;
        delegate.counter.text = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)initialIndex + 1, (unsigned long)urls.count];
        delegate.counter.translatesAutoresizingMaskIntoConstraints = NO;
        [page.view addSubview:delegate.counter];
        [NSLayoutConstraint activateConstraints:@[
            [delegate.counter.centerXAnchor constraintEqualToAnchor:page.view.centerXAnchor],
            [delegate.counter.topAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.topAnchor constant:16],
        ]];
        objc_setAssociatedObject(page, &kApolloHiddenMediaDelegate, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((UIPageViewController *)page).delegate = delegate;
    }
    [presenter presentViewController:page animated:YES completion:nil];
    ApolloLog(@"[HiddenContent] Opened native media pager with %lu image(s) at index %lu",
              (unsigned long)urls.count, (unsigned long)initialIndex);
    return YES;
}
