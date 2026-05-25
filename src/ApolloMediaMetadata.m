#import "ApolloMediaMetadata.h"

static BOOL ApolloStringIsNonEmpty(NSString *string) {
    return [string isKindOfClass:[NSString class]] && string.length > 0;
}

static NSString *ApolloLowercaseString(NSString *string) {
    return ApolloStringIsNonEmpty(string) ? string.lowercaseString : @"";
}

static BOOL ApolloURLHostIsRedditPreview(NSString *urlString) {
    NSString *lower = ApolloLowercaseString(urlString);
    return [lower containsString:@"preview.redd.it"] || [lower containsString:@"external-preview.redd.it"];
}

static BOOL ApolloURLIsRedditStaticPreview(NSString *urlString) {
    if (!ApolloURLHostIsRedditPreview(urlString)) return NO;
    NSString *lower = ApolloLowercaseString(urlString);
    return [lower containsString:@"format=png8"] || [lower containsString:@"format=pjpg"] || [lower containsString:@"format=webp"];
}

static BOOL ApolloURLIsRedditPseudoMP4GIF(NSString *urlString) {
    return ApolloURLHostIsRedditPreview(urlString) && [ApolloLowercaseString(urlString) containsString:@"format=mp4"];
}

static BOOL ApolloURLIsRedditHostedGIFSource(NSString *urlString) {
    if (!ApolloStringIsNonEmpty(urlString)) return NO;
    NSString *lower = ApolloLowercaseString(urlString);
    if ([lower containsString:@"i.redd.it"] && [lower hasSuffix:@".gif"]) return YES;
    if (ApolloURLIsRedditPseudoMP4GIF(urlString)) return YES;
    return NO;
}

BOOL ApolloMetadataEntryIsRedditHostedGIF(NSString *assetID, NSDictionary *entry) {
    if (!ApolloStringIsNonEmpty(assetID) || [assetID hasPrefix:@"giphy|"]) return NO;
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;

    if ([entry[@"m"] isEqualToString:@"image/gif"]) return YES;

    if ([entry[@"e"] isEqualToString:@"AnimatedImage"]) return YES;

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    if (source) {
        for (NSString *key in @[@"gif", @"mp4", @"u"]) {
            if (ApolloURLIsRedditHostedGIFSource(source[key])) return YES;
        }
    }

    return NO;
}

NSString *ApolloRedditHostedGIFDisplayURL(NSString *assetID) {
    if (!ApolloStringIsNonEmpty(assetID) || [assetID hasPrefix:@"giphy|"]) return nil;
    return [NSString stringWithFormat:@"https://i.redd.it/%@.gif", assetID];
}

NSDictionary *ApolloFixRedditHostedGifMetadata(NSDictionary *orig, NSUInteger *outFixedCount) {
    if (outFixedCount) *outFixedCount = 0;
    if (![orig isKindOfClass:[NSDictionary class]] || orig.count == 0) return orig;

    NSMutableDictionary *fixed = nil;
    NSUInteger fixedCount = 0;

    for (NSString *key in orig) {
        if (!ApolloStringIsNonEmpty(key) || [key hasPrefix:@"giphy|"]) continue;

        NSDictionary *entry = orig[key];
        if (!ApolloMetadataEntryIsRedditHostedGIF(key, entry)) continue;

        NSString *gifURL = ApolloRedditHostedGIFDisplayURL(key);
        if (!gifURL) continue;

        if (!fixed) fixed = [orig mutableCopy];

        NSDictionary *existingSource = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
        NSMutableDictionary *source = existingSource ? [existingSource mutableCopy] : [NSMutableDictionary dictionary];
        source[@"gif"] = gifURL;
        // MP4 preference must still resolve to an animatable GIF for Reddit uploads.
        source[@"mp4"] = gifURL;

        NSMutableDictionary *normalized = [entry mutableCopy];
        normalized[@"status"] = @"valid";
        normalized[@"e"] = @"AnimatedImage";
        normalized[@"m"] = @"image/gif";
        normalized[@"s"] = [source copy];
        normalized[@"id"] = key;
        fixed[key] = [normalized copy];
        fixedCount++;
    }

    if (outFixedCount) *outFixedCount = fixedCount;
    return fixed ?: orig;
}

static NSString *ApolloFirstNonPreviewSourceURL(NSDictionary *source, BOOL preferMP4ForExternalGIFs) {
    if (![source isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *keys = preferMP4ForExternalGIFs
        ? @[@"mp4", @"gif", @"u"]
        : @[@"gif", @"mp4", @"u"];

    for (NSString *key in keys) {
        NSString *candidate = source[key];
        if (!ApolloStringIsNonEmpty(candidate)) continue;
        if (ApolloURLIsRedditStaticPreview(candidate) || ApolloURLIsRedditPseudoMP4GIF(candidate)) continue;
        return candidate;
    }
    return nil;
}

NSString *ApolloMediaDisplayURLFromMetadataEntry(NSString *assetID,
                                                 NSDictionary *entry,
                                                 BOOL preferMP4ForExternalGIFs) {
    if (!ApolloStringIsNonEmpty(assetID) || ![entry isKindOfClass:[NSDictionary class]]) return nil;
    if (![[entry objectForKey:@"status"] isEqualToString:@"valid"]) return nil;

    if (ApolloMetadataEntryIsRedditHostedGIF(assetID, entry)) {
        return ApolloRedditHostedGIFDisplayURL(assetID);
    }

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    NSString *url = ApolloFirstNonPreviewSourceURL(source, preferMP4ForExternalGIFs);
    if (!url) {
        NSArray *previews = entry[@"p"];
        if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
            url = [previews.lastObject objectForKey:@"u"];
            if (ApolloURLIsRedditStaticPreview(url) || ApolloURLIsRedditPseudoMP4GIF(url)) {
                url = nil;
            }
        }
    }

    return ApolloStringIsNonEmpty(url) ? url : nil;
}
