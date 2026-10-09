// ApolloRedgifsErrorCards.h
//
// Says why a RedGIFs post failed instead of Apollo's "RedGIFs error :(".
// The hooks and the overview live in ApolloRedgifsErrorCards.xm; the reasons
// and their wording in ApolloRedgifsFailureReason.{h,m}. These two calls feed
// it the RedGIFs API results from Tweak.xm's
// -[NSURLSession dataTaskWithRequest:completionHandler:] hook.

#import <Foundation/Foundation.h>
#import "ApolloRedgifsMissingDuration.h"

#ifdef __cplusplus
extern "C" {
#endif

// For Apollo's own gif lookups (GET api.redgifs.com/v2/gifs/<id> on its
// RedGIFs session): returns a completion that notes why the lookup failed (or
// that it didn't) before calling `completion`, so the card Apollo then shows
// can say so. Every other request gets `completion` back unchanged.
ApolloRedgifsLookupCompletion ApolloRedgifsCompletionRecordingLookupResult(NSURLSession *session,
                                                                          NSURLRequest *request,
                                                                          ApolloRedgifsLookupCompletion completion);

// The /v2/oauth/client -> /v2/auth/temporary token answer Apollo receives.
// When minting fails Apollo fails its queued lookups without sending them, so
// their cards take this reason.
void ApolloRedgifsRecordTokenMintResult(NSData *data, NSURLResponse *response, NSError *error);

#ifdef __cplusplus
}
#endif
