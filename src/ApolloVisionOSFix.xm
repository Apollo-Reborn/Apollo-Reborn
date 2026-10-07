// ApolloVisionOSFix.xm
//
// Fixes a use-after-free crash that occurs only when Apollo runs as an iOS app
// in compatibility mode on visionOS (Apple Vision Pro). iPhone and iPad are
// unaffected, so this hook is installed only when running on visionOS.
//
// Crash (EXC_BAD_ACCESS in objc_msgSend, main thread), reliably reproducible by
// loading a multireddit:
//
//   0  libobjc          objc_msgSend
//   1  UIKitCore        -[UIView(Hierarchy) subviews]
//   2  UIKitCore        -[UIView(MultiLayer) _allSubviews]
//   3  UIKitCore        _UIViewInvalidateTraitCollectionAndSchedulePropagation
//   ...
//   9  UIKitCore        -[UIView(MaterialThemes) _setOverrideUserInterfaceRenderingMode:]
//        (or -[UIView(_UIDynamicUserInterfaceStyleSPI) _setOverrideVibrancyTrait:])
//   ...
//   13 AsyncDisplayKit  -[ASTableView .cxx_destruct]   // view being deallocated
//
// Cause: Apollo is built on AsyncDisplayKit (Texture), which deallocates its
// backing UIViews asynchronously. The visionOS compatibility layer pushes
// dynamic vibrancy / rendering-mode trait overrides into the view hierarchy to
// bridge iPad UI into the spatial environment. When a heavy ASTableNode
// hierarchy is mid-teardown, that propagation walks _allSubviews and
// dereferences a UIView that AsyncDisplayKit has already freed. Native iOS does
// not push these overrides during teardown, so the race does not occur there.
//
// Fix: only on visionOS, make the two private trait-override entry points
// no-ops so UIKit never traverses the dying subtree to apply them.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

@interface UIView (ApolloVisionOSFix)
- (void)_setOverrideVibrancyTrait:(id)arg1;
- (void)_setOverrideUserInterfaceRenderingMode:(long long)arg1;
@end

%group ApolloVisionOSFix

%hook UIView

- (void)_setOverrideVibrancyTrait:(id)arg1 {
    // no-op on visionOS: avoids traversing a possibly-dying view subtree
}

- (void)_setOverrideUserInterfaceRenderingMode:(long long)arg1 {
    // no-op on visionOS: sibling override that reaches the same crash path
}

%end

%end

%ctor {
    if (ApolloIsRunningOnVisionOS()) {
        %init(ApolloVisionOSFix);
    }
}
