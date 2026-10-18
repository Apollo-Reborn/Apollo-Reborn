#import "ApolloSearchLandingPreferences.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

NSString *const ApolloSearchLandingSettingsDidChangeNotification = @"ApolloSearchLandingSettingsDidChangeNotification";
NSString *const ApolloSearchLandingSectionTrending = @"trending";
NSString *const ApolloSearchLandingSectionRandom = @"random";
NSString *const ApolloSearchLandingSectionRecent = @"recent";

static NSArray<NSString *> *ApolloSearchLandingNormalizeOrder(id saved) {
    NSArray<NSString *> *defaults = @[ApolloSearchLandingSectionTrending,
        ApolloSearchLandingSectionRandom, ApolloSearchLandingSectionRecent];
    NSMutableArray<NSString *> *order = [NSMutableArray arrayWithCapacity:defaults.count];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id token in saved) {
            if ([token isKindOfClass:NSString.class] && [defaults containsObject:token] &&
                ![order containsObject:token]) {
                [order addObject:token];
            }
        }
    }
    for (NSString *token in defaults) {
        if (![order containsObject:token]) [order addObject:token];
    }
    return [order copy];
}

NSArray<NSString *> *ApolloSearchLandingSectionOrder(void) {
    return ApolloSearchLandingNormalizeOrder(
        [NSUserDefaults.standardUserDefaults objectForKey:UDKeySearchTabSectionOrder]);
}

void ApolloSearchLandingSetSectionOrder(NSArray<NSString *> *order) {
    NSArray<NSString *> *normalized = ApolloSearchLandingNormalizeOrder(order);
    BOOL changed = ![ApolloSearchLandingSectionOrder() isEqualToArray:normalized];
    [NSUserDefaults.standardUserDefaults setObject:normalized forKey:UDKeySearchTabSectionOrder];
    if (changed) {
        [NSNotificationCenter.defaultCenter postNotificationName:ApolloSearchLandingSettingsDidChangeNotification object:nil];
    }
}

NSInteger ApolloSearchLandingRecentlyVisitedLimit(void) {
    NSString *value = sRecentlyVisitedSubredditsLimit;
    if (![value isKindOfClass:NSString.class]) return 5;
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0) return NSNotFound;
    return MAX(0, value.integerValue);
}
