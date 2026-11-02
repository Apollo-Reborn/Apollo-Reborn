#import <Foundation/Foundation.h>
#import "ApolloMediaMetadata.h"

// ApolloRepairFailedRedditGalleryMetadata (#1587). The failed entries below
// have exactly the shape Reddit returned for galleries posted through its API
// in October 2026: {"status": "failed"} and nothing else.

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSArray *Items(NSArray<NSString *> *mediaIDs) {
    NSMutableArray *items = [NSMutableArray array];
    NSInteger identifier = 1083144681;
    for (NSString *mediaID in mediaIDs) {
        [items addObject:@{@"is_deleted": @NO, @"media_id": mediaID, @"id": @(identifier++)}];
    }
    return items;
}

static NSDictionary *Failed(void) { return @{@"status": @"failed"}; }

static NSString *SourceURL(NSDictionary *metadata, NSString *mediaID) {
    return metadata[mediaID][@"s"][@"u"];
}

static void TestJPEGGalleryFromThumbnail(void) {
    NSDictionary *metadata = @{@"5faxz61jqgyh1": Failed(), @"51rdz81jqgyh1": Failed(), @"io9mw31jqgyh1": Failed()};
    NSString *thumbnail = @"https://preview.redd.it/5faxz61jqgyh1.jpeg?width=140&height=140&crop=1:1,smart&auto=webp&s=d5df065345f7bc34b2a5b94475b9f1b86445800e";
    NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"5faxz61jqgyh1", @"51rdz81jqgyh1", @"io9mw31jqgyh1"]), thumbnail, nil);
    Check(repaired.count == 3, @"every failed photo is rebuilt");
    for (NSString *mediaID in metadata) {
        NSDictionary *entry = repaired[mediaID];
        NSString *expected = [NSString stringWithFormat:@"https://i.redd.it/%@.jpeg", mediaID];
        Check([entry[@"status"] isEqualToString:@"valid"], @"rebuilt photo is valid, the only status RDKGallery keeps");
        Check([entry[@"e"] isEqualToString:@"Image"] && [entry[@"m"] isEqualToString:@"image/jpeg"], @"JPEG photo is a still image");
        Check([entry[@"id"] isEqualToString:mediaID], @"rebuilt entry keeps its media ID");
        Check([SourceURL(repaired, mediaID) isEqualToString:expected], @"source points at the i.redd.it original");
        Check([entry[@"s"][@"x"] integerValue] > 0 && [entry[@"s"][@"y"] integerValue] > 0, @"source has a non-zero size");
        NSArray *previews = entry[@"p"];
        Check(previews.count == 1 && [previews[0][@"u"] isEqualToString:expected], @"grid gets a preview to draw its tile");
        Check([ApolloMediaDisplayURLFromMetadataEntry(mediaID, entry, NO) isEqualToString:expected], @"display URL resolves to the original");
    }
}

static void TestThumbnailExtensionCarriesToTheRest(void) {
    NSDictionary *metadata = @{@"aaa111": Failed(), @"bbb222": Failed()};
    NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"aaa111", @"bbb222"]),
                                                                     @"https://preview.redd.it/aaa111.png?width=140&s=x", nil);
    Check([SourceURL(repaired, @"aaa111") isEqualToString:@"https://i.redd.it/aaa111.png"], @"first photo takes the thumbnail's extension");
    Check([SourceURL(repaired, @"bbb222") isEqualToString:@"https://i.redd.it/bbb222.png"], @"the rest share it");
    Check([repaired[@"bbb222"][@"m"] isEqualToString:@"image/png"], @"PNG photo has a PNG type");

    repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"aaa111", @"bbb222"]),
                                                      @"https://preview.redd.it/aaa111.jpg?width=140&s=x", nil);
    Check([SourceURL(repaired, @"bbb222") isEqualToString:@"https://i.redd.it/bbb222.jpg"], @".jpg galleries (PRAW-style file names) stay .jpg");
}

static void TestGIFThumbnailOnlyAppliesToItsPhoto(void) {
    NSDictionary *metadata = @{@"gif111": Failed(), @"jpg222": Failed()};
    NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"gif111", @"jpg222"]),
                                                                     @"https://preview.redd.it/gif111.gif?width=140&format=png8&s=x", nil);
    NSDictionary *gif = repaired[@"gif111"];
    Check([gif[@"e"] isEqualToString:@"AnimatedImage"] && [gif[@"m"] isEqualToString:@"image/gif"], @"GIF photo is animated");
    Check([gif[@"s"][@"gif"] isEqualToString:@"https://i.redd.it/gif111.gif"], @"GIF source has the animation");
    Check([gif[@"s"][@"mp4"] length] > 0, @"GIF source has an mp4 so Apollo doesn't open a web view");
    Check(ApolloMetadataEntryIsRedditHostedGIF(@"gif111", gif), @"rebuilt GIF reads as Reddit-hosted");
    Check([SourceURL(repaired, @"jpg222") isEqualToString:@"https://i.redd.it/jpg222.jpeg"], @"a GIF thumbnail doesn't make the other photos GIFs");
}

static void TestNoUsableThumbnailFallsBackToJPEG(void) {
    NSDictionary *metadata = @{@"aaa111": Failed(), @"bbb222": Failed()};
    for (NSString *thumbnail in @[@"", @"default", @"self", @"nsfw", @"https://example.com/aaa111.png",
                                  @"https://b.thumbs.redditmedia.com/abc.jpg"]) {
        NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"aaa111", @"bbb222"]), thumbnail, nil);
        Check([SourceURL(repaired, @"aaa111") isEqualToString:@"https://i.redd.it/aaa111.jpeg"],
              [NSString stringWithFormat:@"thumbnail %@ falls back to Apollo Reborn's .jpeg", thumbnail]);
    }
    NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"aaa111", @"bbb222"]), nil, nil);
    Check(repaired.count == 2, @"missing thumbnail still repairs");
}

static void TestOnlyFailedGalleryPhotosChange(void) {
    NSDictionary *valid = @{@"status": @"valid", @"e": @"Image", @"m": @"image/jpg",
                            @"s": @{@"u": @"https://preview.redd.it/ok1.jpg?width=800&s=sig", @"x": @800, @"y": @600}};
    NSDictionary *unprocessed = @{@"status": @"unprocessed"};
    NSDictionary *metadata = @{@"ok1": valid, @"bad2": Failed(), @"wait3": unprocessed, @"inline4": Failed()};
    NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"ok1", @"bad2", @"wait3"]), nil, nil);
    Check(repaired[@"ok1"] == valid, @"valid photo is untouched");
    Check([repaired[@"bad2"][@"status"] isEqualToString:@"valid"], @"failed photo is rebuilt");
    Check(repaired[@"wait3"] == unprocessed, @"still-processing photo is left for Reddit to finish");
    Check(repaired[@"inline4"] == metadata[@"inline4"], @"media outside the gallery order is untouched");
    Check(repaired.count == metadata.count, @"no entries are added or dropped");

    Check(ApolloRepairFailedRedditGalleryMetadata(@{@"ok1": valid}, Items(@[@"ok1"]), nil, nil) == nil, @"healthy gallery returns nil");
    Check(ApolloRepairFailedRedditGalleryMetadata(@{@"wait3": unprocessed}, Items(@[@"wait3"]), nil, nil) == nil, @"processing gallery returns nil");
}

static void TestPhotosThisDeviceUploaded(void) {
    NSDictionary *unprocessed = @{@"status": @"unprocessed"};
    NSDictionary *metadata = @{@"own111": unprocessed, @"own222": unprocessed, @"other333": unprocessed};
    NSDictionary *known = @{@"own111": @"jpeg", @"own222": @"GIF"};
    NSDictionary *repaired = ApolloRepairFailedRedditGalleryMetadata(metadata, Items(@[@"own111", @"own222", @"other333"]), nil, known);
    Check([SourceURL(repaired, @"own111") isEqualToString:@"https://i.redd.it/own111.jpeg"],
          @"own photo is rebuilt while still unprocessed, right after posting");
    Check([repaired[@"own222"][@"e"] isEqualToString:@"AnimatedImage"] &&
          [repaired[@"own222"][@"s"][@"gif"] isEqualToString:@"https://i.redd.it/own222.gif"],
          @"own GIF keeps the extension it was uploaded with");
    Check(repaired[@"other333"] == unprocessed, @"someone else's unprocessed photo is left alone");

    NSDictionary *failed = @{@"own111": Failed(), @"bbb222": Failed()};
    repaired = ApolloRepairFailedRedditGalleryMetadata(failed, Items(@[@"own111", @"bbb222"]),
                                                      @"https://preview.redd.it/own111.png?width=140&s=x", @{@"own111": @"gif"});
    Check([SourceURL(repaired, @"own111") isEqualToString:@"https://i.redd.it/own111.gif"], @"upload record beats the thumbnail");
    Check([SourceURL(repaired, @"bbb222") isEqualToString:@"https://i.redd.it/bbb222.png"], @"other photos still use the thumbnail");

    repaired = ApolloRepairFailedRedditGalleryMetadata(@{@"own111": unprocessed}, Items(@[@"own111"]), nil, @{@"own111": @"mp4"});
    Check(repaired == nil, @"a non-image upload record doesn't rebuild anything");
}

static void TestInputShapes(void) {
    NSDictionary *metadata = @{@"aaa111": Failed()};
    NSDictionary *fromRawJSON = ApolloRepairFailedRedditGalleryMetadata(metadata, @{@"items": Items(@[@"aaa111"])}, nil, nil);
    Check([fromRawJSON[@"aaa111"][@"status"] isEqualToString:@"valid"], @"raw gallery_data dictionary is accepted");

    Check(ApolloRepairFailedRedditGalleryMetadata(metadata, nil, nil, nil) == nil, @"no gallery order, no repair");
    Check(ApolloRepairFailedRedditGalleryMetadata(metadata, @[], nil, nil) == nil, @"empty gallery order, no repair");
    Check(ApolloRepairFailedRedditGalleryMetadata(nil, Items(@[@"aaa111"]), nil, nil) == nil, @"no metadata, no repair");
    Check(ApolloRepairFailedRedditGalleryMetadata(@{}, Items(@[@"aaa111"]), nil, nil) == nil, @"empty metadata, no repair");
    Check(ApolloRepairFailedRedditGalleryMetadata(metadata, @[@"aaa111", NSNull.null, @{@"media_id": @7}], nil, nil) == nil,
          @"malformed gallery items are skipped");

    NSDictionary *odd = @{@"../x?y": Failed(), @"a b": Failed()};
    Check(ApolloRepairFailedRedditGalleryMetadata(odd, Items(@[@"../x?y", @"a b"]), nil, nil) == nil,
          @"media IDs that aren't plain alphanumerics never reach a URL");
}

int main(void) {
    @autoreleasepool {
        TestJPEGGalleryFromThumbnail();
        TestThumbnailExtensionCarriesToTheRest();
        TestGIFThumbnailOnlyAppliesToItsPhoto();
        TestNoUsableThumbnailFallsBackToJPEG();
        TestOnlyFailedGalleryPhotosChange();
        TestPhotosThisDeviceUploaded();
        TestInputShapes();
        printf("reddit_gallery_repair_tests: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
