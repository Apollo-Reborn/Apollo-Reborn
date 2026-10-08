#import "ApolloKagiSearchParsing.h"

@implementation ApolloKagiParsedResult

- (instancetype)init {
    if ((self = [super init])) {
        _URLString = @"";
        _title = @"";
        _snippet = @"";
    }
    return self;
}

@end

@implementation ApolloKagiParsedPage

- (instancetype)init {
    if ((self = [super init])) {
        _results = @[];
    }
    return self;
}

@end

#pragma mark - Small HTML helpers

static NSRegularExpression *ApolloKagiRegex(NSString *pattern) {
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                     options:NSRegularExpressionCaseInsensitive |
                                                             NSRegularExpressionDotMatchesLineSeparators
                                                       error:nil];
}

NSString *ApolloKagiDecodeHTMLEntities(NSString *string) {
    if ([string rangeOfString:@"&"].location == NSNotFound) return string ?: @"";
    static NSDictionary<NSString *, NSString *> *named;
    static NSRegularExpression *reference;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{
            @"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'",
            @"nbsp": @" ", @"hellip": @"\u2026", @"mdash": @"\u2014", @"ndash": @"\u2013",
            @"lsquo": @"\u2018", @"rsquo": @"\u2019", @"ldquo": @"\u201C", @"rdquo": @"\u201D",
            @"middot": @"\u00B7", @"bull": @"\u2022", @"rsaquo": @"\u203A", @"lsaquo": @"\u2039",
            @"raquo": @"\u00BB", @"laquo": @"\u00AB", @"copy": @"\u00A9", @"reg": @"\u00AE",
            @"trade": @"\u2122", @"times": @"\u00D7", @"deg": @"\u00B0", @"eacute": @"\u00E9",
        };
        reference = ApolloKagiRegex(@"&(#[0-9]{1,7}|#x[0-9a-f]{1,6}|[a-z][a-z0-9]{1,15});");
    });
    NSMutableString *out = [NSMutableString stringWithCapacity:string.length];
    __block NSUInteger cursor = 0;
    [reference enumerateMatchesInString:string options:0 range:NSMakeRange(0, string.length)
                             usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        [out appendString:[string substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]];
        cursor = NSMaxRange(match.range);
        NSString *body = [string substringWithRange:[match rangeAtIndex:1]];
        NSString *replacement = nil;
        if ([body hasPrefix:@"#"]) {
            BOOL hex = body.length > 1 && ([body characterAtIndex:1] == 'x' || [body characterAtIndex:1] == 'X');
            unsigned long long value = 0;
            NSScanner *scanner = [NSScanner scannerWithString:[body substringFromIndex:hex ? 2 : 1]];
            BOOL ok = hex ? [scanner scanHexLongLong:&value] : [scanner scanUnsignedLongLong:&value];
            if (ok && value > 0 && value <= 0x10FFFF && !(value >= 0xD800 && value <= 0xDFFF)) {
                UTF32Char scalar = (UTF32Char)value;
                replacement = [[NSString alloc] initWithBytes:&scalar length:sizeof(scalar)
                                                     encoding:NSUTF32LittleEndianStringEncoding];
            }
        } else {
            replacement = named[body.lowercaseString];
        }
        [out appendString:replacement ?: [string substringWithRange:match.range]];
    }];
    [out appendString:[string substringFromIndex:cursor]];
    return out;
}

// Tags → spaces, entities decoded, whitespace (incl. NBSP) collapsed.
static NSString *ApolloKagiPlainText(NSString *html) {
    static NSRegularExpression *tags;
    static NSRegularExpression *spaces;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tags = ApolloKagiRegex(@"<[^>]*>");
        spaces = ApolloKagiRegex(@"[\\s\\u00A0]+");
    });
    NSString *text = [tags stringByReplacingMatchesInString:html options:0
                                                      range:NSMakeRange(0, html.length) withTemplate:@" "];
    text = ApolloKagiDecodeHTMLEntities(text);
    text = [spaces stringByReplacingMatchesInString:text options:0
                                              range:NSMakeRange(0, text.length) withTemplate:@" "];
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ApolloKagiAttribute(NSString *attributes, NSString *name) {
    NSString *pattern = [NSString stringWithFormat:@"(?:^|\\s)%@\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
                         [NSRegularExpression escapedPatternForString:name]];
    NSRegularExpression *regex = ApolloKagiRegex(pattern);
    NSTextCheckingResult *match = [regex firstMatchInString:attributes options:0
                                                      range:NSMakeRange(0, attributes.length)];
    if (!match) return nil;
    NSRange value = [match rangeAtIndex:1].location != NSNotFound ? [match rangeAtIndex:1] : [match rangeAtIndex:2];
    if (value.location == NSNotFound) return nil;
    return ApolloKagiDecodeHTMLEntities([attributes substringWithRange:value]);
}

// Whether a class attribute value lists `className` as one of its classes.
static BOOL ApolloKagiHasClass(NSString *attributes, NSString *className) {
    NSString *classes = ApolloKagiAttribute(attributes, @"class");
    if (!classes.length) return NO;
    for (NSString *item in [classes componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if ([item isEqualToString:className]) return YES;
    }
    return NO;
}

// The </div> that closes the <div ...> opening at `start`, counting nested
// divs. `limit` bounds the scan; {NSNotFound, 0} if unbalanced.
static NSRange ApolloKagiClosingDiv(NSString *html, NSUInteger start, NSUInteger limit) {
    static NSRegularExpression *divTag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ divTag = ApolloKagiRegex(@"<(/?)div\\b[^>]*>"); });
    __block NSInteger depth = 0;
    __block NSRange closing = NSMakeRange(NSNotFound, 0);
    [divTag enumerateMatchesInString:html options:0 range:NSMakeRange(start, limit - start)
                          usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        depth += [match rangeAtIndex:1].length > 0 ? -1 : 1;
        if (depth == 0) {
            closing = match.range;
            *stop = YES;
        }
    }];
    return closing;
}

// The inner HTML of the first <div> in `range` carrying `className`.
static NSString *ApolloKagiInnerHTMLOfDiv(NSString *html, NSRange range, NSString *className) {
    static NSRegularExpression *divOpen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ divOpen = ApolloKagiRegex(@"<div\\b([^>]*)>"); });
    __block NSString *inner = nil;
    [divOpen enumerateMatchesInString:html options:0 range:range
                           usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        if (!ApolloKagiHasClass([html substringWithRange:[match rangeAtIndex:1]], className)) return;
        *stop = YES;
        NSRange closing = ApolloKagiClosingDiv(html, match.range.location, NSMaxRange(range));
        NSUInteger innerStart = NSMaxRange(match.range);
        // Unbalanced (a block cut short by the next one): take what's there.
        NSUInteger innerEnd = closing.location == NSNotFound ? NSMaxRange(range) : closing.location;
        if (innerEnd > innerStart) inner = [html substringWithRange:NSMakeRange(innerStart, innerEnd - innerStart)];
    }];
    return inner;
}

#pragma mark - Result blocks

// A result block's opening tag: <div class="… _0_SRI …">, or the older grouped
// sub-result <div class="… __srgi …"> (still read, in case Kagi brings it back).
static NSArray<NSValue *> *ApolloKagiResultBlockStarts(NSString *html) {
    static NSRegularExpression *divOpen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ divOpen = ApolloKagiRegex(@"<div\\b([^>]*)>"); });
    NSMutableArray<NSValue *> *starts = [NSMutableArray array];
    [divOpen enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length)
                           usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        NSString *attributes = [html substringWithRange:[match rangeAtIndex:1]];
        if ([attributes rangeOfString:@"_0_SRI"].location == NSNotFound &&
            [attributes rangeOfString:@"__srgi"].location == NSNotFound) return;   // cheap pre-check
        if (ApolloKagiHasClass(attributes, @"_0_SRI") || ApolloKagiHasClass(attributes, @"__srgi")) {
            [starts addObject:[NSValue valueWithRange:match.range]];
        }
    }];
    return starts;
}

// The title link: <a class="__sri_title_link …" href>, or the first <a href>
// inside a "__srgi-title" element.
static BOOL ApolloKagiTitleLink(NSString *html, NSRange block, NSString **outHref, NSString **outTitle) {
    static NSRegularExpression *anchor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ anchor = ApolloKagiRegex(@"<a\\b([^>]*)>(.*?)</a\\s*>"); });

    NSRange groupedTitle = [html rangeOfString:@"__srgi-title" options:0 range:block];
    __block NSTextCheckingResult *found = nil;
    [anchor enumerateMatchesInString:html options:0 range:block
                          usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        NSString *attributes = [html substringWithRange:[match rangeAtIndex:1]];
        BOOL titleLink = ApolloKagiHasClass(attributes, @"__sri_title_link");
        BOOL groupedLink = groupedTitle.location != NSNotFound && match.range.location > groupedTitle.location;
        if (titleLink || groupedLink) {
            found = match;
            *stop = YES;
        }
    }];
    if (!found) return NO;
    NSString *attributes = [html substringWithRange:[found rangeAtIndex:1]];
    NSString *href = [ApolloKagiAttribute(attributes, @"href")
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *title = ApolloKagiPlainText([html substringWithRange:[found rangeAtIndex:2]]);
    if (!title.length) title = [ApolloKagiAttribute(attributes, @"title") ?: @""
                                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!href.length || !title.length) return NO;
    *outHref = href;
    *outTitle = title;
    return YES;
}

// Snippet + date from the "__sri-desc" block (the date is a span inside it,
// and so is Kagi's "Summarize" link; neither is snippet text).
static void ApolloKagiDescription(NSString *html, NSRange block, NSString **outSnippet, NSString **outDate) {
    NSString *inner = ApolloKagiInnerHTMLOfDiv(html, block, @"__sri-desc");
    if (!inner.length) return;
    static NSRegularExpression *timeSpan;
    static NSRegularExpression *summarize;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeSpan = ApolloKagiRegex(@"<span\\b[^>]*class\\s*=\\s*\"[^\"]*__sri-time[^\"]*\"[^>]*>(.*?)</span\\s*>");
        summarize = ApolloKagiRegex(@"<a\\b[^>]*class\\s*=\\s*\"[^\"]*summarize-link[^\"]*\"[^>]*>.*?</a\\s*>");
    });
    NSTextCheckingResult *time = [timeSpan firstMatchInString:inner options:0 range:NSMakeRange(0, inner.length)];
    if (time) {
        NSString *date = ApolloKagiPlainText([inner substringWithRange:[time rangeAtIndex:1]]);
        if (date.length) *outDate = date;
    }
    NSString *text = [timeSpan stringByReplacingMatchesInString:inner options:0
                                                          range:NSMakeRange(0, inner.length) withTemplate:@" "];
    text = [summarize stringByReplacingMatchesInString:text options:0
                                                 range:NSMakeRange(0, text.length) withTemplate:@" "];
    *outSnippet = ApolloKagiPlainText(text);
}

#pragma mark - Page

static BOOL ApolloKagiLooksSignedOut(NSString *html) {
    // A signed-in results page always has its results container, even when
    // it holds nothing ("We haven't found anything ... Based on your current
    // filters"). Kagi's marketing line ("Welcome to Kagi ... a paid search
    // engine that gives power back to the user", which kagi-cli looks for) is
    // in EVERY page's meta description, so it proves nothing.
    if ([html rangeOfString:@"_0_main-search-results"].location != NSNotFound) return NO;
    // Cloudflare Turnstile interstitial (what kagi.com shows a client without
    // a valid session) and Kagi's account sign-in form.
    if ([html rangeOfString:@"turnstile" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([html rangeOfString:@"action=\"/loginname"].location != NSNotFound) return YES;
    return [html rangeOfString:@"action=\"/signin"].location != NSNotFound;
}

static NSUInteger ApolloKagiExternalLinkCount(NSString *html) {
    static NSRegularExpression *external;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        external = ApolloKagiRegex(@"href\\s*=\\s*\"https?://(?![a-z0-9.-]*kagi\\.com[/\"])[^\"]+\"");
    });
    return [external numberOfMatchesInString:html options:0 range:NSMakeRange(0, html.length)];
}

ApolloKagiParsedPage *ApolloKagiParseResultsHTML(NSString *html) {
    ApolloKagiParsedPage *page = [[ApolloKagiParsedPage alloc] init];
    if (!html.length) {
        page.kind = ApolloKagiPageKindUnreadable;
        return page;
    }

    NSArray<NSValue *> *starts = ApolloKagiResultBlockStarts(html);
    NSMutableArray<ApolloKagiParsedResult *> *results = [NSMutableArray array];
    for (NSUInteger index = 0; index < starts.count; index++) {
        NSUInteger start = starts[index].rangeValue.location;
        NSUInteger next = index + 1 < starts.count ? starts[index + 1].rangeValue.location : html.length;
        NSRange closing = ApolloKagiClosingDiv(html, start, html.length);
        // A block holding nested blocks (a result group) stops at its first
        // child: each child is read as its own block.
        NSUInteger stop = closing.location == NSNotFound ? next : MIN(NSMaxRange(closing), next);
        NSRange block = NSMakeRange(start, stop - start);

        NSString *href = nil;
        NSString *title = nil;
        if (!ApolloKagiTitleLink(html, block, &href, &title)) continue;
        ApolloKagiParsedResult *result = [[ApolloKagiParsedResult alloc] init];
        result.URLString = href;
        result.title = title;
        NSString *snippet = nil;
        NSString *date = nil;
        ApolloKagiDescription(html, block, &snippet, &date);
        result.snippet = snippet ?: @"";
        result.dateText = date;
        [results addObject:result];
    }
    page.results = results;
    page.hasMore = [html rangeOfString:@"id=\"load_more_results\""].location != NSNotFound;

    if (results.count == 0) {
        if (ApolloKagiLooksSignedOut(html)) {
            page.kind = ApolloKagiPageKindSignedOut;
        } else if (starts.count > 0 || ApolloKagiExternalLinkCount(html) >= 5) {
            // Result blocks with no readable title link, or a page full of
            // links but no known result block: the markup has moved.
            page.kind = ApolloKagiPageKindUnreadable;
        }
    }
    return page;
}

#pragma mark - Session token

NSString *ApolloKagiNormalizeSessionToken(NSString *input) {
    NSString *trimmed = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;

    NSString *token = trimmed;
    if ([trimmed rangeOfString:@"://"].location != NSNotFound || [trimmed hasPrefix:@"kagi.com/"] ||
        [trimmed rangeOfString:@"token="].location != NSNotFound) {
        // The Session Link (https://kagi.com/search?token=…). Anything without
        // a token parameter isn't one.
        NSString *link = [trimmed rangeOfString:@"://"].location == NSNotFound
            ? [@"https://" stringByAppendingString:trimmed] : trimmed;
        NSURLComponents *components = [NSURLComponents componentsWithString:link];
        token = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"token"] && item.value.length) token = item.value;
        }
        if (!token) return nil;
    }

    // Kagi's tokens are URL-safe base64-ish text ("abc…_x-y.z…").
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [[NSCharacterSet characterSetWithCharactersInString:
                    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"] invertedSet];
    });
    if (token.length < 16 || token.length > 512) return nil;
    if ([token rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return token;
}
