#import <Foundation/Foundation.h>

#import "ApolloPasscodePrivacyPolicy.h"

static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "passcode_privacy_policy_tests: %s\n", message);
        abort();
    }
}

int main(void) {
    @autoreleasepool {
        Require(!ApolloPasscodePrivacyCoverRequired(NO, 0, NO, 0, 1000),
                "disabled passcode lock must not add a cover");
        Require(!ApolloPasscodePrivacyCoverRequired(NO, 5, YES, 0, 1000),
                "disabled passcode lock must ignore its stale delay");
        Require(ApolloPasscodePrivacyCoverRequired(YES, 0, YES, 999, 1000),
                "the native immediate policy must add a cover");
        Require(ApolloPasscodePrivacyCoverRequired(YES, -1, YES, 999, 1000),
                "an invalid negative delay must fail closed");
        Require(ApolloPasscodePrivacyCoverRequired(YES, 5, NO, 0, 1000),
                "cold launch must lock even with a positive delay");
        Require(!ApolloPasscodePrivacyCoverRequired(YES, 5, YES, 1000, 1299.999),
                "a delayed lock must remain open before its minute threshold");
        Require(ApolloPasscodePrivacyCoverRequired(YES, 5, YES, 1000, 1300),
                "a delayed lock must engage at its exact minute threshold");
        Require(ApolloPasscodePrivacyCoverRequired(YES, 5, YES, 1000, 1301),
                "a delayed lock must remain engaged after its threshold");
        Require(!ApolloPasscodePrivacyCoverRequired(YES, 5, YES, 1000, 900),
                "a backwards uptime must mirror native elapsed-time behavior");

        Require(!ApolloPasscodePrivacyBackgroundCoverRequired(NO, 0),
                "disabled locking must not alter the background snapshot");
        Require(ApolloPasscodePrivacyBackgroundCoverRequired(YES, 0),
                "the immediate policy must protect the background snapshot");
        Require(!ApolloPasscodePrivacyBackgroundCoverRequired(YES, 5),
                "entering background alone must not trigger a delayed policy");

        Require(ApolloPasscodePrivacyNativeGateRequiresCover(YES, YES, 1.0),
                "a nontransparent native blur must retain the cover");
        Require(ApolloPasscodePrivacyNativeGateRequiresCover(YES, NO, 0.0),
                "a missing private blur must fail closed");
        Require(!ApolloPasscodePrivacyNativeGateRequiresCover(YES, YES, 0.0),
                "the native no-lock alpha must release the preflight cover");
        Require(!ApolloPasscodePrivacyNativeGateRequiresCover(NO, NO, 1.0),
                "disabled native locking must release the preflight cover");
        Require(ApolloPasscodePrivacyNativeGateIsUsable(YES, NO, 1.0),
                "a visible direct native gate must remain usable");
        Require(!ApolloPasscodePrivacyNativeGateIsUsable(NO, NO, 1.0),
                "a detached or nested gate must use the modal-cover fallback");
        Require(!ApolloPasscodePrivacyNativeGateIsUsable(YES, YES, 1.0),
                "a hidden native gate must use the modal-cover fallback");
        Require(!ApolloPasscodePrivacyNativeGateIsUsable(YES, NO, 0.0),
                "a transparent native gate must use the modal-cover fallback");
    }

    puts("passcode_privacy_policy_tests: all 20 checks passed");
    return 0;
}
