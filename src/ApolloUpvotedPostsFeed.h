#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Apollo's own PostsViewController, built as the Upvoted list of `username`
// (ASCII, at most 15 bytes). It loads every page through
// -[RDKClient upvotedLinksForUser:pagination:completion:] with that name, so a
// hook answering that call for a placeholder name can fill it with any posts
// (Recently Read, Hidden & Deleted). Nil on any binary but Apollo 1.15.11.
UIViewController * _Nullable ApolloMakeUpvotedPostsFeed(NSString *username);

// Apollo's own feed-menu icon for the post size a tap switches to.
UIImage * _Nullable ApolloPostsFeedSizeImage(BOOL compact);

// Redraws the feed's loaded rows in the current post size without refetching,
// keeping the top visible post in place, the way Apollo's own Compact/Large
// menu action does. `around` runs the rebuild (to answer the size read).
// NO when this binary isn't supported; the caller reloads instead.
BOOL ApolloPostsFeedRedrawInPlace(UIViewController *feed, void (^around)(dispatch_block_t rebuild));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
