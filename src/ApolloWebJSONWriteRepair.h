#import <Foundation/Foundation.h>

// The write-response repair for comment/self-text writes, split out of
// ApolloWebJSON.m so it stays Foundation-only and compiles into the host-side
// harness (tests/run_web_json_write_repair_tests.sh). The identity lookups
// (ApolloActiveWebSessionUsername / ApolloActiveAccountUsername) and the
// prefetch below are the only things it takes from the rest of the tweak.

__BEGIN_DECLS

// Fixes up the parsed response object for comment writes (/api/editusertext,
// /api/comment) in EVERY auth mode. www.reddit.com always returns each thing's
// data in the legacy old-reddit {parent, content:"<html>"} shape, and since
// 2026-08 oauth.reddit.com has intermittently done the same to API-key (OAuth)
// clients; Apollo renders such a comment with no author/score/timestamp. This
// swaps in the modern comment JSON (the pre-edit model captured at submit time
// for edits, else local synthesis). Network-free: it runs inside the response
// serializer. Returns the input unchanged when the shape is already modern.
// Called from the RDKResponseSerializer hook with the serializer's output.
id ApolloWebJSONFixupWriteResponseObject(NSURLResponse *response, id responseObject);

// Captures the write context for the write-response repair. Called from the
// identity module's RDKClient submit/edit hooks with the client that issued the
// write plus everything the call site knows about WHERE the write landed; the
// repair reads it (TTL-bounded) when a degraded response is missing those
// fields. The client resolves the posting identity (each account owns its own
// RDKClient, so the submitting client's currentUser is the true posting
// identity even for temporaryPostingAccount); subreddit/subredditFullName come
// from the target link/parent comment, linkFullName is the t3 the comment
// lives under, and parentFullName is the t1 being replied to (nil for
// top-level comments and edits). Any argument may be nil — the repair fills
// only what it has.
//
// `body` is the submitted markdown and is what keys this capture to its own
// response: writes can overlap (a second comment submitted while the first is
// still in flight), and Reddit echoes the markdown back as the response thing's
// body/contentText, so the repair can tell which outstanding write a degraded
// response belongs to instead of taking whichever was captured last. Pass it
// whenever the call site has it; a capture with no body still participates, it
// just can't be matched exactly.
void ApolloWebJSONNoteCommentWriteContext(id client, NSString *body, NSString *subreddit,
                                          NSString *subredditFullName,
                                          NSString *linkFullName, NSString *parentFullName);

// The edit counterparts. A comment edit hands over the RDKComment being edited:
// its subreddit/link identify the write like above, and the model itself is
// what a degraded edit response gets its modern fields from (everything but
// the body is still true after the edit), so the serializer never has to fetch
// them. A self-text edit has no model in hand, only the post's fullname, so
// that capture starts an info.json prefetch in parallel with the edit request;
// the serializer uses it if it has landed and never waits for it.
void ApolloWebJSONNoteCommentEditContext(id client, NSString *body, id comment);
void ApolloWebJSONNoteSelfTextEditContext(id client, NSString *body, NSString *linkFullName);

// Fetches the modern JSON `data` dict for a single thing via info.json (tagged
// so it bypasses our own rewrite + the expiry counter) and hands it to
// `completion` on an arbitrary queue — nil when the fetch failed or the thing
// is unknown. Never blocks the caller: the repair only ever reads a result
// that has already landed. Implemented in ApolloWebJSON.m (it needs that
// file's transport privates); the harness supplies its own.
void ApolloWebJSONPrefetchModernThingData(NSString *fullname, void (^completion)(NSDictionary *data));

__END_DECLS
