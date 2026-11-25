#import <Foundation/Foundation.h>

// Add Friend / Remove Friend for an API-Key-Free (cookie) account (issue #1787).
//
// RedditKit sends them as PUT and DELETE /api/v1/me/friends/<name>, which
// www.reddit.com refuses for any cookie request with its 403 block page, so the
// friend never stuck. The web's own form is POST /api/friend or /api/unfriend
// with type=friend, the user's name and the signed-in account's t2_ fullname as
// `container` (checked live 2026-11-25 on an account in good standing and on a
// suspended one: 200 {"json": {"errors": []}}, and prefs/friends.json lists or
// drops the user). Without `container` Reddit answers the same empty error
// list but changes nothing, so a request is only built when the id is known.
// A cookie account's currentUser never learns its id (www's /api/v1/me is a
// features-only object, so its fullName reads "t2_(null)"); the id comes from
// www's /api/me.json instead (ApolloWebJSONFriendAccountFullNameFromMe).
//
// Foundation-only so it compiles into the host-side harness
// (tests/run_web_json_friends_tests.sh). The RedditKit hooks that use it live
// in ApolloWebJSONIdentity.xm.

__BEGIN_DECLS

// RedditKit-relative paths, the same strings Apollo's own
// -friendTaskWithContainer:... and -unfriendTaskWithContainer:... use.
FOUNDATION_EXPORT NSString *const ApolloWebJSONFriendAddPath;
FOUNDATION_EXPORT NSString *const ApolloWebJSONFriendRemovePath;

// The form fields for that POST, or nil when `username` is empty or
// `containerFullName` isn't a t2_ fullname (an account whose id never loaded
// reads "t2_(null)").
NSDictionary<NSString *, NSString *> *ApolloWebJSONFriendWriteParameters(NSString *username,
                                                                         NSString *containerFullName);

// The signed-in account's t2_ fullname from a /api/me.json answer
// ({"kind": "t2", "data": {"id", "name", ...}}, or the bare data object), or
// nil when it has no usable id or names someone other than
// `expectedUsername` (compared without case).
NSString *ApolloWebJSONFriendAccountFullNameFromMe(id meObject, NSString *expectedUsername);

// Why Reddit didn't apply the write, or nil when it did: an HTTP status of 400
// or more, or the first entry of a non-empty {"json": {"errors": [...]}} list
// (its message, else its code). RedditKit hands both to its caller with no
// error, which Apollo shows as "Added friend!".
NSString *ApolloWebJSONFriendWriteFailureMessage(NSInteger statusCode, id responseObject);

__END_DECLS
