#import "ApolloUpvotedPostsFeed.h"
#import <objc/message.h>
#import <dlfcn.h>
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"

// Apollo 1.15.11 is pinned by PostsViewController's initWithCoder: thunk sitting
// at this offset; every entry below is checked by prologue as well, so any
// other binary fails closed.
static const ptrdiff_t kPostsCoderThunkOffset = 0x596f0c;

static const uint8_t *ApolloPostsFeedBinaryBase(void) {
    Method coder = class_getInstanceMethod(ApolloClassPostsViewController, @selector(initWithCoder:));
    const uint8_t *coderIMP = coder ? (const uint8_t *)method_getImplementation(coder) : NULL;
    Dl_info binary;
    if (!coderIMP || !dladdr(coderIMP, &binary) || !binary.dli_fbase) return NULL;
    const uint8_t *base = binary.dli_fbase;
    return coderIMP - base == kPostsCoderThunkOffset ? base : NULL;
}

static const uint8_t *ApolloPostsFeedVerifiedEntry(ptrdiff_t offset, const uint32_t *prologue, size_t size, NSString *label) {
    const uint8_t *base = ApolloPostsFeedBinaryBase();
    if (!base) {
        ApolloLog(@"[PostsFeed] %@ not found (unsupported Apollo binary)", label);
        return NULL;
    }
    if (memcmp(base + offset, prologue, size) != 0) {
        ApolloLog(@"[PostsFeed] %@ prologue mismatch", label);
        return NULL;
    }
    return base + offset;
}

// PostsViewController.init(postsType:): its ObjC initializers trap, so the
// Swift designated initializer is called directly, with the allocated object
// as self (x20) and the 33-byte PostsType enum passed indirectly (payload in
// bytes 0-31, case tag at byte 32: subreddit 0, multireddit 1, upvoted 2,
// downvoted 3, submissions 4, random 5, home/hidden 6).
typedef void *__attribute__((swiftcall)) (*ApolloPostsViewControllerInit)(
    const void *postsType, void *self __attribute__((swift_context)));

UIViewController *ApolloMakeUpvotedPostsFeed(NSString *username) {
    static ApolloPostsViewControllerInit init;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const uint32_t prologue[] = {0xd10503ff, 0xa90e6ffc, 0xa90f67fa, 0xa9105ff8, 0xa91157f6,
                                            0xa9124ff4, 0xa9137bfd, 0x9104c3fd, 0xaa0003fb};
        init = (ApolloPostsViewControllerInit)ApolloPostsFeedVerifiedEntry(kPostsCoderThunkOffset - 0x15f4,
                                                                           prologue, sizeof(prologue),
                                                                           @"PostsViewController initializer");
    });
    Class feedClass = ApolloClassPostsViewController;
    const char *user = username.UTF8String;
    size_t length = user ? strlen(user) : 0;
    if (!init || !feedClass || length == 0 || length > 15) return nil;

    // .upvoted(username:) with the name as a Swift small string: its bytes
    // inline, its length in the top byte with the ASCII/small flags (0xE0), so
    // the enum holds no reference to retain or release.
    uint8_t postsType[40] __attribute__((aligned(16))) = {0};
    memcpy(postsType, user, length);
    postsType[15] = (uint8_t)(0xE0 | length);
    postsType[32] = 2;

    void *allocated = (__bridge_retained void *)[feedClass alloc];
    return CFBridgingRelease(init(postsType, allocated));
}

UIImage *ApolloPostsFeedSizeImage(BOOL compact) {
    NSString *name = compact ? @"option-large-thumbnails"
        : ([[NSUserDefaults standardUserDefaults] boolForKey:@"CompactModeLeftThumbnails"]
               ? @"option-compact-thumbnails-left" : @"option-compact-thumbnails-right");
    UIImage *image = [UIImage imageNamed:name];
    if (!image) image = [UIImage systemImageNamed:compact ? @"rectangle.grid.1x2" : @"list.bullet"];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// ListAdapter's Swift row rebuild (self only, in x20). Apollo's own
// Compact/Large menu action calls it after saving the size, then reloads the
// table; that is what makes existing rows take the new size.
typedef void __attribute__((swiftcall)) (*ApolloListAdapterRebuild)(void *self __attribute__((swift_context)));

BOOL ApolloPostsFeedRedrawInPlace(UIViewController *feed, void (^around)(dispatch_block_t rebuild)) {
    static ApolloListAdapterRebuild rebuild;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const uint32_t prologue[] = {0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4,
                                            0xa9057bfd, 0x910143fd, 0xd106c3ff, 0x910003f3};
        rebuild = (ApolloListAdapterRebuild)ApolloPostsFeedVerifiedEntry(0x172b28, prologue, sizeof(prologue),
                                                                         @"ListAdapter rebuild");
    });
    id listAdapter = ApolloObjectIvar(feed, "listAdapter");
    id tableNode = listAdapter ? (ApolloObjectIvar(listAdapter, "tableNode") ?: ApolloReadSwiftWeakObjectIvar(listAdapter, "tableNode")) : nil;
    if (!rebuild || ![tableNode respondsToSelector:@selector(reloadData)]) return NO;

    // Rows change height, so keep the top visible post in place, not the offset.
    // The first row whose middle is below the (translucent) bars is the one in view.
    NSIndexPath *anchor = nil;
    UITableView *tableView = [tableNode respondsToSelector:@selector(view)] ? ApolloSendObject(tableNode, @selector(view)) : nil;
    if ([tableView isKindOfClass:UITableView.class]) {
        CGFloat visibleTop = tableView.contentOffset.y + tableView.adjustedContentInset.top;
        for (NSIndexPath *indexPath in [tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]) {
            if (CGRectGetMidY([tableView rectForRowAtIndexPath:indexPath]) > visibleTop) {
                anchor = indexPath;
                break;
            }
        }
    }
    dispatch_block_t body = ^{
        rebuild((__bridge void *)listAdapter);
        [tableNode reloadData];
    };
    if (around) around(body);
    else body();
    SEL scroll = @selector(scrollToRowAtIndexPath:atScrollPosition:animated:);
    if (anchor && anchor.row > 0 && [tableNode respondsToSelector:scroll]) {
        ((void (*)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL))objc_msgSend)(
            tableNode, scroll, anchor, UITableViewScrollPositionTop, NO);
    }
    return YES;
}
