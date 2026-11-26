#import "ApolloGatedSubreddit.h"

NSString *const ApolloGatedSubredditWarningKey = @"ApolloGatedSubredditWarning";

NSString *ApolloGatedWarningFromResponseObject(id responseObject) {
    if (![responseObject isKindOfClass:[NSDictionary class]]) return nil;
    id reason = ((NSDictionary *)responseObject)[@"reason"];
    if (![reason isKindOfClass:[NSString class]] || [(NSString *)reason caseInsensitiveCompare:@"gated"] != NSOrderedSame) return nil;
    id message = ((NSDictionary *)responseObject)[@"interstitial_warning_message"];
    NSString *warning = [message isKindOfClass:[NSString class]]
        ? [(NSString *)message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    return warning.length > 0 ? warning : @"Reddit shows a warning before this community.";
}

NSError *ApolloGatedErrorWithWarning(NSError *error, NSString *warning) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:error.userInfo ?: @{}];
    userInfo[ApolloGatedSubredditWarningKey] = warning ?: @"";
    // RedditKit makes an error for every answer with an "error" in it, which a
    // gated one has. Without one the answer would go on as if it were the
    // listing that was asked for.
    return [NSError errorWithDomain:error.domain ?: @"ApolloGatedSubreddit" code:error ? error.code : 403 userInfo:userInfo];
}

// A subreddit's name: 2 to 21 letters, digits or "_", not starting with "_".
static BOOL ApolloGatedIsSubredditName(NSString *name) {
    if (name.length < 2 || name.length > 21 || [name hasPrefix:@"_"]) return NO;
    NSCharacterSet *other = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    return [name rangeOfCharacterFromSet:other].location == NSNotFound;
}

NSString *ApolloGatedSubredditFromListingPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSString *bare = [path componentsSeparatedByString:@"?"].firstObject ?: @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [bare componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    if (parts.count < 2 || [parts[0] caseInsensitiveCompare:@"r"] != NSOrderedSame) return nil;
    NSString *name = parts[1];
    // "r/Drugs.json" is the subreddit's default sort.
    if (parts.count == 2 && [name.lowercaseString hasSuffix:@".json"]) name = [name substringToIndex:name.length - 5];
    return ApolloGatedIsSubredditName(name) ? name : nil;
}

NSURL *ApolloGatedPageURL(NSString *subreddit) {
    if (![subreddit isKindOfClass:[NSString class]] || !ApolloGatedIsSubredditName(subreddit)) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://old.reddit.com/gated"];
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"dest"
                                                           value:[NSString stringWithFormat:@"https://old.reddit.com/r/%@/", subreddit]] ];
    // NSURLComponents leaves ":" and "/" as they are in a query; Reddit's own
    // link to the page has them escaped, and so does this.
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@":" withString:@"%3A"];
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
    return components.URL;
}

// The value of `name="…"` (or name='…') in one HTML tag, with the entities a
// form value has unescaped. nil when the tag has no such attribute.
static NSString *ApolloGatedTagAttribute(NSString *tag, NSString *name) {
    NSString *pattern = [NSString stringWithFormat:@"\\s%@\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", [NSRegularExpression escapedPatternForString:name]];
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                               options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *match = [expression firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match) return nil;
    NSRange range = [match rangeAtIndex:1].location != NSNotFound ? [match rangeAtIndex:1] : [match rangeAtIndex:2];
    NSString *value = range.location != NSNotFound ? [tag substringWithRange:range] : @"";
    NSDictionary<NSString *, NSString *> *entities = @{ @"&quot;": @"\"", @"&#34;": @"\"", @"&#39;": @"'", @"&apos;": @"'",
                                                        @"&lt;": @"<", @"&gt;": @">" };
    for (NSString *entity in entities) value = [value stringByReplacingOccurrencesOfString:entity withString:entities[entity]];
    // "&amp;" last, so "&amp;lt;" comes out as the text "&lt;".
    return [value stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

// One form field for an application/x-www-form-urlencoded body.
static NSString *ApolloGatedFormEncode(NSString *text) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    });
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

NSURLRequest *ApolloGatedAcceptRequest(NSData *pageHTML, NSURL *pageURL, NSString *subreddit) {
    if (pageHTML.length == 0 || !pageURL || subreddit.length == 0) return nil;
    NSString *html = [[NSString alloc] initWithData:pageHTML encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:pageHTML encoding:NSISOLatin1StringEncoding];
    if (html.length == 0) return nil;
    NSRegularExpression *forms = [NSRegularExpression regularExpressionWithPattern:@"<form\\b[^>]*>.*?</form>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:NULL];
    NSRegularExpression *controls = [NSRegularExpression regularExpressionWithPattern:@"<(?:input|button)\\b[^>]*>"
        options:NSRegularExpressionCaseInsensitive error:NULL];
    for (NSTextCheckingResult *found in [forms matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *form = [html substringWithRange:found.range];
        NSString *open = [form substringToIndex:[form rangeOfString:@">"].location + 1];
        if ([ApolloGatedTagAttribute(open, @"method") caseInsensitiveCompare:@"post"] != NSOrderedSame) continue;
        // The warning's form: the subreddit it is for, and a button that accepts.
        NSMutableArray<NSString *> *names = [NSMutableArray array], *values = [NSMutableArray array];
        BOOL accepts = NO;
        for (NSTextCheckingResult *control in [controls matchesInString:form options:0 range:NSMakeRange(0, form.length)]) {
            NSString *tag = [form substringWithRange:control.range];
            NSString *name = ApolloGatedTagAttribute(tag, @"name");
            NSString *value = ApolloGatedTagAttribute(tag, @"value") ?: @"";
            if (name.length == 0) continue;
            if ([name isEqualToString:@"accept"]) {
                if ([value isEqualToString:@"yes"]) accepts = YES;
                continue;
            }
            if ([ApolloGatedTagAttribute(tag, @"type") caseInsensitiveCompare:@"hidden"] != NSOrderedSame) continue;
            [names addObject:name];
            [values addObject:value];
        }
        NSUInteger subredditField = [names indexOfObject:@"sr_name"];
        if (!accepts || subredditField == NSNotFound) continue;
        if ([values[subredditField] caseInsensitiveCompare:subreddit] != NSOrderedSame) continue;

        // An empty action posts back to the page; anything else has to stay on
        // the host the page came from, which is where the cookie is going.
        NSString *action = ApolloGatedTagAttribute(open, @"action");
        NSURL *target = action.length > 0 ? [NSURL URLWithString:action relativeToURL:pageURL].absoluteURL : pageURL;
        if (![target.scheme.lowercaseString isEqualToString:@"https"] ||
            [target.host caseInsensitiveCompare:pageURL.host ?: @""] != NSOrderedSame) {
            return nil;
        }
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        for (NSUInteger i = 0; i < names.count; i++) {
            [fields addObject:[NSString stringWithFormat:@"%@=%@", ApolloGatedFormEncode(names[i]), ApolloGatedFormEncode(values[i])]];
        }
        [fields addObject:@"accept=yes"];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
        request.HTTPMethod = @"POST";
        request.HTTPBody = [[fields componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        return request;
    }
    return nil;
}
