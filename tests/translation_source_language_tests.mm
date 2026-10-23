#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#import "TranslationSourceLanguage.inc"

static NSUInteger sChecks;

static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static id JSON(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

static BOOL SameString(NSString *a, NSString *b) {
    return (a == nil && b == nil) || [a isEqualToString:b];
}

#pragma mark - Google response parsing

// Real responses (2026-10-09) from the two endpoints the Google leg calls.
static void TestGoogleSourceLanguage(void) {
    // gtx (translate_a/single, dt=t): the detected source sits third at the top level.
    NSString *gtxSpanish = @"[[[\"Hello how are you? \",\"Hola, ¿cómo estás? \",null,null,10],[\"Very well thank you\",\"Muy bien gracias\",null,null,10]],null,\"es\",null,null,null,1,[],[[\"es\"],null,[1],[\"es\"]]]";
    Check(SameString(ApolloExtractGoogleSourceLanguage(JSON(gtxSpanish)), @"es"), @"gtx: multi-segment Spanish reports es");

    // The #1345 report: Google saw "Hi Victoria" as (low-confidence) Romanian and
    // handed it back unchanged — the marker had named Catalan.
    NSString *gtxUnchanged = @"[[[\"Hi Victoria\",\"Hi Victoria\",null,null,3,null,null,[[]],[[[\"1eb561d2d816b8957a38cd5018eb164c\",\"tea_AllEn_2022q2.md\"]]]]],null,\"ro\",null,null,null,0.46161,[],[[\"ro\"],null,[0.46161],[\"ro\"]]]";
    Check(SameString(ApolloExtractGoogleSourceLanguage(JSON(gtxUnchanged)), @"ro"), @"gtx: unchanged echo still reports its source");

    // clients5 (dict-chrome-ex): [["<translation>", "<source>"]].
    NSString *clients5 = @"[[\"Hello how are you? Very well thank you\",\"es\"]]";
    Check(SameString(ApolloExtractGoogleSourceLanguage(JSON(clients5)), @"es"), @"clients5: the pair's second string is the source");

    Check(ApolloExtractGoogleSourceLanguage(JSON(@"[[\"only the translation\"]]")) == nil, @"clients5 without a source → nil");
    Check(ApolloExtractGoogleSourceLanguage(JSON(@"[]")) == nil, @"empty array → nil");
    Check(ApolloExtractGoogleSourceLanguage(JSON(@"{\"translatedText\":\"x\"}")) == nil, @"a dictionary is not a Google shape → nil");
    Check(ApolloExtractGoogleSourceLanguage(@"plain string") == nil, @"a bare string → nil");
    // gtx's segment list must never be mistaken for a clients5 pair.
    Check(ApolloExtractGoogleSourceLanguage(JSON(@"[[[\"a\",\"b\",null,null,1]]]")) == nil, @"gtx segments without a source → nil");
}

#pragma mark - Reported-code normalization

static void TestNormalizedReportedSourceLanguage(void) {
    struct { NSString *reported; NSString *expected; } cases[] = {
        { @"es", @"es" },
        { @"EN", @"en" },
        { @"zh-CN", @"zh" },        // Google
        { @"zh-Hans", @"zh" },      // Azure
        { @"pt-PT", @"pt" },
        { @"mni-Mtei", @"mni" },
        { @"haw", @"haw" },
        { @"iw", @"he" },           // ISO 639's withdrawn codes Google still answers with
        { @"jw", @"jv" },
        { @"in", @"id" },
        { @"und", nil },
        { @"auto", nil },
        { @"e1", nil },
        { @"", nil },
        { nil, nil },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NSString *got = ApolloNormalizedReportedSourceLanguage(cases[i].reported);
        Check(SameString(got, cases[i].expected),
              [NSString stringWithFormat:@"'%@' → '%@' (expected '%@')", cases[i].reported, got, cases[i].expected]);
    }
}

#pragma mark - "Provider handed the original back"

static void TestTranslationChangesText(void) {
    // The #1345 comments: Google returned every one of these verbatim.
    for (NSString *body in @[ @"Hi Victoria", @"Romanceslop", @"Wordslop", @"YO ADEEEEEEE" ]) {
        Check(!ApolloTranslatedTextDiffersFromSource(body, body), [NSString stringWithFormat:@"'%@' echoed is unchanged", body]);
    }
    Check(!ApolloTranslatedTextDiffersFromSource(@"Wordslop ", @"wordslop"), @"case and trailing space are not a translation");
    Check(!ApolloTranslatedTextDiffersFromSource(@"lol\n\n![gif](giphy|ECtLJKdGj8jfy)", @"lol"),
          @"a media-id token the provider never saw is not a change");
    Check(ApolloTranslatedTextDiffersFromSource(@"Slopslop", @"Sloppy"), @"a real rewrite is a change");
    Check(ApolloTranslatedTextDiffersFromSource(@"Dankie vir alles my vriend", @"Thanks for everything my friend"), @"a translation is a change");
    Check(!ApolloTranslatedTextDiffersFromSource(@"![gif](giphy|abc)", @"x"), @"a media-only body has nothing to translate");
    Check(!ApolloTranslatedTextDiffersFromSource(@"Hola", nil), @"no reply is not a change");
}

#pragma mark - Store key

static void TestSourceLanguageKey(void) {
    NSString *key = ApolloTranslationSourceLanguageKey(@"Hi Victoria");
    Check(key.length == 32, @"key is 16 bytes of hex");
    // The request is made from the trimmed body, the marker from the raw one.
    Check(SameString(key, ApolloTranslationSourceLanguageKey(@"  hi   victoria\n")), @"case and whitespace fold to the same key");
    Check(SameString(ApolloTranslationSourceLanguageKey(@"lol"),
                     ApolloTranslationSourceLanguageKey(@"lol\n\n![gif](giphy|ECtLJKdGj8jfy)")),
          @"media-id tokens don't change the key");
    Check(!SameString(key, ApolloTranslationSourceLanguageKey(@"Hi Victoria!")), @"different text, different key");
    Check(ApolloTranslationSourceLanguageKey(@"") == nil && ApolloTranslationSourceLanguageKey(nil) == nil, @"no text, no key");
}

int main(void) {
    @autoreleasepool {
        TestGoogleSourceLanguage();
        TestNormalizedReportedSourceLanguage();
        TestTranslationChangesText();
        TestSourceLanguageKey();
        printf("translation source language tests passed (%lu checks)\n", (unsigned long)sChecks);
    }
    return 0;
}
