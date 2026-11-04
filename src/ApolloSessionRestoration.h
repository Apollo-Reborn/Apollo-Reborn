#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns the saved stable comment sort while session restoration still owns
// this post's initial load. Zero means the normal URL-open sort chain applies.
FOUNDATION_EXPORT int64_t
ApolloSessionRestorationPendingCommentSortForPost(NSString * _Nullable postID);

// Applies the live settings change. Disabling immediately cancels restoration
// and removes the saved snapshot rather than waiting for backgrounding.
FOUNDATION_EXPORT void ApolloSessionRestorationSetEnabled(BOOL enabled);

NS_ASSUME_NONNULL_END
