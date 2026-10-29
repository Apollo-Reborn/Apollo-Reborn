#import "ApolloMediaMetadata.h"

static BOOL ApolloStringIsNonEmpty(NSString *string) {
    return [string isKindOfClass:[NSString class]] && string.length > 0;
}

static NSString *ApolloLowercaseString(NSString *string) {
    return ApolloStringIsNonEmpty(string) ? string.lowercaseString : @"";
}

static BOOL ApolloURLHostIsRedditPreview(NSString *urlString) {
    NSString *lower = ApolloLowercaseString(urlString);
    return [lower containsString:@"preview.redd.it"];
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

// A Reddit-hosted GIF entry only needs our normalization when Reddit's own
// metadata is incomplete (e.g. a freshly uploaded GIF that came back not-yet
// "valid", missing the AnimatedImage type, or lacking a usable source URL).
// Healthy entries — which already carry an efficient signed
// `preview.redd.it/<id>.gif?format=mp4` in `s.mp4` that the gallery/album
// viewer streams — must be left untouched so we don't downgrade playback to
// the full `i.redd.it/<id>.gif`.
static BOOL ApolloRedditHostedGifEntryNeedsNormalization(NSDictionary *entry) {
    if (![[entry objectForKey:@"status"] isEqualToString:@"valid"]) return YES;
    if (![[entry objectForKey:@"e"] isEqualToString:@"AnimatedImage"]) return YES;
    if (![[entry objectForKey:@"m"] isEqualToString:@"image/gif"]) return YES;
    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    if (!ApolloStringIsNonEmpty(source[@"gif"])) return YES;
    if (!ApolloStringIsNonEmpty(source[@"mp4"])) return YES;
    return NO;
}

NSDictionary *ApolloFixRedditHostedGifMetadata(NSDictionary *orig, NSUInteger *outFixedCount) {
    if (outFixedCount) *outFixedCount = 0;
    if (![orig isKindOfClass:[NSDictionary class]] || orig.count == 0) return orig;

    NSMutableDictionary *fixed = nil;
    NSUInteger fixedCount = 0;

    for (NSString *key in orig) {
        NSDictionary *entry = orig[key];
        if (!ApolloMetadataEntryIsRedditHostedGIF(key, entry)) continue;
        // Only repair entries Reddit returned incomplete. Skipping healthy
        // entries preserves their efficient signed `preview.redd.it ...
        // format=mp4` source, fixing the regression where the gallery viewer
        // started streaming full `i.redd.it/<id>.gif` files (stuck spinner).
        if (!ApolloRedditHostedGifEntryNeedsNormalization(entry)) continue;

        NSString *gifURL = ApolloRedditHostedGIFDisplayURL(key);
        if (!fixed) fixed = [orig mutableCopy];

        NSDictionary *existingSource = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
        NSMutableDictionary *source = existingSource ? [existingSource mutableCopy] : [NSMutableDictionary dictionary];
        // Synthesize only the source URLs Reddit left missing. Never overwrite
        // an existing value: a present `mp4` is Reddit's efficient signed
        // preview that the gallery streams, and a present `gif` already points
        // at the animatable i.redd.it asset. A missing `mp4` must still resolve
        // to an animatable GIF (otherwise Apollo opens it in a webview).
        if (!ApolloStringIsNonEmpty(source[@"gif"])) source[@"gif"] = gifURL;
        if (!ApolloStringIsNonEmpty(source[@"mp4"])) source[@"mp4"] = gifURL;

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

// MARK: - Failed gallery items (#1587)

// Placeholder size for rebuilt items: Reddit sends no dimensions with a failed
// entry. The comments grid crops its tiles and the media viewer sizes each
// photo from the downloaded image; the feed carousel, which sizes its card
// from these, shows a square card with the photo letterboxed inside.
static const NSInteger kApolloRepairedGalleryItemSide = 1080;

static BOOL ApolloRedditMediaIDIsPlain(NSString *mediaID) {
    if (!ApolloStringIsNonEmpty(mediaID) || mediaID.length > 64) return NO;
    static NSCharacterSet *disallowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        disallowed = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet];
    });
    return [mediaID rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

static NSString *ApolloRepairedGalleryMIMEType(NSString *extension) {
    if ([extension isEqualToString:@"png"]) return @"image/png";
    if ([extension isEqualToString:@"gif"]) return @"image/gif";
    if ([extension isEqualToString:@"webp"]) return @"image/webp";
    return @"image/jpeg";
}

// Reddit renders a gallery's thumbnail from its first photo, keeping that
// photo's media ID and file extension in the path:
// https://preview.redd.it/<media_id>.<ext>?width=140&...
static NSString *ApolloGalleryThumbnailExtension(NSString *thumbnailURL, NSString **outMediaID) {
    if (outMediaID) *outMediaID = nil;
    if (!ApolloStringIsNonEmpty(thumbnailURL)) return nil;
    NSURL *url = [NSURL URLWithString:thumbnailURL];
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"preview.redd.it"] && ![host isEqualToString:@"i.redd.it"]) return nil;
    NSString *name = url.path.lastPathComponent;
    NSString *extension = name.pathExtension.lowercaseString;
    if (![@[@"jpg", @"jpeg", @"png", @"gif", @"webp"] containsObject:extension]) return nil;
    if (outMediaID) *outMediaID = name.stringByDeletingPathExtension;
    return extension;
}

NSDictionary *ApolloRepairFailedRedditGalleryMetadata(NSDictionary *metadata, id galleryItems, NSString *thumbnailURL,
                                                       NSDictionary<NSString *, NSString *> *knownExtensions) {
    if (![metadata isKindOfClass:[NSDictionary class]] || metadata.count == 0) return nil;
    // RDKLink.galleryData is gallery_data.items; raw post JSON has the
    // gallery_data dictionary around it.
    if ([galleryItems isKindOfClass:[NSDictionary class]]) galleryItems = ((NSDictionary *)galleryItems)[@"items"];
    if (![galleryItems isKindOfClass:[NSArray class]] || [galleryItems count] == 0) return nil;

    NSString *thumbnailMediaID = nil;
    NSString *thumbnailExtension = ApolloGalleryThumbnailExtension(thumbnailURL, &thumbnailMediaID);
    // The thumbnail's extension is exact for the first photo. Apollo's
    // composer re-encodes every photo it posts as JPEG, and other API clients
    // upload a gallery in one format, so it stands in for the rest too, unless
    // it's a GIF. With no usable thumbnail (the first seconds after posting),
    // fall back to the .jpeg Apollo Reborn names its uploads with.
    NSString *defaultExtension = (thumbnailExtension && ![thumbnailExtension isEqualToString:@"gif"]) ? thumbnailExtension : @"jpeg";

    NSMutableDictionary *repaired = nil;
    for (id item in (NSArray *)galleryItems) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *mediaID = ((NSDictionary *)item)[@"media_id"];
        if (!ApolloRedditMediaIDIsPlain(mediaID)) continue;
        NSDictionary *entry = [metadata[mediaID] isKindOfClass:[NSDictionary class]] ? metadata[mediaID] : nil;
        NSString *knownExtension = [knownExtensions[mediaID] isKindOfClass:[NSString class]] ? knownExtensions[mediaID].lowercaseString : nil;
        if (![@[@"jpg", @"jpeg", @"png", @"gif", @"webp"] containsObject:knownExtension ?: @""]) knownExtension = nil;
        // Such a gallery reads "unprocessed" for its first ~2 seconds, which is
        // when "Posted! Tap to view" opens it. Only photos this device just
        // uploaded are taken out of that state early: anyone else's may still
        // be on their way to "valid".
        BOOL failed = [entry[@"status"] isEqual:@"failed"];
        BOOL ownUnprocessed = knownExtension && [entry[@"status"] isEqual:@"unprocessed"];
        if (!failed && !ownUnprocessed) continue;

        NSString *extension = knownExtension ?: ([mediaID isEqualToString:thumbnailMediaID] ? thumbnailExtension : defaultExtension);
        NSString *url = [NSString stringWithFormat:@"https://i.redd.it/%@.%@", mediaID, extension];
        BOOL animated = [extension isEqualToString:@"gif"];
        NSNumber *side = @(kApolloRepairedGalleryItemSide);
        NSMutableDictionary *source = [@{@"u": url, @"x": side, @"y": side} mutableCopy];
        if (animated) {
            // Same shape ApolloFixRedditHostedGifMetadata gives a GIF: without
            // an mp4, Apollo opens an animated item in a web view.
            source[@"gif"] = url;
            source[@"mp4"] = url;
        }

        if (!repaired) repaired = [metadata mutableCopy];
        repaired[mediaID] = @{
            @"status": @"valid",
            @"e": animated ? @"AnimatedImage" : @"Image",
            @"m": ApolloRepairedGalleryMIMEType(extension),
            @"id": mediaID,
            @"s": [source copy],
            // The grid draws its tiles from `p` and shows nothing without one.
            // Reddit's resized previews need a signature, so reuse the original.
            @"p": @[@{@"u": url, @"x": side, @"y": side}],
        };
    }
    return [repaired copy];
}
