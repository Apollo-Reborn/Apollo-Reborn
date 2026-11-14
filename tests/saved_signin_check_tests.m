#import <Foundation/Foundation.h>
#import "ApolloSavedSignInCheck.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static NSData *Body(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static ApolloSavedAPIKeySignIn Classify(NSInteger status, NSString *body) {
    return ApolloSavedAPIKeySignInClassify(status, body ? Body(body) : nil, NO, NULL);
}

int main(void) {
    @autoreleasepool {
        // Works: only a 200 with a real access token.
        Check(Classify(200, @"{\"access_token\":\"abc\",\"token_type\":\"bearer\",\"expires_in\":86400}") ==
              ApolloSavedAPIKeySignInWorks, @"200 with an access token works");
        Check(Classify(200, @"{\"access_token\":\"\"}") == ApolloSavedAPIKeySignInUnknown,
              @"empty access token is not a working sign-in");
        Check(Classify(200, @"{\"token_type\":\"bearer\"}") == ApolloSavedAPIKeySignInUnknown,
              @"200 without an access token is unknown");
        Check(Classify(201, @"{\"access_token\":\"abc\"}") == ApolloSavedAPIKeySignInUnknown,
              @"access token only counts on 200");

        // Confirmed dead grant: the only case that asks for a new sign-in.
        Check(Classify(400, @"{\"error\":\"invalid_grant\"}") == ApolloSavedAPIKeySignInGrantRejected,
              @"invalid_grant (400) is a dead grant");
        Check(Classify(200, @"{\"error\":\"invalid_grant\"}") == ApolloSavedAPIKeySignInGrantRejected,
              @"invalid_grant (200) is a dead grant");
        Check(Classify(400, @"{\"message\":\"Bad Request\",\"error\":400}") == ApolloSavedAPIKeySignInGrantRejected,
              @"Reddit's numeric 400 for a revoked refresh token is a dead grant");
        Check(Classify(200, @"{\"access_token\":\"abc\",\"error\":\"invalid_grant\"}") ==
              ApolloSavedAPIKeySignInGrantRejected, @"an error beats a stray access token");

        // The key or secret was refused: the account's grant may be fine.
        Check(Classify(401, @"{\"error\":\"invalid_client\"}") == ApolloSavedAPIKeySignInKeyRefused,
              @"invalid_client is a refused key");
        Check(Classify(400, @"{\"error\":\"unauthorized_client\"}") == ApolloSavedAPIKeySignInKeyRefused,
              @"unauthorized_client is a refused key");
        Check(Classify(400, @"{\"error\":\"unsupported_grant_type\"}") == ApolloSavedAPIKeySignInKeyRefused,
              @"unsupported_grant_type is a client configuration problem");
        Check(Classify(400, @"{\"error\":\"invalid_scope\"}") == ApolloSavedAPIKeySignInKeyRefused,
              @"invalid_scope is a client configuration problem");
        Check(Classify(401, @"{\"message\":\"Unauthorized\",\"error\":401}") == ApolloSavedAPIKeySignInKeyRefused,
              @"Reddit's numeric 401 is a refused key");

        // Not Reddit's JSON: says nothing about the account.
        Check(Classify(400, @"<html><body>Bad Request</body></html>") == ApolloSavedAPIKeySignInUnknown,
              @"non-JSON 400 is unknown");
        Check(Classify(401, @"<html><body>Unauthorized</body></html>") == ApolloSavedAPIKeySignInUnknown,
              @"non-JSON 401 is unknown");
        Check(Classify(403, @"<!doctype html><title>Blocked</title>") == ApolloSavedAPIKeySignInUnknown,
              @"block page is unknown");
        Check(Classify(400, nil) == ApolloSavedAPIKeySignInUnknown, @"empty 400 is unknown");
        Check(Classify(200, @"[\"access_token\"]") == ApolloSavedAPIKeySignInUnknown, @"JSON array is unknown");
        Check(Classify(400, @"{\"error\":") == ApolloSavedAPIKeySignInUnknown, @"truncated JSON is unknown");

        // Transient or unrecognised answers.
        Check(ApolloSavedAPIKeySignInClassify(0, nil, YES, NULL) == ApolloSavedAPIKeySignInUnknown,
              @"transport failure is unknown");
        Check(ApolloSavedAPIKeySignInClassify(200, Body(@"{\"access_token\":\"abc\"}"), YES, NULL) ==
              ApolloSavedAPIKeySignInUnknown, @"transport failure wins over a body");
        Check(Classify(429, @"{\"message\":\"Too Many Requests\",\"error\":429}") == ApolloSavedAPIKeySignInUnknown,
              @"rate limit is unknown");
        Check(Classify(503, @"{\"error\":503}") == ApolloSavedAPIKeySignInUnknown, @"5xx is unknown");
        Check(Classify(500, @"{\"error\":\"server_error\"}") == ApolloSavedAPIKeySignInUnknown,
              @"server_error is unknown");
        Check(Classify(400, @"{\"error\":\"invalid_request\"}") == ApolloSavedAPIKeySignInUnknown,
              @"invalid_request (our request, not the account) is unknown");
        Check(Classify(200, @"{\"error\":\"temporarily_unavailable\"}") == ApolloSavedAPIKeySignInUnknown,
              @"temporarily_unavailable is unknown");
        Check(Classify(200, @"{\"error\":400}") == ApolloSavedAPIKeySignInUnknown,
              @"numeric 400 needs a 400 status");
        Check(Classify(400, @"{\"error\":401}") == ApolloSavedAPIKeySignInUnknown,
              @"numeric 401 needs a 401 status");
        Check(Classify(400, @"{\"error\":{\"code\":400}}") == ApolloSavedAPIKeySignInUnknown,
              @"structured error is unknown");
        Check(Classify(400, @"{\"error\":\"400\"}") == ApolloSavedAPIKeySignInUnknown,
              @"string \"400\" is not Reddit's numeric shape");

        // The log reason never carries the body.
        NSString *reason = nil;
        ApolloSavedAPIKeySignInClassify(200, Body(@"{\"access_token\":\"secret-token\"}"), NO, &reason);
        Check(reason.length > 0 && [reason rangeOfString:@"secret"].location == NSNotFound,
              @"reason never includes the token");
        ApolloSavedAPIKeySignInClassify(400, Body(@"{\"message\":\"Bad Request\",\"error\":400}"), NO, &reason);
        Check([reason isEqualToString:@"error 400"], @"numeric reason is loggable");

        NSLog(@"PASS: %lu saved sign-in checks", (unsigned long)checks);
    }
    return 0;
}
