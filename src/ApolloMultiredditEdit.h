#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue after Apollo fetches an account's multireddits.
FOUNDATION_EXPORT NSString *const ApolloMultiredditsCapturedNotification;

// Keys of an ApolloActiveAccountMultiredditEntries() entry.
FOUNDATION_EXPORT NSString *const ApolloMultiredditEntryPath;      // "/user/<owner>/m/<name>"
FOUNDATION_EXPORT NSString *const ApolloMultiredditEntryTitle;     // its display name
FOUNDATION_EXPORT NSString *const ApolloMultiredditEntrySubreddit; // first member subreddit, when it has one
FOUNDATION_EXPORT NSString *const ApolloMultiredditEntryIcon;      // custom icon (UIImage), when one is set

// The signed-in account's multireddits as Apollo last fetched them, sorted by
// title like the Subreddits list. Empty before that fetch or without an
// account; never another account's. Main thread only. C linkage: defined in
// ApolloMultiredditEdit.xm (Objective-C++), called from plain .m files too.
__BEGIN_DECLS
NSArray<NSDictionary<NSString *, id> *> *ApolloActiveAccountMultiredditEntries(void);
__END_DECLS

NS_ASSUME_NONNULL_END
