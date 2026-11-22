#import "ApolloAccountSuspension.h"
#import "UserDefaultConstants.h" // UDKeyAccountSuspensions

NSString *const ApolloAccountSuspensionDidChangeNotification = @"ApolloAccountSuspensionDidChangeNotification";

// Stored under UDKeyAccountSuspensions (standard defaults): lowercased username
// -> epoch seconds the suspension ends, 0 when Reddit gave no end date. Kept
// across launches so the reason is known before the first answer arrives, and
// when every request is refused (a rate-limited launch can't ask Reddit
// anything). Not a setting: nothing reads it but this file.

static NSTimeInterval sApolloAccountSuspensionTestNow = 0;

static NSObject *ApolloAccountSuspensionLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Guarded by ApolloAccountSuspensionLock. nil until first use.
static NSMutableDictionary<NSString *, NSNumber *> *sApolloAccountSuspensions;

static NSTimeInterval ApolloAccountSuspensionNow(void) {
    return sApolloAccountSuspensionTestNow > 0 ? sApolloAccountSuspensionTestNow : [[NSDate date] timeIntervalSince1970];
}

static NSString *ApolloAccountSuspensionKey(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *key = [[username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return key.length > 0 ? key : nil;
}

// Call with the lock held.
static NSMutableDictionary<NSString *, NSNumber *> *ApolloAccountSuspensionsLocked(void) {
    if (sApolloAccountSuspensions) return sApolloAccountSuspensions;
    sApolloAccountSuspensions = [NSMutableDictionary dictionary];
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:UDKeyAccountSuspensions];
    for (id name in stored) {
        id until = stored[name];
        NSString *key = ApolloAccountSuspensionKey(name);
        if (key && [until isKindOfClass:[NSNumber class]]) sApolloAccountSuspensions[key] = until;
    }
    return sApolloAccountSuspensions;
}

// Call with the lock held.
static void ApolloAccountSuspensionsPersistLocked(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (sApolloAccountSuspensions.count > 0) {
        [defaults setObject:[sApolloAccountSuspensions copy] forKey:UDKeyAccountSuspensions];
    } else {
        [defaults removeObjectForKey:UDKeyAccountSuspensions];
    }
}

static void ApolloAccountSuspensionPostChange(NSString *key) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloAccountSuspensionDidChangeNotification
                                                            object:nil
                                                          userInfo:@{ @"username": key }];
    });
}

BOOL ApolloAccountSuspensionNoteUserData(NSString *username, NSDictionary *userData) {
    NSString *key = ApolloAccountSuspensionKey(username);
    if (!key || ![userData isKindOfClass:[NSDictionary class]]) return NO;
    // JSON true/false only. Anything else (missing, null, a string) is no
    // answer, and no answer must not read as "not suspended".
    id flag = userData[@"is_suspended"];
    if (![flag isKindOfClass:[NSNumber class]]) return NO;
    BOOL suspended = [flag boolValue];
    id expiration = userData[@"suspension_expiration_utc"];
    NSTimeInterval until = [expiration isKindOfClass:[NSNumber class]] ? [expiration doubleValue] : 0;
    if (until < 0) until = 0;

    BOOL changed = NO;
    @synchronized (ApolloAccountSuspensionLock()) {
        NSMutableDictionary<NSString *, NSNumber *> *all = ApolloAccountSuspensionsLocked();
        NSNumber *stored = all[key];
        if (suspended) {
            if (!stored || stored.doubleValue != until) {
                all[key] = @(until);
                changed = YES;
            }
        } else if (stored) {
            [all removeObjectForKey:key];
            changed = YES;
        }
        if (changed) ApolloAccountSuspensionsPersistLocked();
    }
    if (changed) ApolloAccountSuspensionPostChange(key);
    return changed;
}

// "api/v1/me", "/api/me.json", "user/Name/about.json" -> lowercased, no leading
// slash, no ".json", no trailing slash.
static NSString *ApolloAccountSuspensionNormalizedPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSString *p = [[path componentsSeparatedByString:@"?"].firstObject lowercaseString];
    while ([p hasPrefix:@"/"]) p = [p substringFromIndex:1];
    while ([p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    while ([p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    return p;
}

BOOL ApolloAccountSuspensionNoteResponse(NSString *clientUsername, NSString *method, NSString *path, id responseObject) {
    if (method.length > 0 && [method caseInsensitiveCompare:@"GET"] != NSOrderedSame) return NO;
    // This runs for every Reddit answer, so listings, comments and the rest
    // leave here on three substring tests with nothing allocated. The exact
    // match is made on the normalized path below.
    if (![path isKindOfClass:[NSString class]] ||
        ([path rangeOfString:@"api/v1/me" options:NSCaseInsensitiveSearch].location == NSNotFound &&
         [path rangeOfString:@"api/me" options:NSCaseInsensitiveSearch].location == NSNotFound &&
         [path rangeOfString:@"/about" options:NSCaseInsensitiveSearch].location == NSNotFound)) return NO;
    if (![responseObject isKindOfClass:[NSDictionary class]]) return NO;
    NSString *p = ApolloAccountSuspensionNormalizedPath(path);
    if (p.length == 0) return NO;
    NSString *client = ApolloAccountSuspensionKey(clientUsername);

    NSDictionary *user = nil;
    BOOL meRead = NO;
    if ([p isEqualToString:@"api/v1/me"]) {
        user = responseObject;
        meRead = YES;
    } else if ([p isEqualToString:@"api/me"]) {
        user = responseObject[@"data"];
        meRead = YES;
    } else {
        // user/<name>/about. Whose it is gets settled by the object's own
        // name below.
        NSArray<NSString *> *parts = [p componentsSeparatedByString:@"/"];
        if (parts.count != 3 || ![parts[0] isEqualToString:@"user"] || ![parts[2] isEqualToString:@"about"]) return NO;
        user = responseObject[@"data"];
    }
    if (![user isKindOfClass:[NSDictionary class]]) return NO;
    NSString *name = ApolloAccountSuspensionKey(user[@"name"]);
    if (!name) return NO;
    // The object has to describe the account that asked: another user's
    // about.json carries is_suspended too. A "me" read sent before the client
    // knows its user is that account by definition; an about.json then isn't
    // known to be anyone's.
    if (client ? ![name isEqualToString:client] : !meRead) return NO;
    return ApolloAccountSuspensionNoteUserData(name, user);
}

// Call with the lock held. NO, and the entry removed, once its end date passed.
static BOOL ApolloAccountSuspensionActiveLocked(NSString *key, NSTimeInterval *outUntil) {
    NSMutableDictionary<NSString *, NSNumber *> *all = ApolloAccountSuspensionsLocked();
    NSNumber *stored = all[key];
    if (!stored) return NO;
    NSTimeInterval until = stored.doubleValue;
    if (until > 0 && until <= ApolloAccountSuspensionNow()) {
        [all removeObjectForKey:key];
        ApolloAccountSuspensionsPersistLocked();
        return NO;
    }
    if (outUntil) *outUntil = until;
    return YES;
}

BOOL ApolloAccountIsSuspended(NSString *username) {
    NSString *key = ApolloAccountSuspensionKey(username);
    if (!key) return NO;
    @synchronized (ApolloAccountSuspensionLock()) {
        return ApolloAccountSuspensionActiveLocked(key, NULL);
    }
}

NSDate *ApolloAccountSuspensionEnd(NSString *username) {
    NSString *key = ApolloAccountSuspensionKey(username);
    if (!key) return nil;
    NSTimeInterval until = 0;
    @synchronized (ApolloAccountSuspensionLock()) {
        if (!ApolloAccountSuspensionActiveLocked(key, &until)) return nil;
    }
    return until > 0 ? [NSDate dateWithTimeIntervalSince1970:until] : nil;
}

NSString *ApolloAccountSuspensionTimeLeftText(NSString *username) {
    NSDate *end = ApolloAccountSuspensionEnd(username);
    if (!end) return nil;
    NSTimeInterval left = end.timeIntervalSince1970 - ApolloAccountSuspensionNow();
    if (left <= 0) return nil;
    if (left < 3600.0) return @"Less than an hour left";
    if (left < 86400.0) {
        long hours = (long)ceil(left / 3600.0);
        return hours >= 24 ? @"1 day left" : [NSString stringWithFormat:@"%ld hour%@ left", hours, hours == 1 ? @"" : @"s"];
    }
    long days = (long)ceil(left / 86400.0);
    return [NSString stringWithFormat:@"%ld day%@ left", days, days == 1 ? @"" : @"s"];
}

void ApolloAccountSuspensionKeepOnly(NSSet<NSString *> *usernames) {
    if (![usernames isKindOfClass:[NSSet class]]) return;
    NSMutableSet<NSString *> *keep = [NSMutableSet setWithCapacity:usernames.count];
    for (id name in usernames) {
        NSString *key = ApolloAccountSuspensionKey(name);
        if (key) [keep addObject:key];
    }
    @synchronized (ApolloAccountSuspensionLock()) {
        NSMutableDictionary<NSString *, NSNumber *> *all = ApolloAccountSuspensionsLocked();
        NSMutableArray<NSString *> *gone = [NSMutableArray array];
        for (NSString *key in all) {
            if (![keep containsObject:key]) [gone addObject:key];
        }
        if (gone.count == 0) return;
        [all removeObjectsForKeys:gone];
        ApolloAccountSuspensionsPersistLocked();
    }
}

void ApolloAccountSuspensionSetNowForTesting(NSTimeInterval now) {
    sApolloAccountSuspensionTestNow = now;
}

void ApolloAccountSuspensionReloadForTesting(void) {
    @synchronized (ApolloAccountSuspensionLock()) {
        sApolloAccountSuspensions = nil;
    }
}
