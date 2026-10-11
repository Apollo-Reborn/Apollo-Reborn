#ifndef APOLLO_DEVICE_IDENTITY_H
#define APOLLO_DEVICE_IDENTITY_H

#include <stdbool.h>
#include <limits.h>
#include <string.h>

// Apollo's device mapper (sub_1007a3cdc) only recognizes models through
// iPhone 14 Pro Max (iPhone15,3). Anything newer returns "unknown" (0x3f) and
// Pixel Pals / FauxCutOutView stay off. The tweak remaps those identifiers
// to a model Apollo already understands:
//
//   iPhone15,2  — iPhone 14 Pro (Dynamic Island)
//   iPhone14,7  — iPhone 14 (notch)
//
// A closed whitelist of every post-14-Pro machine ID goes stale the moment
// Apple ships another phone (iPhone Duo, iPhone 19, …). Unrecognized iPhones
// therefore default to the Dynamic Island identity. The only models that
// must stay on the notch identity are the known island-less ones (16e / 17e).
//
// Process-wide identity is a feature flag (enable pals / faux cutout), not a
// layout. Per-window chrome uses live cutout / safe-area geometry
// (ApolloDeviceGeometry) so a foldable can hide the faux island on a display
// that has no cutout without remapping the whole process to a notch phone.
//
// Foundation/C only so host tests can compile this header without UIKit.

#define APOLLO_DEVICE_IDENTITY_DYNAMIC_ISLAND "iPhone15,2"
#define APOLLO_DEVICE_IDENTITY_NOTCH          "iPhone14,7"

typedef enum {
    ApolloDeviceIdentityKeep = 0,
    ApolloDeviceIdentityDynamicIsland,
    ApolloDeviceIdentityNotch
} ApolloDeviceIdentityKind;

static inline bool ApolloParseIPhoneMachine(const char *machine, int *major, int *minor) {
    if (!machine || strncmp(machine, "iPhone", 6) != 0) return false;
    const char *p = machine + 6;
    if (*p < '0' || *p > '9') return false;
    int parsedMajor = 0;
    while (*p >= '0' && *p <= '9') {
        if (parsedMajor > (INT_MAX - (*p - '0')) / 10) return false;
        parsedMajor = parsedMajor * 10 + (*p - '0');
        p++;
    }
    if (*p != ',') return false;
    p++;
    if (*p < '0' || *p > '9') return false;
    int parsedMinor = 0;
    while (*p >= '0' && *p <= '9') {
        if (parsedMinor > (INT_MAX - (*p - '0')) / 10) return false;
        parsedMinor = parsedMinor * 10 + (*p - '0');
        p++;
    }
    if (*p != '\0') return false;
    if (major) *major = parsedMajor;
    if (minor) *minor = parsedMinor;
    return true;
}

// Apollo's mapper knows every iPhone through iPhone15,3 (14 Pro Max).
static inline bool ApolloMachineIsRecognizedByApollo(const char *machine) {
    int major = 0;
    int minor = 0;
    if (!ApolloParseIPhoneMachine(machine, &major, &minor)) return false;
    if (major < 15) return true;
    return major == 15 && minor <= 3;
}

// Island-less models newer than iPhone 14 Pro Max. Add new notch-only
// identifiers here when Apple ships them; do not add Dynamic Island models.
static inline bool ApolloMachineIsKnownNotchException(int major, int minor) {
    return (major == 17 && minor == 5)   // iPhone 16e
        || (major == 18 && minor == 5);  // iPhone 17e
}

// geometryAvailable/hasIslandCutout come from the current screen's
// -[UIScreen _exclusionArea] when the caller has one. A live island always
// wins (hardware truth). A missing island on the current screen does NOT
// force the notch identity — that is the folded-out Duo inner display case,
// where the outer display still has an island and pals should stay enabled.
static inline ApolloDeviceIdentityKind ApolloDeviceIdentityKindForMachine(
    const char *machine,
    bool geometryAvailable,
    bool hasIslandCutout)
{
    int major = 0;
    int minor = 0;
    if (!ApolloParseIPhoneMachine(machine, &major, &minor)) {
        return ApolloDeviceIdentityKeep;
    }
    if (ApolloMachineIsRecognizedByApollo(machine)) {
        return ApolloDeviceIdentityKeep;
    }
    if (geometryAvailable && hasIslandCutout) {
        return ApolloDeviceIdentityDynamicIsland;
    }
    if (ApolloMachineIsKnownNotchException(major, minor)) {
        return ApolloDeviceIdentityNotch;
    }
    return ApolloDeviceIdentityDynamicIsland;
}

static inline const char *ApolloDeviceIdentityModelForKind(ApolloDeviceIdentityKind kind) {
    switch (kind) {
        case ApolloDeviceIdentityDynamicIsland:
            return APOLLO_DEVICE_IDENTITY_DYNAMIC_ISLAND;
        case ApolloDeviceIdentityNotch:
            return APOLLO_DEVICE_IDENTITY_NOTCH;
        case ApolloDeviceIdentityKeep:
        default:
            return NULL;
    }
}

#endif
