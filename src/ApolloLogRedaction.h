#import <Foundation/Foundation.h>

// Masks personal data in a debug-log export before it leaves the device.
// Every export path (Settings > Export Debug Logs, the bug-report form, the
// crash-review flow, the Apollo AI export) goes through ApolloCollectLogs*,
// which runs the finished text through ApolloRedactLogExport once.
//
// What it masks:
//   - URLs: scheme + host only. Reddit page/API URLs (reddit.com, *.reddit.com,
//     redd.it) and Reddit media (i./v./preview.redd.it, except snoovatars)
//     keep their path so routes and post media stay readable, minus the post
//     title slug. Every URL loses its query string and fragment.
//   - Usernames written as u/name, /user/name or u_name, plus the signed-in
//     accounts' names wherever they appear (bare too): other people become
//     u/[user-3f9a] (a tag that is random per export but stable inside one, so
//     lines about the same person still line up), the signed-in accounts
//     become [me], [me2], ...
//   - Credentials: Bearer tokens, token/cookie/key/secret/client-id values in
//     key=value or key: value form, JWTs, provider API keys, 64+ hex-digit tokens.
//   - Email addresses, t2_ account IDs, chat room/user IDs in /chat/ routes,
//     websession:<username> keychain account names, container paths.
// What it keeps: subreddit names, post/comment IDs (t3_/t1_), hosts, counts,
// status codes, error domains/codes.
//
// This is a safety net, not a licence: it cannot recognise free text (comment
// bodies, titles, prompts, handles without a u/ prefix). Log lengths, counts,
// booleans and hosts at the call site instead.
//
// Foundation-only so tests/run_log_redaction_tests.sh can build it on the host.

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// ownUsernames: the signed-in accounts, active account first (any case).
// homeDirectory: NSHomeDirectory(); occurrences become "~". Either may be nil.
NSString *ApolloRedactLogExport(NSString *log,
                                NSArray<NSString *> *_Nullable ownUsernames,
                                NSString *_Nullable homeDirectory);

// Same, with a fixed pseudonym salt so tests get deterministic tags.
NSString *ApolloRedactLogExportWithSalt(NSString *log,
                                        NSArray<NSString *> *_Nullable ownUsernames,
                                        NSString *_Nullable homeDirectory,
                                        NSString *salt);

// A URL for a log line: scheme://host/path plus the query's key NAMES, never
// values or the fragment ("apollo://reddit-oauth?{code,state}"). Use it where a
// line must show which parameters were present. The export scrub still reduces
// non-Reddit paths to the host. "nil" for a nil URL.
NSString *ApolloLogURL(NSURL *_Nullable url);

// What kind of web page a scrape is stuck on, without its title (on a profile
// or post page the title is a person's name or the post title): "empty",
// "challenge" (bot/verification/blocked page), "reddit(N chars)" or
// "other(N chars)". Accepts any object; non-strings count as empty.
NSString *ApolloLogPageTitleKind(id _Nullable title);

// The user's OWN post/comment for a log line: its kind kept, its ID
// fingerprinted ("t1_#3f2a"). Browsed posts are fine to log as-is; the IDs of
// things the user wrote lead straight to their account.
NSString *ApolloLogOwnThing(NSString *_Nullable fullnameOrID);

// Stable 4-hex fingerprint of a value, for log lines that must tell two
// secrets apart ("the key changed") without printing either. 16 bits cannot
// be reversed to a 20+ character credential. Returns "none" for an empty value.
NSString *ApolloLogFingerprint(NSString *_Nullable value);

__END_DECLS
NS_ASSUME_NONNULL_END
