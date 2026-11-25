#import "ApolloWebJSONFriends.h"

NSString *const ApolloWebJSONFriendAddPath = @"api/friend";
NSString *const ApolloWebJSONFriendRemovePath = @"api/unfriend";

// "t2_" plus Reddit's base-36 id. Anything else (nil, "t2_(null)" from an
// account whose identity never loaded, another kind's fullname) is refused:
// Reddit would answer it with an empty error list and friend nobody.
static BOOL ApolloWebJSONFriendContainerIsAccountFullName(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length <= 3) return NO;
    if (![[fullName substringToIndex:3] isEqualToString:@"t2_"]) return NO;
    static NSCharacterSet *notBase36;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notBase36 = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyz0123456789"] invertedSet];
    });
    return [[fullName substringFromIndex:3] rangeOfCharacterFromSet:notBase36].location == NSNotFound;
}

NSDictionary<NSString *, NSString *> *ApolloWebJSONFriendWriteParameters(NSString *username,
                                                                         NSString *containerFullName) {
    if (![username isKindOfClass:[NSString class]] || username.length == 0) return nil;
    if (!ApolloWebJSONFriendContainerIsAccountFullName(containerFullName)) return nil;
    return @{
        @"api_type": @"json",
        @"type": @"friend",
        @"name": username,
        @"container": containerFullName,
    };
}

NSString *ApolloWebJSONFriendAccountFullNameFromMe(id meObject, NSString *expectedUsername) {
    if (![meObject isKindOfClass:[NSDictionary class]]) return nil;
    if (![expectedUsername isKindOfClass:[NSString class]] || expectedUsername.length == 0) return nil;
    NSDictionary *me = meObject;
    if ([me[@"data"] isKindOfClass:[NSDictionary class]]) me = me[@"data"];
    id name = me[@"name"];
    if (![name isKindOfClass:[NSString class]] ||
        [(NSString *)name caseInsensitiveCompare:expectedUsername] != NSOrderedSame) return nil;
    id identifier = me[@"id"];
    if (![identifier isKindOfClass:[NSString class]]) return nil;
    // Bare base-36 id on /api/me.json; take a fullname as it is too.
    NSString *fullName = [identifier hasPrefix:@"t2_"] ? identifier : [@"t2_" stringByAppendingString:identifier];
    return ApolloWebJSONFriendContainerIsAccountFullName(fullName) ? fullName : nil;
}

NSString *ApolloWebJSONFriendWriteFailureMessage(NSInteger statusCode, id responseObject) {
    if (statusCode >= 400) {
        return [NSString stringWithFormat:@"Reddit refused the request (HTTP %ld)", (long)statusCode];
    }
    if (![responseObject isKindOfClass:[NSDictionary class]]) return nil;
    id json = ((NSDictionary *)responseObject)[@"json"];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id errors = ((NSDictionary *)json)[@"errors"];
    if (![errors isKindOfClass:[NSArray class]] || [(NSArray *)errors count] == 0) return nil;
    // Each entry is [code, message, field]; prefer the message.
    id first = [(NSArray *)errors firstObject];
    if ([first isKindOfClass:[NSArray class]]) {
        NSArray *entry = first;
        if (entry.count > 1 && [entry[1] isKindOfClass:[NSString class]] && [entry[1] length] > 0) return entry[1];
        if (entry.count > 0 && [entry[0] isKindOfClass:[NSString class]] && [entry[0] length] > 0) return entry[0];
    } else if ([first isKindOfClass:[NSString class]] && [first length] > 0) {
        return first;
    }
    return @"Reddit refused the request";
}
