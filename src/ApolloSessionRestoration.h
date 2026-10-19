#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns the saved stable comment sort while session restoration still owns
// this post's initial load. Zero means the normal URL-open sort chain applies.
FOUNDATION_EXPORT int64_t
ApolloSessionRestorationPendingCommentSortForPost(NSString * _Nullable postID);

NS_ASSUME_NONNULL_END
