#import "ApolloSavedSignInCheck.h"

static void ApolloSavedSignInSetReason(NSString **outReason, NSString *reason) {
    if (outReason) *outReason = reason;
}

ApolloSavedAPIKeySignIn ApolloSavedAPIKeySignInClassify(NSInteger httpStatus,
                                                        NSData *body,
                                                        BOOL transportFailed,
                                                        NSString **outReason) {
    if (transportFailed || httpStatus <= 0) {
        ApolloSavedSignInSetReason(outReason, @"no response");
        return ApolloSavedAPIKeySignInUnknown;
    }
    // Only Reddit's own JSON counts. A block page, a captive portal or a
    // proxy's error page says nothing about the account, whatever its status.
    id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        ApolloSavedSignInSetReason(outReason, @"non-JSON");
        return ApolloSavedAPIKeySignInUnknown;
    }
    NSDictionary *answer = json;
    id error = answer[@"error"];

    // RFC 6749 error codes. Reddit can send them with 200 as well as 400/401.
    if ([error isKindOfClass:[NSString class]]) {
        NSString *code = error;
        ApolloSavedSignInSetReason(outReason, code);
        if ([code isEqualToString:@"invalid_grant"]) return ApolloSavedAPIKeySignInGrantRejected;
        if ([code isEqualToString:@"invalid_client"] ||
            [code isEqualToString:@"unauthorized_client"] ||
            [code isEqualToString:@"unsupported_grant_type"] ||
            [code isEqualToString:@"invalid_scope"]) return ApolloSavedAPIKeySignInKeyRefused;
        return ApolloSavedAPIKeySignInUnknown;
    }

    // Reddit's own shape for this endpoint: {"message": "Bad Request", "error": 400}
    // for a revoked or expired refresh token, {"message": "Unauthorized",
    // "error": 401} when the client id or secret is refused. The request
    // carries nothing else that could be wrong, so a 400 here is the grant.
    if ([error isKindOfClass:[NSNumber class]]) {
        NSInteger code = [error integerValue];
        ApolloSavedSignInSetReason(outReason, [NSString stringWithFormat:@"error %ld", (long)code]);
        if (code == 400 && httpStatus == 400) return ApolloSavedAPIKeySignInGrantRejected;
        if (code == 401 && httpStatus == 401) return ApolloSavedAPIKeySignInKeyRefused;
        return ApolloSavedAPIKeySignInUnknown;
    }
    if (error) {
        ApolloSavedSignInSetReason(outReason, @"unreadable error");
        return ApolloSavedAPIKeySignInUnknown;
    }

    id accessToken = answer[@"access_token"];
    if (httpStatus == 200 && [accessToken isKindOfClass:[NSString class]] && [(NSString *)accessToken length] > 0) {
        ApolloSavedSignInSetReason(outReason, @"access token");
        return ApolloSavedAPIKeySignInWorks;
    }
    ApolloSavedSignInSetReason(outReason, @"no access token");
    return ApolloSavedAPIKeySignInUnknown;
}
