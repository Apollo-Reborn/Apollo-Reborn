// Backup/restore engine for Apollo Reborn settings, extracted from
// CustomAPIViewController so the logic is UI-free. The view controller keeps all
// UI (alerts, document picker, exit(0) restart prompt) and calls into these
// functions for the actual work.

#import <Foundation/Foundation.h>

__BEGIN_DECLS

// Default: Library/Preferences/com.christianselig.Apollo.plist, depending on bundle ID.
// Contains: most Apollo settings
NSString *ApolloMainPreferencesPath(void);

// Should always Library/Preferences/group.com.christianselig.apollo.plist, no matter the bundle ID.
// Contains: theme settings, keyword filters, some account state
NSString *ApolloGroupPreferencesPath(void);

// Build a uniquely named settings backup zip in NSTemporaryDirectory(). Captures
// immutable live main + group persistent defaults (including in-memory ReadPostIDs
// and favorites), writes usernames to accounts.txt and Valet credentials to
// keychain.plist, and zips them using protected temporary files. May be called on
// a worker queue: only the preference snapshot marshals synchronously to main;
// filesystem/keychain/compression work stays on the calling queue. The caller must
// not synchronously wait for that worker from main. Returns the ZIP URL on success
// (caller owns cleanup), or nil with a user-presentable *error on failure.
NSURL *ApolloBackupRestoreCreateBackupZip(NSError **error);

// Restore settings from a backup zip: validates flat archive entries, bounds and
// verifies inflated byte counts/CRCs, then checks all present plist schemas and
// Apollo-owned keychain identities before changing anything.
// Missing optional group/keychain files remain compatible with legacy backups.
// Credential replay is checked and rolls back earlier writes if any item fails;
// only after it succeeds are the main/group defaults and runtime values restored.
// Automatic backups resume after a fully rolled-back failure. Returns
// YES on success; on failure returns NO with *outErrorTitle / *outErrorMessage set
// for the failure alert (e.g. "Restore Failed" / "Invalid Backup").
BOOL ApolloBackupRestoreRestoreFromZipURL(NSURL *zipURL, NSString **outErrorTitle, NSString **outErrorMessage);

__END_DECLS
