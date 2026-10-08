#import "ApolloGoogleSearch.h"

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloScrapeWebView.h"
#import "ApolloState.h"

NSString *const ApolloGoogleSearchErrorDomain = @"ApolloGoogleSearchErrorDomain";

// How long one results page may take before giving up. Google's JS bootstrap
// plus the results navigation is ~1.5-4 s on a phone; the rest is headroom for
// slow networks. The clock stops while the user answers a verification page.
static const NSTimeInterval kApolloGoogleSearchPageTimeout = 25.0;
// A user answering a challenge gets this long before the search gives up.
static const NSTimeInterval kApolloGoogleSearchVerificationTimeout = 300.0;
static const NSTimeInterval kApolloGoogleSearchPollInterval = 0.35;
// Consecutive polls of a settled results container with no Reddit results
// before calling the page empty (~1.4 s): the page can still be swapping in
// its results right after readyState flips to complete.
static const NSInteger kApolloGoogleSearchEmptyPollsToSettle = 4;
// Polls with an unchanged result count before taking a page that is still
// "interactive" (~2 s).
static const NSInteger kApolloGoogleSearchStablePollsToAccept = 6;
static const NSTimeInterval kApolloGoogleSearchRedditInfoTimeout = 5.0;

static NSError *ApolloGoogleSearchError(ApolloGoogleSearchErrorCode code, NSString *description) {
    return [NSError errorWithDomain:ApolloGoogleSearchErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @""}];
}

#pragma mark - Options

@implementation ApolloGoogleSearchOptions

- (id)copyWithZone:(NSZone *)zone {
    ApolloGoogleSearchOptions *copy = [[ApolloGoogleSearchOptions allocWithZone:zone] init];
    copy.timeRange = self.timeRange;
    copy.exactWords = self.exactWords;
    return copy;
}

@end

#pragma mark - Result

@implementation ApolloGoogleSearchResult

- (instancetype)init {
    if ((self = [super init])) {
        _title = @"";
        _snippet = @"";
        _snippetBoldRanges = @[];
    }
    return self;
}

- (NSString *)dedupeKey {
    if (self.postID.length) {
        return [NSString stringWithFormat:@"t3_%@/%@", self.postID.lowercaseString,
                self.commentID.lowercaseString ?: @""];
    }
    if (self.URL) {
        NSString *path = self.URL.path.lowercaseString ?: @"";
        while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
        return path;
    }
    // Not followed yet: what the card shows. Recurring threads ("Weekly
    // Questions Thread") share a subreddit and title but not the line or
    // snippet, so those stay separate; the same thread listed again on a
    // later page matches.
    return [NSString stringWithFormat:@"google:%@|%@|%@|%@", self.subreddit.lowercaseString ?: @"",
            self.title.lowercaseString ?: @"", self.engineMeta.lowercaseString ?: @"",
            self.snippet.lowercaseString ?: @""];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ kind=%ld r/%@ post=%@ comment=%@ title=%@ meta=%@>",
            NSStringFromClass(self.class), (long)self.kind, self.subreddit, self.postID,
            self.commentID, self.title, self.engineMeta];
}

@end

#pragma mark - Query building

static NSRegularExpression *ApolloGoogleRegex(NSString *pattern) {
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                     options:NSRegularExpressionCaseInsensitive
                                                       error:nil];
}

NSString *ApolloGoogleSearchComposeQuery(NSString *rawQuery) {
    NSString *query = [rawQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (query.length == 0) return @"";
    // iOS Smart Punctuation turns typed quotes into curly ones; Google's exact
    // phrase operator wants plain double quotes.
    for (NSString *curly in @[@"\u201C", @"\u201D", @"\u201E", @"\u201F", @"\u2033"]) {
        query = [query stringByReplacingOccurrencesOfString:curly withString:@"\""];
    }

    // "r/name" / "/r/name" tokens scope the search to that subreddit. Reddit's
    // names are 3-21 chars of [A-Za-z0-9_] (a few legacy two-letter ones exist).
    static NSRegularExpression *subredditToken;
    static NSRegularExpression *siteOperator;
    static NSRegularExpression *trailingReddit;
    static NSRegularExpression *spaces;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        subredditToken = ApolloGoogleRegex(@"(?<![\\w/:.])/?r/([A-Za-z0-9][A-Za-z0-9_]{1,20})(?![\\w/])");
        siteOperator = ApolloGoogleRegex(@"(^|\\s)-?site:\\S+");
        trailingReddit = ApolloGoogleRegex(@"\\s+(on\\s+)?reddit\\s*$");
        spaces = ApolloGoogleRegex(@"\\s{2,}");
    });

    BOOL userSite = [siteOperator firstMatchInString:query options:0 range:NSMakeRange(0, query.length)] != nil;

    NSMutableArray<NSString *> *subreddits = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (!userSite) {
        NSArray<NSTextCheckingResult *> *matches =
            [subredditToken matchesInString:query options:0 range:NSMakeRange(0, query.length)];
        NSMutableString *stripped = [query mutableCopy];
        for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
            NSString *name = [query substringWithRange:[match rangeAtIndex:1]];
            if (![seen containsObject:name.lowercaseString]) {
                [seen addObject:name.lowercaseString];
                [subreddits insertObject:name atIndex:0];
            }
            [stripped replaceCharactersInRange:match.range withString:@" "];
        }
        query = stripped;
    }

    // "... reddit" / "... on reddit" at the end is the habit this whole mode
    // replaces; the site: restriction does its job better. Only when there's
    // something left to search for.
    NSString *withoutReddit = [trailingReddit stringByReplacingMatchesInString:query
                                                                       options:0
                                                                         range:NSMakeRange(0, query.length)
                                                                  withTemplate:@""];
    withoutReddit = [withoutReddit stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!userSite && withoutReddit.length > 0) query = withoutReddit;

    query = [spaces stringByReplacingMatchesInString:query options:0
                                               range:NSMakeRange(0, query.length) withTemplate:@" "];
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (userSite) return query;

    NSString *site;
    if (subreddits.count == 0) {
        site = @"site:reddit.com";
    } else if (subreddits.count == 1) {
        site = [@"site:reddit.com/r/" stringByAppendingString:subreddits.firstObject];
    } else {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *name in subreddits) [parts addObject:[@"site:reddit.com/r/" stringByAppendingString:name]];
        site = [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@" OR "]];
    }
    return query.length ? [NSString stringWithFormat:@"%@ %@", query, site] : site;
}

// Google UI language: the device's first preferred language (Google localizes
// the "30+ comments · 2 weeks ago" line, which we show verbatim).
static NSString *ApolloGoogleSearchLanguageCode(void) {
    NSString *preferred = NSLocale.preferredLanguages.firstObject ?: @"en";
    // "zh-Hant-TW" → "zh-TW" is what Google expects for Chinese; others take the bare code.
    NSArray<NSString *> *parts = [preferred componentsSeparatedByString:@"-"];
    NSString *language = parts.firstObject.lowercaseString ?: @"en";
    if ([language isEqualToString:@"zh"] && parts.count > 1) {
        NSString *region = parts.lastObject.uppercaseString;
        BOOL traditional = [preferred containsString:@"Hant"] || [region isEqualToString:@"TW"] || [region isEqualToString:@"HK"];
        return traditional ? @"zh-TW" : @"zh-CN";
    }
    return language.length ? language : @"en";
}

NSURL *ApolloGoogleSearchURL(NSString *rawQuery, ApolloGoogleSearchOptions *options, NSUInteger page) {
    NSString *query = ApolloGoogleSearchComposeQuery(rawQuery);
    if (query.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.google.com/search"];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"hl" value:ApolloGoogleSearchLanguageCode()]];
    // udm=14 is Google's plain "Web" results view: organic links only — no AI
    // Overview, "People also ask", video/image carousels or ads blocks between
    // results. That is both what this list wants to show and what keeps the
    // extractor's job simple.
    [items addObject:[NSURLQueryItem queryItemWithName:@"udm" value:@"14"]];

    NSMutableArray<NSString *> *tbs = [NSMutableArray array];
    switch (options.timeRange) {
        case ApolloGoogleSearchTimeRangeDay: [tbs addObject:@"qdr:d"]; break;
        case ApolloGoogleSearchTimeRangeWeek: [tbs addObject:@"qdr:w"]; break;
        case ApolloGoogleSearchTimeRangeMonth: [tbs addObject:@"qdr:m"]; break;
        case ApolloGoogleSearchTimeRangeYear: [tbs addObject:@"qdr:y"]; break;
        case ApolloGoogleSearchTimeRangeAny: default: break;
    }
    if (options.exactWords) [tbs addObject:@"li:1"];
    if (tbs.count) [items addObject:[NSURLQueryItem queryItemWithName:@"tbs" value:[tbs componentsJoinedByString:@","]]];
    if (page > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"start"
                                                     value:[NSString stringWithFormat:@"%lu", (unsigned long)(page * 10)]]];
    }
    components.queryItems = items;
    // NSURLComponents leaves '+' alone in query values, which Google would read
    // as a space ("c++" → "c  "). Encode it explicitly.
    components.percentEncodedQuery =
        [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return components.URL;
}

#pragma mark - Result classification

static NSArray<NSString *> *ApolloGooglePathSegments(NSString *path) {
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
        if (segment.length) [segments addObject:segment.stringByRemovingPercentEncoding ?: segment];
    }
    return segments;
}

static BOOL ApolloGoogleIsBase36ID(NSString *value) {
    if (value.length < 2 || value.length > 13) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL ApolloGoogleIsName(NSString *value) {
    if (value.length < 2 || value.length > 30) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

// Fills postID/commentID from a ".../comments/<id>[/<slug>][/<cid>]" or
// ".../comments/<id>/comment/<cid>" tail starting at `index` (the "comments" segment).
static void ApolloGoogleApplyThreadTail(ApolloGoogleSearchResult *result, NSArray<NSString *> *segments, NSUInteger index) {
    if (index + 1 >= segments.count) return;
    NSString *postID = segments[index + 1];
    if (!ApolloGoogleIsBase36ID(postID)) return;
    result.postID = postID.lowercaseString;
    result.kind = ApolloGoogleResultKindPost;

    // The comment id is the segment after the slug, or after the literal
    // "comment" in the newer /comments/<id>/comment/<cid> form: same position.
    NSString *commentID = index + 3 < segments.count ? segments[index + 3] : nil;
    if (commentID && ApolloGoogleIsBase36ID(commentID)) {
        result.commentID = commentID.lowercaseString;
        result.kind = ApolloGoogleResultKindComment;
    }
}

ApolloGoogleSearchResult *ApolloGoogleSearchResultForURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host.length) return nil;
    BOOL reddit = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    BOOL shortener = [host isEqualToString:@"redd.it"];
    if (!reddit && !shortener) return nil;

    NSArray<NSString *> *segments = ApolloGooglePathSegments(url.path ?: @"");
    ApolloGoogleSearchResult *result = [[ApolloGoogleSearchResult alloc] init];
    result.kind = ApolloGoogleResultKindOther;

    if (shortener) {
        if (segments.count != 1 || !ApolloGoogleIsBase36ID(segments.firstObject)) return nil;
        result.postID = segments.firstObject.lowercaseString;
        result.kind = ApolloGoogleResultKindPost;
        result.URL = [NSURL URLWithString:[@"https://www.reddit.com/comments/" stringByAppendingString:result.postID]];
        return result;
    }
    if (segments.count == 0) return nil;

    NSString *first = segments[0].lowercaseString;
    NSString *canonicalPath = nil;

    if ([first isEqualToString:@"r"] && segments.count >= 2 && ApolloGoogleIsName(segments[1])) {
        result.subreddit = segments[1];
        if (segments.count >= 4 && [segments[2].lowercaseString isEqualToString:@"comments"]) {
            ApolloGoogleApplyThreadTail(result, segments, 2);
            if (!result.postID) return nil;
        } else if (segments.count >= 3 && [segments[2].lowercaseString isEqualToString:@"s"]) {
            // Share links (/r/<sub>/s/<token>) resolve server-side; Apollo's
            // router follows them, but they can't be deduped against threads.
            result.kind = ApolloGoogleResultKindOther;
        } else if (segments.count == 2 ||
                   (segments.count == 3 && [@[@"hot", @"new", @"top", @"rising", @"about"]
                                             containsObject:segments[2].lowercaseString])) {
            result.kind = ApolloGoogleResultKindSubreddit;
            canonicalPath = [NSString stringWithFormat:@"/r/%@/", result.subreddit];
        } else if (segments.count >= 3 && [segments[2].lowercaseString isEqualToString:@"wiki"]) {
            result.kind = ApolloGoogleResultKindOther;
        } else {
            return nil;   // /r/<sub>/search, /r/<sub>/submit, ...
        }
    } else if (([first isEqualToString:@"user"] || [first isEqualToString:@"u"]) &&
               segments.count >= 2 && ApolloGoogleIsName(segments[1])) {
        result.username = segments[1];
        if (segments.count >= 4 && [segments[2].lowercaseString isEqualToString:@"comments"]) {
            ApolloGoogleApplyThreadTail(result, segments, 2);
            if (!result.postID) return nil;
        } else if (segments.count == 2 ||
                   (segments.count == 3 && [@[@"submitted", @"comments", @"overview"]
                                             containsObject:segments[2].lowercaseString])) {
            result.kind = ApolloGoogleResultKindUser;
            canonicalPath = [NSString stringWithFormat:@"/user/%@/", result.username];
        } else {
            return nil;
        }
    } else if ([first isEqualToString:@"comments"] && segments.count >= 2) {
        ApolloGoogleApplyThreadTail(result, segments, 0);
        if (!result.postID) return nil;
    } else if ([first isEqualToString:@"gallery"] && segments.count >= 2 && ApolloGoogleIsBase36ID(segments[1])) {
        result.postID = segments[1].lowercaseString;
        result.kind = ApolloGoogleResultKindPost;
        canonicalPath = [@"/comments/" stringByAppendingString:result.postID];
    } else {
        // Reddit Answers, the media viewer, /search, /topics, /t/, login, ...:
        // nothing Apollo shows natively.
        return nil;
    }

    if (!canonicalPath) {
        // Keep the path (sub casing, slug, comment id) but normalize host,
        // drop tracking query items and fragments.
        canonicalPath = url.path.length ? url.path : @"/";
    }
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"www.reddit.com";
    components.percentEncodedPath = [canonicalPath stringByAddingPercentEncodingWithAllowedCharacters:
                                     NSCharacterSet.URLPathAllowedCharacterSet] ?: canonicalPath;
    result.URL = components.URL;
    return result.URL ? result : nil;
}

// Copies what `url` says about the result (kind, subreddit, user, post and
// comment ids, canonical URL) onto `result`. NO when it isn't a Reddit page
// Apollo can show.
static BOOL ApolloGoogleApplyURL(ApolloGoogleSearchResult *result, NSURL *url) {
    ApolloGoogleSearchResult *classified = url ? ApolloGoogleSearchResultForURL(url) : nil;
    if (!classified) return NO;
    result.URL = classified.URL;
    result.kind = classified.kind;
    if (classified.subreddit.length) result.subreddit = classified.subreddit;
    if (classified.username.length) result.username = classified.username;
    result.postID = classified.postID;
    result.commentID = classified.commentID;
    return YES;
}

#pragma mark - Text helpers

// Google result titles for Reddit carry a site suffix: "Title : r/PTCGP",
// "Title - Reddit", "Title | Reddit", "Title : reddit". Strip the suffix only.
NSString *ApolloGoogleSearchCleanTitle(NSString *title) {
    NSString *clean = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    static NSRegularExpression *suffix;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffix = ApolloGoogleRegex(@"\\s*(?::|-|–|—|\\|)\\s*(?:r/[A-Za-z0-9_]+|reddit(?:\\.com)?)\\s*$");
    });
    for (int pass = 0; pass < 2; pass++) {
        NSString *next = [suffix stringByReplacingMatchesInString:clean options:0
                                                            range:NSMakeRange(0, clean.length) withTemplate:@""];
        if ([next isEqualToString:clean] || next.length == 0) break;
        clean = next;
    }
    // ...and sometimes a prefix instead: "r/PTCGP - Top 5 Meta Decks".
    static NSRegularExpression *prefix;
    static dispatch_once_t prefixOnce;
    dispatch_once(&prefixOnce, ^{ prefix = ApolloGoogleRegex(@"^r/[A-Za-z0-9_]+\\s*[-–—:|]\\s*"); });
    NSString *unprefixed = [prefix stringByReplacingMatchesInString:clean options:0
                                                              range:NSMakeRange(0, clean.length) withTemplate:@""];
    if (unprefixed.length) clean = unprefixed;
    return clean.length ? clean : title;
}

// Collapses whitespace and converts the extractor's bold markers (\u0001 bold
// run \u0002) into plain text + ranges. Also drops Google's leading
// "r/sub - " prefix and a trailing "Read more".
static NSString *ApolloGoogleParseMarkedSnippet(NSString *marked, NSArray<NSValue *> **boldRanges) {
    NSMutableString *text = [NSMutableString string];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSUInteger boldStart = NSNotFound;
    BOOL pendingSpace = NO;
    for (NSUInteger i = 0; i < marked.length; i++) {
        unichar c = [marked characterAtIndex:i];
        if (c == 0x0001) {
            if (pendingSpace && text.length) { [text appendString:@" "]; pendingSpace = NO; }
            boldStart = text.length;
            continue;
        }
        if (c == 0x0002) {
            if (boldStart != NSNotFound && text.length > boldStart) {
                NSRange range = NSMakeRange(boldStart, text.length - boldStart);
                NSValue *last = ranges.lastObject;
                if (last && NSMaxRange(last.rangeValue) + 1 >= range.location &&
                    NSMaxRange(last.rangeValue) <= range.location) {
                    // Adjacent runs ("<em>foo</em> <em>bar</em>") merge into one.
                    range = NSUnionRange(last.rangeValue, range);
                    [ranges removeLastObject];
                }
                [ranges addObject:[NSValue valueWithRange:range]];
            }
            boldStart = NSNotFound;
            continue;
        }
        if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c] || c == 0x00A0) {
            if (text.length) pendingSpace = YES;
            continue;
        }
        if (pendingSpace) {
            [text appendString:@" "];
            pendingSpace = NO;
        }
        [text appendFormat:@"%C", c];
    }

    // Leading "r/PTCGP - " / "r/PTCGP · " (Google prefixes forum snippets).
    static NSRegularExpression *prefix;
    static NSRegularExpression *readMore;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = ApolloGoogleRegex(@"^r/[A-Za-z0-9_]+\\s*[-–—·:]\\s*");
        readMore = ApolloGoogleRegex(@"\\s*(?:Read more|More)\\s*$");
    });
    NSTextCheckingResult *match = [prefix firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSUInteger cut = match ? match.range.length : 0;
    NSTextCheckingResult *tail = [readMore firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSUInteger end = tail ? tail.range.location : text.length;
    if (end < cut) end = cut;

    NSString *result = [text substringWithRange:NSMakeRange(cut, end - cut)];
    NSMutableArray<NSValue *> *shifted = [NSMutableArray array];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        if (NSMaxRange(range) <= cut || range.location >= end) continue;
        NSUInteger start = MAX(range.location, cut) - cut;
        NSUInteger stop = MIN(NSMaxRange(range), end) - cut;
        if (stop > start) [shifted addObject:[NSValue valueWithRange:NSMakeRange(start, stop - start)]];
    }
    if (boldRanges) *boldRanges = shifted;
    return result;
}

NSString *ApolloGoogleSearchPlainTextFromMarkdown(NSString *markdown) {
    if (!markdown.length) return @"";
    NSString *text = markdown;
    static NSArray<NSArray *> *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rules = @[
            // Backslash escapes (\~750, \*, \#) → the character itself.
            @[ApolloGoogleRegex(@"\\\\([^\\w\\s])"), @"$1"],
            // Fenced/indented code markers, keep the code text.
            @[ApolloGoogleRegex(@"(?m)^```.*$"), @""],
            // Images and links: [label](url) → label; bare <url> → url.
            @[ApolloGoogleRegex(@"!?\\[([^\\]]*)\\]\\([^)]*\\)"), @"$1"],
            @[ApolloGoogleRegex(@"<(https?://[^>]+)>"), @"$1"],
            // Spoilers >!text!< → text.
            @[ApolloGoogleRegex(@">!(.*?)!<"), @"$1"],
            // Headings, quotes, list bullets at line starts.
            @[ApolloGoogleRegex(@"(?m)^\\s{0,3}#{1,6}\\s*"), @""],
            @[ApolloGoogleRegex(@"(?m)^\\s*(?:&gt;|>)\\s?"), @""],
            @[ApolloGoogleRegex(@"(?m)^\\s*[-*+]\\s+"), @"• "],
            // Emphasis / strike / inline code / superscript.
            @[ApolloGoogleRegex(@"(\\*\\*|__)(.+?)\\1"), @"$2"],
            @[ApolloGoogleRegex(@"(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])"), @"$1"],
            @[ApolloGoogleRegex(@"~~(.+?)~~"), @"$1"],
            @[ApolloGoogleRegex(@"`([^`]*)`"), @"$1"],
            @[ApolloGoogleRegex(@"\\^\\(([^)]*)\\)"), @"$1"],
            // Table rules and horizontal rules.
            @[ApolloGoogleRegex(@"(?m)^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$"), @""],
            @[ApolloGoogleRegex(@"(?m)^\\s*(\\*\\s*){3,}$|^\\s*(-\\s*){3,}$"), @""],
            @[ApolloGoogleRegex(@"&nbsp;|&#x200B;"), @" "],
            @[ApolloGoogleRegex(@"\\n{3,}"), @"\n\n"],
        ];
    });
    for (NSArray *rule in rules) {
        NSRegularExpression *regex = rule[0];
        text = [regex stringByReplacingMatchesInString:text options:0
                                                 range:NSMakeRange(0, text.length) withTemplate:rule[1]];
    }
    text = [text stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    text = [text stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    text = [text stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// "Reddit · r/PTCGP" (Google's breadcrumb) or "Title : r/PTCGP" → "PTCGP".
static NSString *ApolloGoogleSubredditFromLines(NSArray *lines, NSString *title) {
    static NSRegularExpression *token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ token = ApolloGoogleRegex(@"(?:^|[\\s·:|/-])r/([A-Za-z0-9][A-Za-z0-9_]{1,20})\\b"); });
    NSMutableArray *candidates = [NSMutableArray arrayWithArray:lines ?: @[]];
    if (title.length) [candidates addObject:title];
    for (id line in candidates) {
        if (![line isKindOfClass:[NSString class]]) continue;
        NSTextCheckingResult *match = [token firstMatchInString:line options:0 range:NSMakeRange(0, [(NSString *)line length])];
        if (match) return [(NSString *)line substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
}

#pragma mark - Extractor script

// Reads the rendered results page. Structure-based, not text-based: Google's
// class names are obfuscated and rotate, and its UI strings are localized.
//
//   * a result = an <a href> that contains a heading (h3 or role=heading) and
//     points at Reddit: directly, through a google.com/url?q= redirect, or
//     through the opaque google.com/goto?url=<token> link (resolved natively);
//   * its block = the highest ancestor that contains no OTHER such result;
//   * snippet = the longest text-bearing element in the block outside the
//     title link that isn't just a wrapper around a longer child;
//   * meta = short text lines in and around the title link that aren't the
//     title or the snippet (Google's forum "30+ comments · 2 weeks ago" line;
//     the "Reddit · r/sub" breadcrumb is filtered out natively).
//
// Also reports how many links the results container holds, so a page full of
// links with no recognizable result reads as "couldn't read the page" rather
// than as a genuine "no results".
//
// Bold runs (Google's highlighted query terms) are wrapped in \u0001…\u0002.
static NSString *const kApolloGoogleExtractorJS =
    @"(function(){"
    "var out={href:location.href,ready:document.readyState,results:[]};"
    "function T(el){return el?(el.innerText||el.textContent||'').replace(/\\s+/g,' ').trim():'';}"
    "try{"
    "var host=location.hostname,path=location.pathname;"
    "if(/^\\/sorry(\\/|$)/.test(path)){out.challenge='captcha';return JSON.stringify(out);}"
    "if(/(^|\\.)consent\\.(google|youtube)\\./.test(host)){out.challenge='consent';return JSON.stringify(out);}"
    "if(document.querySelector('form[action*=\"consent.google\"],iframe[src*=\"consent.google\"]')){out.challenge='consent';}"
    "if(document.querySelector('#captcha-form,iframe[src*=\"recaptcha\"],div.g-recaptcha')){out.challenge='captcha';return JSON.stringify(out);}"
    "var rso=document.getElementById('rso'),search=document.getElementById('search');"
    "out.container=!!(rso||search);"
    "var root=rso||search||document.getElementById('main')||document.body;"
    "if(!root)return JSON.stringify(out);"
    // Direct link → {url}; google.com/url?q= → {url} of the target; the phone
    // layout's opaque google.com/goto?url=<token> → {go} (resolved natively).
    "function unwrap(h){if(!h)return null;var u;try{u=new URL(h,location.href);}catch(e){return null;}"
      "if(/(^|\\.)google\\.[a-z.]+$/.test(u.hostname)){"
        "if(u.pathname==='/goto')return {go:u.href};"
        "if(u.pathname==='/url'||u.pathname==='/interstitial'){var q=u.searchParams.get('q')||u.searchParams.get('url');"
          "if(!q)return null;if(/^https?:/.test(q)){try{return {url:new URL(q).href};}catch(e){return null;}}return {go:u.href};}"
        "return null;}"
      "return {url:u.href};}"
    "function isReddit(h){try{var x=new URL(h).hostname.toLowerCase();return x==='reddit.com'||/\\.reddit\\.com$/.test(x)||x==='redd.it';}catch(e){return false;}}"
    "var HSEL='h3,[role=\"heading\"]';"
    "function titleAnchors(scope){var list=[],as=scope.querySelectorAll('a[href]');"
      "for(var i=0;i<as.length;i++){var h=as[i].querySelector(HSEL);if(h&&T(h).length)list.push(as[i]);}return list;}"
    "function marked(el){var s='';(function walk(n,b){for(var c=n.firstChild;c;c=c.nextSibling){"
        "if(c.nodeType===3){s+=b?'\\u0001'+c.nodeValue+'\\u0002':c.nodeValue;continue;}"
        "if(c.nodeType!==1)continue;var tag=c.tagName;"
        "if(tag==='SCRIPT'||tag==='STYLE'||tag==='A'||tag==='svg'||tag==='SVG'||tag==='IMG'||tag==='G-IMG')continue;"
        "var cs=getComputedStyle(c);if(cs.display==='none'||cs.visibility==='hidden')continue;"
        "var bold=b||tag==='EM'||tag==='B'||tag==='STRONG'||parseInt(cs.fontWeight,10)>=600;"
        "if(tag==='BR'||cs.display==='block'||cs.display==='flex')s+=' ';"
        "walk(c,bold);}})(el,false);return s;}"
    "var anchors=titleAnchors(root);out.anchorCount=anchors.length;"
    "out.containerLinks=(rso||search)?(rso||search).querySelectorAll('a[href]').length:0;"
    // "More search results" (phone) / "Next" (desktop): language-neutral, any
    // link whose start= is past this page's.
    "var cur=parseInt(new URL(location.href).searchParams.get('start')||'0',10);out.next=false;"
    "var sl=document.querySelectorAll('a[href*=\"start=\"]');for(var n=0;n<sl.length;n++){"
      "try{var st=parseInt(new URL(sl[n].getAttribute('href'),location.href).searchParams.get('start')||'0',10);if(st>cur){out.next=true;break;}}catch(e){}}"
    "for(var i=0;i<anchors.length;i++){var a=anchors[i];"
      "var link=unwrap(a.getAttribute('href'));if(!link||(link.url&&!isReddit(link.url)))continue;"
      "var heading=a.querySelector(HSEL);var title=T(heading);"
      "var block=a;for(var p=a.parentElement;p&&p!==root&&p!==document.body;p=p.parentElement){"
        "if(titleAnchors(p).length>1)break;block=p;}"
      "var best=null,bestLen=0,els=block.querySelectorAll('div,span');"
      "for(var j=0;j<els.length;j++){var el=els[j];if(a.contains(el)||el.contains(a))continue;"
        "var t=T(el);if(t.length<25)continue;var dominated=false;"
        "for(var c=el.firstElementChild;c;c=c.nextElementSibling){if(T(c).length>=t.length*0.9){dominated=true;break;}}"
        "if(dominated)continue;if(t.length>bestLen){best=el;bestLen=t.length;}}"
      "var snippet=best?marked(best):'';"
      "var lines=[];var leafs=block.querySelectorAll('div,span');"
      "for(var k=0;k<leafs.length;k++){var lf=leafs[k];if(a.contains(lf)||(best&&(best.contains(lf)||lf.contains(best)))||lf.contains(a))continue;"
        "if(lf.querySelector('div,span'))continue;var lt=T(lf);if(!lt||lt.length>80)continue;if(lines.indexOf(lt)<0)lines.push(lt);}"
      "var inAnchor=[];var al=a.querySelectorAll('div,span,cite');"
      "for(var m=0;m<al.length;m++){var x=al[m];if(x.querySelector('div,span,cite'))continue;var xt=T(x);if(xt&&xt!==title&&inAnchor.indexOf(xt)<0)inAnchor.push(xt);}"
      "out.results.push({url:link.url||null,go:link.go||null,title:title,snippet:snippet,lines:lines,anchorLines:inAnchor});}"
    "}catch(e){out.error=String(e&&e.message||e);}"
    "return JSON.stringify(out);})()";

#pragma mark - Link resolution

// Google's phone layout hides every result's destination behind an opaque
// google.com/goto?url=<token> link (the token is encrypted, the destination
// appears nowhere else in the page). The link itself is a plain 302 to the
// destination, so one redirect-stopping GET per result recovers the URL
// without loading the Reddit page.
@interface ApolloGoogleRedirectStopper : NSObject <NSURLSessionTaskDelegate>
@end

@implementation ApolloGoogleRedirectStopper
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);   // stop here; the Location header is the answer
}
@end

static NSString *ApolloGoogleSearchUserAgent(BOOL desktop) {
    NSArray<NSString *> *parts = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
    NSString *major = parts.count > 0 ? parts[0] : @"18";
    NSString *minor = parts.count > 1 ? parts[1] : @"0";
    if (desktop) {
        return [NSString stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                "(KHTML, like Gecko) Version/%@.%@ Safari/605.1.15", major, minor];
    }
    return [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@_%@ like Mac OS X) AppleWebKit/605.1.15 "
            "(KHTML, like Gecko) Version/%@.%@ Mobile/15E148 Safari/604.1", major, minor, major, minor];
}

static WKWebsiteDataStore *ApolloGoogleSearchDataStore(void);

#if APOLLO_SIM_BUILD
// "gsearchdebug followdelay=<seconds>": hold each followed link's answer back,
// so a second action on a result can arrive while its first follow is in flight.
static NSTimeInterval sApolloGoogleSearchDebugFollowDelay;
#endif

// Follows one Google /goto link to its destination: a single redirect-stopping
// GET (the Location header is the answer; the Reddit page itself is never
// loaded). It carries the search session's own Google cookies and user agent,
// so to Google it is the same browser clicking the result it just showed.
static void ApolloGoogleResolveLink(NSURL *link, BOOL desktop, void (^completion)(NSURL *target)) {
    [ApolloGoogleSearchDataStore().httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 8.0;
        configuration.HTTPAdditionalHeaders = @{@"User-Agent": ApolloGoogleSearchUserAgent(desktop)};
        // The ephemeral jar picks the cookies that apply to this URL (domain,
        // path, secure) the same way the web view would.
        [configuration.HTTPCookieStorage setCookies:cookies forURL:link mainDocumentURL:link];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                              delegate:[[ApolloGoogleRedirectStopper alloc] init]
                                                         delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithURL:link
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            NSString *location = nil;
            for (NSString *key in http.allHeaderFields) {
                if ([key caseInsensitiveCompare:@"Location"] == NSOrderedSame) location = http.allHeaderFields[key];
            }
            NSURL *target = location.length ? [NSURL URLWithString:location relativeToURL:link].absoluteURL : nil;
            if (!target) ApolloLog(@"[GoogleSearch] result link didn't redirect (status %ld, %@)",
                                   (long)http.statusCode, error.localizedDescription ?: @"no error");
#if APOLLO_SIM_BUILD
            if (sApolloGoogleSearchDebugFollowDelay > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sApolloGoogleSearchDebugFollowDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ completion(target); });
                return;
            }
#endif
            dispatch_async(dispatch_get_main_queue(), ^{ completion(target); });
        }];
        [task resume];
        [session finishTasksAndInvalidate];
    }];
}

// Which Google layout to ask for. iPhone: the phone layout, with the same
// iPhone Safari identity the device really has (a consistent fingerprint is
// what keeps Google's bot checks quiet). iPad: the desktop layout, which is
// what iPad Safari gets by default ("Request Desktop Website" is on out of
// the box there). The extractor reads both. The sim bridge can force either
// ("ua=d" / "ua=m") to test the other layout.
static NSInteger sApolloGoogleSearchLayoutOverride = -1;   // -1 auto, 0 phone, 1 desktop
static BOOL ApolloGoogleSearchUsesDesktopLayout(void) {
    if (sApolloGoogleSearchLayoutOverride >= 0) return sApolloGoogleSearchLayoutOverride == 1;
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

#pragma mark - Cookie jar

// Google's cookies are how it recognizes this browser again: the consent
// choice, the exemption cookie a solved check leaves behind, and the Google
// account a user signed into on one of its check pages. A jar that starts
// empty looks like a fresh private-browsing session every time, which is what
// Google's checks (captcha, or its newer "sign in to verify you're a human"
// page) react to, and whatever the user answered is gone again (#1302).
//
// iOS 17+: a dedicated persistent store. Before iOS 17 the only persistent
// store is the default one, which holds Apollo's own web sessions (the
// API-key-free Reddit login), so there the jar is a non-persistent store whose
// lasting cookies are kept in a file of their own: put back before a search
// loads a page into an empty jar, and written again when they change. The file
// is not in the settings plist, so Backup Settings never exports it.
// Session-only cookies end with the app, as they do in the iOS 17 store.

// Main thread only.
static BOOL sApolloGoogleJarMirrored;        // the pre-iOS 17 jar, backed by the file
static BOOL sApolloGoogleJarRestoring;       // a restore is in flight: nothing is saved until it lands
static BOOL sApolloGoogleJarRestoreLate;     // ...and it overran its wait: searches stop waiting for it
static NSUInteger sApolloGoogleJarRestoreAttempt;
static NSMutableArray<dispatch_block_t> *sApolloGoogleJarWaiters;   // searches waiting to load
static BOOL sApolloGoogleJarSaveScheduled;
static NSData *sApolloGoogleJarLastSaved;    // what the file holds, to skip identical writes
static BOOL sApolloGoogleJarFileUnreadable;  // the file is there but couldn't be read: leave it alone this launch

static const NSTimeInterval kApolloGoogleJarRestoreTimeout = 3.0;
static const NSTimeInterval kApolloGoogleJarSaveDelay = 1.0;

#if APOLLO_SIM_BUILD
// "gsearchdebug legacyjar=1": use the pre-iOS 17 jar on a newer simulator.
// Read when the jar is made (the first search of a launch).
static NSString *const kApolloGoogleSearchDebugLegacyJarKey = @"ApolloGoogleSearchDebugLegacyJar";
#endif

static NSString *ApolloGoogleJarFilePath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]
                stringByAppendingPathComponent:@"ApolloGoogleSearchCookies.plist"];
}

static dispatch_queue_t ApolloGoogleJarFileQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apolloreborn.google-search-cookies",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

// The cookies that outlive the app, as a binary plist of their properties
// (name, value, domain, path, expiry, Secure, HttpOnly, SameSite: plain
// strings, numbers and dates). nil when there are none.
static NSData *ApolloGoogleJarArchive(NSArray<NSHTTPCookie *> *cookies, NSUInteger *count) {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        if (cookie.isSessionOnly || cookie.expiresDate.timeIntervalSinceNow <= 0) continue;
        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        [cookie.properties enumerateKeysAndObjectsUsingBlock:^(NSHTTPCookiePropertyKey key, id value, BOOL *stop) {
            if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ||
                [value isKindOfClass:[NSDate class]]) properties[key] = value;
        }];
        [list addObject:properties];
    }
    if (count) *count = list.count;
    if (list.count == 0) return nil;
    return [NSPropertyListSerialization dataWithPropertyList:list format:NSPropertyListBinaryFormat_v1_0
                                                     options:0 error:nil];
}

static NSArray<NSHTTPCookie *> *ApolloGoogleJarUnarchive(NSData *data) {
    id list = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (![list isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (id properties in (NSArray *)list) {
        NSHTTPCookie *cookie = [properties isKindOfClass:[NSDictionary class]]
            ? [NSHTTPCookie cookieWithProperties:properties] : nil;
        if (cookie && !cookie.isSessionOnly && cookie.expiresDate.timeIntervalSinceNow > 0) [cookies addObject:cookie];
    }
    return cookies;
}

static void ApolloGoogleJarSave(void) {
    if (!sApolloGoogleJarMirrored || sApolloGoogleJarRestoring || sApolloGoogleJarFileUnreadable) return;
    [ApolloGoogleSearchDataStore().httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSUInteger count = 0;
        NSData *data = ApolloGoogleJarArchive(cookies, &count);
        // Never write an empty jar over the file: Google always leaves cookies
        // behind, so an empty jar means the jar itself was lost (WebKit's
        // networking process was relaunched), and the next search restores it.
        if (!data || [data isEqualToData:sApolloGoogleJarLastSaved]) return;
        sApolloGoogleJarLastSaved = data;
        dispatch_async(ApolloGoogleJarFileQueue(), ^{
            NSError *error = nil;
            BOOL saved = [data writeToFile:ApolloGoogleJarFilePath()
                                   options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                                     error:&error];
            if (saved) {
                ApolloLog(@"[GoogleSearch] saved %lu Google cookie(s) for the next launch", (unsigned long)count);
                return;
            }
            ApolloLog(@"[GoogleSearch] couldn't save Google's cookies: %@", error.localizedDescription ?: @"unknown error");
            dispatch_async(dispatch_get_main_queue(), ^{
                // Not on disk after all: let the next save try again.
                if (sApolloGoogleJarLastSaved == data) sApolloGoogleJarLastSaved = nil;
            });
        });
    }];
}

static void ApolloGoogleJarSaveSoon(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloGoogleJarSaveSoon(); });
        return;
    }
    if (!sApolloGoogleJarMirrored || sApolloGoogleJarSaveScheduled) return;
    sApolloGoogleJarSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloGoogleJarSaveDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sApolloGoogleJarSaveScheduled = NO;
        ApolloGoogleJarSave();
    });
}

@interface ApolloGoogleJarObserver : NSObject <WKHTTPCookieStoreObserver>
@end

@implementation ApolloGoogleJarObserver
- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore {
    ApolloGoogleJarSaveSoon();
}
@end

static WKWebsiteDataStore *ApolloGoogleSearchDataStore(void) {
    static WKWebsiteDataStore *store;
    static ApolloGoogleJarObserver *observer;   // the cookie store holds its observers weakly
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL legacyJar = NO;
#if APOLLO_SIM_BUILD
        legacyJar = [NSUserDefaults.standardUserDefaults boolForKey:kApolloGoogleSearchDebugLegacyJarKey];
        if (legacyJar) ApolloLog(@"[GoogleSearch][debug] using the pre-iOS 17 cookie jar");
#endif
        if (@available(iOS 17.0, *)) {
            // Separate from the Reddit scrape jar and from Apollo's own web views.
            NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:@"6B0E4C1D-2F8A-4C39-9A57-3D1E8F6B2A94"];
            if (identifier && !legacyJar) store = [WKWebsiteDataStore dataStoreForIdentifier:identifier];
        }
        if (!store) {
            store = [WKWebsiteDataStore nonPersistentDataStore];
            sApolloGoogleJarMirrored = YES;
            observer = [[ApolloGoogleJarObserver alloc] init];
            [store.httpCookieStore addObserver:observer];
        }
    });
    return store;
}

static void ApolloGoogleJarReleaseWaiters(void) {
    NSArray<dispatch_block_t> *waiters = [sApolloGoogleJarWaiters copy];
    [sApolloGoogleJarWaiters removeAllObjects];
    for (dispatch_block_t waiter in waiters) waiter();
}

// Runs `ready` (main queue) once the jar can take a page load: right away on
// iOS 17+ and whenever the jar already holds cookies; otherwise once the saved
// ones are back in. The jar is empty at the first search of a launch, and
// again if WebKit's networking process was relaunched since. A restore that
// overruns kApolloGoogleJarRestoreTimeout stops holding up searches, but
// saving stays off until it lands, so a half-restored jar never replaces the
// file. Main thread.
static void ApolloGoogleSearchPrepareJar(dispatch_block_t ready) {
    WKHTTPCookieStore *jar = ApolloGoogleSearchDataStore().httpCookieStore;
    if (!sApolloGoogleJarMirrored) {
        ready();
        return;
    }
    if (sApolloGoogleJarRestoring && sApolloGoogleJarRestoreLate) {
        ready();
        return;
    }
    if (!sApolloGoogleJarWaiters) sApolloGoogleJarWaiters = [NSMutableArray array];
    [sApolloGoogleJarWaiters addObject:[ready copy]];
    if (sApolloGoogleJarRestoring) return;
    sApolloGoogleJarRestoring = YES;
    sApolloGoogleJarRestoreLate = NO;
    NSUInteger attempt = ++sApolloGoogleJarRestoreAttempt;

    void (^landed)(NSString *) = ^(NSString *outcome) {
        if (attempt != sApolloGoogleJarRestoreAttempt || !sApolloGoogleJarRestoring) return;
        BOOL late = sApolloGoogleJarRestoreLate;
        sApolloGoogleJarRestoring = NO;
        sApolloGoogleJarRestoreLate = NO;
        if (outcome) ApolloLog(@"[GoogleSearch] %@", outcome);
        ApolloGoogleJarReleaseWaiters();
        // Searches ran meanwhile and their saves were held back: catch up.
        if (late) ApolloGoogleJarSaveSoon();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloGoogleJarRestoreTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (attempt != sApolloGoogleJarRestoreAttempt || !sApolloGoogleJarRestoring) return;
        sApolloGoogleJarRestoreLate = YES;
        ApolloLog(@"[GoogleSearch] restoring Google's cookies is slow; searching without waiting");
        ApolloGoogleJarReleaseWaiters();
    });

    [jar getAllCookies:^(NSArray<NSHTTPCookie *> *live) {
        if (live.count) {
            // This launch's jar is already in use.
            landed(nil);
            return;
        }
        dispatch_async(ApolloGoogleJarFileQueue(), ^{
            NSError *readError = nil;
            NSData *data = [NSData dataWithContentsOfFile:ApolloGoogleJarFilePath() options:0 error:&readError];
            BOOL missing = [readError.domain isEqualToString:NSCocoaErrorDomain] && readError.code == NSFileReadNoSuchFileError;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!data && !missing) {
                    // Not the same as no file: a save now would replace cookies
                    // that are still on disk with this launch's empty start.
                    sApolloGoogleJarFileUnreadable = YES;
                    landed([NSString stringWithFormat:@"couldn't read the saved Google cookies (%@); not saving over them this launch",
                            readError.localizedDescription ?: @"unknown error"]);
                    return;
                }
                NSArray<NSHTTPCookie *> *saved = ApolloGoogleJarUnarchive(data);
                if (saved.count == 0) {
                    landed(data ? @"no usable saved Google cookies" : nil);
                    return;
                }
                sApolloGoogleJarLastSaved = data;
                dispatch_group_t group = dispatch_group_create();
                for (NSHTTPCookie *cookie in saved) {
                    dispatch_group_enter(group);
                    [jar setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
                }
                dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                    landed([NSString stringWithFormat:@"restored %lu saved Google cookie(s)", (unsigned long)saved.count]);
                });
            });
        });
    }];
}

#pragma mark - Session

@interface ApolloGoogleSearchSession () <WKNavigationDelegate>
@end

#if APOLLO_SIM_BUILD
static WKWebView *sApolloGoogleSearchDebugWeb;
// Sim bridge test knobs ("gsearchdebug ..."): open Google's consent or
// "unusual traffic" page first (continuing to the real search) to exercise the
// verification sheet; skip the Reddit read to see the Google-only card; or
// fail the next search outright to see the error state.
static NSString *sApolloGoogleSearchDebugVerifyPage;   // nil, "consent" or "sorry"
static BOOL sApolloGoogleSearchDebugSkipRedditInfo;
static BOOL sApolloGoogleSearchDebugFailNext;
// A saved results page to load instead of the network ("fixture=<path>"), to
// exercise the list and the on-demand link following while Google is showing
// this machine its check.
static NSString *sApolloGoogleSearchDebugFixturePath;
// The page currently loading (e.g. sitting on a verification page), for "gsearchjs".
static __weak WKWebView *sApolloGoogleSearchDebugLiveWeb;
// "stall=1": polls never get an answer, like a WebKit process that stopped
// responding, to exercise the deadline watchdog.
static BOOL sApolloGoogleSearchDebugStall;
#endif

@implementation ApolloGoogleSearchSession {
    WKWebView *_web;
    NSUInteger _generation;
    ApolloGoogleSearchCompletion _completion;
    ApolloGoogleSearchOptions *_options;
    NSUInteger _page;
    BOOL _verifying;
    BOOL _loading;
    CFTimeInterval _deadline;
    NSInteger _emptyPolls;
    NSInteger _polls;
    NSURLSessionDataTask *_infoTask;
    BOOL _desktop;
    NSInteger _lastRawCount;
    NSInteger _stablePolls;
    // Link follows in flight, keyed by result, with everyone waiting on each:
    // a second action on a result whose link is still being followed (Open
    // while Read More loads) waits for that follow instead of clicking
    // Google's link a second time.
    NSMapTable<ApolloGoogleSearchResult *, NSMutableArray *> *_pendingFollows;
}

- (void)dealloc {
    // Create attached the view to the key window; don't leave it behind.
    ApolloScrapeWebViewDestroy(_web);
    [_infoTask cancel];
}

- (BOOL)isLoading {
    return _loading;
}

- (void)searchQuery:(NSString *)query
            options:(ApolloGoogleSearchOptions *)options
               page:(NSUInteger)page
         completion:(ApolloGoogleSearchCompletion)completion {
    [self tearDownSilently];

    NSURL *url = ApolloGoogleSearchURL(query, options, page);
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(@[], NO, nil);
        });
        return;
    }

#if APOLLO_SIM_BUILD
    if (sApolloGoogleSearchDebugFailNext) {
        sApolloGoogleSearchDebugFailNext = NO;
        NSError *error = ApolloGoogleSearchError(ApolloGoogleSearchErrorNetwork, @"The Internet connection appears to be offline.");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (completion) completion(@[], NO, error);
        });
        return;
    }
#endif
    NSUInteger generation = ++_generation;
    _completion = [completion copy];
    _options = [options copy] ?: [[ApolloGoogleSearchOptions alloc] init];
    _page = page;
    _loading = YES;
    _emptyPolls = 0;
    _polls = 0;
    _lastRawCount = -1;
    _stablePolls = 0;
    _deadline = CACurrentMediaTime() + kApolloGoogleSearchPageTimeout;
    ApolloLog(@"[GoogleSearch] search page %lu: %@", (unsigned long)page, url.absoluteString);
    [self armDeadlineWatchdog:generation];

    BOOL desktop = ApolloGoogleSearchUsesDesktopLayout();
    _desktop = desktop;
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = ApolloGoogleSearchDataStore();
    // No page media ever needs to play here; keep WebKit from even trying.
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    if (desktop) config.defaultWebpagePreferences.preferredContentMode = WKContentModeDesktop;

    __weak typeof(self) weakSelf = self;
    ApolloScrapeWebViewCreate(config, ^(WKWebView *web) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_generation != generation || !strongSelf->_loading) {
            ApolloScrapeWebViewDestroy(web);
            return;
        }
        strongSelf->_web = web;
        web.navigationDelegate = strongSelf;
#if APOLLO_SIM_BUILD
        sApolloGoogleSearchDebugLiveWeb = web;
#endif
        web.customUserAgent = ApolloGoogleSearchUserAgent(desktop);
        if (desktop) web.frame = CGRectMake(0, 0, 1280, 1000);
        NSURL *loadURL = url;
#if APOLLO_SIM_BUILD
        if (sApolloGoogleSearchDebugVerifyPage.length) {
            NSString *base = [sApolloGoogleSearchDebugVerifyPage isEqualToString:@"sorry"]
                ? @"https://www.google.com/sorry/index" : @"https://consent.google.com/ml";
            NSURLComponents *debug = [NSURLComponents componentsWithString:base];
            debug.queryItems = @[[NSURLQueryItem queryItemWithName:@"continue" value:url.absoluteString],
                                 [NSURLQueryItem queryItemWithName:@"hl" value:@"en"]];
            loadURL = debug.URL ?: url;
            ApolloLog(@"[GoogleSearch][debug] opening %@ first", loadURL.host);
        }
        NSString *fixture = sApolloGoogleSearchDebugFixturePath.length
            ? [NSString stringWithContentsOfFile:sApolloGoogleSearchDebugFixturePath encoding:NSUTF8StringEncoding error:nil] : nil;
        if (fixture.length) {
            ApolloLog(@"[GoogleSearch][debug] loading fixture page (%lu chars)", (unsigned long)fixture.length);
            [web loadHTMLString:fixture baseURL:url];
            [strongSelf schedulePoll:generation after:0.6];
            return;
        }
#endif
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:loadURL];
        request.timeoutInterval = kApolloGoogleSearchPageTimeout;
        // Below iOS 17 the jar starts each launch empty: the saved Google
        // cookies go back in before the first page load.
        ApolloGoogleSearchPrepareJar(^{
            typeof(self) readySelf = weakSelf;
            if (!readySelf || readySelf->_generation != generation || !readySelf->_loading || readySelf->_web != web) return;
            [web loadRequest:request];
            [readySelf schedulePoll:generation after:0.6];
        });
    });
}

- (void)cancel {
    [self tearDownSilently];
}

- (void)verificationCancelledByUser {
    if (!_loading) return;
    ApolloLog(@"[GoogleSearch] verification cancelled by the user");
    [self finishWithResults:nil mayHaveMore:NO
                      error:ApolloGoogleSearchError(ApolloGoogleSearchErrorVerificationCancelled,
                                                    @"Google's check wasn't completed.")];
}

- (void)tearDownSilently {
    _generation++;
    _completion = nil;
    _loading = NO;
    [_infoTask cancel];
    _infoTask = nil;
    if (_verifying) {
        _verifying = NO;
        if (self.dismissVerification) self.dismissVerification();
    }
    if (_web) {
        ApolloScrapeWebViewDestroy(_web);
        _web = nil;
    }
}

// The deadline runs on its own timer rather than inside the polls: a page
// whose WebKit process stops answering never completes a poll, and the search
// must still end with Try Again instead of spinning forever.
- (void)armDeadlineWatchdog:(NSUInteger)generation {
    NSTimeInterval wait = MAX(0.0, _deadline - CACurrentMediaTime()) + 0.05;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf deadlineWatchdogFired:generation];
    });
}

- (void)deadlineWatchdogFired:(NSUInteger)generation {
    if (generation != _generation || !_loading) return;
    if (CACurrentMediaTime() < _deadline) {
        // Moved out since: a verification page is up, or the results are in
        // and the Reddit read is running.
        [self armDeadlineWatchdog:generation];
        return;
    }
    ApolloLog(@"[GoogleSearch] timed out after %ld polls (verifying=%d) at %@",
              (long)_polls, _verifying, _web.URL.absoluteString);
    [self finishWithResults:nil mayHaveMore:NO
                      error:ApolloGoogleSearchError(ApolloGoogleSearchErrorTimedOut,
                                                    @"Google took too long to respond.")];
}

- (void)schedulePoll:(NSUInteger)generation after:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pollGeneration:generation];
    });
}

- (void)pollGeneration:(NSUInteger)generation {
    if (generation != _generation || !_loading || !_web) return;
    _polls++;
#if APOLLO_SIM_BUILD
    if (sApolloGoogleSearchDebugStall) {
        ApolloLog(@"[GoogleSearch][debug] stall: poll %ld gets no answer", (long)_polls);
        return;
    }
#endif

    __weak typeof(self) weakSelf = self;
    [_web evaluateJavaScript:kApolloGoogleExtractorJS completionHandler:^(id value, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_generation || !strongSelf->_loading) return;
        NSDictionary *page = nil;
        if ([value isKindOfClass:[NSString class]]) {
            id json = [NSJSONSerialization JSONObjectWithData:[(NSString *)value dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) page = json;
        }
        [strongSelf handleExtraction:page generation:generation];
    }];
}

- (void)handleExtraction:(NSDictionary *)page generation:(NSUInteger)generation {
    NSString *challenge = [page[@"challenge"] isKindOfClass:[NSString class]] ? page[@"challenge"] : nil;
    NSArray *rawResults = [page[@"results"] isKindOfClass:[NSArray class]] ? page[@"results"] : @[];
    BOOL container = [page[@"container"] boolValue];
    BOOL complete = [page[@"ready"] isEqual:@"complete"];

    if (page[@"error"]) ApolloLogError(@"[GoogleSearch] extractor error: %@", page[@"error"]);

    if (challenge && rawResults.count == 0) {
        if (!_verifying) {
            _verifying = YES;
            ApolloLog(@"[GoogleSearch] Google asked for %@ at %@ — handing the page to the user",
                      challenge, _web.URL.host);
            if (self.presentVerification) {
                self.presentVerification(_web);
            } else {
                [self finishWithResults:nil mayHaveMore:NO
                                  error:ApolloGoogleSearchError(ApolloGoogleSearchErrorVerificationCancelled,
                                                                @"Google wants to verify this search.")];
                return;
            }
        }
        _deadline = CACurrentMediaTime() + kApolloGoogleSearchVerificationTimeout;
        [self schedulePoll:generation after:0.8];
        return;
    }

    if (rawResults.count == 0 && container && complete &&
        ++_emptyPolls < kApolloGoogleSearchEmptyPollsToSettle) {
        [self schedulePoll:generation after:kApolloGoogleSearchPollInterval];
        return;
    }
    // A settled results page with plenty of links but not one recognizable
    // result is Google's markup having moved, not an empty search: say so
    // instead of showing "no results" (and log it, it needs an extractor fix).
    if (rawResults.count == 0 && container && complete &&
        [page[@"anchorCount"] integerValue] == 0 && [page[@"containerLinks"] integerValue] >= 5) {
        ApolloLog(@"[GoogleSearch] results page has %@ links but no readable results — extractor needs updating",
                  page[@"containerLinks"]);
        [self finishWithResults:nil mayHaveMore:NO
                          error:ApolloGoogleSearchError(ApolloGoogleSearchErrorUnreadable,
                                                        @"Google's results page couldn't be read.")];
        return;
    }
    // Google streams the page: the first results are in the DOM long before
    // the rest. Take the page once it has finished loading, or once its result
    // count has held steady for a while (a slow ad/asset can keep readyState
    // at "interactive" well after the results are all there).
    if (rawResults.count > 0 && !complete) {
        if ((NSInteger)rawResults.count == _lastRawCount) _stablePolls++;
        else _stablePolls = 0;
        _lastRawCount = (NSInteger)rawResults.count;
        if (_stablePolls < kApolloGoogleSearchStablePollsToAccept) {
            [self schedulePoll:generation after:kApolloGoogleSearchPollInterval];
            return;
        }
    }
    if (rawResults.count > 0 || (container && complete)) {
        if (_verifying) {
            _verifying = NO;
            ApolloLog(@"[GoogleSearch] verification done, results are back");
            if (self.dismissVerification) self.dismissVerification();
        }
        _deadline = CACurrentMediaTime() + kApolloGoogleSearchPageTimeout;
        BOOL more = [page[@"next"] boolValue] || rawResults.count >= 7;
#if APOLLO_SIM_BUILD
        [self debugDumpPage:page];
#endif
        // Stop polling: the page has what we need. Release WebKit right away
        // instead of holding a live results page.
        [self releasePage];
        NSArray<ApolloGoogleSearchResult *> *results = [self resultsFromRaw:rawResults];
        ApolloLog(@"[GoogleSearch] page %lu: %lu raw result(s) → %lu Reddit result(s), next=%d, polls=%ld, desktop=%d",
                  (unsigned long)_page, (unsigned long)rawResults.count, (unsigned long)results.count,
                  [page[@"next"] boolValue], (long)_polls, _desktop);
        [self enrichThenFinish:results mayHaveMore:more generation:generation];
        return;
    }

    [self schedulePoll:generation after:kApolloGoogleSearchPollInterval];
}

- (NSArray<ApolloGoogleSearchResult *> *)resultsFromRaw:(NSArray *)rawResults {
    NSMutableArray<ApolloGoogleSearchResult *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *raw in rawResults) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSString *urlString = [raw[@"url"] isKindOfClass:[NSString class]] ? raw[@"url"] : nil;
        NSString *goString = [raw[@"go"] isKindOfClass:[NSString class]] ? raw[@"go"] : nil;
        NSString *title = [raw[@"title"] isKindOfClass:[NSString class]] ? raw[@"title"] : @"";
        NSMutableArray *lines = [NSMutableArray array];
        if ([raw[@"anchorLines"] isKindOfClass:[NSArray class]]) [lines addObjectsFromArray:raw[@"anchorLines"]];
        if ([raw[@"lines"] isKindOfClass:[NSArray class]]) [lines addObjectsFromArray:raw[@"lines"]];

        ApolloGoogleSearchResult *result = nil;
        if (urlString.length) {
            // A direct link (older layouts): classify it now.
            result = ApolloGoogleSearchResultForURL([NSURL URLWithString:urlString]);
            if (!result) continue;
        } else if (goString.length) {
            // The usual case: an opaque Google link, followed only when the user
            // acts on the result. The subreddit comes from Google's breadcrumb
            // ("Reddit · r/PTCGP") or the title's " : r/PTCGP" suffix.
            result = [[ApolloGoogleSearchResult alloc] init];
            result.kind = ApolloGoogleResultKindPost;
            result.googleLinkURL = [NSURL URLWithString:goString];
            result.subreddit = ApolloGoogleSubredditFromLines(lines, title);
            if (!result.googleLinkURL) continue;
        } else {
            continue;
        }

        result.title = ApolloGoogleSearchCleanTitle(title);
        NSString *key = result.dedupeKey;
        if (key.length && [seen containsObject:key]) continue;
        if (key.length) [seen addObject:key];
        NSArray<NSValue *> *bold = nil;
        NSString *marked = [raw[@"snippet"] isKindOfClass:[NSString class]] ? raw[@"snippet"] : @"";
        result.snippet = ApolloGoogleParseMarkedSnippet(marked, &bold);
        result.snippetBoldRanges = bold ?: @[];
        result.engineMeta = [self metaFromLines:lines result:result];
        [results addObject:result];
    }
    return results;
}

// Google's forum line: a short line with a separator and a digit
// ("30+ comments · 2 weeks ago", "5 answers · 1 year ago"), or at least a
// relative date. Language-neutral on purpose — digits and "·" survive
// localization, the words don't.
- (NSString *)metaFromLines:(NSArray *)lines result:(ApolloGoogleSearchResult *)result {
    NSString *fallback = nil;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSString *line in lines) {
        if (![line isKindOfClass:[NSString class]] || line.length < 3) continue;
        NSString *lower = line.lowercaseString;
        if ([lower hasPrefix:@"reddit"] || [lower hasPrefix:@"r/"] || [lower hasPrefix:@"http"] ||
            [lower containsString:@"reddit.com"] || [line isEqualToString:result.title]) continue;
        BOOL hasDigit = [line rangeOfCharacterFromSet:digits].location != NSNotFound;
        if (!hasDigit) continue;
        if ([line containsString:@"·"] || [line containsString:@"•"]) return line;
        if (!fallback) fallback = line;
    }
    return fallback;
}

// Done with the page: release WebKit's memory right away.
- (void)releasePage {
    if (!_web) return;
#if APOLLO_SIM_BUILD
    if (sApolloGoogleSearchDebugWeb != _web) ApolloScrapeWebViewDestroy(sApolloGoogleSearchDebugWeb);
    sApolloGoogleSearchDebugWeb = _web;   // kept for "gsearchjs"
    _web.navigationDelegate = nil;
#else
    ApolloScrapeWebViewDestroy(_web);
#endif
    _web = nil;
}

#pragma mark Reddit enrichment

static NSString *ApolloGoogleString(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] ? value : nil;
}

// Reddit-hosted media (i.redd.it, v.redd.it, galleries, "reddit.com"
// crossposts) is labeled by kind; only a real external site shows its domain.
static ApolloGoogleResultMedia ApolloGoogleMediaForPost(NSDictionary *post) {
    if ([post[@"is_self"] boolValue]) return ApolloGoogleResultMediaNone;
    if ([post[@"is_gallery"] boolValue]) return ApolloGoogleResultMediaGallery;
    NSString *domain = ApolloGoogleString(post[@"domain"]).lowercaseString ?: @"";
    NSString *hint = ApolloGoogleString(post[@"post_hint"]) ?: @"";
    if ([post[@"is_video"] boolValue] || [domain isEqualToString:@"v.redd.it"] ||
        [hint isEqualToString:@"hosted:video"] || [hint isEqualToString:@"rich:video"]) return ApolloGoogleResultMediaVideo;
    if ([domain isEqualToString:@"i.redd.it"] || [hint isEqualToString:@"image"]) return ApolloGoogleResultMediaImage;
    if (domain.length == 0 || [domain hasPrefix:@"self."] || [domain isEqualToString:@"reddit.com"] ||
        [domain hasSuffix:@".reddit.com"] || [domain hasSuffix:@"redd.it"]) return ApolloGoogleResultMediaNone;
    return ApolloGoogleResultMediaLink;
}

// Copies an /api/info.json listing onto the results it covers. Main thread.
static NSUInteger ApolloGoogleApplyRedditInfo(id json, NSArray<ApolloGoogleSearchResult *> *results) {
    NSDictionary *data = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
    NSArray *children = [data isKindOfClass:[NSDictionary class]] ? data[@"children"] : nil;
    if (![children isKindOfClass:[NSArray class]]) return 0;

    NSMutableDictionary<NSString *, NSDictionary *> *posts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *comments = [NSMutableDictionary dictionary];
    for (NSDictionary *child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *thing = child[@"data"];
        NSString *identifier = ApolloGoogleString(thing[@"id"]).lowercaseString;
        if (![thing isKindOfClass:[NSDictionary class]] || !identifier) continue;
        if ([child[@"kind"] isEqual:@"t3"]) posts[identifier] = thing;
        else if ([child[@"kind"] isEqual:@"t1"]) comments[identifier] = thing;
    }

    NSUInteger applied = 0;
    for (ApolloGoogleSearchResult *result in results) {
        NSDictionary *post = result.postID ? posts[result.postID] : nil;
        NSDictionary *comment = result.commentID ? comments[result.commentID] : nil;
        if (!post && !comment) continue;
        applied++;
        result.hasRedditInfo = YES;
        if (post) {
            result.redditTitle = ApolloGoogleString(post[@"title"]);
            result.commentCount = [post[@"num_comments"] integerValue];
            if (!result.subreddit) result.subreddit = ApolloGoogleString(post[@"subreddit"]);
            result.over18 = [post[@"over_18"] boolValue];
            result.spoiler = [post[@"spoiler"] boolValue];
            result.media = ApolloGoogleMediaForPost(post);
            if (result.media == ApolloGoogleResultMediaLink) {
                NSString *domain = ApolloGoogleString(post[@"domain"]).lowercaseString;
                if ([domain hasPrefix:@"www."]) domain = [domain substringFromIndex:4];
                result.linkDomain = domain;
            }
        }
        NSDictionary *primary = comment ?: post;
        result.author = ApolloGoogleString(primary[@"author"]);
        result.score = [primary[@"score"] integerValue];
        double created = [primary[@"created_utc"] doubleValue];
        if (created > 0) result.created = [NSDate dateWithTimeIntervalSince1970:created];
        NSString *body = comment ? ApolloGoogleString(comment[@"body"]) : ApolloGoogleString(post[@"selftext"]);
        if ([body isEqualToString:@"[removed]"] || [body isEqualToString:@"[deleted]"]) {
            body = nil;
        }
        result.bodyText = body;
    }
    return applied;
}

// One batched /api/info.json read (posts and comments together) on the
// account's usual path for tweak-authored reads: oauth.reddit.com with the
// captured bearer in API-key mode; www.reddit.com in API-key-free mode, where
// the request chokepoint signs it with the web session. Completion on main;
// nil task (and an async completion) when there is nothing to read.
NSURLSessionDataTask *ApolloGoogleSearchFetchRedditInfo(NSArray<ApolloGoogleSearchResult *> *results,
                                                        void (^completion)(NSUInteger applied, NSInteger status, NSError *error)) {
    NSMutableOrderedSet<NSString *> *fullnames = [NSMutableOrderedSet orderedSet];
    for (ApolloGoogleSearchResult *result in results) {
        if (result.postID) [fullnames addObject:[@"t3_" stringByAppendingString:result.postID]];
        if (result.commentID) [fullnames addObject:[@"t1_" stringByAppendingString:result.commentID]];
    }
    if (fullnames.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(0, 0, nil); });
        return nil;
    }

    NSString *token = ApolloActiveAccountRedditBearerToken();
    NSString *base = token.length ? @"https://oauth.reddit.com" : @"https://www.reddit.com";
    NSString *ids = [[fullnames.array subarrayWithRange:NSMakeRange(0, MIN(fullnames.count, 100))]
                     componentsJoinedByString:@","];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/info.json?raw_json=1&id=%@", base, ids]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:kApolloGoogleSearchRedditInfoTimeout];
    if (sUserAgent.length) [request setValue:sUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (token.length) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = (data && !error && status >= 200 && status < 300)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger applied = ApolloGoogleApplyRedditInfo(json, results);
            completion(applied, status, error);
        });
    }];
    [task resume];
    return task;
}

// Results whose Reddit URL the page already gave (direct links) are enriched
// before the page is delivered; the rest wait for the user to act on them.
- (void)enrichThenFinish:(NSArray<ApolloGoogleSearchResult *> *)results
             mayHaveMore:(BOOL)more
              generation:(NSUInteger)generation {
    NSMutableArray<ApolloGoogleSearchResult *> *known = [NSMutableArray array];
    for (ApolloGoogleSearchResult *result in results) {
        if (result.postID) [known addObject:result];
    }
#if APOLLO_SIM_BUILD
    if (sApolloGoogleSearchDebugSkipRedditInfo) [known removeAllObjects];
#endif
    if (known.count == 0) {
        [self finishWithResults:results mayHaveMore:more error:nil];
        return;
    }
    __weak typeof(self) weakSelf = self;
    _infoTask = ApolloGoogleSearchFetchRedditInfo(known, ^(NSUInteger applied, NSInteger status, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_generation || !strongSelf->_loading) return;
        strongSelf->_infoTask = nil;
        ApolloLog(@"[GoogleSearch] Reddit info: status=%ld applied=%lu/%lu%@", (long)status,
                  (unsigned long)applied, (unsigned long)known.count,
                  error ? [@" error=" stringByAppendingString:error.localizedDescription] : @"");
        [strongSelf finishWithResults:results mayHaveMore:more error:nil];
    });
}

- (void)resolveResult:(ApolloGoogleSearchResult *)result
       withRedditInfo:(BOOL)withRedditInfo
           completion:(void (^)(NSError *error))completion {
    void (^finish)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    };
    void (^readReddit)(void) = ^{
        BOOL skip = !withRedditInfo || result.hasRedditInfo || !result.postID;
#if APOLLO_SIM_BUILD
        skip = skip || sApolloGoogleSearchDebugSkipRedditInfo;
#endif
        if (skip) {
            finish(nil);
            return;
        }
        ApolloGoogleSearchFetchRedditInfo(@[result], ^(NSUInteger applied, NSInteger status, NSError *error) {
            ApolloLog(@"[GoogleSearch] Reddit info for one result: status=%ld applied=%lu", (long)status, (unsigned long)applied);
            finish(nil);
        });
    };
    if (result.URL) {
        readReddit();
        return;
    }
    if (!result.googleLinkURL) {
        finish(ApolloGoogleSearchError(ApolloGoogleSearchErrorUnreadable, @"This result has no link."));
        return;
    }
    void (^followed)(BOOL) = ^(BOOL ok) {
        if (ok) readReddit();
        else finish(ApolloGoogleSearchError(ApolloGoogleSearchErrorUnreadable, @"Couldn't open this result."));
    };
    NSMutableArray *waiters = [_pendingFollows objectForKey:result];
    if (waiters) {
        [waiters addObject:[followed copy]];
        return;
    }
    if (!_pendingFollows) _pendingFollows = [NSMapTable strongToStrongObjectsMapTable];
    [_pendingFollows setObject:[NSMutableArray arrayWithObject:[followed copy]] forKey:result];
    __weak typeof(self) weakSelf = self;
    ApolloGoogleResolveLink(result.googleLinkURL, ApolloGoogleSearchUsesDesktopLayout(), ^(NSURL *target) {
        BOOL ok = target && ApolloGoogleApplyURL(result, target);
        if (ok) ApolloLog(@"[GoogleSearch] followed a result link (kind %ld)", (long)result.kind);
        else ApolloLog(@"[GoogleSearch] result link led to %@, not a Reddit page Apollo can open", target.host ?: @"nothing");
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;   // the list is gone, and everyone waiting with it
        NSArray *all = [[strongSelf->_pendingFollows objectForKey:result] copy];
        [strongSelf->_pendingFollows removeObjectForKey:result];
        for (void (^waiter)(BOOL) in all) waiter(ok);
    });
}

- (void)finishWithResults:(NSArray<ApolloGoogleSearchResult *> *)results
              mayHaveMore:(BOOL)more
                    error:(NSError *)error {
    ApolloGoogleSearchCompletion completion = _completion;
    [self tearDownSilently];
    // Below iOS 17: keep what this search left in the jar (a sign-in, a
    // solved check) even where WebKit doesn't report cookie changes.
    ApolloGoogleJarSaveSoon();
    if (error) ApolloLogError(@"[GoogleSearch] failed: %@", error.localizedDescription);
    if (completion) completion(results ?: @[], error ? NO : more, error);
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // Only Google's own pages (results, challenge, consent) load here. A tap in
    // the verification sheet that leaves Google (a result, a help link) is
    // dropped instead of turning the sheet into a browser.
    NSString *host = action.request.URL.host.lowercaseString ?: @"";
    NSString *scheme = action.request.URL.scheme.lowercaseString ?: @"";
    BOOL google = [host isEqualToString:@"google.com"] || [host hasSuffix:@".google.com"] ||
                  [host containsString:@".google."] || [host hasPrefix:@"google."] ||
                  [host hasSuffix:@"gstatic.com"] || [host hasSuffix:@"recaptcha.net"];
    BOOL internal = [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"blob"] ||
                    [scheme isEqualToString:@"data"];
    if (!action.targetFrame.isMainFrame || google || internal) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    ApolloLog(@"[GoogleSearch] blocked navigation away from Google to %@", host);
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleNavigationError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleNavigationError:error];
}

- (void)handleNavigationError:(NSError *)error {
    if (!_loading) return;
    // -999: superseded by another navigation (Google's own redirects), and
    // 102: frame load interrupted by a policy change. Neither is a failure.
    if (([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) ||
        ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102)) return;
    if (_verifying) return;   // let the user see and retry the page themselves
    ApolloLogError(@"[GoogleSearch] navigation failed: %@ (%@ %ld)", error.localizedDescription,
              error.domain, (long)error.code);
    [self finishWithResults:nil mayHaveMore:NO
                      error:ApolloGoogleSearchError(ApolloGoogleSearchErrorNetwork,
                                                    error.localizedDescription ?: @"Couldn't reach Google.")];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (!_loading) return;
    ApolloLog(@"[GoogleSearch] web content process terminated");
    [self finishWithResults:nil mayHaveMore:NO
                      error:ApolloGoogleSearchError(ApolloGoogleSearchErrorUnreadable,
                                                    @"The search page stopped unexpectedly.")];
}

#if APOLLO_SIM_BUILD
- (void)debugDumpPage:(NSDictionary *)page {
    NSArray *raw = page[@"results"];
    NSUInteger index = 0;
    for (NSDictionary *item in raw) {
        ApolloLog(@"[GoogleSearch][debug] #%lu url=%@ go=%@ title=%@ lines=%@ anchorLines=%@ snippet=%@",
                  (unsigned long)index, item[@"url"], [item[@"go"] isKindOfClass:[NSString class]] ? [item[@"go"] substringToIndex:MIN((NSUInteger)60, [item[@"go"] length])] : @"-", item[@"title"],
                  [item[@"lines"] componentsJoinedByString:@" | "],
                  [item[@"anchorLines"] componentsJoinedByString:@" | "],
                  [[item[@"snippet"] stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)1] withString:@"<b>"]
                   stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)2] withString:@"</b>"]);
        index++;   // not inside the log arguments: a disabled level skips them
    }
    WKWebView *web = _web;
    [web evaluateJavaScript:@"document.documentElement.outerHTML" completionHandler:^(id html, NSError *error) {
        if (![html isKindOfClass:[NSString class]]) return;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"apollo-gsearch-last.html"];
        [(NSString *)html writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        ApolloLog(@"[GoogleSearch][debug] page HTML (%lu chars) → %@", (unsigned long)[(NSString *)html length], path);
    }];
}
#endif

@end

#if APOLLO_SIM_BUILD
static ApolloGoogleSearchSession *sApolloGoogleSearchDebugSession;

void ApolloGoogleSearchDebugRun(NSString *query) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger page = 0;
    ApolloGoogleSearchOptions *options = [[ApolloGoogleSearchOptions alloc] init];
    // Optional "p=N t=w x=1 |" prefix before a '|' for page / time / exact.
    NSRange bar = [trimmed rangeOfString:@"|"];
    if (bar.location != NSNotFound) {
        for (NSString *token in [[trimmed substringToIndex:bar.location] componentsSeparatedByString:@" "]) {
            if ([token hasPrefix:@"p="]) page = (NSUInteger)[token substringFromIndex:2].integerValue;
            if ([token isEqualToString:@"t=d"]) options.timeRange = ApolloGoogleSearchTimeRangeDay;
            if ([token isEqualToString:@"t=w"]) options.timeRange = ApolloGoogleSearchTimeRangeWeek;
            if ([token isEqualToString:@"t=m"]) options.timeRange = ApolloGoogleSearchTimeRangeMonth;
            if ([token isEqualToString:@"t=y"]) options.timeRange = ApolloGoogleSearchTimeRangeYear;
            if ([token isEqualToString:@"x=1"]) options.exactWords = YES;
            if ([token isEqualToString:@"ua=d"]) sApolloGoogleSearchLayoutOverride = 1;
            if ([token isEqualToString:@"ua=m"]) sApolloGoogleSearchLayoutOverride = 0;
            if ([token isEqualToString:@"ua=a"]) sApolloGoogleSearchLayoutOverride = -1;
        }
        trimmed = [[trimmed substringFromIndex:bar.location + 1]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (!sApolloGoogleSearchDebugSession) sApolloGoogleSearchDebugSession = [[ApolloGoogleSearchSession alloc] init];
    ApolloLog(@"[GoogleSearch][debug] composed query: %@", ApolloGoogleSearchComposeQuery(trimmed));
    [sApolloGoogleSearchDebugSession searchQuery:trimmed options:options page:page
                                      completion:^(NSArray<ApolloGoogleSearchResult *> *results, BOOL more, NSError *error) {
        ApolloLog(@"[GoogleSearch][debug] done: %lu result(s), more=%d, error=%@",
                  (unsigned long)results.count, more, error.localizedDescription ?: @"none");
        for (ApolloGoogleSearchResult *result in results) {
            ApolloLog(@"[GoogleSearch][debug] %@ | %@ | reddit=%d score=%ld comments=%ld created=%@ author=%@ body=%lu chars | snippet=%@",
                      result.URL.absoluteString, result.redditTitle ?: result.title, result.hasRedditInfo,
                      (long)result.score, (long)result.commentCount, result.created, result.author,
                      (unsigned long)result.bodyText.length, result.snippet);
        }
    }];
}

void ApolloGoogleSearchDebugConfigure(NSString *arguments) {
    for (NSString *token in [arguments componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if ([token hasPrefix:@"verify="]) {
            NSString *value = [token substringFromIndex:7];
            sApolloGoogleSearchDebugVerifyPage = [value isEqualToString:@"off"] ? nil : value;
        } else if ([token hasPrefix:@"info="]) {
            sApolloGoogleSearchDebugSkipRedditInfo = [[token substringFromIndex:5] isEqualToString:@"0"];
        } else if ([token isEqualToString:@"fail"]) {
            sApolloGoogleSearchDebugFailNext = YES;
        } else if ([token hasPrefix:@"fixture="]) {
            NSString *path = [token substringFromIndex:8];
            sApolloGoogleSearchDebugFixturePath = [path isEqualToString:@"off"] ? nil : path;
        } else if ([token hasPrefix:@"followdelay="]) {
            sApolloGoogleSearchDebugFollowDelay = MAX(0.0, [token substringFromIndex:12].doubleValue);
        } else if ([token hasPrefix:@"stall="]) {
            sApolloGoogleSearchDebugStall = [[token substringFromIndex:6] isEqualToString:@"1"];
        } else if ([token hasPrefix:@"legacyjar="]) {
            [NSUserDefaults.standardUserDefaults setBool:[[token substringFromIndex:10] isEqualToString:@"1"]
                                                  forKey:kApolloGoogleSearchDebugLegacyJarKey];
        } else if ([token isEqualToString:@"cookies"]) {
            // Lists the jar: names and flags only, never values.
            [ApolloGoogleSearchDataStore().httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
                ApolloLog(@"[GoogleSearch][debug] jar (%@): %lu cookie(s)",
                          sApolloGoogleJarMirrored ? @"pre-iOS 17, file-backed" : @"persistent store", (unsigned long)cookies.count);
                for (NSHTTPCookie *cookie in cookies) {
                    ApolloLog(@"[GoogleSearch][debug]   %@ @ %@ secure=%d httpOnly=%d sameSite=%@ expires=%@",
                              cookie.name, cookie.domain, cookie.isSecure, cookie.isHTTPOnly,
                              cookie.sameSitePolicy ?: @"-", cookie.expiresDate ?: @"session");
                }
            }];
        }
    }
    ApolloLog(@"[GoogleSearch][debug] verify=%@ redditInfo=%d failNext=%d fixture=%@ followDelay=%.1f stall=%d legacyJar=%d (from the jar's first use each launch)",
              sApolloGoogleSearchDebugVerifyPage ?: @"off", !sApolloGoogleSearchDebugSkipRedditInfo,
              sApolloGoogleSearchDebugFailNext, sApolloGoogleSearchDebugFixturePath ?: @"off",
              sApolloGoogleSearchDebugFollowDelay, sApolloGoogleSearchDebugStall,
              [NSUserDefaults.standardUserDefaults boolForKey:kApolloGoogleSearchDebugLegacyJarKey]);
}

void ApolloGoogleSearchDebugEvaluateJS(NSString *js) {
    WKWebView *live = sApolloGoogleSearchDebugLiveWeb;
    if (live) {
        [live evaluateJavaScript:js completionHandler:^(id value, NSError *error) {
            ApolloLog(@"[GoogleSearch][js] (live) %@", error ? error.localizedDescription : value);
        }];
        return;
    }
    if (!sApolloGoogleSearchDebugWeb) {
        ApolloLog(@"[GoogleSearch][debug] no results page kept yet — run gsearch first");
        return;
    }
    [sApolloGoogleSearchDebugWeb evaluateJavaScript:js completionHandler:^(id value, NSError *error) {
        NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
        if (error) text = [@"ERROR " stringByAppendingString:error.localizedDescription];
        // os_log truncates long messages; chunk them.
        NSUInteger chunk = 800;
        for (NSUInteger offset = 0; offset < MAX(text.length, (NSUInteger)1); offset += chunk) {
            NSString *part = text.length ? [text substringWithRange:NSMakeRange(offset, MIN(chunk, text.length - offset))] : @"(empty)";
            ApolloLog(@"[GoogleSearch][js] %@", part);
        }
    }];
}
#endif
