#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

FOUNDATION_EXPORT NSString *const ApolloDuoSearchRecentsDidChangeNotification;

// Main-thread, session-only snapshots. Newest first; never persisted.
NSArray<NSString *> *ApolloDuoSearchRecentSubreddits(void);
// Caller resolves a genuine subreddit from a loaded, visible Duo Posts page.
void ApolloDuoSearchRecordVisit(NSString *subredditName);

__END_DECLS

NS_ASSUME_NONNULL_END
