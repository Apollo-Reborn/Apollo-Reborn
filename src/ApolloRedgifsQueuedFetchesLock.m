#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdatomic.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloSwiftSingletonCapture.h"
#import "fishhook.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Crash (#956, #1126, #1240): EXC_BAD_ACCESS in swift_release, or a malloc
// corruption abort, on a Texture node-allocation thread while a feed with
// several RedGIFs posts loads. It is usually the first feed after launch or
// after switching accounts.
//
// Root cause is in Apollo's own binary (read out of 1.15.11): RedGIFsClient,
// a pure-Swift lazy singleton, parks fetches in its `queuedFetches` array
// while its RedGIFs auth token is in flight. Every fetch reads
// `isTokenBeingFetched` inside `dispatchQueue.sync`, but the "token is being
// fetched" branch then appends to `queuedFetches` OUTSIDE that queue. Texture
// builds post cells on about ten threads at once and each RedGIFs post cell
// calls the client from its node block, so several threads append to the same
// Swift Array at the same moment. Two of them both see its buffer as uniquely
// referenced, both grow it, and both release the old buffer: a double free.
// #1240 and #956 show two and six threads parked on that same release; in
// #1126 malloc's corruption check caught it first. The token-response
// handler also drains the array inside `dispatch_sync(dispatchQueue)`, which
// races those off-queue appends too.
//
// None of those functions has an ObjC seam, but two of Apollo's imports
// bracket every touch of the array:
// - Each append opens it with swift_beginAccess(&queuedFetches, buffer,
//   Modify|Tracking, pc) and closes it with swift_endAccess(buffer); that is
//   Swift's dynamic exclusivity check, whose access set is per thread, so it
//   never notices the cross-thread overlap itself.
// - The drain runs as a C dispatch_sync block on the client's own queue.
// fishhook rebinds those three imports in Apollo's image only, and this file
// runs every bracketed access to that one ivar, and every dispatch_sync block
// on that one queue, under one recursive mutex. That is what Apollo should
// have done (append inside the queue).
//
// Scope and cost:
// - The rebinding happens when RedGIFsClient is allocated (the first RedGIFs
//   post of the session), so sessions without RedGIFs content never route
//   through these hooks.
// - The first line of each hook compares one pointer (the captured ivar
//   address, the innermost held access buffer, or the client's queue);
//   anything else goes straight to the original.
// - Lock order is always queue -> mutex. The drain takes the mutex inside its
//   queue block, and an off-queue append never waits on the queue while
//   holding it. An append holds the mutex only across Swift runtime array
//   calls (retain, isUniquelyReferenced, grow).
//
// #568 (ApolloRedgifsSubdomainFix) sends v3.redgifs.com posts down this path,
// which is why the race is reachable more often than in stock Apollo.
//
// =============================================================================

// swift::ExclusivityFlags::Tracking. Only tracked (scoped) accesses get a
// matching swift_endAccess; an instantaneous access is a lone begin.
static const uintptr_t kApolloSwiftAccessTracking = 0x20;

// Apollo 1.15.11 nests at most two tracked accesses to the array on one
// thread (the drain's perform() re-queueing a fetch). Room to spare.
#define kApolloRedgifsMaxHeldAccesses 8

static Class sRedgifsClientClass;
static const struct mach_header *sApolloImageHeader;
static intptr_t sApolloImageSlide;

// Apollo's singleton client. It is never deallocated, so an unretained
// pointer is safe; the tweak only ever reads its dispatchQueue ivar.
static void *sRedgifsClient;
static ptrdiff_t sDispatchQueueOffset;
// &client.queuedFetches, published from the allocation hook before Apollo
// can run the client's init, let alone touch the array.
static void *_Atomic sQueuedFetchesStorage;
// client.dispatchQueue, read on the first bracketed access (init is done by
// then). Compared, never messaged.
static void *_Atomic sClientDispatchQueue;

// Recursive: the drain holds it across perform(), which re-queues a fetch.
static pthread_mutex_t sQueuedFetchesLock;
// Owner-only bookkeeping: read and written only while holding the mutex.
static unsigned sLockDepth;
static void *sHeldAccessBuffers[kApolloRedgifsMaxHeldAccesses];
static unsigned sHeldAccessCount;
// The thread holding the mutex (NULL when free). Other threads only compare
// it against themselves, so a stale read can never produce a false match.
static pthread_t _Atomic sLockOwner;
// Mirror of the innermost held buffer for swift_endAccess's first-line check.
// A buffer is a live stack slot of the thread that holds the mutex, so no
// other thread's endAccess can ever compare equal to it.
static void *_Atomic sInnermostHeldAccessBuffer;
static atomic_uint sContendedAccessCount;

typedef void (*ApolloSwiftBeginAccessFn)(void *pointer, void *buffer, uintptr_t flags, void *pc);
typedef void (*ApolloSwiftEndAccessFn)(void *buffer);
typedef void (*ApolloDispatchSyncFn)(dispatch_queue_t queue, dispatch_block_t block);
static ApolloSwiftBeginAccessFn orig_swift_beginAccess;
static ApolloSwiftEndAccessFn orig_swift_endAccess;
static ApolloDispatchSyncFn orig_dispatch_sync;

static void ApolloRedgifsReadClientQueueOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *queue = *(void **)((char *)sRedgifsClient + sDispatchQueueOffset);
        atomic_store_explicit(&sClientDispatchQueue, queue, memory_order_relaxed);
        ApolloLog(@"[RedgifsRace] RedGIFsClient dispatchQueue %p; drains now run under the queuedFetches lock", queue);
    });
}

static void ApolloRedgifsLock(void) {
    if (pthread_mutex_trylock(&sQueuedFetchesLock) != 0) {
        // Another thread is inside the array right now: without this lock the
        // two would have raced (the #1240 crash). Log the first few.
        unsigned contended = atomic_fetch_add_explicit(&sContendedAccessCount, 1, memory_order_relaxed) + 1;
        if (contended <= 3) {
            ApolloLog(@"[RedgifsRace] queuedFetches access waited for another thread (contention #%u)", contended);
        }
        pthread_mutex_lock(&sQueuedFetchesLock);
    }
    if (sLockDepth++ == 0) atomic_store_explicit(&sLockOwner, pthread_self(), memory_order_relaxed);
}

static void ApolloRedgifsUnlock(void) {
    if (--sLockDepth == 0) atomic_store_explicit(&sLockOwner, (pthread_t)NULL, memory_order_relaxed);
    pthread_mutex_unlock(&sQueuedFetchesLock);
}

static void ApolloRedgifsBeginAccess(void *pointer, void *buffer, uintptr_t flags, void *pc) {
    // With a null pc the runtime reports its own caller in conflict
    // diagnostics; keep that pointing at Apollo rather than at this hook.
    if (!pc) pc = __builtin_return_address(0);
    if (pointer != atomic_load_explicit(&sQueuedFetchesStorage, memory_order_relaxed)) {
        orig_swift_beginAccess(pointer, buffer, flags, pc);
        return;
    }
    // Pairs with the capture's release store: the client fields below were
    // written before the ivar address was published.
    atomic_thread_fence(memory_order_acquire);

    if (!(flags & kApolloSwiftAccessTracking)) {
        // An instantaneous access has no end call, so it cannot be bracketed.
        // In 1.15.x only the drains make one, inside the dispatch_sync that
        // already holds the lock. Anything else means a new code path.
        if (atomic_load_explicit(&sLockOwner, memory_order_relaxed) != pthread_self()) {
            static dispatch_once_t warnOnce;
            dispatch_once(&warnOnce, ^{
                ApolloLog(@"[RedgifsRace] Unbracketed queuedFetches access outside the lock (flags %#lx); this path is not protected",
                          (unsigned long)flags);
            });
        }
        orig_swift_beginAccess(pointer, buffer, flags, pc);
        return;
    }

    ApolloRedgifsReadClientQueueOnce();
    ApolloRedgifsLock();
    if (sHeldAccessCount < kApolloRedgifsMaxHeldAccesses) {
        sHeldAccessBuffers[sHeldAccessCount++] = buffer;
        atomic_store_explicit(&sInnermostHeldAccessBuffer, buffer, memory_order_relaxed);
    } else {
        // Unreachable in 1.15.x; fail open rather than lose track of a buffer.
        ApolloRedgifsUnlock();
        static dispatch_once_t overflowOnce;
        dispatch_once(&overflowOnce, ^{
            ApolloLog(@"[RedgifsRace] Nested queuedFetches accesses exceeded %d; leaving deeper ones unlocked",
                      kApolloRedgifsMaxHeldAccesses);
        });
    }
    orig_swift_beginAccess(pointer, buffer, flags, pc);
}

static void ApolloRedgifsEndAccess(void *buffer) {
    if (buffer != atomic_load_explicit(&sInnermostHeldAccessBuffer, memory_order_relaxed)) {
        orig_swift_endAccess(buffer);
        return;
    }
    // Only the thread holding the mutex can get here (see above).
    orig_swift_endAccess(buffer);
    sHeldAccessCount--;
    atomic_store_explicit(&sInnermostHeldAccessBuffer,
                          sHeldAccessCount ? sHeldAccessBuffers[sHeldAccessCount - 1] : NULL,
                          memory_order_relaxed);
    ApolloRedgifsUnlock();
}

static void ApolloRedgifsDispatchSync(__unsafe_unretained dispatch_queue_t queue,
                                      __unsafe_unretained dispatch_block_t block) {
    void *clientQueue = atomic_load_explicit(&sClientDispatchQueue, memory_order_relaxed);
    if (!clientQueue && queue && sRedgifsClient) {
        // Not cached until the first bracketed access. Apollo always appends
        // before it can drain, but compare against the live ivar so a drain
        // can never slip through unwrapped. Before init assigns it this reads
        // leftover heap bytes, which only ever means "not a match".
        clientQueue = atomic_load_explicit((void *_Atomic *)((char *)sRedgifsClient + sDispatchQueueOffset),
                                           memory_order_relaxed);
    }
    if (!queue || (__bridge void *)queue != clientQueue) {
        orig_dispatch_sync(queue, block);
        return;
    }
    // The token-response handler drains queuedFetches in here. Take the mutex
    // INSIDE the queue block: taking it before dispatch_sync would invert the
    // order against a no-token append that is already running on the queue
    // and waiting for the mutex. The drain can call fetch completions (on a
    // failed token); stock Apollo already runs those while holding this queue.
    orig_dispatch_sync(queue, ^{
        ApolloRedgifsLock();
        @try {
            block();
        } @finally {
            ApolloRedgifsUnlock();
        }
    });
}

static void ApolloRedgifsCaptureClient(void *client) {
    Ivar queuedFetches = class_getInstanceVariable(sRedgifsClientClass, "queuedFetches");
    Ivar dispatchQueue = class_getInstanceVariable(sRedgifsClientClass, "dispatchQueue");
    ptrdiff_t queuedFetchesOffset = queuedFetches ? ivar_getOffset(queuedFetches) : 0;
    ptrdiff_t dispatchQueueOffset = dispatchQueue ? ivar_getOffset(dispatchQueue) : 0;
    // Both sit after the Swift object header, so 0 means "not laid out".
    if (queuedFetchesOffset <= 0 || dispatchQueueOffset <= 0) {
        ApolloLog(@"[RedgifsRace] RedGIFsClient ivar offsets unusable (queuedFetches %td, dispatchQueue %td); lock not installed",
                  queuedFetchesOffset, dispatchQueueOffset);
        return;
    }

    sRedgifsClient = client;
    sDispatchQueueOffset = dispatchQueueOffset;
    atomic_store_explicit(&sQueuedFetchesStorage, (char *)client + queuedFetchesOffset, memory_order_release);

    // The orig pointers were seeded in the constructor, so a thread that picks
    // up a freshly rebound slot mid-install still calls through to the real
    // function. Apollo's image only: nothing else needs these hooks.
    rebind_symbols_image((void *)sApolloImageHeader, sApolloImageSlide, (struct rebinding[3]){
        {"swift_beginAccess", (void *)ApolloRedgifsBeginAccess, (void **)&orig_swift_beginAccess},
        {"swift_endAccess", (void *)ApolloRedgifsEndAccess, (void **)&orig_swift_endAccess},
        {"dispatch_sync", (void *)ApolloRedgifsDispatchSync, (void **)&orig_dispatch_sync},
    }, 3);
    ApolloLog(@"[RedgifsRace] Captured RedGIFsClient %p (queuedFetches +%td, dispatchQueue +%td); swift_beginAccess/swift_endAccess/dispatch_sync hook installed",
              client, queuedFetchesOffset, dispatchQueueOffset);
}

__attribute__((constructor))
static void ApolloRedgifsQueuedFetchesLockInit(void) {
    sRedgifsClientClass = objc_getClass("_TtC6Apollo13RedGIFsClient");
    if (!sRedgifsClientClass ||
        !class_getInstanceVariable(sRedgifsClientClass, "queuedFetches") ||
        !class_getInstanceVariable(sRedgifsClientClass, "dispatchQueue")) {
        ApolloLog(@"[RedgifsRace] RedGIFsClient or its queuedFetches/dispatchQueue ivars not found; lock inactive");
        return;
    }

    // Rebind in the image that defines the client (Apollo's executable, or an
    // MH_DYLIB under LiveContainer); its code is what touches the array.
    const char *imageName = class_getImageName(sRedgifsClientClass);
    for (uint32_t i = 0; imageName && i < _dyld_image_count(); i++) {
        const char *candidate = _dyld_get_image_name(i);
        if (candidate && strcmp(candidate, imageName) == 0) {
            sApolloImageHeader = _dyld_get_image_header(i);
            sApolloImageSlide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    orig_swift_beginAccess = (ApolloSwiftBeginAccessFn)dlsym(RTLD_DEFAULT, "swift_beginAccess");
    orig_swift_endAccess = (ApolloSwiftEndAccessFn)dlsym(RTLD_DEFAULT, "swift_endAccess");
    orig_dispatch_sync = (ApolloDispatchSyncFn)dlsym(RTLD_DEFAULT, "dispatch_sync");
    if (!sApolloImageHeader || !orig_swift_beginAccess || !orig_swift_endAccess || !orig_dispatch_sync) {
        ApolloLog(@"[RedgifsRace] Apollo image or runtime symbols not found; lock inactive");
        return;
    }

    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&sQueuedFetchesLock, &attributes);
    pthread_mutexattr_destroy(&attributes);

    if (ApolloCaptureFirstSwiftAllocation(sRedgifsClientClass, ApolloRedgifsCaptureClient)) {
        ApolloLog(@"[RedgifsRace] ctor: queuedFetches lock armed; hooks install when Apollo allocates RedGIFsClient");
    }
}
