#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

/// Accessibility identifier on the Liquid Glass formatting strip. Walkers that
/// look for Apollo's own toolbar controls (GIF injection, media gating, accent
/// tint) skip this subtree.
extern NSString *const ApolloComposerGlassToolbarIdentifier;

/// Re-mirror the native toolbar's state (enabled, gating dimming) onto the
/// glass strip after a control inside `view`'s QuickBarKeyboardView changed
/// outside a layout pass. No-op when `view` isn't in a composer toolbar.
void ApolloComposerGlassToolbarSetNeedsSync(UIView *_Nullable view);

__END_DECLS
NS_ASSUME_NONNULL_END
