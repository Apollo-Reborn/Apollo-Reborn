// Memory diagnostics + coordinated cache purging.
//
// Motivation: the 8/2026 crash-report wave (issues #806/#811/#814/#816/#820)
// showed Apollo reaching 550-750MB phys footprint and dying in every way an
// OOM can present (jetsam, allocation-failure aborts, couldNotInstantiate
// recursion) — while apollo-reborn.log carried zero memory signal. This module
// makes footprint visible in the log and gives cache-owning modules a single
// place to register purge handlers that run on UIKit memory warnings.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Current phys_footprint in MB (the number jetsam judges), or -1 if the
// task_info query fails.
double ApolloMemoryFootprintMB(void);

// Register a named handler run on the main queue whenever UIKit posts
// UIApplicationDidReceiveMemoryWarningNotification. Handlers should drop
// re-derivable caches (decoded images, poster frames, players). The name is
// logged with the purge. Safe to call from any thread, including before the
// app finishes launching.
void ApolloMemoryRegisterPurgeHandler(NSString *name, void (^handler)(void));

// Register an image cache to be emptied by the same warning. The registry
// retains `cache` for the process lifetime, so this is for the singleton caches
// modules build in a dispatch_once — never for a per-view-controller one.
void ApolloMemoryRegisterPurgableCache(NSString *name, NSCache *cache);

// Log the current footprint with a context tag (e.g. after a purge, at a
// suspected growth point). Rate-limited only by the caller.
void ApolloMemoryLogFootprint(NSString *context);

__END_DECLS
NS_ASSUME_NONNULL_END
