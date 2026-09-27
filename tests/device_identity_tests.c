#include "ApolloDeviceChromeInsets.h"
#include "ApolloDeviceIdentity.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;

static void Check(bool condition, const char *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void CheckKind(const char *machine,
                      bool geometryAvailable,
                      bool hasIsland,
                      ApolloDeviceIdentityKind expected,
                      const char *message) {
    ApolloDeviceIdentityKind kind =
        ApolloDeviceIdentityKindForMachine(machine, geometryAvailable, hasIsland);
    if (kind != expected) {
        fprintf(stderr, "FAIL: %s (machine=%s kind=%d expected=%d)\n",
                message, machine ? machine : "(null)", (int)kind, (int)expected);
        exit(1);
    }
    checks++;
}

int main(void) {
    int major = 0;
    int minor = 0;

    Check(!ApolloParseIPhoneMachine(NULL, &major, &minor), "null machine does not parse");
    Check(!ApolloParseIPhoneMachine("", &major, &minor), "empty machine does not parse");
    Check(!ApolloParseIPhoneMachine("arm64", &major, &minor), "host arch does not parse");
    Check(!ApolloParseIPhoneMachine("iPad16,1", &major, &minor), "iPad does not parse as iPhone");
    Check(!ApolloParseIPhoneMachine("iPhone", &major, &minor), "bare iPhone does not parse");
    Check(!ApolloParseIPhoneMachine("iPhone15", &major, &minor), "missing minor does not parse");
    Check(!ApolloParseIPhoneMachine("iPhone15,2x", &major, &minor), "trailing junk does not parse");

    Check(!ApolloParseIPhoneMachine("iPhone99999999999999999999,1", &major, &minor),
          "overflowing major identifier is rejected");
    Check(!ApolloParseIPhoneMachine("iPhone19,99999999999999999999", &major, &minor),
          "overflowing minor identifier is rejected");

    Check(ApolloParseIPhoneMachine("iPhone15,2", &major, &minor)
              && major == 15 && minor == 2,
          "parses iPhone15,2");
    Check(ApolloParseIPhoneMachine("iPhone17,5", &major, &minor)
              && major == 17 && minor == 5,
          "parses iPhone17,5");

    Check(ApolloMachineIsRecognizedByApollo("iPhone14,7"), "iPhone 14 is recognized");
    Check(ApolloMachineIsRecognizedByApollo("iPhone15,2"), "iPhone 14 Pro is recognized");
    Check(ApolloMachineIsRecognizedByApollo("iPhone15,3"), "iPhone 14 Pro Max is recognized");
    Check(!ApolloMachineIsRecognizedByApollo("iPhone15,4"), "iPhone 15 is not recognized");
    Check(!ApolloMachineIsRecognizedByApollo("iPhone19,1"), "future iPhone is not recognized");
    Check(!ApolloMachineIsRecognizedByApollo("iPad8,1"), "iPad is not an Apollo iPhone model");

    CheckKind("iPhone14,7", false, false, ApolloDeviceIdentityKeep,
              "stock notch iPhone stays unmapped");
    CheckKind("iPhone15,2", false, false, ApolloDeviceIdentityKeep,
              "stock 14 Pro stays unmapped");
    CheckKind("iPhone15,3", true, true, ApolloDeviceIdentityKeep,
              "stock 14 Pro Max stays unmapped even when an island is visible");

    CheckKind("iPhone15,4", false, false, ApolloDeviceIdentityDynamicIsland,
              "iPhone 15 remaps to island without a table entry");
    CheckKind("iPhone16,1", false, false, ApolloDeviceIdentityDynamicIsland,
              "iPhone 15 Pro remaps to island");
    CheckKind("iPhone17,1", false, false, ApolloDeviceIdentityDynamicIsland,
              "iPhone 16 Pro remaps to island");
    CheckKind("iPhone18,4", false, false, ApolloDeviceIdentityDynamicIsland,
              "iPhone Air remaps to island");
    CheckKind("iPhone19,1", false, false, ApolloDeviceIdentityDynamicIsland,
              "unknown future iPhone (Duo / 19) remaps to island");

    CheckKind("iPhone17,5", false, false, ApolloDeviceIdentityNotch,
              "iPhone 16e is the notch exception");
    CheckKind("iPhone18,5", false, false, ApolloDeviceIdentityNotch,
              "iPhone 17e is the notch exception");
    CheckKind("iPhone17,5", true, true, ApolloDeviceIdentityDynamicIsland,
              "a live island overrides a notch-exception table entry");
    CheckKind("iPhone19,1", true, false, ApolloDeviceIdentityDynamicIsland,
              "missing island on the current screen does not remap Duo to notch");

    CheckKind("arm64", false, false, ApolloDeviceIdentityKeep,
              "simulator host arch is left for the caller to replace");
    CheckKind("iPad16,1", false, false, ApolloDeviceIdentityKeep,
              "iPad identifiers are not remapped");
    CheckKind(NULL, true, true, ApolloDeviceIdentityKeep,
              "null machine stays unmapped");

    Check(strcmp(ApolloDeviceIdentityModelForKind(ApolloDeviceIdentityDynamicIsland),
                 "iPhone15,2") == 0,
          "island identity is iPhone15,2");
    Check(strcmp(ApolloDeviceIdentityModelForKind(ApolloDeviceIdentityNotch),
                 "iPhone14,7") == 0,
          "notch identity is iPhone14,7");
    Check(ApolloDeviceIdentityModelForKind(ApolloDeviceIdentityKeep) == NULL,
          "keep has no remap string");

    Check(ApolloDeviceChromeInset(0.0, 16.0) == 0.0,
          "standard 16pt layout margin does not shift chrome");
    Check(ApolloDeviceChromeInset(47.0, 47.0) == 47.0,
          "safe-area-only landscape inset is unchanged");
    Check(ApolloDeviceChromeInset(47.0, 63.0) == 47.0,
          "safe + standard 16pt margin stays on the safe area");
    Check(ApolloDeviceChromeInset(0.0, 80.0) == 64.0,
          "hinge-sized layout margin beyond 16pt is honored");
    Check(ApolloDeviceChromeInset(80.0, 80.0) == 80.0,
          "hinge reported as safe area is used as-is");
    Check(ApolloDeviceChromeInset(0.0, 16.4) == 0.0,
          "sub-point noise on the 16pt margin is ignored");
    Check(ApolloDeviceChromeExtra(47.0, 63.0) == 0.0,
          "standard safe+16 does not produce a column extra");
    Check(ApolloDeviceChromeExtra(0.0, 80.0) == 64.0,
          "hinge-sized extra is the chrome inset without the safe area");

    printf("OK: %u checks\n", checks);
    return 0;
}
