#import "ApolloInlineImageMetadata.h"

#import <dispatch/dispatch.h>
#import <math.h>

static BOOL ApolloInlineMetadataIsRedditImageHost(NSString *host) {
    NSString *lower = [host.lowercaseString copy];
    return [lower isEqualToString:@"redd.it"] || [lower hasSuffix:@".redd.it"];
}

static NSURL *ApolloInlineMetadataURL(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return nil;
    NSString *decoded = [value stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:decoded];
}

static BOOL ApolloInlineMetadataURLsMatch(NSURL *candidate, NSURL *target) {
    if (![candidate isKindOfClass:[NSURL class]] || ![target isKindOfClass:[NSURL class]]) return NO;
    if (!ApolloInlineMetadataIsRedditImageHost(candidate.host) ||
        !ApolloInlineMetadataIsRedditImageHost(target.host)) {
        return NO;
    }
    NSString *candidatePath = candidate.path;
    NSString *targetPath = target.path;
    return candidatePath.length > 0 && [candidatePath isEqualToString:targetPath];
}

static BOOL ApolloInlineMetadataEntryCanDescribeImage(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;

    NSString *status = [entry[@"status"] isKindOfClass:[NSString class]] ? entry[@"status"] : nil;
    if (status.length > 0 && ![status isEqualToString:@"valid"]) return NO;

    NSString *kind = [entry[@"e"] isKindOfClass:[NSString class]] ? entry[@"e"] : nil;
    if (kind.length > 0 && ![kind isEqualToString:@"Image"] &&
        ![kind isEqualToString:@"AnimatedImage"]) {
        return NO;
    }
    return YES;
}

static double ApolloInlineMetadataRatioFromDimensions(NSDictionary *dimensions) {
    if (![dimensions isKindOfClass:[NSDictionary class]]) return 0.0;
    id widthValue = dimensions[@"x"];
    id heightValue = dimensions[@"y"];
    if (![widthValue respondsToSelector:@selector(doubleValue)] ||
        ![heightValue respondsToSelector:@selector(doubleValue)]) {
        return 0.0;
    }
    double width = [widthValue doubleValue];
    double height = [heightValue doubleValue];
    if (!isfinite(width) || !isfinite(height) || width <= 0.0 || height <= 0.0) return 0.0;
    return height / width;
}

static double ApolloInlineMetadataRatioFromEntry(NSDictionary *entry) {
    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    double sourceRatio = ApolloInlineMetadataRatioFromDimensions(source);
    if (sourceRatio > 0.0) return sourceRatio;

    NSArray *previews = [entry[@"p"] isKindOfClass:[NSArray class]] ? entry[@"p"] : nil;
    NSDictionary *largest = nil;
    double largestArea = 0.0;
    for (id candidate in previews) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        double width = [candidate[@"x"] respondsToSelector:@selector(doubleValue)]
            ? [candidate[@"x"] doubleValue] : 0.0;
        double height = [candidate[@"y"] respondsToSelector:@selector(doubleValue)]
            ? [candidate[@"y"] doubleValue] : 0.0;
        double area = width * height;
        if (isfinite(area) && width > 0.0 && height > 0.0 && area > largestArea) {
            largest = candidate;
            largestArea = area;
        }
    }
    return ApolloInlineMetadataRatioFromDimensions(largest);
}

static BOOL ApolloInlineMetadataEntryMatchesURL(NSString *assetID,
                                                 NSDictionary *entry,
                                                 NSURL *url) {
    NSString *urlAssetID = [url.lastPathComponent stringByDeletingPathExtension];
    if (assetID.length > 0 && [assetID isEqualToString:urlAssetID]) return YES;

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    for (NSString *key in @[@"u", @"gif", @"mp4"]) {
        if (ApolloInlineMetadataURLsMatch(ApolloInlineMetadataURL(source[key]), url)) return YES;
    }
    NSArray *previews = [entry[@"p"] isKindOfClass:[NSArray class]] ? entry[@"p"] : nil;
    for (id candidate in previews) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        if (ApolloInlineMetadataURLsMatch(ApolloInlineMetadataURL(candidate[@"u"]), url)) return YES;
    }
    return NO;
}

double ApolloInlineImageAspectRatioFromMediaMetadata(NSURL *url, NSDictionary *mediaMetadata) {
    if (![url isKindOfClass:[NSURL class]] ||
        !ApolloInlineMetadataIsRedditImageHost(url.host) ||
        ![mediaMetadata isKindOfClass:[NSDictionary class]] ||
        mediaMetadata.count == 0) {
        return 0.0;
    }

    // Reddit's asset ID is the URL filename and the media_metadata key. When
    // present, that identity is stronger than scanning URL fields and avoids
    // depending on NSDictionary enumeration order.
    NSString *urlAssetID = [url.lastPathComponent stringByDeletingPathExtension];
    NSDictionary *directEntry = [mediaMetadata[urlAssetID] isKindOfClass:[NSDictionary class]]
        ? mediaMetadata[urlAssetID] : nil;
    if (ApolloInlineMetadataEntryCanDescribeImage(directEntry) &&
        ApolloInlineMetadataEntryMatchesURL(urlAssetID, directEntry, url)) {
        return ApolloInlineMetadataRatioFromEntry(directEntry);
    }

    NSDictionary *matchedEntry = nil;
    for (id key in mediaMetadata) {
        if (![key isKindOfClass:[NSString class]]) continue;
        NSDictionary *entry = [mediaMetadata[key] isKindOfClass:[NSDictionary class]]
            ? mediaMetadata[key] : nil;
        if (!ApolloInlineMetadataEntryCanDescribeImage(entry) ||
            !ApolloInlineMetadataEntryMatchesURL(key, entry, url)) {
            continue;
        }
        // A path scan is a fallback for metadata keys that are not the file's
        // asset ID. Refuse to guess if malformed metadata maps two entries to
        // the same URL.
        if (matchedEntry) return 0.0;
        matchedEntry = entry;
    }
    return ApolloInlineMetadataRatioFromEntry(matchedEntry);
}

// Asset ID -> height / width. An asset's dimensions do not depend on which
// comment, post, or account loaded it. NSCache is thread-safe (models parse off
// the main thread while Texture measures on background threads) and bounded so
// browsing cannot grow this process-wide lookup indefinitely.
static NSCache<NSString *, NSNumber *> *ApolloInlineMetadataRegisteredRatios(void) {
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 1024;
    });
    return cache;
}

void ApolloInlineImageRegisterMediaMetadata(NSDictionary *mediaMetadata) {
    if (![mediaMetadata isKindOfClass:[NSDictionary class]]) return;

    for (id key in mediaMetadata) {
        if (![key isKindOfClass:[NSString class]] || [key length] == 0) continue;
        NSDictionary *entry = [mediaMetadata[key] isKindOfClass:[NSDictionary class]]
            ? mediaMetadata[key] : nil;
        if (!ApolloInlineMetadataEntryCanDescribeImage(entry)) continue;

        double ratio = ApolloInlineMetadataRatioFromEntry(entry);
        if (ratio > 0.0) {
            // Reddit asset IDs are stable. If a later parse supplies different
            // valid dimensions for the same ID, prefer the latest authoritative
            // metadata; malformed/invalid entries never erase a known ratio.
            [ApolloInlineMetadataRegisteredRatios() setObject:@(ratio) forKey:key];
        }
    }
}

double ApolloInlineImageAspectRatioFromRegisteredMetadata(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] ||
        !ApolloInlineMetadataIsRedditImageHost(url.host)) {
        return 0.0;
    }

    NSString *assetID = [url.lastPathComponent stringByDeletingPathExtension];
    if (assetID.length == 0) return 0.0;
    return [[ApolloInlineMetadataRegisteredRatios() objectForKey:assetID] doubleValue];
}
