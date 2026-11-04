#import "ApolloLogRedaction.h"

// See ApolloLogRedaction.h for what is masked and why. The passes run in a
// fixed order over the whole export:
//   1. paths     (before URLs, so file:// URLs and bare paths agree)
//   2. URLs      (before credentials: dropping the query removes most tokens)
//   3. credentials
//   4. emails    (after URLs, which already stripped user:pass@ authorities)
//   5. names and IDs (websession:, /chat/, u_, u/, /user/, t2_, then the
//      signed-in accounts' bare names last so they catch whatever is left)

typedef NSString *_Nullable (^ARLRReplacer)(NSTextCheckingResult *match, NSString *source);

// Set once any pattern fails to compile (never expected: they are constant and
// host-tested). The export is then withheld instead of going out unscrubbed.
static _Atomic BOOL sARLRPatternFailed = NO;

static NSRegularExpression *ARLRRegex(NSString *pattern, NSRegularExpressionOptions options) {
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:options
                                                                             error:&error];
    // A pattern typo must fail loudly in the host tests, not silently skip a pass.
    NSCAssert(regex, @"ApolloLogRedaction: bad pattern %@: %@", pattern, error);
    if (!regex) sARLRPatternFailed = YES;
    return regex;
}

// Ranges of the lines that contain any of `triggers`, merged, in order.
static NSIndexSet *ARLRLinesContaining(NSString *s, NSArray<NSString *> *triggers, NSStringCompareOptions options) {
    NSMutableIndexSet *lines = [NSMutableIndexSet indexSet];
    NSUInteger length = s.length;
    for (NSString *trigger in triggers) {
        NSRange search = NSMakeRange(0, length);
        while (search.length > 0) {
            NSRange hit = [s rangeOfString:trigger options:options range:search];
            if (hit.location == NSNotFound) break;
            NSRange line = [s lineRangeForRange:hit];
            [lines addIndexesInRange:line];
            NSUInteger next = NSMaxRange(line);
            if (next >= length) break;
            search = NSMakeRange(next, length - next);
        }
    }
    return lines;
}

// Rebuilds `input` with each match replaced by the block's result. A nil
// result keeps that match unchanged. Returns `input` itself when nothing
// changed, so passes that find nothing cost one scan and no copy.
//
// `triggers`: literals every match must sit on the same line as (a URL needs
// "://", an email "@"). The regex then runs only over those lines — a literal
// scan is ~50x cheaper than a regex scan of a multi-megabyte export, and most
// lines have none. nil runs the regex over everything. Lookarounds still see
// outside the line (transparent bounds).
static NSString *ARLRReplaceOnLines(NSString *input, NSRegularExpression *regex,
                                    NSArray<NSString *> *triggers, NSStringCompareOptions triggerOptions,
                                    ARLRReplacer replacer) {
    if (!regex || input.length == 0) return input;
    NSArray<NSTextCheckingResult *> *matches = nil;
    if (triggers) {
        NSIndexSet *lines = ARLRLinesContaining(input, triggers, triggerOptions);
        if (lines.count == 0) return input;
        NSMutableArray<NSTextCheckingResult *> *found = [NSMutableArray array];
        [lines enumerateRangesUsingBlock:^(NSRange range, __unused BOOL *stop) {
            [found addObjectsFromArray:[regex matchesInString:input
                                                      options:NSMatchingWithTransparentBounds
                                                        range:range]];
        }];
        matches = found;
    } else {
        matches = [regex matchesInString:input options:0 range:NSMakeRange(0, input.length)];
    }
    NSMutableString *out = nil;
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        NSString *replacement = replacer(match, input);
        if (!replacement) continue;
        if (!out) out = [NSMutableString stringWithCapacity:input.length];
        [out appendString:[input substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]];
        [out appendString:replacement];
        cursor = NSMaxRange(match.range);
    }
    if (!out) return input;
    [out appendString:[input substringFromIndex:cursor]];
    return out;
}

static NSString *ARLRReplace(NSString *input, NSRegularExpression *regex, NSArray<NSString *> *triggers,
                             ARLRReplacer replacer) {
    return ARLRReplaceOnLines(input, regex, triggers, NSLiteralSearch, replacer);
}

static NSString *ARLRGroup(NSTextCheckingResult *match, NSString *source, NSUInteger index) {
    if (index >= match.numberOfRanges) return @"";
    NSRange range = [match rangeAtIndex:index];
    return range.location == NSNotFound ? @"" : [source substringWithRange:range];
}

static uint64_t ARLRHash(NSString *value) {
    // FNV-1a over UTF-16 units: tiny, stable, and only used for short tags.
    uint64_t hash = 1469598103934665603ULL;
    NSUInteger length = value.length;
    for (NSUInteger i = 0; i < length; i++) {
        hash ^= [value characterAtIndex:i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

NSString *ApolloLogFingerprint(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @"none";
    return [NSString stringWithFormat:@"%04llx", ARLRHash(value) & 0xffff];
}

NSString *ApolloLogURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return @"nil";
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return @"<unparsable URL>";
    NSMutableString *out = [NSMutableString string];
    if (components.scheme.length) [out appendFormat:@"%@://", components.scheme];
    if (components.host.length) [out appendString:components.host];
    if (components.port) [out appendFormat:@":%@", components.port];
    [out appendString:components.path ?: @""];
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.name.length) [keys addObject:item.name];
    }
    if (keys.count) [out appendFormat:@"?{%@}", [keys.array componentsJoinedByString:@","]];
    return out;
}

NSString *ApolloLogPageTitleKind(id title) {
    NSString *string = [title isKindOfClass:[NSString class]] ? title : @"";
    if (string.length == 0) return @"empty";
    NSString *lower = string.lowercaseString;
    for (NSString *marker in @[ @"moment", @"verif", @"blocked", @"captcha", @"security", @"robot", @"humanity" ]) {
        if ([lower containsString:marker]) return @"challenge";
    }
    return [NSString stringWithFormat:@"%@(%lu chars)",
            [lower containsString:@"reddit"] ? @"reddit" : @"other", (unsigned long)string.length];
}

NSString *ApolloLogOwnThing(NSString *fullnameOrID) {
    if (![fullnameOrID isKindOfClass:[NSString class]] || fullnameOrID.length == 0) return @"(none)";
    NSString *prefix = @"";
    if (fullnameOrID.length > 3 && [fullnameOrID characterAtIndex:0] == 't' && [fullnameOrID characterAtIndex:2] == '_') {
        prefix = [fullnameOrID substringToIndex:3];
    }
    return [NSString stringWithFormat:@"%@#%@", prefix, ApolloLogFingerprint(fullnameOrID.lowercaseString)];
}

#pragma mark - Per-export state

@interface ARLRContext : NSObject
@property (nonatomic, copy) NSString *salt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *tags;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *ownTags;
@end

@implementation ARLRContext

// The salt changes every export, so a tag can't be matched to a name by
// hashing a guess, while the same name keeps one tag within one export.
- (NSString *)tagForValue:(NSString *)value prefix:(NSString *)prefix {
    NSString *key = [prefix stringByAppendingString:value.lowercaseString];
    NSString *tag = self.tags[key];
    if (tag) return tag;
    uint64_t hash = ARLRHash([self.salt stringByAppendingString:key]);
    tag = [NSString stringWithFormat:@"[%@-%04llx]", prefix, hash & 0xffff];
    self.tags[key] = tag;
    return tag;
}

- (NSString *)userTag:(NSString *)username {
    return self.ownTags[username.lowercaseString] ?: [self tagForValue:username prefix:@"user"];
}

@end

#pragma mark - Passes

static NSString *ARLRRedactPaths(NSString *s, NSString *homeDirectory) {
    if (homeDirectory.length > 1) {
        s = [s stringByReplacingOccurrencesOfString:homeDirectory withString:@"~"];
    }
    static NSRegularExpression *container, *macHome;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // App, bundle and app-group containers of this and other installs.
        container = ARLRRegex(@"(?:/private)?/var/(?:mobile/)?containers/(?:data/application|bundle/application|shared/appgroup)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                              NSRegularExpressionCaseInsensitive);
        // Simulator builds: the developer's macOS account name.
        macHome = ARLRRegex(@"/Users/[^/\\s\"']+/", 0);
    });
    s = ARLRReplaceOnLines(s, container, @[ @"ontainers/" ], NSCaseInsensitiveSearch, ^NSString *(__unused NSTextCheckingResult *m, __unused NSString *src) {
        return @"<container>";
    });
    return ARLRReplace(s, macHome, @[ @"/Users/" ], ^NSString *(__unused NSTextCheckingResult *m, __unused NSString *src) {
        return @"/Users/[mac-user]/";
    });
}

// Reddit's page/API hosts and its own media hosts (i.redd.it, v.redd.it,
// preview.redd.it, ...) keep their path: routes, subreddit names and post IDs
// are what make these lines useful, and a post's media ID says no more than
// its t3_ ID, which exports keep. Two exceptions keep only the host:
// snoovatar paths (a person's avatar) and every other host, where the path IS
// the content (an article, someone's social profile; redditmedia.com style
// paths carry a user's profile-subreddit ID).
static BOOL ARLRHostKeepsPath(NSString *host, NSString *path) {
    NSString *lower = host.lowercaseString;
    if ([lower isEqualToString:@"reddit.com"] || [lower hasSuffix:@".reddit.com"] ||
        [lower isEqualToString:@"redd.it"]) {
        return YES;
    }
    if ([lower hasSuffix:@".redd.it"]) {
        return [path rangeOfString:@"/snoovatar/" options:NSCaseInsensitiveSearch].location == NSNotFound;
    }
    return NO;
}

static NSSet<NSString *> *ARLRKnownExtensions(void) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[
            @"jpg", @"jpeg", @"png", @"gif", @"gifv", @"webp", @"heic", @"avif", @"svg", @"ico",
            @"mp4", @"m4v", @"mov", @"webm", @"m3u8", @"mpd", @"ts", @"m4s", @"mp3", @"m4a", @"aac",
            @"json", @"js", @"css", @"html", @"htm", @"php", @"pdf", @"xml", @"txt",
        ]];
    });
    return extensions;
}

static NSString *ARLRRedactURLs(NSString *s) {
    static NSRegularExpression *url, *slug;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // scheme :// authority path ?query #fragment. The stop set keeps the
        // punctuation around a URL in prose, lists and NSError/NSDictionary
        // descriptions ("(a, b)", "{key=url}", "url;") out of the match. A
        // comma followed by more URL text stays in ("crop=256:256,smart").
        NSString *stop = @"\\s\"'<>(),;{}\\[\\]|\\\\^`";
        NSString *comma = @",(?=[^\\s,)\\]}])";
        NSString *pattern = [NSString stringWithFormat:
            @"\\b([A-Za-z][A-Za-z0-9+.-]{1,20})://([^/%@?#]*)((?:[^%@?#]|%@)*)(\\?(?:[^%@#]|%@)*)?(#(?:[^%@]|%@)*)?",
            stop, stop, comma, stop, comma, stop, comma];
        url = ARLRRegex(pattern, 0);
        // /comments/<id>/<title-slug> — keep the ID, drop the post title.
        slug = ARLRRegex(@"(/comments/[A-Za-z0-9]+/)([^/]+)", NSRegularExpressionCaseInsensitive);
    });
    return ARLRReplace(s, url, @[ @"://" ], ^NSString *(NSTextCheckingResult *m, NSString *src) {
        NSString *scheme = ARLRGroup(m, src, 1);
        NSString *authority = ARLRGroup(m, src, 2);
        NSString *path = ARLRGroup(m, src, 3);
        NSString *query = ARLRGroup(m, src, 4);
        NSString *fragment = ARLRGroup(m, src, 5);

        // user:password@host — never print the userinfo.
        NSRange at = [authority rangeOfString:@"@" options:NSBackwardsSearch];
        NSString *host = at.location == NSNotFound ? authority : [authority substringFromIndex:NSMaxRange(at)];
        NSString *hostOnly = [host componentsSeparatedByString:@":"].firstObject ?: host;

        NSMutableString *out = [NSMutableString stringWithFormat:@"%@://%@", scheme, host];
        if (path.length > 0) {
            if (ARLRHostKeepsPath(hostOnly, path)) {
                [out appendString:ARLRReplace(path, slug, nil, ^NSString *(NSTextCheckingResult *sm, NSString *ssrc) {
                    return [ARLRGroup(sm, ssrc, 1) stringByAppendingString:@"…"];
                })];
            } else if ([path isEqualToString:@"/"]) {
                [out appendString:@"/"];
            } else {
                // Keep a known media/document extension: "is it a .gifv or an
                // .mp4" is often the whole media bug. Anything else ("real.name")
                // could be part of a handle.
                NSString *extension = path.lastPathComponent.pathExtension.lowercaseString;
                [out appendString:[ARLRKnownExtensions() containsObject:extension]
                    ? [@"/…." stringByAppendingString:extension] : @"/…"];
            }
        }
        if (query.length > 0) [out appendString:@"?…"];
        if (fragment.length > 0) [out appendString:@"#…"];
        return out;
    });
}

static BOOL ARLRIsPlaceholderValue(NSString *value) {
    static NSRegularExpression *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // States, lengths and earlier redaction markers say nothing secret and
        // are often the point of the line ("clientId=<empty>", "cookie=yes").
        placeholder = ARLRRegex(@"^(?:yes|no|true|false|present|absent|missing|none|nil|null|\\(null\\)|<empty>|<nil>|<none>|empty|set|unset|ok|on|off|\\d{1,4}|\\[.*)$",
                                NSRegularExpressionCaseInsensitive);
    });
    return [placeholder firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

// Line triggers for the key=value pass (matched case-insensitively): a root
// of every key name, so any casing a log uses reaches the regex.
static NSArray<NSString *> *ARLRKeyTriggers(void) {
    return @[ @"token", @"session", @"loid", @"edgebucket", @"csrf", @"modhash", @"client",
              @"passw", @"api_key", @"apikey", @"secret", @"authorization", @"cookie" ];
}

static NSString *ARLRRedactCredentials(NSString *s) {
    static NSRegularExpression *bearer, *keyValue, *jwt, *apiKey, *hex64;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bearer = ARLRRegex(@"\\b(bearer)\\s+[A-Za-z0-9._~+/=-]{8,}", NSRegularExpressionCaseInsensitive);
        keyValue = ARLRRegex(@"\\b(access_?token|refresh_?token|id_?token|token_v2|reddit_session|session_tracker|loid|edgebucket|csrf_?token|x-csrf-token|x-modhash|modhash|client_?secret|client_?id|password|passwd|api_?key|secret|authorization|set-cookie|cookie|registration_?token|device_?token|push_?token|apns_?token)([\"']?\\s*[:=]\\s*[\"']?)([^\\s\"';&,}]+)",
                             NSRegularExpressionCaseInsensitive);
        jwt = ARLRRegex(@"\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", 0);
        // OpenAI/Anthropic/OpenRouter (sk-...), Google (AIza...), GitHub, Slack.
        apiKey = ARLRRegex(@"\\b(?:(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{10,})", 0);
        // APNs device tokens (64 hex), Live Activity push tokens (longer) and
        // similar 256-bit+ secrets. Git hashes (40) and UUIDs stay.
        hex64 = ARLRRegex(@"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64,}(?![0-9A-Fa-f])", 0);
    });
    s = ARLRReplaceOnLines(s, bearer, @[ @"bearer" ], NSCaseInsensitiveSearch, ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return [ARLRGroup(m, src, 1) stringByAppendingString:@" [token]"];
    });
    s = ARLRReplaceOnLines(s, keyValue, ARLRKeyTriggers(), NSCaseInsensitiveSearch, ^NSString *(NSTextCheckingResult *m, NSString *src) {
        if (ARLRIsPlaceholderValue(ARLRGroup(m, src, 3))) return nil;
        return [NSString stringWithFormat:@"%@%@[redacted]", ARLRGroup(m, src, 1), ARLRGroup(m, src, 2)];
    });
    s = ARLRReplace(s, jwt, @[ @"eyJ" ], ^NSString *(__unused NSTextCheckingResult *m, __unused NSString *src) {
        return @"[token]";
    });
    s = ARLRReplace(s, apiKey, @[ @"sk-", @"pk-", @"rk-", @"AIza", @"ghp_", @"gho_", @"ghu_", @"ghs_", @"ghr_", @"xox" ], ^NSString *(__unused NSTextCheckingResult *m, __unused NSString *src) {
        return @"[key]";
    });
    return ARLRReplace(s, hex64, nil, ^NSString *(__unused NSTextCheckingResult *m, __unused NSString *src) {
        return @"[hex-token]";
    });
}

static NSString *ARLRRedactEmails(NSString *s) {
    static NSRegularExpression *email;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // (?!\d+x\.) keeps retina asset names such as icon@2x.png.
        email = ARLRRegex(@"[A-Za-z0-9._%+-]+@(?!\\d+x\\.)[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}", 0);
    });
    return ARLRReplace(s, email, @[ @"@" ], ^NSString *(__unused NSTextCheckingResult *m, __unused NSString *src) {
        return @"[email]";
    });
}

static NSString *ARLRRedactNames(NSString *s, ARLRContext *context) {
    static NSRegularExpression *webSession, *userSub, *userPath, *accountID, *chatRoute;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keychain account names of per-account web sessions.
        webSession = ARLRRegex(@"\\b(websession:)([^:\\s\"',;)]+)", NSRegularExpressionCaseInsensitive);
        // r/u_name, the profile "subreddit" of a user.
        userSub = ARLRRegex(@"(?<![A-Za-z0-9_])(u_)([A-Za-z0-9_-]{3,20})(?![A-Za-z0-9_-])", 0);
        // u/name, /u/name, /user/name. The token must start a word, so "menu/x"
        // or "api/multi/user/x" match only at "user".
        userPath = ARLRRegex(@"(?<![A-Za-z0-9_])(u|user)/([A-Za-z0-9_-]{3,20})(?![A-Za-z0-9_-])",
                             NSRegularExpressionCaseInsensitive);
        accountID = ARLRRegex(@"\\b(t2_)([a-z0-9]{1,13})\\b", 0);
        // New-chat routes name the room or the partner's account.
        chatRoute = ARLRRegex(@"(/chat/(?:room|user|direct)/)([^/\\s\"',;)\\]]+)", 0);
    });
    s = ARLRReplaceOnLines(s, webSession, @[ @"websession:" ], NSCaseInsensitiveSearch, ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return [ARLRGroup(m, src, 1) stringByAppendingString:[context userTag:ARLRGroup(m, src, 2)]];
    });
    // Before the username passes: /chat/user/<id> must not become /chat/user/[user-…].
    s = ARLRReplace(s, chatRoute, @[ @"/chat/" ], ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return [ARLRGroup(m, src, 1) stringByAppendingString:@"[id]"];
    });
    s = ARLRReplace(s, userSub, @[ @"u_" ], ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return [ARLRGroup(m, src, 1) stringByAppendingString:[context userTag:ARLRGroup(m, src, 2)]];
    });
    s = ARLRReplaceOnLines(s, userPath, @[ @"u/", @"user/" ], NSCaseInsensitiveSearch, ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return [NSString stringWithFormat:@"%@/%@", ARLRGroup(m, src, 1), [context userTag:ARLRGroup(m, src, 2)]];
    });
    s = ARLRReplace(s, accountID, @[ @"t2_" ], ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return [ARLRGroup(m, src, 1) stringByAppendingString:[context tagForValue:ARLRGroup(m, src, 2) prefix:@"id"]];
    });

    // The signed-in accounts' names anywhere else ("account=foo", arrays,
    // titles). One alternation, longest first so "kurisu_alt" wins over "kurisu".
    if (context.ownTags.count == 0) return s;
    NSArray<NSString *> *names = [context.ownTags.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length == b.length ? [a compare:b] : (a.length > b.length ? NSOrderedAscending : NSOrderedDescending);
    }];
    NSMutableArray<NSString *> *escaped = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) [escaped addObject:[NSRegularExpression escapedPatternForString:name]];
    NSString *pattern = [NSString stringWithFormat:@"(?<![A-Za-z0-9_-])(?:%@)(?![A-Za-z0-9_-])",
                         [escaped componentsJoinedByString:@"|"]];
    NSRegularExpression *own = ARLRRegex(pattern, NSRegularExpressionCaseInsensitive);
    return ARLRReplaceOnLines(s, own, names, NSCaseInsensitiveSearch, ^NSString *(NSTextCheckingResult *m, NSString *src) {
        return context.ownTags[ARLRGroup(m, src, 0).lowercaseString];
    });
}

#pragma mark - Entry points

NSString *ApolloRedactLogExportWithSalt(NSString *log,
                                        NSArray<NSString *> *ownUsernames,
                                        NSString *homeDirectory,
                                        NSString *salt) {
    if (![log isKindOfClass:[NSString class]] || log.length == 0) return log ?: @"";

    ARLRContext *context = [ARLRContext new];
    context.salt = salt ?: @"";
    context.tags = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *ownTags = [NSMutableDictionary dictionary];
    for (NSString *raw in ownUsernames) {
        if (![raw isKindOfClass:[NSString class]]) continue;
        NSString *name = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        // Reddit names are 3-20 characters; anything shorter would mangle
        // ordinary words.
        if (name.length < 3 || ownTags[name]) continue;
        ownTags[name] = ownTags.count == 0 ? @"[me]" : [NSString stringWithFormat:@"[me%lu]", (unsigned long)ownTags.count + 1];
    }
    context.ownTags = ownTags;

    // One pool per pass: a pass that changes anything returns a fresh copy of
    // the whole export (megabytes), and the caller's pool would otherwise keep
    // every intermediate alive until the export finishes.
    NSString *s = log;
    @autoreleasepool { s = ARLRRedactPaths(s, homeDirectory); }
    @autoreleasepool { s = ARLRRedactURLs(s); }
    @autoreleasepool { s = ARLRRedactCredentials(s); }
    @autoreleasepool { s = ARLRRedactEmails(s); }
    @autoreleasepool { s = ARLRRedactNames(s, context); }
    if (sARLRPatternFailed) {
        return @"Apollo Reborn withheld this log: its privacy filter failed to load, so it could not mask "
               @"usernames and links. Please mention this in your report.";
    }
    return s;
}

NSString *ApolloRedactLogExport(NSString *log,
                                NSArray<NSString *> *ownUsernames,
                                NSString *homeDirectory) {
    return ApolloRedactLogExportWithSalt(log, ownUsernames, homeDirectory, [NSUUID UUID].UUIDString);
}
