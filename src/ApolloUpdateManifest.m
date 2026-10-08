#import "ApolloUpdateManifest.h"

@implementation ApolloUpdateInfo
@end

@implementation ApolloUpdateNoteBlock
@end

@implementation ApolloUpdateReleaseNotes
@end

NSString *ApolloUpdateManifestKeyForBuildVariant(NSString *buildVariant) {
    // ARBuildVariant values stamped by scripts/build_release_variants.sh.
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"ipa":              @"standard",
            @"ipa-noext":        @"noExtensions",
            @"glass":            @"glass",
            @"glass-noext":      @"noExtensionsGlass",
            @"glassicons":       @"glassIcons",
            @"glassicons-noext": @"noExtensionsGlassIcons",
        };
    });
    return buildVariant.length ? map[buildVariant] : nil;
}

NSString *ApolloUpdateNormalizedVersion(NSString *version) {
    NSString *v = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([v hasPrefix:@"v"]) v = [v substringFromIndex:1];
    NSRange dash = [v rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location != NSNotFound) {
        NSString *revision = [v substringFromIndex:dash.location + 1];
        NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
        if (revision.length > 0 && [revision rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            v = [v substringToIndex:dash.location];
        }
    }
    return v;
}

// Numeric prefix of each dot-separated component: "3.8.5" -> [3, 8, 5].
static NSArray<NSNumber *> *ApolloUpdateVersionComponents(NSString *version) {
    NSMutableArray<NSNumber *> *components = [NSMutableArray array];
    for (NSString *part in [ApolloUpdateNormalizedVersion(version) componentsSeparatedByString:@"."]) {
        [components addObject:@(part.integerValue)];  // stops at the first non-digit, 0 if none
    }
    return components;
}

NSComparisonResult ApolloUpdateCompareVersions(NSString *a, NSString *b) {
    NSArray<NSNumber *> *ca = ApolloUpdateVersionComponents(a);
    NSArray<NSNumber *> *cb = ApolloUpdateVersionComponents(b);
    NSUInteger count = MAX(ca.count, cb.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger x = i < ca.count ? ca[i].integerValue : 0;
        NSInteger y = i < cb.count ? cb[i].integerValue : 0;
        if (x < y) return NSOrderedAscending;
        if (x > y) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSString *ApolloUpdateString(id value) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0 ? value : nil;
}

// https only: these URLs get handed to other apps and Safari.
static NSURL *ApolloUpdateHTTPSURL(id value) {
    NSString *string = ApolloUpdateString(value);
    NSURL *url = string ? [NSURL URLWithString:string] : nil;
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length ? url : nil;
}

ApolloUpdateInfo *ApolloUpdateInfoFromManifest(id manifest, NSString *variantKey) {
    if (![manifest isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *release = [manifest[@"release"] isKindOfClass:NSDictionary.class] ? manifest[@"release"] : nil;
    NSString *version = ApolloUpdateString(release[@"tweakVersion"]);
    if (!version || [version rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == NSNotFound) {
        return nil;
    }

    ApolloUpdateInfo *info = [ApolloUpdateInfo new];
    info.version = version;
    info.releaseURL = ApolloUpdateHTTPSURL(release[@"url"]);

    NSDictionary *variants = [manifest[@"variants"] isKindOfClass:NSDictionary.class] ? manifest[@"variants"] : nil;
    NSDictionary *variant = variantKey && [variants[variantKey] isKindOfClass:NSDictionary.class] ? variants[variantKey] : nil;
    info.sourceURL = ApolloUpdateHTTPSURL(variant[@"sourceURL"]);
    info.downloadURL = ApolloUpdateHTTPSURL(variant[@"directDownloadURL"]);
    // The notes are identical across variants, so a build that doesn't know its own variant
    // still reads them from the standard source.
    NSDictionary *standard = [variants[@"standard"] isKindOfClass:NSDictionary.class] ? variants[@"standard"] : nil;
    info.notesSourceURL = info.sourceURL ?: ApolloUpdateHTTPSURL(standard[@"sourceURL"]);
    return info;
}

NSURL *ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloader sideloader, NSURL *sourceURL) {
    switch (sideloader) {
        case ApolloUpdateSideloaderFlareStore:
            return nil;
        case ApolloUpdateSideloaderFeather:
            // Feather takes the source URL as the path: feather://source/https://...
            return [NSURL URLWithString:[@"feather://source/" stringByAppendingString:sourceURL.absoluteString]];
        case ApolloUpdateSideloaderAltStore:
        case ApolloUpdateSideloaderSideStore: {
            // AltStore Classic and SideStore share the source?url= shape (DISTRIBUTION.md).
            NSURLComponents *components = [NSURLComponents new];
            components.scheme = sideloader == ApolloUpdateSideloaderAltStore ? @"altstore-classic" : @"sidestore";
            components.host = @"source";
            components.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:sourceURL.absoluteString]];
            return components.URL;
        }
    }
}

NSURL *ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloader sideloader, NSURL *ipaURL) {
    switch (sideloader) {
        case ApolloUpdateSideloaderFeather:
            // Feather downloads the IPA into its Library (no progress UI for URL downloads).
            return [NSURL URLWithString:[@"feather://install/" stringByAppendingString:ipaURL.absoluteString]];
        case ApolloUpdateSideloaderFlareStore:
            // FlareStore's documented direct-IPA path (Settings > URL Schemes).
            return [NSURL URLWithString:[@"flarestore://downloadApp=" stringByAppendingString:ipaURL.absoluteString]];
        case ApolloUpdateSideloaderAltStore:
        case ApolloUpdateSideloaderSideStore:
            return nil;
    }
}

NSURL *ApolloUpdateSideloaderLaunchURL(ApolloUpdateSideloader sideloader) {
    switch (sideloader) {
        case ApolloUpdateSideloaderAltStore:   return [NSURL URLWithString:@"altstore-classic://"];
        case ApolloUpdateSideloaderSideStore:  return [NSURL URLWithString:@"sidestore://"];
        case ApolloUpdateSideloaderFeather:    return [NSURL URLWithString:@"feather://"];
        case ApolloUpdateSideloaderFlareStore: return [NSURL URLWithString:@"flarestore://"];
    }
}

NSURL *ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloader sideloader, ApolloUpdateInfo *info) {
    NSURL *url = nil;
    if (info.handoff == ApolloUpdateHandoffExact) {
        // The IPA link works whether or not the source is added, so it wins where it exists.
        if (info.downloadURL) url = ApolloUpdateSideloaderInstallURL(sideloader, info.downloadURL);
        if (!url && info.sourceURL) url = ApolloUpdateSideloaderSourceURL(sideloader, info.sourceURL);
    }
    return url ?: ApolloUpdateSideloaderLaunchURL(sideloader);
}

#pragma mark - Release notes

// A bullet's trailing credit: "(#1260: @user)", "(#1256, #1258: @user)", "(#12)".
static NSRegularExpression *ApolloUpdateCreditRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\((#\\d+(?:,\\s*#\\d+)*(?::\\s*[^()]*)?)\\)\\s*$"
                                                          options:0 error:NULL];
    });
    return regex;
}

NSArray<ApolloUpdateNoteBlock *> *ApolloUpdateParseReleaseNotes(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @[];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length) [lines addObject:line];
    }
    NSMutableArray<ApolloUpdateNoteBlock *> *blocks = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        BOOL bullet = [line hasPrefix:@"- "] || [line hasPrefix:@"* "];
        ApolloUpdateNoteBlock *block = [ApolloUpdateNoteBlock new];
        if (bullet) {
            block.kind = ApolloUpdateNoteKindBullet;
            NSString *body = [[line substringFromIndex:2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSTextCheckingResult *credit = [ApolloUpdateCreditRegex() firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
            if (credit && credit.range.location > 0) {
                block.credit = [body substringWithRange:[credit rangeAtIndex:1]];
                body = [body substringToIndex:credit.range.location];
            }
            block.text = body;
        } else {
            NSString *next = i + 1 < lines.count ? lines[i + 1] : nil;
            BOOL nextIsBullet = [next hasPrefix:@"- "] || [next hasPrefix:@"* "];
            block.kind = nextIsBullet ? ApolloUpdateNoteKindHeading : ApolloUpdateNoteKindParagraph;
            block.text = line;
        }
        [blocks addObject:block];
    }
    return blocks;
}

static NSDate *ApolloUpdateDateFromString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    return [formatter dateFromString:value];
}

static ApolloUpdateReleaseNotes *ApolloUpdateNotesEntry(NSString *version, id date, id description) {
    if (!version.length || ![description isKindOfClass:NSString.class]) return nil;
    NSArray<ApolloUpdateNoteBlock *> *blocks = ApolloUpdateParseReleaseNotes(description);
    if (!blocks.count) return nil;
    ApolloUpdateReleaseNotes *notes = [ApolloUpdateReleaseNotes new];
    notes.version = version;
    notes.date = ApolloUpdateDateFromString(date);
    notes.blocks = blocks;
    return notes;
}

NSArray<ApolloUpdateReleaseNotes *> *ApolloUpdateReleaseNotesFromSource(id sourceJSON, NSString *installedVersion, NSString *latestVersion) {
    if (![sourceJSON isKindOfClass:NSDictionary.class]) return @[];
    NSArray *apps = [sourceJSON[@"apps"] isKindOfClass:NSArray.class] ? sourceJSON[@"apps"] : nil;
    NSDictionary *app = nil;
    for (id candidate in apps) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        if (!app) app = candidate;
        if ([candidate[@"bundleIdentifier"] isEqual:@"com.christianselig.Apollo"]) { app = candidate; break; }
    }
    if (!app) return @[];

    BOOL (^inRange)(NSString *) = ^BOOL(NSString *version) {
        return ApolloUpdateCompareVersions(version, installedVersion) == NSOrderedDescending
            && ApolloUpdateCompareVersions(version, latestVersion) != NSOrderedDescending;
    };

    NSMutableArray<ApolloUpdateReleaseNotes *> *result = [NSMutableArray array];
    NSArray *versions = [app[@"versions"] isKindOfClass:NSArray.class] ? app[@"versions"] : nil;
    for (id entry in versions) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *version = ApolloUpdateString(entry[@"version"]);
        if (!version || !inRange(version)) continue;
        ApolloUpdateReleaseNotes *notes = ApolloUpdateNotesEntry(version, entry[@"date"], entry[@"localizedDescription"]);
        if (notes) [result addObject:notes];
    }
    if (!result.count && !versions.count) {
        NSString *version = ApolloUpdateString(app[@"version"]);
        if (version && inRange(version)) {
            ApolloUpdateReleaseNotes *notes = ApolloUpdateNotesEntry(version, app[@"versionDate"], app[@"versionDescription"]);
            if (notes) [result addObject:notes];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(ApolloUpdateReleaseNotes *a, ApolloUpdateReleaseNotes *b) {
        return ApolloUpdateCompareVersions(b.version, a.version);   // newest first
    }];
    if (result.count > 8) [result removeObjectsInRange:NSMakeRange(8, result.count - 8)];
    return result;
}
