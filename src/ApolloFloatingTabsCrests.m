#import "ApolloFloatingTabsCrests.h"

// =============================================================================
// MARK: - Title → two sides
// =============================================================================

static NSRegularExpression *ApolloFTCrestRegex(NSString *pattern) {
    // Compiled once per pattern; the four patterns below are process-lifetime.
    static NSMutableDictionary<NSString *, NSRegularExpression *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSRegularExpression *regex = cache[pattern];
        if (!regex) {
            regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                              options:NSRegularExpressionCaseInsensitive
                                                                error:NULL];
            if (regex) cache[pattern] = regex;
        }
        return regex;
    }
}

static NSString *ApolloFTCrestCollapseWhitespace(NSString *text) {
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *part in parts) if (part.length > 0) [kept addObject:part];
    return [kept componentsJoinedByString:@" "];
}

// Trims separators/punctuation left over from the split ("Boston Celtics -",
// "- Barcelona") and anything after a second separator on the away side.
static NSString *ApolloFTCrestCleanSide(NSString *side) {
    NSCharacterSet *junk = [NSCharacterSet characterSetWithCharactersInString:@" \t-–—:;,.|"];
    NSString *cleaned = [side stringByTrimmingCharactersInSet:junk];
    // "Barcelona - El Clásico": keep the team, drop the tagline.
    NSRange tail = [cleaned rangeOfString:@"\\s+[-–—|]\\s+" options:NSRegularExpressionSearch];
    if (tail.location != NSNotFound) cleaned = [cleaned substringToIndex:tail.location];
    cleaned = [cleaned stringByTrimmingCharactersInSet:junk];
    if (cleaned.length < 2 || cleaned.length > 40) return nil;
    if ([cleaned rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) return nil;
    return cleaned;
}

BOOL ApolloFTCrestTeamsFromTitle(NSString *title, NSString **outHome, NSString **outAway) {
    if (outHome) *outHome = nil;
    if (outAway) *outAway = nil;
    NSString *trimmed = ApolloFTCrestCollapseWhitespace(title ?: @"");
    if (trimmed.length < 6) return NO;

    // Gate + body: "<Kind> Thread: body" or "[<Kind> Thread] body". The prefix
    // must say thread/game/GDT/PGT so an ordinary "Messi vs Ronaldo?" post
    // never gets crests.
    NSString *prefix = nil, *body = nil;
    NSRegularExpression *bracket = ApolloFTCrestRegex(@"^\\[([^\\]]{1,40})\\]\\s*(.+)$");
    NSRegularExpression *colon = ApolloFTCrestRegex(@"^([^:\\[\\]]{1,40}):\\s*(.+)$");
    NSRange whole = NSMakeRange(0, trimmed.length);
    NSTextCheckingResult *match = [bracket firstMatchInString:trimmed options:0 range:whole]
                               ?: [colon firstMatchInString:trimmed options:0 range:whole];
    if (!match) return NO;
    prefix = [[trimmed substringWithRange:[match rangeAtIndex:1]] lowercaseString];
    body = [trimmed substringWithRange:[match rangeAtIndex:2]];
    BOOL gated = NO;
    for (NSString *word in @[@"thread", @"game", @"gdt", @"pgt", @"match"]) {
        if ([prefix rangeOfString:word].location != NSNotFound) { gated = YES; break; }
    }
    if (!gated) return NO;

    // Body: stop at the competition/date segment, drop records and "(aet)".
    NSRange pipe = [body rangeOfString:@"|"];
    if (pipe.location != NSNotFound) body = [body substringToIndex:pipe.location];
    body = [ApolloFTCrestRegex(@"\\([^)]*\\)") stringByReplacingMatchesInString:body options:0
                                                                           range:NSMakeRange(0, body.length)
                                                                    withTemplate:@" "];
    body = ApolloFTCrestCollapseWhitespace(body);
    if (body.length < 5) return NO;

    // Score form first ("Spain 1 - 0 Argentina", "México 2-3 Inglaterra"),
    // then a plain separator ("A vs B", "A vs. B", "A v B", "A @ B", "A at B").
    NSArray<NSString *> *patterns = @[
        @"^(.+?)\\s+\\d{1,3}\\s*[-–—]\\s*\\d{1,3}\\s+(.+)$",
        @"^(.+?)\\s+(?:vs\\.?|v\\.?|@|at)\\s+(.+)$",
    ];
    for (NSString *pattern in patterns) {
        NSTextCheckingResult *split = [ApolloFTCrestRegex(pattern) firstMatchInString:body options:0
                                                                                  range:NSMakeRange(0, body.length)];
        if (!split) continue;
        NSString *home = ApolloFTCrestCleanSide([body substringWithRange:[split rangeAtIndex:1]]);
        NSString *away = ApolloFTCrestCleanSide([body substringWithRange:[split rangeAtIndex:2]]);
        if (!home || !away) return NO;
        if (outHome) *outHome = home;
        if (outAway) *outAway = away;
        return YES;
    }
    return NO;
}

// =============================================================================
// MARK: - Side → catalogue entry
// =============================================================================

// Club-form filler that carries no identity ("FC Porto" and "Porto" are the
// same club). Deliberately excludes suffixes like "FA"/"AB" that the catalogue
// uses to tell variants apart ("Argentina" vs "Argentina_FA").
static NSSet<NSString *> *ApolloFTCrestFillerTokens(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"fc", @"cf", @"sc", @"ac", @"afc", @"ssc", @"as", @"us", @"ss", @"cd", @"ud", @"rcd", @"rc",
            @"sd", @"ad", @"fk", @"sk", @"bk", @"if", @"fsv", @"vfb", @"vfl", @"tsg", @"tsv", @"sv",
            @"spvgg", @"club", @"de", @"del", @"di", @"da", @"do", @"la", @"le", @"los", @"las", @"the",
            @"of", @"and", @"y", @"e", @"cp", @"cs", @"ca", @"kv", @"rsc", @"nk", @"hnk", @"gnk", @"ks",
            @"pfc", @"jk", @"sf", @"cfc", @"afc", @"sfc", @"cb", @"rb",
        ]];
    });
    return set;
}

// Spellings the thread titles use that the catalogue writes differently.
static NSDictionary<NSString *, NSString *> *ApolloFTCrestAliases(void) {
    static NSDictionary<NSString *, NSString *> *aliases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        aliases = @{
            @"man": @"manchester", @"utd": @"united", @"munchen": @"munich", @"muenchen": @"munich",
            @"st": @"saint", @"psg": @"paris saint germain", @"spurs": @"tottenham hotspur",
        };
    });
    return aliases;
}

// Lowercase, accent-folded, punctuation-free identity tokens for a name.
static NSArray<NSString *> *ApolloFTCrestTokens(NSString *name, BOOL applyAliases) {
    NSString *folded = [name stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch |
                                                         NSWidthInsensitiveSearch)
                                                 locale:[NSLocale localeWithLocaleIdentifier:@"en_US"]];
    NSMutableString *spaced = [NSMutableString stringWithCapacity:folded.length];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        unichar out = [alnum characterIsMember:c] ? c : (unichar)' ';
        [spaced appendFormat:@"%C", out];
    }
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSSet<NSString *> *filler = ApolloFTCrestFillerTokens();
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSString *raw in [spaced componentsSeparatedByString:@" "]) {
        NSString *token = raw.lowercaseString;
        if (token.length == 0 || [filler containsObject:token]) continue;
        if ([token rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound) continue; // "04", "1919"
        NSString *alias = applyAliases ? ApolloFTCrestAliases()[token] : nil;
        if (alias) [tokens addObjectsFromArray:[alias componentsSeparatedByString:@" "]];
        else [tokens addObject:token];
    }
    return tokens;
}

// Same folding without the filler/alias/digit rules: the whole name as typed.
static NSArray<NSString *> *ApolloFTCrestRawTokens(NSString *name) {
    NSString *folded = [name stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch |
                                                         NSWidthInsensitiveSearch)
                                                 locale:[NSLocale localeWithLocaleIdentifier:@"en_US"]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSString *raw in [folded componentsSeparatedByCharactersInSet:alnum.invertedSet]) {
        if (raw.length > 0) [tokens addObject:raw.lowercaseString];
    }
    return tokens;
}

@interface ApolloFTCrestEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSArray<NSString *> *tokens;     // filler-free identity tokens
@property (nonatomic, copy) NSArray<NSString *> *rawTokens;  // with fillers ("fc barcelona" vs "barcelona sc")
@end
@implementation ApolloFTCrestEntry
@end

// Normalised catalogue per subreddit, keyed on the catalogue array's identity
// so a refreshed list re-indexes and a repeated lookup is a dictionary hit.
static NSArray<ApolloFTCrestEntry *> *ApolloFTCrestIndexForCatalogue(NSString *subreddit,
                                                                     NSArray<NSDictionary<NSString *, NSString *> *> *catalogue) {
    static NSCache<NSString *, NSArray<ApolloFTCrestEntry *> *> *cache;
    static NSMutableDictionary<NSString *, NSValue *> *sources;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 8;
        sources = [NSMutableDictionary dictionary];
    });
    NSString *key = subreddit.lowercaseString ?: @"";
    @synchronized (sources) {
        NSArray<ApolloFTCrestEntry *> *index = [cache objectForKey:key];
        if (index && [sources[key] pointerValue] == (__bridge void *)catalogue) return index;
        NSMutableArray<ApolloFTCrestEntry *> *built = [NSMutableArray arrayWithCapacity:catalogue.count];
        for (NSDictionary *raw in catalogue) {
            NSString *name = raw[@"name"], *url = raw[@"url"];
            if (![name isKindOfClass:[NSString class]] || ![url isKindOfClass:[NSString class]]) continue;
            NSArray<NSString *> *tokens = ApolloFTCrestTokens(name, NO);
            if (tokens.count == 0) continue;
            ApolloFTCrestEntry *entry = [ApolloFTCrestEntry new];
            entry.name = name;
            entry.url = url;
            entry.tokens = tokens;
            entry.rawTokens = ApolloFTCrestRawTokens(name);
            [built addObject:entry];
        }
        [cache setObject:built forKey:key];
        sources[key] = [NSValue valueWithPointer:(__bridge void *)catalogue];
        return built;
    }
}

// How a side relates to a catalogue entry, strongest first:
//   Exact    identical tokens, or identical once the spaces are removed —
//            r/CFB names its schools "ohiostate" / "notredame" / "texasam".
//   Forward  every side token is in the entry verbatim: "Marseille" →
//            Olympique_de_Marseille. The entry is the longer name.
//   Prefix   every side token is in the entry verbatim or as a ≥3-letter
//            prefix either way: "Inter Milan" → FC_Internazionale_Milano.
//   Reverse  every entry token is in the side verbatim: "Kansas City Chiefs"
//            → Chiefs (r/nfl names teams by nickname). The side is longer.
//            Ranked last because a namesake can hide in a longer side ("Inter
//            Milan" contains AC_Milan's "Milan"), so it only wins when nothing
//            above it matches.
typedef NS_ENUM(NSInteger, ApolloFTCrestMatch) {
    ApolloFTCrestMatchNone = 0,
    ApolloFTCrestMatchReverse = 1,
    ApolloFTCrestMatchPrefix = 2,
    ApolloFTCrestMatchForward = 3,
    ApolloFTCrestMatchExact = 4,
};

static BOOL ApolloFTCrestTokensContain(NSArray<NSString *> *haystack, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) if (![haystack containsObject:needle]) return NO;
    return YES;
}

static ApolloFTCrestMatch ApolloFTCrestScore(NSArray<NSString *> *side, NSArray<NSString *> *candidate) {
    if ([side isEqualToArray:candidate]) return ApolloFTCrestMatchExact;
    if ([[side componentsJoinedByString:@""] isEqualToString:[candidate componentsJoinedByString:@""]]) {
        return ApolloFTCrestMatchExact;
    }
    if (ApolloFTCrestTokensContain(candidate, side)) return ApolloFTCrestMatchForward;
    BOOL prefix = YES;
    for (NSString *token in side) {
        BOOL matched = NO;
        for (NSString *other in candidate) {
            NSString *shorter = token.length <= other.length ? token : other;
            NSString *longer = token.length <= other.length ? other : token;
            if (shorter.length >= 3 && [longer hasPrefix:shorter]) { matched = YES; break; }
        }
        if (!matched) { prefix = NO; break; }
    }
    if (prefix) return ApolloFTCrestMatchPrefix;
    if (ApolloFTCrestTokensContain(side, candidate)) return ApolloFTCrestMatchReverse;
    return ApolloFTCrestMatchNone;
}

NSString *ApolloFTCrestURLForTeam(NSString *team, NSString *subreddit,
                                  NSArray<NSDictionary<NSString *, NSString *> *> *catalogue,
                                  NSString **outName) {
    if (outName) *outName = nil;
    NSArray<NSString *> *side = ApolloFTCrestTokens(team ?: @"", YES);
    if (side.count == 0 || catalogue.count == 0) return nil;

    // Anything short of an exact match is only trusted when it can't be a
    // namesake: a forward/prefix match needs a specific side (two words, or
    // one long word — "Internazionale", "Leverkusen") and an entry adding at
    // most one word ("Olympique de Marseille" for "Marseille" yes, "Chattanooga
    // Red Wolves" for "Wolves" never); a reverse match needs an entry with a
    // real word in it (≥4 letters, so "ES" or "PN" never match anything) and
    // a side adding at most two ("Kansas City Chiefs" → Chiefs). The keyless
    // catalogue is partial, so a club's real entry can be missing and a
    // namesake must not be picked in its place.
    BOOL specific = side.count >= 2 || side.firstObject.length >= 9;
    NSArray<NSString *> *rawSide = ApolloFTCrestRawTokens(team);

    // Rank: score, then fewer extra identity tokens, then the raw name with
    // fillers ("FC Barcelona" → FC_Barcelona, not Barcelona_SC). Anything
    // still tied between different crests is a guess, and a wrong crest is
    // far worse than the letter fallback — treat it as a miss.
    ApolloFTCrestEntry *best = nil;
    BOOL tied = NO;
    NSInteger bestScore = 0, bestRaw = 0;
    NSUInteger bestExtra = NSUIntegerMax;
    for (ApolloFTCrestEntry *entry in ApolloFTCrestIndexForCatalogue(subreddit, catalogue)) {
        ApolloFTCrestMatch score = ApolloFTCrestScore(side, entry.tokens);
        if (score == ApolloFTCrestMatchNone) continue;
        NSUInteger longer = MAX(entry.tokens.count, side.count), shorter = MIN(entry.tokens.count, side.count);
        NSUInteger extra = longer - shorter;
        if (score != ApolloFTCrestMatchExact) {
            if (score == ApolloFTCrestMatchReverse) {
                BOOL entryHasWord = NO;
                for (NSString *token in entry.tokens) if (token.length >= 4) { entryHasWord = YES; break; }
                if (!entryHasWord || extra > 2) continue;
            } else if (!specific || extra > 1) {
                continue;
            }
        }
        NSInteger raw = ApolloFTCrestScore(rawSide, entry.rawTokens);
        if (!best || score > bestScore || (score == bestScore && extra < bestExtra)
            || (score == bestScore && extra == bestExtra && raw > bestRaw)) {
            best = entry; bestScore = score; bestExtra = extra; bestRaw = raw; tied = NO;
        } else if (score == bestScore && extra == bestExtra && raw == bestRaw
                   && ![entry.url isEqualToString:best.url]) {
            tied = YES;
        }
    }
    if (!best || tied) return nil;
    if (outName) *outName = best.name;
    return best.url;
}
