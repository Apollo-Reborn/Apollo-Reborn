#import <Foundation/Foundation.h>

// Captures the first instance of an Apollo Swift class at the moment it is
// allocated. Several Apollo services are pure-Swift lazy singletons with no
// ObjC entry point (ReadPostsTracker, RedGIFsClient); swift_allocObject is the
// one place their instance pointer is visible from the tweak.
//
// This module is the ONLY owner of the swift_allocObject rebinding. fishhook
// keeps a single `replaced` slot per rebinding and rewrites it from every image
// it walks, so two modules that each hook swift_allocObject and later unhook
// with a global rebind cut each other out of the chain. Register here instead
// of rebinding swift_allocObject yourself.
//
// Call from a constructor, before Apollo can allocate the class. `callback`
// runs once, synchronously on the allocating thread, with the fresh (not yet
// initialised) object; it must not message the object or run Swift code on it.
// The hook removes itself once every registered class has been captured.
typedef void (*ApolloSwiftSingletonCaptureCallback)(void *object);

__BEGIN_DECLS
BOOL ApolloCaptureFirstSwiftAllocation(Class swiftClass, ApolloSwiftSingletonCaptureCallback callback);
__END_DECLS
