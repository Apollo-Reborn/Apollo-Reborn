#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

FOUNDATION_EXPORT NSString *const ApolloSearchLandingSettingsDidChangeNotification;
FOUNDATION_EXPORT NSString *const ApolloSearchLandingSectionTrending;
FOUNDATION_EXPORT NSString *const ApolloSearchLandingSectionRandom;
FOUNDATION_EXPORT NSString *const ApolloSearchLandingSectionRecent;

// Unknown and duplicate identifiers are ignored; missing sections are appended
// in the default order. Every returned section appears exactly once.
NSArray<NSString *> *ApolloSearchLandingSectionOrder(void);
void ApolloSearchLandingSetSectionOrder(NSArray<NSString *> *order);

// Zero hides Recently Visited. NSNotFound means unlimited; the default is five.
NSInteger ApolloSearchLandingRecentlyVisitedLimit(void);

__END_DECLS

NS_ASSUME_NONNULL_END
