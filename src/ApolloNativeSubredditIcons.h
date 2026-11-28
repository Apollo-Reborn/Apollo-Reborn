#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Apollo's SubredditIconTracker saves icons in standard defaults under
// "SubredditIconData" (keyed archive of [name, iconURL, keyColor]) and has no
// expiry. Clearing it leaves placeholders until the next subscription sync, so
// instead a weekly lookup stores current URLs as a pending update that %ctor
// writes into the blob before the tracker loads it. Foundation-only.
//
// The tracker's save (0x1004f8af0, on entering the background and on
// terminate) only merges with what's stored when the stored value is an array
// (`arrayForKey:`), the format before the keyed archive. For the archive it
// gets nil and writes just the icons set during this launch, dropping every
// other saved icon, so the saved set alternates between launches and each
// dropped icon is fetched again. ApolloNativeSubredditIconValueForSave puts
// the dropped entries back.

// Apollo's own cap (SubredditIconTracker.maximumTotal).
FOUNDATION_EXPORT NSUInteger const ApolloNativeSubredditIconMaxEntries;

// The archive Apollo is saving (`incoming`) with every entry of the stored one
// (`saved`) whose name isn't in it, compared case-insensitively. Saved entries
// come first and the incoming ones after them, so they win; past `maxEntries`
// the oldest saved entries are dropped. Returns nil when nothing would be
// added or either archive can't be decoded.
FOUNDATION_EXPORT NSData *_Nullable ApolloNativeSubredditIconDataMergingSaved(NSData *_Nullable incoming,
                                                                              NSData *_Nullable saved,
                                                                              NSUInteger maxEntries,
                                                                              NSUInteger *_Nullable keptCount);

// For -[NSUserDefaults setObject:forKey:]: the value to write instead of
// `value`. For a "SubredditIconData" archive that would drop saved icons, the
// merged archive; anything else is returned unchanged.
FOUNDATION_EXPORT id _Nullable ApolloNativeSubredditIconValueForSave(NSUserDefaults *defaults,
                                                                     id _Nullable value,
                                                                     NSString *_Nullable key);

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
