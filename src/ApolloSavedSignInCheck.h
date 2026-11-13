#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What Reddit's token endpoint said about an account's saved API-key sign-in
// (one refresh_token grant). Only a confirmed dead grant asks the user to sign
// in again; a refused key or an answer we can't read changes nothing.
typedef NS_ENUM(NSInteger, ApolloSavedAPIKeySignIn) {
    ApolloSavedAPIKeySignInWorks,
    ApolloSavedAPIKeySignInGrantRejected, // the saved refresh token is dead: sign in again
    ApolloSavedAPIKeySignInKeyRefused,    // the API key or secret was refused; the grant may be fine
    ApolloSavedAPIKeySignInUnknown,       // offline, rate limited, block page, 5xx, unreadable answer
};

#ifdef __cplusplus
extern "C" {
#endif

// Classifies one token-endpoint answer. Foundation-only so the host tests
// (tests/run_saved_signin_check_tests.sh) can cover every case.
// outReason gets a short loggable description (an OAuth error name, Reddit's
// numeric error, "non-JSON", …); it never contains the response body.
ApolloSavedAPIKeySignIn ApolloSavedAPIKeySignInClassify(NSInteger httpStatus,
                                                        NSData *_Nullable body,
                                                        BOOL transportFailed,
                                                        NSString *_Nullable *_Nullable outReason);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
