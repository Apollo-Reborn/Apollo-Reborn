#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloExecutableSDK.h"
#import "fishhook.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Extend only Apollo's three native iamthatis color checks.
static const uint64_t kIamthatisLo = 0x69746168746d6169ULL;
static const uint64_t kIamthatisHi = 0xe900000000000073ULL;
static const char *kCompareSymbol = "$ss27_stringCompareWithSmolCheck__9expectingSbs11_StringGutsV_ADs01_G16ComparisonResultOtF";

typedef bool (*ApolloStringCompareFn)(uint64_t, uint64_t, uint64_t, uint64_t, uint8_t);
typedef void *(*ApolloStringBridgeFn)(uint64_t, uint64_t); // Returns +1 NSString.
static ApolloStringCompareFn sOriginalCompare;
static ApolloStringBridgeFn sStringBridge;
static uintptr_t sResolverSites[3];

static BOOL ApolloIsMaintainerUsername(NSString *username) {
    if (!username) return NO;
    static NSString *const names[] = {
        @"ClydeDroid", @"corderjones", @"DeltAndy",
        @"iChopPryde", @"IllIIllIllIllII", @"musiquorum"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
        if ([username caseInsensitiveCompare:names[i]] == NSOrderedSame) return YES;
    }
    return NO;
}

__attribute__((noinline))
static bool ApolloMaintainerCompareCold(uint64_t l0, uint64_t l1, uint8_t expecting, uintptr_t caller) {
    if (expecting == 0 && (caller == sResolverSites[0] || caller == sResolverSites[1] || caller == sResolverSites[2])) {
        NSString *author = (__bridge_transfer NSString *)sStringBridge(l0, l1);
        if (ApolloIsMaintainerUsername(author)) return true;
    }
    return sOriginalCompare(l0, l1, kIamthatisLo, kIamthatisHi, expecting);
}

static bool ApolloMaintainerCompare(uint64_t l0, uint64_t l1, uint64_t r0, uint64_t r1, uint8_t expecting) {
    // All other comparisons pass through without touching Objective-C objects.
    if (__builtin_expect(r0 == kIamthatisLo && r1 == kIamthatisHi, 0)) {
        return ApolloMaintainerCompareCold(l0, l1, expecting, (uintptr_t)__builtin_return_address(0));
    }
    return sOriginalCompare(l0, l1, r0, r1, expecting);
}

static BOOL ApolloMaintainerSupportedImage(const struct mach_header *header, intptr_t slide) {
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return NO;
    // Apollo 1.15.11; packaging and ASLR preserve this UUID and code layout.
    const uint8_t expectedUUID[16] = {
        0x9e, 0x4e, 0xc7, 0xac, 0x92, 0xb8, 0x3a, 0x03,
        0x85, 0x6c, 0xce, 0x36, 0x64, 0xd7, 0x6b, 0x97
    };
    if (!ApolloMachOHasUUID(header, expectedUUID)) return NO;

    // Post, comment, inbox: each BL targets the same Swift comparison stub.
    const uintptr_t calls[] = {0x10039ddac, 0x100503ee4, 0x10068003c};
    const uint32_t branches[] = {0x9419ade7, 0x94141599, 0x940e2543};
    const uint32_t arguments[] = {
        0xd28c2d22, 0xf2ae8da2, 0xf2cc2d02, 0xf2ed2e82,
        0xd2800e63, 0xf2fd2003, 0x52800004
    }; // rhs = "iamthatis", expecting = .equal.
    for (size_t i = 0; i < 3; i++) {
        uintptr_t call = calls[i] + slide;
        if (*(const uint32_t *)call != branches[i] ||
            memcmp((const void *)(call - sizeof(arguments)), arguments, sizeof(arguments)) != 0) return NO;
        sResolverSites[i] = call + 4;
    }
    // adrp/ldr/br through the import slot at 0x100bb4800.
    const uint32_t stub[] = {0xf0000d50, 0xf9440210, 0xd61f0200};
    return memcmp((const void *)(0x100a09548 + slide), stub, sizeof(stub)) == 0;
}

__attribute__((constructor))
static void ApolloMaintainerTintInit(void) {
    const struct mach_header *header = NULL;
    intptr_t slide = 0;
    // Class ownership also finds Apollo when LiveContainer loads it as a dylib.
    const char *imageName = ApolloClassCommentCellNode ? class_getImageName(ApolloClassCommentCellNode) : NULL;
    for (uint32_t i = 0; imageName && i < _dyld_image_count(); i++) {
        const char *candidate = _dyld_get_image_name(i);
        if (candidate && strcmp(candidate, imageName) == 0) {
            header = _dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    sOriginalCompare = (ApolloStringCompareFn)dlsym(RTLD_DEFAULT, kCompareSymbol);
    sStringBridge = (ApolloStringBridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    if (!header || !sOriginalCompare || !sStringBridge || !ApolloMaintainerSupportedImage(header, slide)) {
        ApolloLog(@"MaintainerTint: unsupported Apollo image or missing Swift symbols; native tint hook inactive");
        return;
    }

    int result = rebind_symbols_image((void *)header, slide, (struct rebinding[1]){
        {kCompareSymbol, (void *)ApolloMaintainerCompare, (void **)&sOriginalCompare}
    }, 1);
    // fishhook's return value alone does not confirm that a slot was patched.
    if (result != 0 || *(void **)(0x100bb4800 + slide) != (void *)ApolloMaintainerCompare) {
        ApolloLog(@"MaintainerTint: comparison import was not rebound; native tint hook inactive");
        return;
    }
    ApolloLog(@"MaintainerTint: native comparison hook installed for six maintainers");
}
