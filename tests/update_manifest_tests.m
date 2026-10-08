#import <Foundation/Foundation.h>
#import "ApolloUpdateManifest.h"

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static NSDictionary *SampleManifest(void) {
    return @{
        @"release": @{
            @"tag": @"v1.15.11_3.9.0",
            @"name": @"v3.9.0 - Headline",
            @"url": @"https://github.com/Apollo-Reborn/Apollo-Reborn/releases/tag/v1.15.11_3.9.0",
            @"tweakVersion": @"3.9.0",
        },
        @"variants": @{
            @"standard": @{
                @"sourceURL": @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps.json",
                @"directDownloadURL": @"https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0.ipa",
                @"size": @96696713,
            },
            @"glass": @{
                @"sourceURL": @"http://insecure.example/apps_glass.json",
                @"directDownloadURL": @"javascript:alert(1)",
            },
        },
    };
}

static void TestVersionCompare(void) {
    CHECK(ApolloUpdateCompareVersions(@"3.8.5", @"3.9.0") == NSOrderedAscending, @"3.8.5 < 3.9.0");
    CHECK(ApolloUpdateCompareVersions(@"3.10.0", @"3.9.0") == NSOrderedDescending, @"3.10.0 > 3.9.0 (numeric, not lexical)");
    CHECK(ApolloUpdateCompareVersions(@"v3.9.0", @"3.9.0") == NSOrderedSame, @"leading v ignored");
    CHECK(ApolloUpdateCompareVersions(@"3.9", @"3.9.0") == NSOrderedSame, @"missing component is 0");
    CHECK(ApolloUpdateCompareVersions(@"3.9.0-4", @"3.9.0") == NSOrderedSame, @"dpkg revision ignored");
    CHECK(ApolloUpdateCompareVersions(@"3.9.1", @"3.9.0-4") == NSOrderedDescending, @"patch beats revision");
    CHECK(ApolloUpdateCompareVersions(@"4.0.0", @"3.99.99") == NSOrderedDescending, @"major wins");
    CHECK(ApolloUpdateCompareVersions(@"3.9.0b", @"3.9.0") == NSOrderedSame, @"lettered suffix reads as 0 tail");
}

static void TestVariantKeys(void) {
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"ipa") isEqualToString:@"standard"], @"ipa");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"ipa-noext") isEqualToString:@"noExtensions"], @"ipa-noext");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glass") isEqualToString:@"glass"], @"glass");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glass-noext") isEqualToString:@"noExtensionsGlass"], @"glass-noext");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glassicons") isEqualToString:@"glassIcons"], @"glassicons");
    CHECK([ApolloUpdateManifestKeyForBuildVariant(@"glassicons-noext") isEqualToString:@"noExtensionsGlassIcons"], @"glassicons-noext");
    CHECK(ApolloUpdateManifestKeyForBuildVariant(@"deb-rootless") == nil, @"deb has no IPA variant");
    CHECK(ApolloUpdateManifestKeyForBuildVariant(@"unknown") == nil, @"unknown");
    CHECK(ApolloUpdateManifestKeyForBuildVariant(nil) == nil, @"nil");
}

static void TestManifestParse(void) {
    ApolloUpdateInfo *info = ApolloUpdateInfoFromManifest(SampleManifest(), @"standard");
    CHECK(info != nil, @"parses");
    CHECK([info.version isEqualToString:@"3.9.0"], @"version %@", info.version);
    CHECK([info.releaseURL.host isEqualToString:@"github.com"], @"release url");
    CHECK([info.sourceURL.lastPathComponent isEqualToString:@"apps.json"], @"source url");
    CHECK([info.downloadURL.lastPathComponent isEqualToString:@"Apollo-Reborn-3.9.0.ipa"], @"download url");
    CHECK([info.notesSourceURL isEqual:info.sourceURL], @"a known variant reads its own notes");
    CHECK(info.handoff == ApolloUpdateHandoffNone, @"the parser leaves the handoff to the caller");

    ApolloUpdateInfo *noVariant = ApolloUpdateInfoFromManifest(SampleManifest(), nil);
    CHECK(noVariant != nil && noVariant.sourceURL == nil && noVariant.downloadURL == nil, @"nil variant leaves URLs unset");
    CHECK([noVariant.notesSourceURL.lastPathComponent isEqualToString:@"apps.json"], @"nil variant reads the standard notes");

    ApolloUpdateInfo *unknown = ApolloUpdateInfoFromManifest(SampleManifest(), @"nonexistent");
    CHECK(unknown != nil && unknown.sourceURL == nil, @"unknown variant key leaves URLs unset");
    CHECK(unknown.notesSourceURL != nil, @"unknown variant key still reads the standard notes");

    ApolloUpdateInfo *insecure = ApolloUpdateInfoFromManifest(SampleManifest(), @"glass");
    CHECK(insecure != nil && insecure.sourceURL == nil && insecure.downloadURL == nil, @"non-https URLs dropped");
    CHECK([insecure.notesSourceURL.lastPathComponent isEqualToString:@"apps.json"], @"an unusable variant source falls back to the standard notes");

    NSDictionary *noStandard = @{@"release": @{@"tweakVersion": @"3.9.0"}, @"variants": @{}};
    CHECK(ApolloUpdateInfoFromManifest(noStandard, nil).notesSourceURL == nil, @"no source anywhere means no notes source");

    CHECK(ApolloUpdateInfoFromManifest(nil, @"standard") == nil, @"nil manifest");
    CHECK(ApolloUpdateInfoFromManifest(@[@1], @"standard") == nil, @"array manifest");
    CHECK(ApolloUpdateInfoFromManifest(@{@"release": @{}}, @"standard") == nil, @"missing tweakVersion");
    CHECK(ApolloUpdateInfoFromManifest(@{@"release": @{@"tweakVersion": @"latest"}}, nil) == nil, @"non-numeric version");
    CHECK(ApolloUpdateInfoFromManifest(@{@"release": @{@"tweakVersion": @3}}, nil) == nil, @"wrong-typed version");
}

static void TestSideloaderURLs(void) {
    NSURL *source = [NSURL URLWithString:@"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_noext.json"];

    NSURL *alt = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderAltStore, source);
    CHECK([alt.scheme isEqualToString:@"altstore-classic"] && [alt.host isEqualToString:@"source"], @"altstore %@", alt);
    CHECK([alt.absoluteString containsString:@"url=https"], @"altstore carries the source %@", alt);

    NSURL *side = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderSideStore, source);
    CHECK([side.scheme isEqualToString:@"sidestore"] && [side.host isEqualToString:@"source"], @"sidestore %@", side);

    NSURL *feather = ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderFeather, source);
    CHECK([feather.absoluteString isEqualToString:
           @"feather://source/https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_noext.json"],
          @"feather %@", feather);

    CHECK(ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloaderFlareStore, source) == nil, @"flarestore takes the IPA, not the source");

    // The source must round-trip out of the query intact.
    NSURLComponents *parsed = [NSURLComponents componentsWithURL:side resolvingAgainstBaseURL:NO];
    NSString *roundTrip = nil;
    for (NSURLQueryItem *item in parsed.queryItems) if ([item.name isEqualToString:@"url"]) roundTrip = item.value;
    CHECK([roundTrip isEqualToString:source.absoluteString], @"round trip %@", roundTrip);
}

static void TestInstallURLs(void) {
    NSURL *ipa = [NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn/releases/download/v1.15.11_3.9.0/Apollo-Reborn-3.9.0-GLASS.ipa"];
    NSURL *feather = ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFeather, ipa);
    CHECK([feather.absoluteString isEqualToString:[@"feather://install/" stringByAppendingString:ipa.absoluteString]], @"feather install %@", feather);
    NSURL *flare = ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderFlareStore, ipa);
    CHECK([flare.absoluteString isEqualToString:[@"flarestore://downloadApp=" stringByAppendingString:ipa.absoluteString]], @"flarestore download %@", flare);
    CHECK(ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderAltStore, ipa) == nil, @"altstore has no documented install link");
    CHECK(ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloaderSideStore, ipa) == nil, @"sidestore has no documented install link");
}

static void TestLaunchAndHandoffURLs(void) {
    CHECK([ApolloUpdateSideloaderLaunchURL(ApolloUpdateSideloaderAltStore).absoluteString isEqualToString:@"altstore-classic://"], @"altstore launch");
    CHECK([ApolloUpdateSideloaderLaunchURL(ApolloUpdateSideloaderSideStore).absoluteString isEqualToString:@"sidestore://"], @"sidestore launch");
    CHECK([ApolloUpdateSideloaderLaunchURL(ApolloUpdateSideloaderFeather).absoluteString isEqualToString:@"feather://"], @"feather launch");
    CHECK([ApolloUpdateSideloaderLaunchURL(ApolloUpdateSideloaderFlareStore).absoluteString isEqualToString:@"flarestore://"], @"flarestore launch");

    ApolloUpdateInfo *info = ApolloUpdateInfoFromManifest(SampleManifest(), @"standard");
    info.handoff = ApolloUpdateHandoffExact;
    NSString *ipa = info.downloadURL.absoluteString;
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderAltStore, info).scheme isEqualToString:@"altstore-classic"]
          && [ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderAltStore, info).host isEqualToString:@"source"], @"exact altstore adds the source");
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderSideStore, info).host isEqualToString:@"source"], @"exact sidestore adds the source");
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderFeather, info).absoluteString isEqualToString:[@"feather://install/" stringByAppendingString:ipa]], @"exact feather installs the IPA");
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderFlareStore, info).absoluteString isEqualToString:[@"flarestore://downloadApp=" stringByAppendingString:ipa]], @"exact flarestore downloads the IPA");

    // Feather without an IPA link falls back to the source link; FlareStore has none, so it opens bare.
    info.downloadURL = nil;
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderFeather, info).absoluteString hasPrefix:@"feather://source/https://"], @"feather falls back to the source");
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderFlareStore, info).absoluteString isEqualToString:@"flarestore://"], @"flarestore without an IPA opens bare");

    // An unknown variant must never carry a variant-specific payload, even if one were set.
    info = ApolloUpdateInfoFromManifest(SampleManifest(), @"standard");
    info.handoff = ApolloUpdateHandoffOpenApp;
    for (ApolloUpdateSideloader s = ApolloUpdateSideloaderAltStore; s <= ApolloUpdateSideloaderFlareStore; s++) {
        CHECK([ApolloUpdateSideloaderHandoffURL(s, info) isEqual:ApolloUpdateSideloaderLaunchURL(s)], @"open-app handoff is the bare launch for %ld", (long)s);
    }
    info.handoff = ApolloUpdateHandoffNone;
    CHECK([ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloaderFeather, info).absoluteString isEqualToString:@"feather://"], @"no handoff also opens bare");
}

static void TestNormalizedVersion(void) {
    CHECK([ApolloUpdateNormalizedVersion(@"v3.9.0") isEqualToString:@"3.9.0"], @"leading v");
    CHECK([ApolloUpdateNormalizedVersion(@"3.9.0-4") isEqualToString:@"3.9.0"], @"dpkg revision");
    CHECK([ApolloUpdateNormalizedVersion(@"v3.9.0-12") isEqualToString:@"3.9.0"], @"both");
    CHECK([ApolloUpdateNormalizedVersion(@"3.9.0b") isEqualToString:@"3.9.0b"], @"a lettered suffix is a different version");
    CHECK([ApolloUpdateNormalizedVersion(@"3.9.0-beta") isEqualToString:@"3.9.0-beta"], @"a non-numeric tail stays");
    CHECK([ApolloUpdateNormalizedVersion(@" 3.9.0\n") isEqualToString:@"3.9.0"], @"whitespace trimmed");
}

static void TestReleaseNotesParse(void) {
    NSString *body = @"Liquid Glass build.\n\nFeatures\n- Add Google Search to the Search tab (#1260: @icpryde)\n- Open the viewer menu where you hold (#1254: @IllIIllIllIllII)\n\nFixes\n- Fix a crash (#1251, #1252: @icpryde, @other)\n- Plain bullet with no credit\n- Mentions (a thing) mid-sentence and ends (#7)\n";
    NSArray<ApolloUpdateNoteBlock *> *blocks = ApolloUpdateParseReleaseNotes(body);
    CHECK(blocks.count == 8, @"block count %lu", (unsigned long)blocks.count);
    CHECK(blocks[0].kind == ApolloUpdateNoteKindParagraph && [blocks[0].text isEqualToString:@"Liquid Glass build."], @"intro paragraph");
    CHECK(blocks[1].kind == ApolloUpdateNoteKindHeading && [blocks[1].text isEqualToString:@"Features"], @"heading above bullets");
    CHECK(blocks[2].kind == ApolloUpdateNoteKindBullet && [blocks[2].text isEqualToString:@"Add Google Search to the Search tab"], @"bullet text without credit: %@", blocks[2].text);
    CHECK([blocks[2].credit isEqualToString:@"#1260: @icpryde"], @"credit %@", blocks[2].credit);
    CHECK([blocks[5].credit isEqualToString:@"#1251, #1252: @icpryde, @other"], @"multi credit %@", blocks[5].credit);
    CHECK(blocks[6].credit == nil && [blocks[6].text isEqualToString:@"Plain bullet with no credit"], @"no credit");
    CHECK([blocks[7].credit isEqualToString:@"#7"] && [blocks[7].text isEqualToString:@"Mentions (a thing) mid-sentence and ends"], @"credit only at the end: %@ | %@", blocks[7].text, blocks[7].credit);
    CHECK(ApolloUpdateParseReleaseNotes(nil).count == 0 && ApolloUpdateParseReleaseNotes((id)@3).count == 0 && ApolloUpdateParseReleaseNotes(@"\n \n").count == 0, @"junk input is empty");
}

static NSDictionary *SampleSource(void) {
    return @{@"apps": @[@{
        @"bundleIdentifier": @"com.christianselig.Apollo",
        @"version": @"3.9.0",
        @"versionDescription": @"Top level notes",
        @"versions": @[
            @{@"version": @"3.9.0", @"date": @"2026-10-01T02:00:00Z", @"localizedDescription": @"Newest\n\nFeatures\n- New thing (#1: @a)"},
            @{@"version": @"3.8.5", @"date": @"2026-09-29T02:39:57Z", @"localizedDescription": @"Middle\n- Middle thing"},
            @{@"version": @"3.8.0", @"date": @"2026-09-25T02:15:27Z", @"localizedDescription": @"Installed one"},
            @{@"version": @"4.0.0", @"localizedDescription": @"Too new"},
            @{@"version": @"3.8.9", @"localizedDescription": @""},
        ]}]};
}

static void TestReleaseNotesFromSource(void) {
    NSArray<ApolloUpdateReleaseNotes *> *notes = ApolloUpdateReleaseNotesFromSource(SampleSource(), @"3.8.0", @"3.9.0");
    CHECK(notes.count == 2, @"two releases in range, got %lu", (unsigned long)notes.count);
    CHECK([notes[0].version isEqualToString:@"3.9.0"] && [notes[1].version isEqualToString:@"3.8.5"], @"newest first");
    CHECK(notes[0].date != nil && notes[1].date != nil, @"dates parsed");
    CHECK(notes[0].blocks.count == 3, @"blocks parsed %lu", (unsigned long)notes[0].blocks.count);
    CHECK(ApolloUpdateReleaseNotesFromSource(SampleSource(), @"3.9.0", @"3.9.0").count == 0, @"nothing newer than installed");
    CHECK(ApolloUpdateReleaseNotesFromSource(SampleSource(), @"3.8.0", @"3.8.5").count == 1, @"latest bounds the range");

    NSDictionary *flat = @{@"apps": @[@{@"bundleIdentifier": @"com.christianselig.Apollo", @"version": @"3.9.0",
                                        @"versionDate": @"2026-10-01T02:00:00Z", @"versionDescription": @"Top level notes"}]};
    NSArray<ApolloUpdateReleaseNotes *> *fallback = ApolloUpdateReleaseNotesFromSource(flat, @"3.8.5", @"3.9.0");
    CHECK(fallback.count == 1 && [fallback[0].version isEqualToString:@"3.9.0"], @"falls back to versionDescription");

    NSMutableArray *many = [NSMutableArray array];
    for (int i = 1; i <= 12; i++) [many addObject:@{@"version": [NSString stringWithFormat:@"3.9.%d", i], @"localizedDescription": @"x"}];
    NSDictionary *big = @{@"apps": @[@{@"versions": many}]};
    NSArray<ApolloUpdateReleaseNotes *> *capped = ApolloUpdateReleaseNotesFromSource(big, @"3.9.0", @"3.9.12");
    CHECK(capped.count == 8 && [capped[0].version isEqualToString:@"3.9.12"], @"capped at 8, newest first");

    NSDictionary *twoApps = @{@"apps": @[@{@"bundleIdentifier": @"other.app", @"version": @"3.9.0", @"versionDescription": @"wrong"},
                                          @{@"bundleIdentifier": @"com.christianselig.Apollo", @"version": @"3.9.0", @"versionDescription": @"right"}]};
    NSArray<ApolloUpdateReleaseNotes *> *picked = ApolloUpdateReleaseNotesFromSource(twoApps, @"3.8.0", @"3.9.0");
    CHECK(picked.count == 1 && [picked[0].blocks[0].text isEqualToString:@"right"], @"prefers Apollo's bundle id");

    CHECK(ApolloUpdateReleaseNotesFromSource(nil, @"3.8.0", @"3.9.0").count == 0 && ApolloUpdateReleaseNotesFromSource(@[@1], @"3.8.0", @"3.9.0").count == 0
          && ApolloUpdateReleaseNotesFromSource(@{@"apps": @[]}, @"3.8.0", @"3.9.0").count == 0, @"bad sources are empty");
}

int main(void) {
    @autoreleasepool {
        TestVersionCompare();
        TestVariantKeys();
        TestManifestParse();
        TestSideloaderURLs();
        TestInstallURLs();
        TestLaunchAndHandoffURLs();
        TestNormalizedVersion();
        TestReleaseNotesParse();
        TestReleaseNotesFromSource();
    }
    if (sFailures) {
        fprintf(stderr, "update_manifest_tests: %d check(s) failed\n", sFailures);
        return 1;
    }
    printf("update_manifest_tests: all checks passed\n");
    return 0;
}
