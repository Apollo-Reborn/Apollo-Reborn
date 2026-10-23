#import <UIKit/UIKit.h>

// One-off Halloween look for the 3.9.0 What's New sheet (October 2026): the
// header shows Count Helios (the vampire icon from the Helios pack) instead of
// the current app icon, the accent turns pumpkin orange, and a small flock of
// bats bursts out of the icon, flutters across the sheet and flies off its
// edges. Only the 3.9.0 sheet gets it, and the sheet itself is shown once per
// version, so each user sees it once. Delete this file, ApolloWhatsNewHalloween.m,
// Resources/WhatsNewCountHelios{,Dark}.png, the Makefile line and the calls in
// ApolloWhatsNew.xm once 3.9.0 is no longer the current release.
//
// Called from ApolloWhatsNew.xm (Objective-C++), defined in plain ObjC, so the
// declarations are wrapped in extern "C" like ApolloWhatsNew.h.
NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// YES only for the release the look was made for ("3.9.0").
BOOL ApolloWhatsNewHalloweenWantedForVersion(NSString *version);

// Count Helios, light and dark (one image that follows the view's appearance),
// rendered from liquid-glass/icons/helios-count/helios-count.icon with Icon
// Composer's ictool at 64pt @3x. Bundled with the tweak, so standard builds
// without the Liquid Glass icon catalog have it too. nil if the files are
// missing, so the caller keeps the current app icon.
UIImage *_Nullable ApolloWhatsNewHalloweenIcon(void);

// Pumpkin orange, a touch deeper in light mode. Both variants keep white text
// on the Continue button (ApolloColorIsLight stays below its 0.6 cutoff).
UIColor *ApolloWhatsNewHalloweenAccent(void);

// Plays the bat flock over hostView after `delay` seconds, starting from
// `origin` (hostView coordinates). The overlay ignores touches and
// accessibility, and removes itself once the last bat has flown off. Does
// nothing with Reduce Motion on.
void ApolloWhatsNewPlayBats(UIView *hostView, CGPoint origin, NSTimeInterval delay);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
