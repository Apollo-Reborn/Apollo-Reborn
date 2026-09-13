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

#endif
