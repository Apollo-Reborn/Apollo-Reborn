#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns the namespaced Classics ID for a legacy, unprefixed base ID, or nil
// when the ID is not one of the Classics choices renamed by the picker layout.
FOUNDATION_EXPORT NSString * _Nullable ApolloLGMigratedClassicsIconID(NSString *iconID);

// Returns the legacy, unprefixed Classics ID for a namespaced base ID, or nil
// when the ID is not one of the renamed Classics choices.
FOUNDATION_EXPORT NSString * _Nullable ApolloLGLegacyClassicsIconID(NSString *iconID);

// patch.sh registers every Liquid Glass alternate icon twice: under its own
// name and under that name plus this suffix, both pointing at the same asset.
// Switching between the two makes iOS redraw a home-screen icon it is stuck on.
FOUNDATION_EXPORT NSString *const ApolloLGRefreshIconSuffix;

// The alternate icon name without the refresh suffix, so callers see one name
// whichever of the two registrations iOS currently holds. nil stays nil.
FOUNDATION_EXPORT NSString * _Nullable ApolloLGCanonicalAlternateIconName(NSString * _Nullable name);

NS_ASSUME_NONNULL_END
