// Sim-only: run +[ASDisplayNode initialize] before any Logos %init, so %hooks
// on Texture lifecycle callbacks that a node class INHERITS (rather than
// implements) install in simulator builds the way they do on device.
//
// +[ASDisplayNode initialize] class_addMethod's no-op stubs for the lifecycle
// callbacks onto ASDisplayNode only: baseDidInit, baseWillDealloc, didLoad,
// layoutDidFinish, did{Enter,Exit}{Preload,Display,Visible}State,
// hierarchyDisplayDidFinish, calculatedLayoutDidChange, willCalculateLayout:,
// interfaceStateDidChange:fromState:, layerActionForKey:. Until something
// messages ASDisplayNode, those selectors exist nowhere in e.g.
// LinkButtonNode -> ASControlNode -> ASDisplayNode.
//
// The sim build uses the internal Logos generator (scripts/run-in-sim.sh),
// whose _logos_register_hook walks class_copyMethodList up the superclass
// chain. That never runs +initialize, so a %hook of an inherited callback
// registered from a %ctor finds nothing and is skipped silently: no log, and
// its _logos_orig stays NULL. Device builds hook through Substrate's
// MSHookMessageEx, whose class_getInstanceMethod falls back to the method
// resolver, which messages the class and runs +initialize first, so the same
// hooks install on device.
//
// +load rather than a constructor: ObjC +load methods of an image run before
// that image's C/C++ constructors, so this lands ahead of every %ctor and
// _logosLocalInit in the dylib whatever the link order (today the first one
// is ApolloAISummary.xm's). Compiled only into APOLLO_SIM_BUILD (see the
// Makefile's sim-only file list); device and release builds never contain it.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

static BOOL ApolloSimClassOwnsSelector(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

@interface ApolloSimTextureInit : NSObject
@end

@implementation ApolloSimTextureInit

+ (void)load {
    Class asDisplayNode = objc_getClass("ASDisplayNode");
    if (!asDisplayNode) {
        ApolloLog(@"[SimTextureInit] ASDisplayNode not found; inherited Texture lifecycle %%hooks will not install in this sim build");
        return;
    }

    // A real message send is what makes the runtime run +initialize. Send
    // +class through objc_msgSend explicitly: clang lowers [cls class] to
    // objc_opt_class, which can answer without messaging the class.
    ((Class (*)(id, SEL))objc_msgSend)(asDisplayNode, @selector(class));

    // Tripwire: if a Texture update stops adding the stubs in +initialize,
    // the inherited-callback hooks would silently stop installing again.
    BOOL stubbed = ApolloSimClassOwnsSelector(asDisplayNode, @selector(didEnterVisibleState));
    ApolloLog(@"[SimTextureInit] ASDisplayNode initialized before Logos %%init; lifecycle stubs %@",
              stubbed ? @"present" : @"MISSING (inherited Texture lifecycle hooks will not install)");
}

@end
