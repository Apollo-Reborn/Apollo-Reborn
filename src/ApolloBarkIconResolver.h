#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns the selected icon when its PNG is hosted by this repository.
// Unknown, malformed, and future icon IDs safely use default.png instead of
// registering a Bark URL that will return 404.
NSString *ApolloBarkResolvedHostedIconName(id _Nullable selectedName);

NS_ASSUME_NONNULL_END
