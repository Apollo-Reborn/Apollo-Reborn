#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

FOUNDATION_EXPORT NSString *const ApolloSearchRecentsDidChangeNotification;

// Main-thread, session-only snapshots. Newest first; never persisted.
// The configured display limit is applied here without discarding history.
NSArray<NSString *> *ApolloSearchRecentSubreddits(void);
// Caller resolves a genuine subreddit from a loaded, visible Posts page.
void ApolloSearchRecordVisit(NSString *subredditName);

__END_DECLS

NS_ASSUME_NONNULL_END
