#ifndef APOLLO_EXECUTABLE_SDK_H
#define APOLLO_EXECUTABLE_SDK_H

#include <mach-o/loader.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Apollo has only a few KB of load commands. Bound this independently of an
// image's declared command count before walking its header at startup.
enum { ApolloMaximumMachOLoadCommandBytes = 1024 * 1024 };

// Shared identity guard for native-code hooks; SDK/packaging changes preserve LC_UUID.
static inline bool ApolloMachOHasUUID(const struct mach_header *image, const uint8_t expected[16]) {
    if (!image || image->magic != MH_MAGIC_64 || image->cputype != CPU_TYPE_ARM64 ||
        image->sizeofcmds > ApolloMaximumMachOLoadCommandBytes) return false;
    const uint8_t *cursor = (const uint8_t *)((const struct mach_header_64 *)image + 1);
    const uint8_t *end = cursor + image->sizeofcmds;
    for (uint32_t i = 0; i < image->ncmds; i++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return false;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor) ||
            (command->cmdsize & 7) != 0) return false;
        if (command->cmd == LC_UUID) {
            return command->cmdsize >= sizeof(struct uuid_command) &&
                memcmp(((const struct uuid_command *)command)->uuid, expected, 16) == 0;
        }
        cursor += command->cmdsize;
    }
    return false;
}

// Reads a mapped Mach-O header and its load-command bytes, not a file's whole
// contents. The explicit extent also lets host tests exercise truncated or
// malformed commands without reading past their fixture. Filetype is
// deliberately irrelevant: LiveContainer loads Apollo as MH_DYLIB.
static inline uint32_t ApolloSDKVersionFromMachO(const void *bytes, size_t length) {
    if (!bytes || length < sizeof(struct mach_header_64)) return 0;
    struct mach_header_64 header;
    memcpy(&header, bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 ||
        header.sizeofcmds > ApolloMaximumMachOLoadCommandBytes ||
        header.sizeofcmds > length - sizeof(header) ||
        header.ncmds > header.sizeofcmds / sizeof(struct load_command)) return 0;

    size_t offset = sizeof(header);
    size_t end = offset + header.sizeofcmds;
    uint32_t sdk = 0;
    uint32_t legacySDK = 0;
    bool hasBuildVersion = false;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (end - offset < sizeof(struct load_command)) return 0;
        struct load_command command;
        memcpy(&command, (const char *)bytes + offset, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > end - offset ||
            (command.cmdsize & 7) != 0) return 0;
        if (command.cmd == LC_BUILD_VERSION) {
            if (command.cmdsize < sizeof(struct build_version_command)) return 0;
            struct build_version_command build;
            memcpy(&build, (const char *)bytes + offset, sizeof(build));
            if (build.ntools > (command.cmdsize - sizeof(build)) / sizeof(struct build_tool_version)) return 0;
            if (build.platform == PLATFORM_IOS || build.platform == PLATFORM_IOSSIMULATOR) {
                if (hasBuildVersion) return 0;
                hasBuildVersion = true;
                sdk = build.sdk;
            }
        } else if (command.cmd == LC_VERSION_MIN_IPHONEOS) {
            if (command.cmdsize < sizeof(struct version_min_command)) return 0;
            struct version_min_command version;
            memcpy(&version, (const char *)bytes + offset, sizeof(version));
            legacySDK = version.sdk;
        }
        offset += command.cmdsize;
    }
    if (offset != end) return 0;
    return hasBuildVersion ? sdk : legacySDK;
}

static inline bool ApolloSDKEnablesLiquidGlass(uint32_t sdk, bool glassRuntime) {
    // The original iOS 26 SDK encoded its version as 19.0; later toolchains
    // use 26/27. Keep both forms, but never enable glass on an older runtime.
    return glassRuntime && (sdk >> 16) >= 19;
}

// Apple ignores UIDesignRequiresCompatibility for executables linked with
// SDK 27+. The released glass patch stamps SDK 19 (the original iOS 26
// encoding); SDK 26 is supported too. Do not offer a switch that UIKit would
// ignore if a future packager raises the executable's SDK again.
static inline bool ApolloSDKSupportsLiquidGlassCompatibility(uint32_t sdk, bool glassRuntime) {
    return ApolloSDKEnablesLiquidGlass(sdk, glassRuntime) && (sdk >> 16) < 27;
}

// SDK 27 is required for Duo's native canvas, but no longer honors the plist
// opt-out. A separately validated UIKit launch override can serve single-
// display devices. Unknown capabilities and future SDK/OS versions keep the
// system design; they must not expose a switch we cannot apply.
static inline bool ApolloSDKSupportsLiquidGlassRuntimeSelection(uint32_t sdk,
                                                               bool glassRuntime,
                                                               long runtimeMajor,
                                                               long logicalDisplayCount) {
    return glassRuntime && (sdk >> 16) == 27 &&
        (runtimeMajor == 26 || runtimeMajor == 27) && logicalDisplayCount == 1;
}

#endif
