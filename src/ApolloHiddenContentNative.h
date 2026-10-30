#import <UIKit/UIKit.h>
#import "ApolloHiddenContentData.h"

NS_ASSUME_NONNULL_BEGIN

// Hidden & Deleted shows its results in Apollo's own lists: posts in a
// PostsViewController and comments in a UserCommentsViewController, the
// controllers behind a profile's Posts and Comments rows. Each list is built
// for a private placeholder username, and the RDKClient fetches it makes for
// that name are answered with the archive results.
@protocol ApolloHiddenContentNativeListOwner <NSObject>
// The user pulled to refresh a list that already shows the current results.
- (void)apollo_nativeListRequestedRefresh:(UIViewController *)list;
@end

#ifdef __cplusplus
extern "C" {
#endif

// Nil when this Apollo binary isn't the one the initializers were verified on.
UIViewController * _Nullable ApolloHiddenContentMakeNativeList(ApolloHiddenContentKind kind, id<ApolloHiddenContentNativeListOwner> owner);

// Replaces the list's results and shows them (answering a pending first page,
// or reloading the list).
void ApolloHiddenContentNativeListSetItems(UIViewController *list, NSArray<ApolloHiddenContentItem *> *items);

// Ends a pending refresh without new results; the list keeps what it shows.
void ApolloHiddenContentNativeListEndRefresh(UIViewController *list);

// Post size for the Posts list: its own setting, defaulting to the feeds'.
BOOL ApolloHiddenContentNativePostsCompact(void);
// Saves the size and redraws the loaded posts in it, keeping the top post in view.
void ApolloHiddenContentNativePostsSetCompact(UIViewController *list, BOOL compact);

// The list's table view, for scroll-to-top.
UIScrollView * _Nullable ApolloHiddenContentNativeListScrollView(UIViewController *list);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
