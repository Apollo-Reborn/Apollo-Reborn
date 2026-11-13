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

// #1665 (real Google replies, 2026-11-07 and 11-12). The shared compare stays
// exact: accents are real spelling, so it never folds them away.
static void TestRespellingIsJudgedOnlyOnUnsureReplies(void) {
    NSString *luka25 = [@"LUKA" stringByPaddingToLength:29 withString:@"A" startingAtIndex:0];
    NSString *luka26 = [@"LUKA" stringByPaddingToLength:30 withString:@"A" startingAtIndex:0];
    Check(ApolloTranslatedTextDiffersFromSource(@"sí", @"Sì"), @"review: sí → Sì (es → it) is a translation for every provider");
    Check(ApolloTranslatedTextDiffersFromSource(@"Dončić", @"Doncic"), @"the shared compare doesn't fold accents");
    Check(ApolloTranslatedTextDiffersFromSource(luka25, luka26), @"the shared compare doesn't fold stretched words");

    // What the unsure-guess check counts as a re-spelling.
    Check(ApolloGoogleReplyOnlyRespellsText(luka25, luka26), @"LUKA + 25 A's back with 26 (tl) only re-spells");
    Check(ApolloGoogleReplyOnlyRespellsText(@"LUKAAAAAA", @"LUKAAAAA"), @"one A fewer (haw) only re-spells");
    Check(ApolloGoogleReplyOnlyRespellsText(@"Hmmm!!!!", @"Hmmmmm!!!"), @"runs of 3+ of a letter or a mark fold together");
    Check(ApolloGoogleReplyOnlyRespellsText(@"Dončić", @"Doncic"), @"accents dropped only re-spell");
    Check(ApolloGoogleReplyOnlyRespellsText(@"😂😂😂😂", @"😂😂😂"), @"a repeated emoji folds like a letter");
    Check(ApolloGoogleReplyOnlyRespellsText(@"Hi Victoria", @"Hi Victoria"), @"an echo is no change either");
    Check(!ApolloGoogleReplyOnlyRespellsText(@"Kuminga", @"Kumiga"), @"a dropped letter is a rewrite");
    Check(!ApolloGoogleReplyOnlyRespellsText(@"Luka 3!!!", @"Wound 3!!!"), @"a name read as a word is a rewrite");
    Check(!ApolloGoogleReplyOnlyRespellsText(@"Nooo", @"No"), @"a double letter is not a run");
    Check(!ApolloGoogleReplyOnlyRespellsText(@"Jajaja", @"Ha ha ha"), @"a real rewrite of a laugh");
    Check(!ApolloGoogleReplyOnlyRespellsText(@"Hola", nil), @"no reply → nothing to compare");
}

#pragma mark - Google detection confidence

static NSString *const kJapaneseParagraph = @"今日は本当に楽しかったです。また明日も一緒に遊びに行きましょうね。";
static NSString *const kChineseParagraph = @"今天的比赛真的太精彩了，湖人队最后时刻的表现让人难以置信。";

static void TestGoogleSourceConfidence(void) {
    NSString *gtxLuka = @"[[[\"LUKAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"LUKAAAAAAAAAAAAAAAAAAAAAAAAAA\",null,null,3,null,null,[[]],[[[\"1eb561d2d816b8957a38cd5018eb164c\",\"tea_AllEn_2022q2.md\"]]]]],null,\"tl\",null,null,null,0.30606875,[],[[\"tl\"],null,[0.30606875],[\"tl\"]]]";
    NSNumber *luka = ApolloExtractGoogleSourceConfidence(JSON(gtxLuka));
    Check(luka && fabs(luka.doubleValue - 0.30606875) < 1e-9, @"gtx: confidence is seventh at the top level");
    NSString *gtxDanke = @"[[[\"Thanks\",\"Danke\",null,null,10]],null,\"de\",null,null,null,0.66015625,[],[[\"de\"],null,[0.66015625],[\"de\"]]]";
    Check(fabs(ApolloExtractGoogleSourceConfidence(JSON(gtxDanke)).doubleValue - 0.66015625) < 1e-9, @"gtx: Danke reads 0.66");
    NSString *gtxSpanish = @"[[[\"Hello how are you? \",\"Hola, ¿cómo estás? \",null,null,10]],null,\"es\",null,null,null,1,[],[[\"es\"],null,[1],[\"es\"]]]";
    Check(ApolloExtractGoogleSourceConfidence(JSON(gtxSpanish)).doubleValue == 1.0, @"gtx: a whole-number confidence reads 1");
    Check(ApolloExtractGoogleSourceConfidence(JSON(@"[[\"Hello\",\"es\"]]")) == nil, @"clients5 reports no confidence");
    Check(ApolloExtractGoogleSourceConfidence(JSON(@"[[],null,\"es\",null,null,null,null]")) == nil, @"null → nil");
    Check(ApolloExtractGoogleSourceConfidence(JSON(@"[[],null,\"es\",null,null,null,5]")) == nil, @"out of 0–1 → nil");
    Check(ApolloExtractGoogleSourceConfidence(JSON(@"{\"x\":1}")) == nil, @"not an array → nil");
}

static void TestShortForLanguageGuess(void) {
    Check(ApolloTextIsShortForLanguageGuess(@"LUKAAAAAAAAAAAAAAAAAAAAAAAAAA"), @"the reported stretched word is short");
    Check(ApolloTextIsShortForLanguageGuess(@"Luka Luka Luka Luka"), @"four words are short");
    Check(ApolloTextIsShortForLanguageGuess(@"Luka 3!!!"), @"a name and a number are short");
    Check(ApolloTextIsShortForLanguageGuess(@"APOLLOTRANSLATIONNAME0TOKEN szn"), @"a protected-name sentinel is one word");
    Check(ApolloTextIsShortForLanguageGuess(@"ありがとう"), @"one Japanese word is short");
    Check(!ApolloTextIsShortForLanguageGuess(kJapaneseParagraph), @"review: a Japanese paragraph is not one word");
    Check(!ApolloTextIsShortForLanguageGuess(kChineseParagraph), @"a Chinese paragraph is not one word");
    Check(!ApolloTextIsShortForLanguageGuess(@"วันนี้เกมสนุกมากจริงๆ ทีมเล่นได้ดีมาก"), @"a Thai sentence is not two words");
    Check(!ApolloTextIsShortForLanguageGuess(@"Kuminga to the bench again"), @"five words are not short");
    Check(!ApolloTextIsShortForLanguageGuess([@"LUKA" stringByPaddingToLength:45 withString:@"A" startingAtIndex:0]), @"over 40 characters is not short");
    Check(!ApolloTextIsShortForLanguageGuess(@"😂😂😂"), @"emoji alone have no words to judge");
    Check(!ApolloTextIsShortForLanguageGuess(@" \n "), @"no words → nothing to judge");
    Check(!ApolloTextIsShortForLanguageGuess(nil), @"no text → nothing to judge");
}

static void TestUnsureGoogleGuess(void) {
    NSString *luka25 = [@"LUKA" stringByPaddingToLength:29 withString:@"A" startingAtIndex:0];
    NSString *luka26 = [@"LUKA" stringByPaddingToLength:30 withString:@"A" startingAtIndex:0];
    NSString *luka60 = [@"LUKA" stringByPaddingToLength:64 withString:@"A" startingAtIndex:0];
    NSString *luka61 = [@"LUKA" stringByPaddingToLength:65 withString:@"A" startingAtIndex:0];
    // Hand the original back.
    Check(ApolloGoogleReplyIsUnsureGuess(luka25, luka26, @0.30606875), @"reported: LUKAAA… +1 A, tl 0.31");
    Check(ApolloGoogleReplyIsUnsureGuess(@"Kuminga", @"Kumiga", @0.32569098), @"Kuminga → Kumiga, mi 0.33");
    Check(ApolloGoogleReplyIsUnsureGuess(@"Luka Luka Luka Luka", @"Wounds Wounds Wounds Wounds", @0.46366933), @"four words, id 0.46");
    Check(ApolloGoogleReplyIsUnsureGuess(@"Vando szn", @"No. Vando", @0.48275268), @"Vando szn → No. Vando, hu 0.48");
    Check(ApolloGoogleReplyIsUnsureGuess(@"Ja.", @"And.", @0.44573644), @"Ja. → And., et 0.45");
    Check(ApolloGoogleReplyIsUnsureGuess(luka60, luka61, @0.3), @"a stretched word past 40 characters still only re-spells");
    Check(ApolloGoogleReplyIsUnsureGuess(@"Lets gooo Lukaaaa Doncic baby yesss", @"Lets goooo Lukaaaaa Doncic baby yesss", @0.3),
          @"longer text Google only re-spelled");
    // Keep Google's translation.
    Check(!ApolloGoogleReplyIsUnsureGuess(kJapaneseParagraph, @"I really enjoyed today. Let's go out together again tomorrow.", @0.45),
          @"review: a Japanese paragraph at 0.45 keeps its translation");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"sí", @"Sì", @0.6770428), @"review: sí → Sì (es 0.68) keeps its translation");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"Dončić", @"Doncic", @0.640625), @"a confident re-spelling (sl 0.64) stays Google's call");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"Danke", @"Thanks", @0.66015625), @"Danke de 0.66 → translate");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"Golazo", @"Great goal", @0.51953125), @"Golazo es 0.52 → translate");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"Golazo", @"Great goal", @0.5), @"exactly 0.5 → translate");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"Kuminga to the bench again", @"Kuminga to the bank again", @0.3), @"five words rewritten → translate");
    Check(!ApolloGoogleReplyIsUnsureGuess(@"Kuminga", @"Kumiga", nil), @"no confidence (clients5) → translate");
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
        TestRespellingIsJudgedOnlyOnUnsureReplies();
        TestGoogleSourceConfidence();
        TestShortForLanguageGuess();
        TestUnsureGoogleGuess();
        TestSourceLanguageKey();
        printf("translation source language tests passed (%lu checks)\n", (unsigned long)sChecks);
    }
    return 0;
}
