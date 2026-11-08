#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

void ApolloTabBarIconTintSetEnabled(BOOL enabled);
// YES for the inactive icon tint's own color, which ApolloLiquidGlass.xm's
// appearance scrub must keep.
BOOL ApolloTabBarIconTintOwnsColor(UIColor *_Nullable color);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
