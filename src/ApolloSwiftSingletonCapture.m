#import "ApolloSwiftSingletonCapture.h"

#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>

#import "ApolloCommon.h"
#import "fishhook.h"

// Registrations only come from constructors, so this never needs to grow at
// runtime. Two classes use it today (RecentlyRead, RedgifsQueuedFetchesLock).
#define kApolloSwiftSingletonCaptureMaxTargets 4

typedef struct {
    // A Swift class object doubles as its type metadata, which is what
    // swift_allocObject receives as its first argument.
    void *metadata;
    ApolloSwiftSingletonCaptureCallback callback;
    atomic_bool captured;
} ApolloSwiftSingletonCaptureTarget;

typedef struct {
    const struct mach_header *header;
    intptr_t slide;
} ApolloSwiftSingletonCaptureImage;

static ApolloSwiftSingletonCaptureTarget sTargets[kApolloSwiftSingletonCaptureMaxTargets];
static atomic_uint sTargetCount;
static atomic_uint sPendingCount;
// Images whose swift_allocObject import is rebound (one per distinct image
// that defines a registered class; Apollo's in practice).
static ApolloSwiftSingletonCaptureImage sHookedImages[kApolloSwiftSingletonCaptureMaxTargets];
static unsigned sHookedImageCount;
static os_unfair_lock sRegistrationLock = OS_UNFAIR_LOCK_INIT;

static void *(*orig_swift_allocObject)(void *metadata, size_t size, size_t alignMask);

static void ApolloSwiftSingletonCaptureRemoveHook(void) {
    // Each class's singleton is allocated by the image that defines it, so
    // only those images were rebound; put their import back.
    for (unsigned i = 0; i < sHookedImageCount; i++) {
        rebind_symbols_image((void *)sHookedImages[i].header, sHookedImages[i].slide, (struct rebinding[1]){
            {"swift_allocObject", (void *)orig_swift_allocObject, NULL}
        }, 1);
    }
}

static void *ApolloSwiftSingletonCaptureAllocObject(void *metadata, size_t size, size_t alignMask) {
    void *object = orig_swift_allocObject(metadata, size, alignMask);
    // Hot path: every Swift allocation Apollo makes lands here until all
    // targets are captured. One compare per registered class, then return.
    unsigned count = atomic_load_explicit(&sTargetCount, memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        ApolloSwiftSingletonCaptureTarget *target = &sTargets[i];
        if (target->metadata != metadata) continue;
        bool expected = false;
        if (object && atomic_compare_exchange_strong(&target->captured, &expected, true)) {
            ApolloLog(@"[SwiftSingletonCapture] Captured %s %p", class_getName((__bridge Class)metadata), object);
            target->callback(object);
            if (atomic_fetch_sub(&sPendingCount, 1) == 1) {
                // Every registered class is captured: restore the original so
                // later allocations pay nothing.
                ApolloSwiftSingletonCaptureRemoveHook();
                ApolloLog(@"[SwiftSingletonCapture] All %u singletons captured; swift_allocObject hook removed", count);
            }
        }
        break;
    }
    return object;
}

static BOOL ApolloSwiftSingletonCaptureImageForClass(Class swiftClass, ApolloSwiftSingletonCaptureImage *image) {
    // Apollo's executable normally, an MH_DYLIB under LiveContainer.
    const char *imageName = class_getImageName(swiftClass);
    for (uint32_t i = 0; imageName && i < _dyld_image_count(); i++) {
        const char *candidate = _dyld_get_image_name(i);
        if (candidate && strcmp(candidate, imageName) == 0) {
            image->header = _dyld_get_image_header(i);
            image->slide = _dyld_get_image_vmaddr_slide(i);
            return image->header != NULL;
        }
    }
    return NO;
}

BOOL ApolloCaptureFirstSwiftAllocation(Class swiftClass, ApolloSwiftSingletonCaptureCallback callback) {
    if (!swiftClass || !callback) return NO;
    ApolloSwiftSingletonCaptureImage image;
    if (!ApolloSwiftSingletonCaptureImageForClass(swiftClass, &image)) {
        ApolloLog(@"[SwiftSingletonCapture] No image for %s; not capturing", class_getName(swiftClass));
        return NO;
    }

    os_unfair_lock_lock(&sRegistrationLock);
    unsigned count = atomic_load_explicit(&sTargetCount, memory_order_relaxed);
    if (count >= kApolloSwiftSingletonCaptureMaxTargets) {
        os_unfair_lock_unlock(&sRegistrationLock);
        ApolloLog(@"[SwiftSingletonCapture] Registry full; not capturing %s", class_getName(swiftClass));
        return NO;
    }
    BOOL imageHooked = NO;
    for (unsigned i = 0; i < sHookedImageCount; i++) {
        if (sHookedImages[i].header == image.header) imageHooked = YES;
    }
    if (!imageHooked) sHookedImages[sHookedImageCount++] = image;

    ApolloSwiftSingletonCaptureTarget *target = &sTargets[count];
    target->metadata = (__bridge void *)swiftClass;
    target->callback = callback;
    atomic_init(&target->captured, false);
    atomic_fetch_add(&sPendingCount, 1);
    // Publish the filled slot before the hook can read it.
    atomic_store_explicit(&sTargetCount, count + 1, memory_order_release);
    os_unfair_lock_unlock(&sRegistrationLock);

    if (!imageHooked) {
        // Constructors run before Apollo's code, so nothing can call through
        // the slot while it is being rebound.
        rebind_symbols_image((void *)image.header, image.slide, (struct rebinding[1]){
            {"swift_allocObject", (void *)ApolloSwiftSingletonCaptureAllocObject, (void **)&orig_swift_allocObject}
        }, 1);
        ApolloLog(@"[SwiftSingletonCapture] swift_allocObject hook installed");
    }
    ApolloLog(@"[SwiftSingletonCapture] Waiting for first %s allocation", class_getName(swiftClass));
    return YES;
}
