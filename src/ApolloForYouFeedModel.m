#import "ApolloForYouFeedModel.h"

static NSString *const kApolloForYouFeedEndpoint = @"https://www.reddit.com/svc/shreddit/feeds/interest-home-feed";
static NSString *const kApolloForYouTokenPrefix = @"foryou:";

NSURL *ApolloForYouFeedPageURL(NSString *feed, NSString *afterFullname) {
    if (feed.length == 0) return nil;
    // Query values are percent-encoded by hand: base64 carries "+", "/" and
    // "=", which NSURLComponents would leave bare in a query value (and the
    // server would read "+" as a space).
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    if (afterFullname.length > 0) {
        // The website sends base64 of the fullname as both `after` and `cursor`;
        // `after` alone pages correctly (checked 2026-11-01).
        NSString *encoded = [[afterFullname dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        [pairs addObject:[@"after=" stringByAppendingString:
                          [encoded stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
    }
    [pairs addObject:[@"feed=" stringByAppendingString:[feed stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
    [pairs addObject:@"render-mode=partial"];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", kApolloForYouFeedEndpoint,
                                 [pairs componentsJoinedByString:@"&"]]];
}

// `<shreddit-post` followed by whitespace: excludes `<shreddit-post-flair`,
// `<shreddit-post-overflow-menu` etc., and `<shreddit-ad-post` never matches.
// The tag body is captured up to the first '>' (attribute values in this markup
// are HTML-escaped, so a literal '>' never appears inside one).
static NSRegularExpression *ApolloForYouPostTagRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"<shreddit-post\\s([^>]*)>"
                                                          options:0
                                                            error:nil];
    });
    return regex;
}

static NSRegularExpression *ApolloForYouIDAttributeRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Preceded by whitespace so `post-id=`, `author-id=`, `subreddit-id=`
        // and `user-id=` never match.
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|\\s)id=\"(t3_[a-z0-9]+)\""
                                                          options:0
                                                            error:nil];
    });
    return regex;
}

static NSRegularExpression *ApolloForYouPromotedRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|\\s)(?:promoted|is-promoted)(?:[\\s=]|$)"
                                                          options:0
                                                            error:nil];
    });
    return regex;
}

NSArray<NSString *> *ApolloForYouFeedParsePostIDs(NSString *html) {
    if (html.length == 0) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSRegularExpression *idRegex = ApolloForYouIDAttributeRegex();
    NSRegularExpression *promotedRegex = ApolloForYouPromotedRegex();
    [ApolloForYouPostTagRegex() enumerateMatchesInString:html
                                                 options:0
                                                   range:NSMakeRange(0, html.length)
                                              usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        NSRange bodyRange = [match rangeAtIndex:1];
        if (bodyRange.location == NSNotFound) return;
        NSString *body = [html substringWithRange:bodyRange];
        NSRange whole = NSMakeRange(0, body.length);
        if ([promotedRegex firstMatchInString:body options:0 range:whole]) return;
        NSTextCheckingResult *idMatch = [idRegex firstMatchInString:body options:0 range:whole];
        if (!idMatch) return;
        NSString *fullname = [body substringWithRange:[idMatch rangeAtIndex:1]];
        if ([seen containsObject:fullname]) return;
        [seen addObject:fullname];
        [ids addObject:fullname];
    }];
    return ids;
}

BOOL ApolloForYouFeedHTMLHasNextPage(NSString *html) {
    return html.length > 0 && [html rangeOfString:@"interest-home-feed?after="].location != NSNotFound;
}

BOOL ApolloForYouFeedHTMLIsSignedIn(NSString *html) {
    if (ApolloForYouFeedParsePostIDs(html).count == 0) return YES;
    return [html rangeOfString:@" user-logged-in"].location != NSNotFound;
}

static double ApolloForYouHeaderNumber(NSDictionary *headers, NSString *name) {
    if (![headers isKindOfClass:[NSDictionary class]]) return -1;
    for (id key in headers) {
        if (![key isKindOfClass:[NSString class]] || [(NSString *)key caseInsensitiveCompare:name] != NSOrderedSame) continue;
        id value = headers[key];
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) return -1;
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double number = 0;
        return [scanner scanDouble:&number] ? number : -1;
    }
    return -1;
}

double ApolloForYouFeedRateLimitRemaining(NSDictionary *headers) {
    return ApolloForYouHeaderNumber(headers, @"x-ratelimit-remaining");
}

double ApolloForYouFeedRateLimitReset(NSDictionary *headers) {
    return ApolloForYouHeaderNumber(headers, @"x-ratelimit-reset");
}

NSArray<NSDictionary *> *ApolloForYouFeedOrderedChildren(id infoResponse, NSArray<NSString *> *orderedIDs) {
    id listing = infoResponse;
    if ([listing isKindOfClass:[NSArray class]]) listing = [(NSArray *)listing lastObject];
    if (![listing isKindOfClass:[NSDictionary class]]) return @[];
    id data = ((NSDictionary *)listing)[@"data"];
    id children = [data isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)data)[@"children"] : nil;
    if (![children isKindOfClass:[NSArray class]]) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (id child in (NSArray *)children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        if (![((NSDictionary *)child)[@"kind"] isEqual:@"t3"]) continue;
        id childData = ((NSDictionary *)child)[@"data"];
        if (![childData isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = ((NSDictionary *)childData)[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        // A post the user hid on Reddit stays hidden here too.
        if ([((NSDictionary *)childData)[@"hidden"] isEqual:@YES]) continue;
        byName[name] = child;
    }
    NSMutableArray<NSDictionary *> *ordered = [NSMutableArray arrayWithCapacity:orderedIDs.count];
    for (NSString *fullname in orderedIDs) {
        NSDictionary *child = byName[fullname];
        if (child) [ordered addObject:child];
    }
    return ordered;
}

NSDictionary *ApolloForYouFeedListing(NSArray<NSDictionary *> *children, NSString *after) {
    return @{
        @"kind": @"Listing",
        @"data": @{
            @"children": children ?: @[],
            @"after": after.length > 0 ? after : [NSNull null],
            @"before": [NSNull null],
            @"dist": @(children.count),
        },
    };
}

NSString *ApolloForYouFeedToken(NSString *sessionID, NSUInteger index) {
    return [NSString stringWithFormat:@"%@%@:%lu", kApolloForYouTokenPrefix, sessionID ?: @"", (unsigned long)index];
}

BOOL ApolloForYouFeedParseToken(NSString *token, NSString **outSessionID, NSUInteger *outIndex) {
    if (![token isKindOfClass:[NSString class]] || ![token hasPrefix:kApolloForYouTokenPrefix]) return NO;
    NSString *rest = [token substringFromIndex:kApolloForYouTokenPrefix.length];
    NSRange colon = [rest rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound || colon.location == 0) return NO;
    NSString *sessionID = [rest substringToIndex:colon.location];
    NSString *indexString = [rest substringFromIndex:colon.location + 1];
    NSScanner *scanner = [NSScanner scannerWithString:indexString];
    unsigned long long index = 0;
    if (![scanner scanUnsignedLongLong:&index] || !scanner.isAtEnd) return NO;
    if (outSessionID) *outSessionID = sessionID;
    if (outIndex) *outIndex = (NSUInteger)index;
    return YES;
}

BOOL ApolloForYouFeedIsHomeListingPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return NO;
    NSString *p = path;
    while ([p hasPrefix:@"/"]) p = [p substringFromIndex:1];
    static NSSet<NSString *> *homePaths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        homePaths = [NSSet setWithArray:@[ @"best.json", @"hot.json", @"new.json", @"rising.json",
                                           @"controversial.json", @"top.json" ]];
    });
    return [homePaths containsObject:p.lowercaseString];
}
