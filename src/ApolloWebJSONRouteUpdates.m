#import "ApolloWebJSONRouteUpdates.h"
#import "ApolloWebJSONRoutes.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloWebSessionStore.h"
#import <UIKit/UIKit.h>

static NSString *const kApolloRouteUpdatesURL =
    @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/keyless-routes.json";
static const NSTimeInterval kApolloRouteUpdatesInterval = 15 * 60;
static const NSTimeInterval kApolloRouteUpdatesFailureRetry = 5 * 60;
// The file is limited to 16 KB (ApolloWebJSONRouteTableParse); the cache plist
// adds a little around it.
static const unsigned long long kApolloRouteUpdatesMaxCacheBytes = 32 * 1024;

// All main thread.
static BOOL sLoadedCache;
static BOOL sFetching;
static NSTimeInterval sLastCheckedAt;   // a fetch that got an answer (200, 304 or 404)
static NSTimeInterval sLastFailedAt;
static NSString *sCachedETag;
static NSData *sCachedData;
static NSTimer *sCheckTimer;
static NSString *sLastResult;           // for the Route Status screen; nil before the first check

static NSURL *ApolloRouteUpdatesURL(void) {
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_KEYLESS_ROUTES_URL");
    if (override && *override) return [NSURL URLWithString:@(override)];
#endif
    return [NSURL URLWithString:kApolloRouteUpdatesURL];
}

static NSURL *ApolloRouteUpdatesCacheFile(void) {
    NSURL *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [[caches URLByAppendingPathComponent:@"ApolloReborn" isDirectory:YES]
            URLByAppendingPathComponent:@"KeylessRoutes.plist"];
}

// Validates `data` and puts it in effect. NO when the whole file was rejected,
// which leaves the table in effect as it was.
static BOOL ApolloRouteUpdatesApply(NSData *data, NSString *source) {
    NSArray<NSString *> *rejections = nil;
    NSDictionary *table = ApolloWebJSONRouteTableParse(data, &rejections);
    for (NSString *line in rejections) ApolloLog(@"[WebJSON] Route updates (%@): left out %@", source, line);
    if (!table) {
        ApolloLog(@"[WebJSON] Route updates (%@): file rejected, keeping the routes in use", source);
        return NO;
    }
    NSString *before = ApolloWebJSONRouteRemoteTableDescription();
    ApolloWebJSONRouteSetRemoteTable(table);
    NSString *after = ApolloWebJSONRouteRemoteTableDescription();
    if (![before isEqualToString:after]) ApolloLog(@"[WebJSON] Route updates (%@):\n%@", source, after);
    return YES;
}

// Also keeps when it was last checked, so a relaunch doesn't fetch again within
// the interval.
static void ApolloRouteUpdatesSaveCache(NSURL *url, NSData *data, NSString *etag, NSTimeInterval checkedAt) {
    NSMutableDictionary *stored = [@{ @"url": url.absoluteString ?: @"", @"data": data ?: [NSData data],
                                      @"checkedAt": @(checkedAt) } mutableCopy];
    if (etag.length) stored[@"etag"] = etag;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:stored format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:NULL];
    NSURL *file = ApolloRouteUpdatesCacheFile();
    [[NSFileManager defaultManager] createDirectoryAtURL:file.URLByDeletingLastPathComponent
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    [plist writeToURL:file atomically:YES];
}

static void ApolloRouteUpdatesRemoveCache(void) {
    [[NSFileManager defaultManager] removeItemAtURL:ApolloRouteUpdatesCacheFile() error:NULL];
    sCachedETag = nil;
    sCachedData = nil;
}

// The last validated file for this URL, put in effect. A cache left by another
// URL (a sim override) is ignored.
static void ApolloRouteUpdatesLoadCacheIfNeeded(void) {
    if (sLoadedCache) return;
    sLoadedCache = YES;
    NSURL *file = ApolloRouteUpdatesCacheFile();
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:file.path error:NULL];
    if ([attributes[NSFileSize] unsignedLongLongValue] > kApolloRouteUpdatesMaxCacheBytes) return;
    NSData *plist = [NSData dataWithContentsOfURL:file];
    id stored = plist ? [NSPropertyListSerialization propertyListWithData:plist options:NSPropertyListImmutable
                                                                   format:NULL error:NULL] : nil;
    if (![stored isKindOfClass:[NSDictionary class]]) return;
    if (![stored[@"url"] isEqual:ApolloRouteUpdatesURL().absoluteString]) return;
    NSData *data = [stored[@"data"] isKindOfClass:[NSData class]] ? stored[@"data"] : nil;
    if (!ApolloRouteUpdatesApply(data, @"cached")) return;
    sCachedData = [data copy];
    sLastResult = @"Using the saved copy";
    if ([stored[@"checkedAt"] isKindOfClass:[NSNumber class]]) {
        sLastCheckedAt = MIN([stored[@"checkedAt"] doubleValue], [NSDate timeIntervalSinceReferenceDate]);
    }
    id etag = stored[@"etag"];
    // An ETag is one header value; never replay a corrupt one.
    if ([etag isKindOfClass:[NSString class]] && [etag rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
        sCachedETag = [etag copy];
    }
}

static BOOL ApolloRouteUpdatesActive(void) {
    return sKeylessRouteUpdates && sWebJSONEnabled;
}

static void ApolloRouteUpdatesCancelTimer(void) {
    [sCheckTimer invalidate];
    sCheckTimer = nil;
}

static void ApolloRouteUpdatesObserveInactivity(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
            ApolloRouteUpdatesCancelTimer();
        }];
    });
}

static NSURLSession *ApolloRouteUpdatesSession(void) {
    // Ephemeral, no cookies or URL cache, and a fixed User-Agent, like the update check.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.HTTPCookieStorage = nil;
    config.URLCache = nil;
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 30;
    config.HTTPAdditionalHeaders = @{ @"User-Agent": @"Apollo-Reborn" };
    return [NSURLSession sessionWithConfiguration:config];
}

static void ApolloRouteUpdatesScheduleNext(void);

static void ApolloRouteUpdatesFinish(BOOL answered) {
    sFetching = NO;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (answered) sLastCheckedAt = now;
    else sLastFailedAt = now;
    ApolloRouteUpdatesScheduleNext();
}

static void ApolloRouteUpdatesFetch(void) {
    if (sFetching) return;
    sFetching = YES;
    NSURL *url = ApolloRouteUpdatesURL();
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15];
    if (sCachedETag.length && !url.isFileURL) [request setValue:sCachedETag forHTTPHeaderField:@"If-None-Match"];
    NSURLSession *session = ApolloRouteUpdatesSession();
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [session finishTasksAndInvalidate];
            if (!ApolloRouteUpdatesActive()) { sFetching = NO; return; }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : (data && !error ? 200 : 0);
            if (error || status == 0) {
                ApolloLog(@"[WebJSON] Route updates: fetch failed (%@)", error.localizedDescription ?: @"no response");
                sLastResult = @"Couldn't connect";
                ApolloRouteUpdatesFinish(NO);
                return;
            }
            if (status == 304) {
                sLastResult = @"Unchanged";
                if (sCachedData) ApolloRouteUpdatesSaveCache(url, sCachedData, sCachedETag, [NSDate timeIntervalSinceReferenceDate]);
                ApolloRouteUpdatesFinish(YES);
                return;
            }
            if (status == 404) {
                // Deleting the file is how maintainers undo every override.
                ApolloLog(@"[WebJSON] Route updates: keyless-routes.json isn't there, using the built-in routes");
                ApolloWebJSONRouteSetRemoteTable(nil);
                ApolloRouteUpdatesRemoveCache();
                sLastResult = @"No file, using built-in routes";
                ApolloRouteUpdatesFinish(YES);
                return;
            }
            if (status != 200) {
                ApolloLog(@"[WebJSON] Route updates: HTTP %ld", (long)status);
                sLastResult = [NSString stringWithFormat:@"Failed (HTTP %ld)", (long)status];
                ApolloRouteUpdatesFinish(NO);
                return;
            }
            BOOL applied = ApolloRouteUpdatesApply(data, @"fetched");
            sLastResult = applied ? @"Updated" : @"File rejected, keeping the routes in use";
            if (applied) {
                NSString *etag = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"ETag"] : nil;
                sCachedETag = [etag copy];
                sCachedData = [data copy];
                ApolloRouteUpdatesSaveCache(url, data, etag, [NSDate timeIntervalSinceReferenceDate]);
            }
            ApolloRouteUpdatesFinish(YES);
        });
    }] resume];
}

static NSTimeInterval ApolloRouteUpdatesNextDelay(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval afterCheck = sLastCheckedAt > 0 ? sLastCheckedAt + kApolloRouteUpdatesInterval - now : 0;
    NSTimeInterval afterFailure = sLastFailedAt > 0 ? sLastFailedAt + kApolloRouteUpdatesFailureRetry - now : 0;
    return MAX(0, MAX(afterCheck, afterFailure));
}

static void ApolloRouteUpdatesScheduleNext(void) {
    ApolloRouteUpdatesCancelTimer();
    if (!ApolloRouteUpdatesActive() || sFetching) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    NSTimeInterval delay = MAX(1, ApolloRouteUpdatesNextDelay());
    sCheckTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer *timer) {
        ApolloWebJSONRouteUpdatesCheckIfNeeded();
    }];
    sCheckTimer.tolerance = MIN(30, delay * 0.05);
    [[NSRunLoop mainRunLoop] addTimer:sCheckTimer forMode:NSRunLoopCommonModes];
}

void ApolloWebJSONRouteUpdatesCheckIfNeeded(void) {
    if (!ApolloRouteUpdatesActive()) {
        ApolloRouteUpdatesCancelTimer();
        return;
    }
    ApolloRouteUpdatesObserveInactivity();
    ApolloRouteUpdatesLoadCacheIfNeeded();
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    if (ApolloRouteUpdatesNextDelay() > 0) {
        ApolloRouteUpdatesScheduleNext();
        return;
    }
    ApolloRouteUpdatesFetch();
}

void ApolloWebJSONRouteUpdatesSetEnabled(BOOL enabled) {
    sKeylessRouteUpdates = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UDKeyKeylessRouteUpdates];
    if (!enabled) {
        ApolloRouteUpdatesCancelTimer();
        ApolloWebJSONRouteSetRemoteTable(nil);
        sLoadedCache = NO;
        ApolloLog(@"[WebJSON] Route updates off: using the built-in routes");
        return;
    }
    ApolloLog(@"[WebJSON] Route updates on");
    ApolloWebJSONRouteUpdatesCheckIfNeeded();
}

#pragma mark - Status (Route Status screen, logs)

static NSString *ApolloRouteUpdatesRelativeTime(NSTimeInterval at, NSTimeInterval now) {
    if (at <= 0) return @"never";
    NSTimeInterval ago = MAX(0, now - at);
    if (ago < 60) return @"just now";
    if (ago < 3600) return [NSString stringWithFormat:@"%.0f min ago", floor(ago / 60.0)];
    return [NSString stringWithFormat:@"%.0f h ago", floor(ago / 3600.0)];
}

NSDictionary<NSString *, id> *ApolloWebJSONRouteUpdatesStatus(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"enabled"] = @(sKeylessRouteUpdates);
    status[@"lastChecked"] = ApolloRouteUpdatesRelativeTime(sLastCheckedAt, now);
    status[@"result"] = !sKeylessRouteUpdates ? @"Off, using built-in routes" : (sLastResult ?: @"Not checked yet");
    return status;
}

// Per fallback endpoint, for `account`: which route a request would take now,
// and every route's counts. Methods of one path with the same routes share
// their health (it's kept per path), so they're one entry ("GET/POST …").
// Shared by the screen, the summary and the headline.
static NSArray<NSDictionary *> *ApolloRouteUpdatesEndpointStatus(NSString *account, NSTimeInterval now) {
    NSArray<NSDictionary *> *health = ApolloWebJSONRouteHealthSnapshot(account, now);
    NSMutableArray<NSDictionary *> *endpoints = [NSMutableArray array];
    for (NSString *key in ApolloWebJSONRouteFallbackEndpoints()) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@" "];
        NSString *method = parts.firstObject, *path = parts.lastObject;
        NSArray<NSNumber *> *order = ApolloWebJSONRoutesForRequest(method, path);
        NSUInteger same = [endpoints indexOfObjectPassingTest:^BOOL(NSDictionary *e, __unused NSUInteger i, __unused BOOL *stop) {
            return [e[@"path"] isEqualToString:path] && [e[@"order"] isEqualToArray:order];
        }];
        if (same != NSNotFound) {
            NSMutableDictionary *merged = [endpoints[same] mutableCopy];
            merged[@"key"] = [NSString stringWithFormat:@"%@/%@ %@", [merged[@"key"] componentsSeparatedByString:@" "].firstObject, method, path];
            endpoints[same] = merged;
            continue;
        }
        NSString *pattern = ApolloWebJSONRoutePathPattern(path);
        NSMutableArray<NSDictionary *> *routes = [NSMutableArray array];
        BOOL allCooling = YES;
        for (NSNumber *route in ApolloWebJSONRoutesForRequest(method, path)) {
            NSDictionary *found = nil;
            for (NSDictionary *row in health) {
                if ([row[@"pattern"] isEqualToString:pattern] && [row[@"route"] isEqual:route]) { found = row; break; }
            }
            NSTimeInterval cooling = ApolloWebJSONRouteCooldownRemaining(account, path, (ApolloWebJSONRoute)route.integerValue, now);
            if (cooling <= 0) allCooling = NO;
            [routes addObject:@{ @"route": route, @"ok": found[@"ok"] ?: @0, @"blocked": found[@"blocked"] ?: @0,
                                 @"lastOkAt": found[@"lastOkAt"] ?: @0, @"cooldownRemaining": @(cooling) }];
        }
        NSInteger using = ApolloWebJSONRouteChoose(account, method, path, 0, now);
        [endpoints addObject:@{ @"key": key, @"path": path, @"order": order, @"routes": routes, @"using": @(using),
                                @"allCooling": @(allCooling), @"remote": @(ApolloWebJSONRouteIsFromRemoteTable(method, path)) }];
    }
    return endpoints;
}

NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteStatusEndpoints(void) {
    return ApolloRouteUpdatesEndpointStatus(ApolloActiveWebSessionUsername(), [NSDate timeIntervalSinceReferenceDate]);
}

NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteStatusBlockedPaths(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableSet<NSString *> *fallbackPatterns = [NSMutableSet set];
    for (NSString *key in ApolloWebJSONRouteFallbackEndpoints()) {
        [fallbackPatterns addObject:ApolloWebJSONRoutePathPattern([key componentsSeparatedByString:@" "].lastObject)];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSDictionary *row in ApolloWebJSONRouteHealthSnapshot(ApolloActiveWebSessionUsername(), now)) {
        if ([row[@"blocked"] unsignedIntegerValue] == 0 || [fallbackPatterns containsObject:row[@"pattern"]]) continue;
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"blocked"] compare:a[@"blocked"]]; }];
    return rows;
}

NSString *ApolloWebJSONRouteStatusHeadline(void) {
    NSString *account = ApolloActiveWebSessionUsername();
    if (account.length == 0) return @"";
    BOOL fallback = NO;
    for (NSDictionary *endpoint in ApolloRouteUpdatesEndpointStatus(account, [NSDate timeIntervalSinceReferenceDate])) {
        if ([endpoint[@"allCooling"] boolValue]) return @"Blocked";
        for (NSDictionary *route in endpoint[@"routes"]) {
            if ([route[@"cooldownRemaining"] doubleValue] > 0) fallback = YES;
        }
    }
    if (fallback) return @"Using Fallback";
    return ApolloWebJSONRouteStatusBlockedPaths().count ? @"Some Blocked" : @"Working";
}

NSString *ApolloWebJSONRouteStatusSummary(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSString *account = ApolloActiveWebSessionUsername();
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Route status for u/%@ (since launch)", account.length ? account : @"(none)"]];
    for (NSDictionary *endpoint in ApolloRouteUpdatesEndpointStatus(account, now)) {
        NSInteger using = [endpoint[@"using"] integerValue];
        [lines addObject:[NSString stringWithFormat:@"%@: using %@%@%@", endpoint[@"key"],
                          using >= 0 ? ApolloWebJSONRouteName((ApolloWebJSONRoute)using) : @"?",
                          [endpoint[@"allCooling"] boolValue] ? @", every route blocked" : @"",
                          [endpoint[@"remote"] boolValue] ? @", order from keyless-routes.json" : @""]];
        for (NSDictionary *route in endpoint[@"routes"]) {
            NSTimeInterval cooling = [route[@"cooldownRemaining"] doubleValue];
            [lines addObject:[NSString stringWithFormat:@"  %@: %@ ok, %@ blocked%@",
                              ApolloWebJSONRouteName((ApolloWebJSONRoute)[route[@"route"] integerValue]), route[@"ok"], route[@"blocked"],
                              cooling > 0 ? [NSString stringWithFormat:@", skipped for %.0f more min", ceil(cooling / 60.0)] : @""]];
        }
    }
    NSArray<NSDictionary *> *blocked = ApolloWebJSONRouteStatusBlockedPaths();
    [lines addObject:blocked.count ? @"Blocked paths without another route:" : @"Blocked paths without another route: none"];
    for (NSDictionary *row in blocked) {
        [lines addObject:[NSString stringWithFormat:@"  %@: %@ blocked, %@ ok", row[@"pattern"], row[@"blocked"], row[@"ok"]]];
    }
    NSDictionary *updates = ApolloWebJSONRouteUpdatesStatus();
    [lines addObject:[NSString stringWithFormat:@"Route updates: %@, last checked %@", updates[@"result"], updates[@"lastChecked"]]];
    [lines addObject:[@"Overrides: " stringByAppendingString:ApolloWebJSONRouteRemoteTableDescription()]];
    return [lines componentsJoinedByString:@"\n"];
}
