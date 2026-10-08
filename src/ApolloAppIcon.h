#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// The app's currently active icon: the default, or whichever alternate the user picked in
// the icon picker. Icons with image files come from Info.plist's CFBundleIcons, the way
// UIApplication resolves alternateIconName. A picked alternate that only exists in the asset
// catalog (the Liquid Glass builds' Icon Composer icons) has no file, so the system renders it.
UIImage *_Nullable ApolloCurrentAppIcon(void);

// The Liquid Glass icon picker registers this: it knows the applied icon from its own record,
// because UIApplication.alternateIconName is wrong on some sideloaded installs and would make
// the sheets show the default icon. Return nil for "not one of mine" and the Info.plist
// lookup above takes over.
typedef UIImage *_Nullable (*ApolloAppIconProvider)(void);
void ApolloAppIconSetProvider(ApolloAppIconProvider _Nullable provider);

__END_DECLS

NS_ASSUME_NONNULL_END
