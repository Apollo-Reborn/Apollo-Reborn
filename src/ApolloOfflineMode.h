#import <Foundation/Foundation.h>
#import "ApolloOfflineLibrary.h"

// Offline Mode runtime (ApolloOfflineMode.xm): the URL protocol that answers
// Apollo's own requests from the saved batch, the connectivity watch that
// decides when it does, and the controller the settings screen drives.

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue when download progress, the library, connectivity
// or the serving state changes.
extern NSNotificationName const ApolloOfflineModeDidChangeNotification;

#ifdef __cplusplus
extern "C" {
#endif
// YES while saved entries answer requests. Thread-safe. A feature that
// fetches feed content outside Apollo's own requests can check this and step
// aside while the offline library is showing.
BOOL ApolloOfflineModeIsServing(void);
#ifdef __cplusplus
}
#endif

@interface ApolloOfflineModeController : NSObject

+ (instancetype)sharedController;

@property (nonatomic, readonly) BOOL downloading;
// The running download was started by Keep Fresh, not by the user.
@property (nonatomic, readonly) BOOL downloadingAutomatically;
@property (nonatomic, readonly) BOOL onWiFi;
// Re-checks whether Keep Fresh should refresh now (after a setting changes).
- (void)considerKeepFresh:(NSString *)reason;
// Stops a running Keep Fresh refresh the current network or settings no longer allow.
- (void)stopKeepFreshIfNotAllowed:(NSString *)reason;
@property (nonatomic, readonly) BOOL networkAvailable;
// YES while saved entries are answering requests.
@property (nonatomic, readonly) BOOL serving;
@property (nonatomic, readonly, copy) NSString *progressText;
@property (nonatomic, readonly) unsigned long long progressBytes;
@property (nonatomic, readonly) unsigned long long budgetBytes;

@property (nonatomic, readonly) ApolloOfflineUseMode useMode;
- (void)setUseMode:(ApolloOfflineUseMode)useMode;

// Feeds the next download would fetch, from the settings (Home, Popular, subs).
- (NSArray<NSString *> *)plannedFeedTitles;

// Completion runs on the main queue with a user-facing message.
- (void)startDownloadWithCompletion:(void (^ _Nullable)(BOOL success, NSString *message))completion;
- (void)cancelDownload;
- (void)deleteLibrary;

// "42 posts · 3 videos · 87 MB\nAbout 12 min of scrolling · Today, 7:01 AM"
// (two lines) or "Not downloaded".
- (NSString *)librarySummary;

@end

NS_ASSUME_NONNULL_END
