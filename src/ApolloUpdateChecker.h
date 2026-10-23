// In-app update check. A sideloaded app can't replace itself (iOS only runs code
// signed by the user's own certificate, which lives in their sideloader), so this
// finds the newest release in release-manifest.json and hands the user off to
// AltStore / SideStore / Feather (or the IPA download) for the actual update.

#import <Foundation/Foundation.h>
#import "ApolloUpdateManifest.h"

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Call on every foreground and after changing the automatic-check setting. Checks
// every 15 minutes while active, using conditional requests; stops on inactivity.
// Failed checks retry after 5 minutes. Only eligible sideloaded builds check automatically.
// Prompts only over the base UI, once per version per launch unless Later is chosen:
// Later snoozes that version for 24 hours across launches; Skip hides it indefinitely.
void ApolloUpdateCheckIfNeeded(void);

// Manual "Check for Updates": always fetches and always reports the outcome.
// `statusChanged` fires on the main queue when the check starts and finishes so
// a row can re-read ApolloUpdateStatusText().
void ApolloUpdateCheckNow(void (^_Nullable statusChanged)(void));

// Row detail text: "Checking…", "v3.9.0 available", "Up to date", or nil before any check.
NSString *_Nullable ApolloUpdateStatusText(void);

// NO for jailbroken .deb installs, which update through their package manager.
BOOL ApolloUpdateChecksAvailable(void);

// Fetches the release notes for `info` (every release after the installed one, newest first)
// from the variant's source JSON. `completion` runs on the main queue: nil when the fetch
// failed, empty when the source has no notes in range.
void ApolloUpdateFetchReleaseNotes(ApolloUpdateInfo *info,
                                   void (^completion)(NSArray<ApolloUpdateReleaseNotes *> *_Nullable notes));

__END_DECLS

NS_ASSUME_NONNULL_END
