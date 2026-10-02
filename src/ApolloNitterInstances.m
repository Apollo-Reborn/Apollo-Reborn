#import "ApolloNitterInstances.h"

static NSString *const ApolloNitterTrackerURL = @"https://status.d420.de/api/v1/instances";
static NSString *const ApolloNitterErrorDomain = @"ApolloNitterInstances";

// How long a successful tracker response is reused. Long enough that bouncing
// in and out of the picker never re-requests (the tracker 429s quickly), short
// enough that an instance going down mid-session eventually drops off the list.
static const NSTimeInterval ApolloNitterInstanceCacheLifetime = 15.0 * 60.0;

@interface ApolloNitterInstance ()
@property (nonatomic, copy, readwrite) NSString *host;
@property (nonatomic, readwrite) NSInteger points;
@property (nonatomic, readwrite) NSInteger averagePingMilliseconds;
@end

@implementation ApolloNitterInstance
@end

#pragma mark - Host matching

static BOOL ApolloNitterHostIsOrIsUnder(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]];
}

static BOOL ApolloNitterHostIsXOwned(NSString *lowerHost) {
    for (NSString *domain in @[@"x.com", @"twitter.com", @"t.co", @"twimg.com"]) {
        if (ApolloNitterHostIsOrIsUnder(lowerHost, domain)) return YES;
    }
    return NO;
}

// Only X's web front doors are rewritten. api., help., developer., pbs. and
// other subdomains serve things Nitter has no equivalent for, so they keep
// their normal routing.
static BOOL ApolloNitterHostIsRewritable(NSString *lowerHost) {
    static NSSet<NSString *> *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = [NSSet setWithArray:@[
            @"x.com", @"www.x.com", @"mobile.x.com",
            @"twitter.com", @"www.twitter.com", @"mobile.twitter.com",
        ]];
    });
    return [hosts containsObject:lowerHost];
}

// A plausible public DNS name: dotted, LDH labels, no empty or hyphen-edged
// labels. Not a full validator; it only has to keep obvious typos and
// non-hosts out of the setting.
static BOOL ApolloNitterIsPlausibleHostname(NSString *host) {
    if (host.length < 4 || host.length > 253) return NO;
    NSArray<NSString *> *labels = [host componentsSeparatedByString:@"."];
    if (labels.count < 2) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"];
    for (NSString *label in labels) {
        if (label.length == 0 || label.length > 63) return NO;
        if ([label hasPrefix:@"-"] || [label hasSuffix:@"-"]) return NO;
        if ([label rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    }
    return YES;
}

NSString *ApolloNitterNormalizeHost(NSString *input) {
    if (![input isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [[input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (trimmed.length == 0) return nil;
    if ([trimmed rangeOfString:@"://"].location == NSNotFound) {
        trimmed = [@"https://" stringByAppendingString:trimmed];
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if (!components) return nil;
    if (![components.scheme isEqualToString:@"https"] && ![components.scheme isEqualToString:@"http"]) return nil;
    if (components.user.length > 0 || components.password.length > 0) return nil;

    NSString *host = components.host.lowercaseString;
    if (!ApolloNitterIsPlausibleHostname(host)) return nil;
    if (ApolloNitterHostIsXOwned(host)) return nil;

    // https stays bare (the common case, and the format saved before plain
    // http was supported). An explicit http:// is kept, so a self-hosted
    // instance on a home network without TLS opens over http rather than
    // being silently upgraded to an https address that doesn't answer.
    BOOL plainHTTP = [components.scheme isEqualToString:@"http"];
    NSString *address = plainHTTP ? [@"http://" stringByAppendingString:host] : host;

    NSNumber *port = components.port;
    if (port) {
        NSInteger value = port.integerValue;
        if (value <= 0 || value > 65535) return nil;
        if (value != (plainHTTP ? 80 : 443)) return [NSString stringWithFormat:@"%@:%ld", address, (long)value];
    }
    return address;
}

// Builds the instance's base URL from an ApolloNitterNormalizeHost result:
// bare "host[:port]" means https, an "http://" prefix means plain http.
static NSURLComponents *ApolloNitterInstanceComponents(NSString *instanceHost) {
    NSString *base = [instanceHost hasPrefix:@"http://"] ? instanceHost : [@"https://" stringByAppendingString:instanceHost];
    return [NSURLComponents componentsWithString:base];
}

#pragma mark - URL rewriting

// First path segments that are X app pages rather than profiles. Nitter has no
// equivalent for these (or, for /explore, redirects to its own about page), so
// links to them keep their normal routing.
static BOOL ApolloNitterIsUnsupportedTopLevelPath(NSString *segment) {
    static NSSet<NSString *> *segments;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        segments = [NSSet setWithArray:@[
            @"home", @"explore", @"settings", @"messages", @"notifications", @"compose",
            @"login", @"logout", @"signup", @"account", @"intent", @"share",
            @"tos", @"privacy", @"rules", @"jobs", @"download",
        ]];
    });
    return [segments containsObject:segment];
}

// `/i/<kind>/...` routes Nitter serves itself (status, web/status, lists,
// communities, spaces, broadcasts, articles, numeric user ids). Nitter shows a
// "feature not supported" page for every other `/i/` path.
static BOOL ApolloNitterIsSupportedInternalPath(NSString *kind) {
    static NSSet<NSString *> *kinds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kinds = [NSSet setWithArray:@[
            @"status", @"web", @"lists", @"communities", @"spaces", @"broadcasts", @"article", @"user",
        ]];
    });
    return [kinds containsObject:kind];
}

NSURL *ApolloNitterURLForTwitterURL(NSURL *url, NSString *instanceHost) {
    if (![url isKindOfClass:[NSURL class]] || ![instanceHost isKindOfClass:[NSString class]] || instanceHost.length == 0) return nil;

    // Build from the absolute string rather than -[NSURL host]: on iOS < 26
    // Tweak.xm hooks -host to report x.com as twitter.com.
    NSURLComponents *source = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    NSString *scheme = source.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    if (!ApolloNitterHostIsRewritable(source.host.lowercaseString ?: @"")) return nil;

    NSURLComponents *instance = ApolloNitterInstanceComponents(instanceHost);
    if (instance.host.length == 0) return nil;

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in [source.percentEncodedPath componentsSeparatedByString:@"/"]) {
        if (segment.length > 0) [segments addObject:segment];
    }
    NSString *first = segments.firstObject.lowercaseString;
    if (first) {
        if ([first isEqualToString:@"i"]) {
            if (segments.count < 2 || !ApolloNitterIsSupportedInternalPath(segments[1].lowercaseString)) return nil;
        } else if (ApolloNitterIsUnsupportedTopLevelPath(first)) {
            return nil;
        }
    }

    NSURLComponents *rewritten = [NSURLComponents new];
    rewritten.scheme = instance.scheme;
    rewritten.host = instance.host;
    rewritten.port = instance.port;
    rewritten.percentEncodedPath = segments.count > 0
        ? [@"/" stringByAppendingString:[segments componentsJoinedByString:@"/"]]
        : @"/";

    // X share links carry tracking parameters (?s=20&t=...), and nothing else
    // in an X page query means anything to Nitter, so the query is dropped.
    // Search is the exception: carry the query text over and map X's people
    // search tab onto Nitter's.
    if ([first isEqualToString:@"search"]) {
        NSString *query = nil;
        NSString *tab = nil;
        for (NSURLQueryItem *item in source.queryItems) {
            if ([item.name isEqualToString:@"q"]) query = item.value;
            else if ([item.name isEqualToString:@"f"]) tab = item.value;
        }
        if (query.length > 0) {
            NSString *nitterTab = [tab isEqualToString:@"user"] ? @"users" : @"tweets";
            rewritten.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"f" value:nitterTab],
                [NSURLQueryItem queryItemWithName:@"q" value:query],
            ];
        }
    }

    return rewritten.URL;
}

#pragma mark - Instance list

static NSInteger ApolloNitterIntegerValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value integerValue] : 0;
}

NSArray<ApolloNitterInstance *> *ApolloNitterParseInstanceList(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id hosts = ((NSDictionary *)json)[@"hosts"];
    if (![hosts isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<ApolloNitterInstance *> *instances = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id entry in (NSArray *)hosts) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = entry;
        id healthy = dict[@"healthy"];
        if (![healthy isKindOfClass:[NSNumber class]] || ![healthy boolValue]) continue;

        id domain = dict[@"domain"];
        NSString *host = [domain isKindOfClass:[NSString class]] ? ApolloNitterNormalizeHost(domain) : nil;
        // Public instances are https only; plain http is for an address the
        // user typed themselves, never one the tracker hands us.
        if (!host || [host hasPrefix:@"http://"] || [seen containsObject:host]) continue;
        [seen addObject:host];

        ApolloNitterInstance *instance = [ApolloNitterInstance new];
        instance.host = host;
        instance.points = ApolloNitterIntegerValue(dict[@"points"]);
        instance.averagePingMilliseconds = MAX(0, ApolloNitterIntegerValue(dict[@"ping_avg"]));
        [instances addObject:instance];
    }

    [instances sortUsingComparator:^NSComparisonResult(ApolloNitterInstance *a, ApolloNitterInstance *b) {
        if (a.points != b.points) return a.points > b.points ? NSOrderedAscending : NSOrderedDescending;
        return [a.host compare:b.host];
    }];
    return instances;
}

// Main-queue-only state.
static NSArray<ApolloNitterInstance *> *sCachedInstances;
static NSDate *sCachedInstancesDate;
static NSMutableArray *sPendingCompletions;

void ApolloNitterFetchHealthyInstances(void (^completion)(NSArray<ApolloNitterInstance *> *instances, NSError *error)) {
    if (!completion) return;
    NSCAssert([NSThread isMainThread], @"ApolloNitterFetchHealthyInstances must be called on the main queue");

    if (sCachedInstances && sCachedInstancesDate &&
        -[sCachedInstancesDate timeIntervalSinceNow] < ApolloNitterInstanceCacheLifetime) {
        NSArray<ApolloNitterInstance *> *cached = sCachedInstances;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }

    if (!sPendingCompletions) sPendingCompletions = [NSMutableArray array];
    [sPendingCompletions addObject:[completion copy]];
    if (sPendingCompletions.count > 1) return; // a request is already in flight

    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Ephemeral: no cookies or disk cache left behind by a third-party tracker.
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 15.0;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ApolloNitterTrackerURL]];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray<ApolloNitterInstance *> *instances = nil;
        NSError *finalError = error;
        if (!finalError) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            if (status != 200) {
                finalError = [NSError errorWithDomain:ApolloNitterErrorDomain
                                                 code:status
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Instance tracker returned HTTP %ld", (long)status]}];
            } else {
                instances = ApolloNitterParseInstanceList(data);
                if (!instances) {
                    finalError = [NSError errorWithDomain:ApolloNitterErrorDomain
                                                     code:-1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Instance tracker returned an unexpected response"}];
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (instances) {
                sCachedInstances = instances;
                sCachedInstancesDate = [NSDate date];
            }
            NSArray *callbacks = [sPendingCompletions copy];
            [sPendingCompletions removeAllObjects];
            for (void (^callback)(NSArray<ApolloNitterInstance *> *, NSError *) in callbacks) {
                callback(instances, instances ? nil : finalError);
            }
        });
    }] resume];
}
