#import "ApolloSessionState.h"

NSString *const ApolloSessionStateFeedURLKey = @"feedURL";
NSString *const ApolloSessionStateFeedItemKey = @"feedItem";
NSString *const ApolloSessionStateFeedDeltaKey = @"feedDelta";
NSString *const ApolloSessionStateFeedOffsetKey = @"feedOffset";
NSString *const ApolloSessionStateDetailURLKey = @"detailURL";
NSString *const ApolloSessionStateDetailItemKey = @"detailItem";
NSString *const ApolloSessionStateDetailDeltaKey = @"detailDelta";
NSString *const ApolloSessionStateDetailOffsetKey = @"detailOffset";
NSString *const ApolloSessionStateSavedAtKey = @"savedAt";
NSString *const ApolloSessionStateAccountScopeKey = @"accountScope";

static const NSUInteger kApolloSessionMaximumStringLength = 2048;
static const double kApolloSessionMaximumCoordinate = 10000000.0;

static NSString *ApolloSessionBoundedString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = value;
    return string.length > 0 && string.length <= kApolloSessionMaximumStringLength ? string : nil;
}

static NSNumber *ApolloSessionBoundedNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    double number = [value doubleValue];
    return isfinite(number) && fabs(number) <= kApolloSessionMaximumCoordinate ? @(number) : nil;
}

static NSURLComponents *ApolloSessionRedditComponents(NSString *value) {
    NSString *string = ApolloSessionBoundedString(value);
    if (!string) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:string];
    if (![[components.scheme lowercaseString] isEqualToString:@"apollo"] ||
        ![[components.host lowercaseString] isEqualToString:@"reddit.com"] ||
        components.user.length || components.password.length || components.query.length ||
        components.fragment.length) return nil;
    NSString *path = components.path;
    if (![path hasPrefix:@"/"] || [path containsString:@".."] || path.length > 1024) return nil;
    return components;
}

BOOL ApolloSessionStateFeedURLIsAllowed(NSString *value) {
    if ([value isEqualToString:@"apollo-reborn://session/home"]) return YES;
    NSURLComponents *components = ApolloSessionRedditComponents(value);
    if (!components) return NO;
    NSString *path = components.path.lowercaseString;
    if ([path hasPrefix:@"/r/"]) return [path rangeOfString:@"/comments/"].location == NSNotFound;
    return [path hasPrefix:@"/user/"] || [path hasPrefix:@"/u/"];
}

BOOL ApolloSessionStateDetailURLIsAllowed(NSString *value) {
    NSURLComponents *components = ApolloSessionRedditComponents(value);
    if (!components) return NO;
    NSString *path = components.path.lowercaseString;
    return [path hasPrefix:@"/r/"] && [path rangeOfString:@"/comments/"].location != NSNotFound;
}

static BOOL ApolloSessionAccountScopeIsAllowed(NSString *scope) {
    if ([scope isEqualToString:@"signed-out"]) return YES;
    if (scope.length != 64) return NO;
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    return [scope rangeOfCharacterFromSet:notHex].location == NSNotFound;
}

NSDictionary<NSString *, id> *ApolloSessionStateNormalize(NSDictionary *candidate,
                                                           NSDate *now,
                                                           NSTimeInterval maximumAge) {
    if (![candidate isKindOfClass:NSDictionary.class] || ![now isKindOfClass:NSDate.class] ||
        maximumAge <= 0 || !isfinite(maximumAge)) return nil;
    NSDate *savedAt = [candidate[ApolloSessionStateSavedAtKey] isKindOfClass:NSDate.class]
        ? candidate[ApolloSessionStateSavedAtKey] : nil;
    if (!savedAt) return nil;
    NSTimeInterval age = [now timeIntervalSinceDate:savedAt];
    if (!isfinite(age) || age < -300.0 || age > maximumAge) return nil;

    NSString *feedURL = ApolloSessionBoundedString(candidate[ApolloSessionStateFeedURLKey]);
    NSString *accountScope = ApolloSessionBoundedString(candidate[ApolloSessionStateAccountScopeKey]);
    if (!ApolloSessionStateFeedURLIsAllowed(feedURL) ||
        !ApolloSessionAccountScopeIsAllowed(accountScope)) return nil;

    NSMutableDictionary *normalized = [@{
        ApolloSessionStateSavedAtKey: savedAt,
        ApolloSessionStateFeedURLKey: feedURL,
        ApolloSessionStateAccountScopeKey: accountScope,
    } mutableCopy];
    NSArray<NSString *> *stringKeys = @[
        ApolloSessionStateFeedItemKey, ApolloSessionStateDetailItemKey,
    ];
    for (NSString *key in stringKeys) {
        NSString *value = ApolloSessionBoundedString(candidate[key]);
        if (value) normalized[key] = value;
    }
    NSArray<NSString *> *numberKeys = @[
        ApolloSessionStateFeedDeltaKey, ApolloSessionStateFeedOffsetKey,
        ApolloSessionStateDetailDeltaKey, ApolloSessionStateDetailOffsetKey,
    ];
    for (NSString *key in numberKeys) {
        NSNumber *value = ApolloSessionBoundedNumber(candidate[key]);
        if (value) normalized[key] = value;
    }
    NSString *detailURL = ApolloSessionBoundedString(candidate[ApolloSessionStateDetailURLKey]);
    if (detailURL && ApolloSessionStateDetailURLIsAllowed(detailURL)) {
        normalized[ApolloSessionStateDetailURLKey] = detailURL;
    }
    return normalized;
}
