#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Apollo's SubredditIconTracker saves icons in standard defaults under
// "SubredditIconData" (keyed archive of [name, iconURL, keyColor]) and never
// expires them. Clearing it leaves placeholders until the next subscription
// sync, so instead a weekly lookup stores current URLs as a pending update that
// %ctor writes into the blob before the tracker loads it. Foundation-only.

// Subreddit names stored in the tracker blob, in blob order. Empty for a
// missing or unreadable blob.
FOUNDATION_EXPORT NSArray<NSString *> *ApolloNativeSubredditIconNames(NSData *_Nullable blob);

// Lowercased display name -> current icon URL string, parsed from an
// /api/info.json?sr_name=... listing. Prefers community_icon over the legacy
// icon_img; subreddits with neither are left out.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *ApolloNativeSubredditIconURLsFromInfoResponse(NSData *_Nullable data);

// The blob with each entry's URL replaced from `iconURLs` (keyed by lowercased
// name). Entries without a replacement, and any entry shape this doesn't
// recognize, are kept as-is. Returns nil when nothing changed or the blob
// can't be decoded.
FOUNDATION_EXPORT NSData *_Nullable ApolloNativeSubredditIconDataApplyingURLs(NSData *_Nullable blob,
                                                                              NSDictionary<NSString *, NSString *> *iconURLs,
                                                                              NSUInteger *_Nullable changedCount);

// Whether the periodic lookup is due (never run, or last run a week or more ago).
FOUNDATION_EXPORT BOOL ApolloNativeSubredditIconRefreshIsDue(NSUserDefaults *defaults, NSDate *now);

// Records a finished lookup. `iconURLs` merges into any pending update that has
// not been applied yet. `complete` advances the refresh date; a partial lookup
// leaves it so the next launch retries.
FOUNDATION_EXPORT void ApolloNativeSubredditIconRecordRefresh(NSUserDefaults *defaults,
                                                              NSDictionary<NSString *, NSString *> *iconURLs,
                                                              BOOL complete,
                                                              NSDate *now);

// Call from %ctor, before Apollo's tracker initializes. Writes a pending update
// into the tracker blob and clears it. Returns the number of icons replaced.
FOUNDATION_EXPORT NSUInteger ApolloNativeSubredditIconApplyPendingRefresh(NSUserDefaults *defaults);

NS_ASSUME_NONNULL_END
