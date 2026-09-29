#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ApolloExecutableSDK.h"

typedef struct {
    struct mach_header_64 header;
    struct build_version_command build;
    struct version_min_command legacy;
} SDKFixture;

typedef struct {
    const char *path;
    const struct mach_header *header;
} LoadedImage;

static LoadedImage images[4];
static uint32_t imageCount;
static const char *nativeImageName;
static unsigned availableNativeClasses = 1;
static unsigned checks;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static SDKFixture Fixture(uint32_t sdk, uint32_t platform, uint32_t filetype) {
    SDKFixture fixture = {0};
    fixture.header.magic = MH_MAGIC_64;
    fixture.header.filetype = filetype;
    fixture.header.ncmds = 1;
    fixture.header.sizeofcmds = sizeof(fixture.build);
    fixture.build.cmd = LC_BUILD_VERSION;
    fixture.build.cmdsize = sizeof(fixture.build);
    fixture.build.platform = platform;
    fixture.build.sdk = sdk;
    return fixture;
}

static Class QAClassLookup(const char *name) {
    if ((availableNativeClasses & 1) && strcmp(name, "_TtC6Apollo11AppDelegate") == 0) return NSObject.class;
    if ((availableNativeClasses & 2) && strcmp(name, "_TtC6Apollo13SceneDelegate") == 0) return NSObject.class;
    if ((availableNativeClasses & 4) && strcmp(name, "_TtC6Apollo19PostsViewController") == 0) return NSObject.class;
    return Nil;
}
static const char *QAClassImageName(__unused Class cls) { return nativeImageName; }
static uint32_t QAImageCount(void) { return imageCount; }
static const char *QAImageName(uint32_t index) { return images[index].path; }
static const struct mach_header *QAImageHeader(uint32_t index) { return images[index].header; }

// Exercise the actual production class/image selection, with only the loader
// and class registry substituted. This tests image order and class fallback,
// rather than reimplementing the new selection algorithm in the harness.
#define objc_lookUpClass QAClassLookup
#define class_getImageName QAClassImageName
#define _dyld_image_count QAImageCount
#define _dyld_get_image_name QAImageName
#define _dyld_get_image_header QAImageHeader
#include "ExecutableSDKSelection.inc"
#undef objc_lookUpClass
#undef class_getImageName
#undef _dyld_image_count
#undef _dyld_get_image_name
#undef _dyld_get_image_header

static uint32_t OldFirstExecutableSDK(void) {
    const struct mach_header_64 *header = NULL;
    for (uint32_t i = 0; i < imageCount; i++) {
        if (images[i].header && images[i].header->filetype == MH_EXECUTE) {
            header = (const struct mach_header_64 *)images[i].header;
            break;
        }
    }
    if (!header && imageCount) header = (const struct mach_header_64 *)images[0].header;
    return header ? ApolloSDKVersionFromMachO(header, sizeof(*header) + header->sizeofcmds) : 0;
}

static void TestImageSelection(void) {
    SDKFixture host = Fixture(0x001A0000, PLATFORM_IOS, MH_EXECUTE);
    SDKFixture guest = Fixture(0x00100000, PLATFORM_IOS, MH_DYLIB);
    SDKFixture tweak = Fixture(0x001B0000, PLATFORM_IOS, MH_DYLIB);
    nativeImageName = "/guest/Apollo.app/Apollo";
    images[0] = (LoadedImage){"/host/LiveContainer.app/LiveContainer", (const struct mach_header *)&host};
    images[1] = (LoadedImage){nativeImageName, (const struct mach_header *)&guest};
    images[2] = (LoadedImage){"/guest/Apollo.app/Frameworks/ApolloReborn.dylib", (const struct mach_header *)&tweak};
    imageCount = 3;
    Check(ApolloSDKEnablesLiquidGlass(OldFirstExecutableSDK(), true),
          @"old first-executable detector reproduces false glass for a classic hosted guest");
    Check(GetLinkedSDKVersion() == guest.build.sdk, @"hosted guest is selected despite MH_DYLIB filetype");
    Check(!ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), true),
          @"standard, noext and glass-icons guests retain classic chrome under a glass-linked host");
    Check(!ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), false), @"classic guest stays classic on iOS 18");

    LoadedImage swap = images[0];
    images[0] = images[2];
    images[2] = swap;
    Check(GetLinkedSDKVersion() == guest.build.sdk, @"injected tweak at image zero is ignored");
    guest.header.filetype = MH_EXECUTE;
    guest.build.platform = PLATFORM_IOSSIMULATOR;
    Check(GetLinkedSDKVersion() == guest.build.sdk, @"standalone simulator executable is selected by native class");
    guest.build.sdk = 0x00130000;
    Check(ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), true), @"SDK 19 encoding preserves glass-patched simulator");
    Check(!ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), false), @"glass-patched guest cannot enable glass on iOS 18");
    guest.build.platform = PLATFORM_IOS;
    guest.header.filetype = MH_DYLIB;
    guest.build.sdk = 0x001A0000;
    Check(ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), true), @"glass guest works on iOS 26");
    guest.build.sdk = 0x001B0000;
    Check(ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), true), @"glass guest works on iOS 27");
    Check(!ApolloSDKEnablesLiquidGlass(GetLinkedSDKVersion(), false), @"future-linked guest still requires glass runtime");
    availableNativeClasses = 2;
    Check(GetLinkedSDKVersion() == guest.build.sdk, @"SceneDelegate identifies the native image when AppDelegate is absent");
    availableNativeClasses = 4;
    Check(GetLinkedSDKVersion() == guest.build.sdk, @"PostsViewController identifies the native image when delegate classes are absent");
    availableNativeClasses = 0;
    Check(GetLinkedSDKVersion() == 0, @"missing native classes never fall back to the host");
    availableNativeClasses = 1;
    nativeImageName = "/other/Apollo.app/Apollo";
    Check(GetLinkedSDKVersion() == 0, @"similar basename cannot select the wrong image");
    nativeImageName = "";
    Check(GetLinkedSDKVersion() == 0, @"empty native image path disables glass");
    nativeImageName = NULL;
    Check(GetLinkedSDKVersion() == 0, @"missing native image path disables glass");
    nativeImageName = "/guest/Apollo.app/Apollo";
    guest.header.sizeofcmds = UINT32_MAX;
    Check(GetLinkedSDKVersion() == 0, @"malformed guest metadata cannot fall back to the host SDK");
    images[1].header = NULL;
    Check(GetLinkedSDKVersion() == 0, @"unavailable guest header never falls back to host or tweak");
    imageCount = 0;
    Check(GetLinkedSDKVersion() == 0, @"empty image list disables glass");
}

static void TestLoadCommands(void) {
    SDKFixture good = Fixture(0x001A0000, PLATFORM_IOS, MH_DYLIB);
    Check(ApolloSDKVersionFromMachO(&good, sizeof(good)) == good.build.sdk, @"valid iOS build version parses");
    Check(ApolloSDKVersionFromMachO(NULL, sizeof(good)) == 0, @"null header is rejected");
    Check(ApolloSDKVersionFromMachO(&good, sizeof(good.header) - 1) == 0, @"truncated header is rejected");
    Check(ApolloSDKVersionFromMachO(&good, sizeof(good.header) + sizeof(good.build) - 1) == 0,
          @"truncated load commands are rejected");
    SDKFixture bad = good;
    bad.header.magic = MH_CIGAM_64;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"unsupported byte order is rejected");
    bad = good;
    bad.header.sizeofcmds = UINT32_MAX;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"oversized load-command area is rejected");
    bad = good;
    bad.header.ncmds = UINT32_MAX;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"impossible command count is rejected");
    bad = good;
    bad.build.cmdsize = 0;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"zero-sized command cannot loop forever");
    bad = good;
    bad.build.cmdsize = UINT32_MAX;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"command overrun is rejected");
    bad = good;
    bad.build.cmdsize = 23;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"unaligned command is rejected");
    bad = good;
    bad.build.cmdsize = sizeof(struct load_command);
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"short build-version payload is rejected");
    bad = good;
    bad.build.ntools = 1;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"truncated build-tool table is rejected");
    bad = good;
    bad.build.platform = PLATFORM_MACOS;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"macOS SDK cannot enable iOS glass");
    bad = good;
    bad.header.ncmds = 2;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"command count exceeding area is rejected");
    bad = good;
    bad.header.sizeofcmds += 8;
    Check(ApolloSDKVersionFromMachO(&bad, sizeof(bad)) == 0, @"unaccounted command bytes are rejected");
    SDKFixture legacy = good;
    struct version_min_command minimum = {LC_VERSION_MIN_IPHONEOS, sizeof(minimum), 0x000E0000, 0x00100000};
    memcpy(&legacy.build, &minimum, sizeof(minimum));
    legacy.header.sizeofcmds = sizeof(minimum);
    Check(ApolloSDKVersionFromMachO(&legacy, sizeof(legacy)) == 0x00100000, @"legacy iPhoneOS SDK command parses");
    good.header.ncmds = 2;
    good.header.sizeofcmds += sizeof(good.legacy);
    good.legacy = minimum;
    Check(ApolloSDKVersionFromMachO(&good, sizeof(good)) == good.build.sdk,
          @"build-version SDK takes precedence over legacy SDK metadata");

    struct {
        struct mach_header_64 header;
        struct uuid_command uuid;
        struct build_version_command build;
    } preceded = {0};
    preceded.header = good.header;
    preceded.header.sizeofcmds = sizeof(preceded.uuid) + sizeof(preceded.build);
    preceded.uuid.cmd = LC_UUID;
    preceded.uuid.cmdsize = sizeof(preceded.uuid);
    preceded.build = good.build;
    Check(ApolloSDKVersionFromMachO(&preceded, sizeof(preceded)) == good.build.sdk,
          @"unrelated load commands before the SDK are skipped safely");
    struct {
        struct mach_header_64 header;
        struct build_version_command builds[2];
    } duplicate = {0};
    duplicate.header = good.header;
    duplicate.header.sizeofcmds = sizeof(duplicate.builds);
    duplicate.builds[0] = good.build;
    duplicate.builds[1] = good.build;
    Check(ApolloSDKVersionFromMachO(&duplicate, sizeof(duplicate)) == 0,
          @"ambiguous duplicate iOS build-version commands are rejected");
}

int main(void) {
    @autoreleasepool {
        TestImageSelection();
        TestLoadCommands();
        printf("PASS: %u executable SDK and Liquid Glass checks\n", checks);
    }
    return 0;
}
