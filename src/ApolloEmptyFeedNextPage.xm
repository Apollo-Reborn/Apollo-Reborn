// A feed whose loaded posts are all gone loads its next page instead of showing
// a loading spinner forever (#1328).
//
// "Hide Read Posts" (the floating button turned on by Settings > General >
// Mark Read / Hiding Posts > Show Hide Read Button, or the feed's ••• menu)
// keeps only the unread posts. When every loaded post is read, nothing is left
// and Apollo 1.15.11 never asks for the next page: the feed stays blank under a
// spinner until a pull to refresh.
//
// Root cause (Hopper, confirmed in the simulator):
//   * Infinite scrolling is ASDK batch fetching. ASTableView asks
//     -[ListAdapter shouldBatchFetchForTableNode:], which forwards to
//     PostsViewController.shouldBatchFetch(for:listAdapter:):
//         Infinite Scrolling ("DoomscrollDefeater3") && !isSearching
//             && links.count >= 1 && pagination != nil
//     `links.count >= 1` keeps ASDK from fetching while a feed's first page is
//     still loading.
//   * Hide Read sets `links` to the unread posts. With none left, `links` is
//     empty while `pagination` still holds the next page's cursor. ASDK asks
//     once after deleting the rows, gets NO, and never asks again (an empty
//     table can't scroll). ListAdapter shows its spinner because a next page
//     exists.
//   * With Infinite Scrolling off it ends the same way: the "load page N" row
//     is only added below existing posts, so an empty feed has nothing to tap.
//
// Fix: when Apollo answers NO for a feed with no posts left and a next-page
// cursor, answer YES. ASDK then runs Apollo's own fetchNewPage(completion:), as
// it does when you scroll to the bottom, and the next page replaces the
// spinner. With Infinite Scrolling off this loads one page, and the "load page
// N" row comes back below it.
//
// A cursor means the loaded posts were removed, never that a first page is
// still loading: Apollo starts every first page (launch, refresh, sort change)
// from a fresh RDKPagination(limit:) with no `after`, and only stores a cursor
// together with the page that brought it (handleNewLinks / appendNewLinks).
// appendNewLinks(_:withPagination:error:postsTypeAtTimeOfFetch:completion:)
// handles an empty `links`.
//
// Only with an account signed in. Hide Read itself refuses to run signed out
// ("You need to be signed in to hide read posts."), and that is the one case
// where the old cursor outlives `links`: an account change empties `links`,
// then fetchLinks(isFromSortChange:) waits for an application-only token before
// it resets the cursor, so the old feed's next page must not load meanwhile.
// Signed in, fetchLinks resets the cursor before ASDK asks.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloAccountCredentials.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"

@interface RDKPagination : NSObject
@property (copy, nonatomic) NSString *after;
@end

// `links: [RDKLink]` is one word. Only a native Swift array buffer is read
// (count at +0x10 after masking the flag bits, as Apollo's own code does); a
// bridged NSArray (either of the top two bits set) returns -1 so the caller
// keeps Apollo's answer.
static NSInteger ApolloEmptyFeedLinkCount(UIViewController *feed) {
    uint64_t raw = (uint64_t)(uintptr_t)ApolloReadRawIvar(feed, "links");
    if (!raw || (raw >> 62) != 0) return -1;
    return (NSInteger)ApolloSwiftArrayCount((void *)(uintptr_t)(raw & 0x00FFFFFFFFFFFFF8ULL));
}

// `lazy var pagination: RDKPagination?` stores 1 until it is first read (the
// getter then creates one with no cursor) and 0 for nil.
static RDKPagination *ApolloEmptyFeedPagination(UIViewController *feed) {
    uintptr_t raw = (uintptr_t)ApolloReadRawIvar(feed, "$__lazy_storage_$_pagination");
    if (raw <= 1) return nil;
    RDKPagination *pagination = (__bridge RDKPagination *)(void *)raw;
    return [pagination respondsToSelector:@selector(after)] ? pagination : nil;
}

%group ApolloEmptyFeedNextPageHooks

%hook _TtC6Apollo11ListAdapter

- (BOOL)shouldBatchFetchForTableNode:(id)tableNode {
    BOOL shouldFetch = %orig;
    // ASDK asks on main; Apollo's Swift state is only read there.
    if (shouldFetch || ![NSThread isMainThread]) return shouldFetch;
    // The delegate is the controller that just answered: the forwarder weak-loads
    // `delegate` and calls its shouldBatchFetch(for:) witness.
    UIViewController *feed = ApolloReadSwiftWeakObjectIvar(self, "delegate");
    if (![feed isKindOfClass:ApolloClassPostsViewController]) return NO;
    // Posts left (or `links` unreadable) or searching: Apollo's answer stands.
    if (ApolloEmptyFeedLinkCount(feed) != 0 || ApolloReadBoolIvar(feed, "isSearching", YES)) return NO;
    RDKPagination *pagination = ApolloEmptyFeedPagination(feed);
    if (pagination.after.length == 0 || !ApolloActiveAccountClient()) return NO;

    // ASDK asks again on every scroll event until the page arrives; log once.
    static __weak RDKPagination *sLoggedPagination;
    if (sLoggedPagination != pagination) {
        sLoggedPagination = pagination;
        ApolloLog(@"[EmptyFeedNextPage] No posts left in %@ and a next page exists; loading it",
                  NSStringFromClass(feed.class));
    }
    return YES;
}

%end

%end

%ctor {
    Class adapterClass = objc_getClass("_TtC6Apollo11ListAdapter");
    Class feedClass = ApolloClassPostsViewController;
    if (!class_getInstanceMethod(adapterClass, @selector(shouldBatchFetchForTableNode:)) ||
        !class_getInstanceVariable(adapterClass, "delegate") || !feedClass ||
        !class_getInstanceVariable(feedClass, "links") ||
        !class_getInstanceVariable(feedClass, "$__lazy_storage_$_pagination") ||
        !class_getInstanceVariable(feedClass, "isSearching")) {
        ApolloLog(@"[EmptyFeedNextPage] ListAdapter or PostsViewController changed shape; hook NOT installed");
        return;
    }
    %init(ApolloEmptyFeedNextPageHooks);
    ApolloLog(@"[EmptyFeedNextPage] hook installed (a feed with no posts left loads its next page)");
}
