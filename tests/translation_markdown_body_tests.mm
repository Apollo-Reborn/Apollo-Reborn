#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

// The extracted ApolloTranslation.xm helpers use UIKit font types; AppKit's have
// the same shape for everything they touch.
#define UIFont NSFont
#define UIFontDescriptor NSFontDescriptor
#define UIFontDescriptorSymbolicTraits NSFontDescriptorSymbolicTraits
#define UIFontDescriptorTraitBold NSFontDescriptorTraitBold
#define UIFontDescriptorTraitItalic NSFontDescriptorTraitItalic

#import "TranslationMarkdown.inc"

static NSUInteger sChecks;

static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

#pragma mark - Body matching (raw markdown vs Apollo's rendered text)

// Real pairs from r/de threads 1wsbvea / 1wsnt1e / 1wsxfr0 (2026-09-29): the comment's
// comment.body, and the MarkdownTextNode string Apollo rendered from it. On main
// none of these matched, so each translation was fetched and never applied.
typedef struct {
    NSString *name;
    NSString *raw;
    NSString *rendered;
} BodyPair;

static NSArray<NSValue *> *AllPairs(BodyPair *pairs, NSUInteger count) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [out addObject:[NSValue valueWithPointer:&pairs[i]]];
    return out;
}

static void TestRealPairsMatch(void) {
    static BodyPair pairs[] = {
        { @"t1_pcknfzt quote + link (the report)",
          @">Zur Begründung ihres Antrags hatten AfD und CDU angeführt, viele Bürger, Angehörige und Initiativen empfänden Stolpersteine im Gehwegbereich als keine angemessene Form des Erinnerns. [...] Statt weiterer Stolpersteine soll das Gedenken künftig vor allem auf dem Nordfriedhof der Stadt stattfinden. [Quelle](https://www.tagesschau.de/inland/regional/sachsen/afd-cdu-antrag-beschlossen,stolpersteine-heidenau-100.html)\n\nOffiziell, weil man verhindern will, dass die Namen der Opfer \"mit Füßen getreten\" werden. Inoffiziell halt zur Verbesserung des Stadtbilds™ - hat schon einen Grund, dass die Stimmen dafür von CDU und AfD kamen. Gedenken, klar, aber bitte schön fernab des Alltags.",
          @"\tZur Begründung ihres Antrags hatten AfD und CDU angeführt, viele Bürger, Angehörige und Initiativen empfänden Stolpersteine im Gehwegbereich als keine angemessene Form des Erinnerns. […] Statt weiterer Stolpersteine soll das Gedenken künftig vor allem auf dem Nordfriedhof der Stadt stattfinden. Quelle\n\nOffiziell, weil man verhindern will, dass die Namen der Opfer “mit Füßen getreten” werden. Inoffiziell halt zur Verbesserung des Stadtbilds™ - hat schon einen Grund, dass die Stimmen dafür von CDU und AfD kamen. Gedenken, klar, aber bitte schön fernab des Alltags." },
        { @"t1_pcmjatq leading link",
          @"Gabs schonmal: [https://www.der-postillon.com/2014/01/ex-kanzleramtsminister-ronald-pofalla.html](https://www.der-postillon.com/2014/01/ex-kanzleramtsminister-ronald-pofalla.html)\n\nInklusive Vordatierung um einen Tag",
          @"Gabs schonmal: https://www.der-postillon.com/2014/01/ex-kanzleramtsminister-ronald-pofalla.html\n\nInklusive Vordatierung um einen Tag" },
        { @"t1_pcoabfa escaped underscores in a link label",
          @"Tatsächlich\n\n[https://www.reddit.com/r/Astronomy/comments/1mnc2t3/full\\_moon\\_behind\\_hohenzollern\\_castle/](https://www.reddit.com/r/Astronomy/comments/1mnc2t3/full_moon_behind_hohenzollern_castle/)",
          @"Tatsächlich\n\nhttps://www.reddit.com/r/Astronomy/comments/1mnc2t3/full_moon_behind_hohenzollern_castle/" },
        { @"t1_pcpe9qh loose bullet list",
          @"In aller Kürze:\n\n* Anforderungen an die Überprüfung und Verifizierung von Zielen durch menschliche Bediener gestrichen.\n \n* Mandat für die vorhersehbare Funktionsweise von KI-Waffen entfernt. \n\n* Anforderung an Nutzer, ethische Aspekte beim Einsatz KI-gesteuerter Waffen zu berücksichtigen, gestrichen. \n\n* Anwendbarkeit des Rahmens auf das gesamte Völkerrecht eingeschränkt.\n\n\nDa freut man sich ja gerade zu auf die neue tolle KI-Welt /s\n\nWieder einmal versagt das UN-System, einen einschneidenden, technologisch-orientierten Wendepunkt in der Menschheitsgeschichte entsprechend im Sinne von Menschen zu vereinbaren.",
          @"In aller Kürze:\n\n\t•\tAnforderungen an die Überprüfung und Verifizierung von Zielen durch menschliche Bediener gestrichen.\n\t•\tMandat für die vorhersehbare Funktionsweise von KI-Waffen entfernt.\n\t•\tAnforderung an Nutzer, ethische Aspekte beim Einsatz KI-gesteuerter Waffen zu berücksichtigen, gestrichen.\n\t•\tAnwendbarkeit des Rahmens auf das gesamte Völkerrecht eingeschränkt.\n\nDa freut man sich ja gerade zu auf die neue tolle KI-Welt /s\n\nWieder einmal versagt das UN-System, einen einschneidenden, technologisch-orientierten Wendepunkt in der Menschheitsgeschichte entsprechend im Sinne von Menschen zu vereinbaren." },
        { @"t1_pcqfekv quote + bold + quoted link label",
          @"> warum das damals so gut geklappt hat das Klonen zu reglementieren\n\nDas hat es nicht. Dolly 1996. UN drei Jahre Beratung. 2005 ein **unverbindliches** Abkommen - neun Jahre nach Dolly. Über Erlauben/Verbieten des \"therapeutischen Klonen\" konnte man sich nicht einigen.\n\nEuropa: Deutschland hat das Abkommen von Oviedo nicht unterzeichnet.\n\n[\"Cloning, International Regulation\"](https://opil.ouplaw.com/display/10.1093/law:epil/9780199231690/law-9780199231690-e1616?rskey=o984pO&result=2&prd=OPIL#1)",
          @"\twarum das damals so gut geklappt hat das Klonen zu reglementieren\n\nDas hat es nicht. Dolly 1996. UN drei Jahre Beratung. 2005 ein unverbindliches Abkommen - neun Jahre nach Dolly. Über Erlauben/Verbieten des “therapeutischen Klonen” konnte man sich nicht einigen.\n\nEuropa: Deutschland hat das Abkommen von Oviedo nicht unterzeichnet.\n\n“Cloning, International Regulation”" },
    };
    for (NSValue *value in AllPairs(pairs, sizeof(pairs) / sizeof(pairs[0]))) {
        BodyPair *pair = (BodyPair *)value.pointerValue;
        // The bug: plain whitespace/case folding can't relate the two.
        NSString *plainRaw = ApolloNormalizeTextForCompare(pair->raw);
        NSString *plainRendered = ApolloNormalizeTextForCompare(pair->rendered);
        Check(![plainRaw isEqualToString:plainRendered] && ![plainRaw containsString:plainRendered],
              [NSString stringWithFormat:@"%@: pair no longer exercises the bug", pair->name]);
        // The fix: the rendered node qualifies as this comment's body, both ways round.
        Check(ApolloTextQualifiesAsBodyCandidate(pair->rendered, pair->raw),
              [NSString stringWithFormat:@"%@: rendered text should match its markdown source", pair->name]);
        Check(!ApolloTextLooksLikePreviewExcerptOfBody(pair->rendered, pair->raw),
              [NSString stringWithFormat:@"%@: a full rendered body is not an excerpt", pair->name]);
    }
}

static void TestNegativeControls(void) {
    NSString *body = @"> Zitat aus dem Artikel\n\nMeine eigene, deutlich längere Antwort auf das Zitat.";
    Check(!ApolloTextQualifiesAsBodyCandidate(@"Warum?", body), @"an unrelated short text must not match");
    Check(!ApolloTextQualifiesAsBodyCandidate(@"leekdonut", body), @"a byline label must not match");

    // A link card's truncated description of a longer body stays an excerpt.
    NSString *article = @"No more stumbling blocks will be laid in Heidenau in memory of victims of National Socialism. "
                         "The city council decided this with votes from the AfD and the CDU on Tuesday evening. "
                         "Relatives and initiatives had asked for the opposite for years.";
    NSString *leadSentence = @"No more stumbling blocks will be laid in Heidenau in memory of victims of National Socialism.";
    Check(ApolloTextLooksLikePreviewExcerptOfBody(leadSentence, article), @"a leading sentence of a longer body is an excerpt");
    Check(!ApolloTextQualifiesAsBodyCandidate(leadSentence, article), @"an excerpt must not qualify as the body");
    NSString *truncatedCard = @"No more stumbling blocks will be laid in Heidenau in memory of victims…";
    Check(!ApolloTextQualifiesAsBodyCandidate(truncatedCard, article), @"a truncated card description must not qualify as the body");

    // Plain text takes the fast path and folds exactly like before.
    NSString *plain = @"Hallo Welt - wie geht's dir heute? Alles gut, danke.";
    Check([ApolloNormalizeBodyTextForCompare(plain) isEqualToString:ApolloNormalizeTextForCompare(plain)],
          @"plain text normalizes exactly as before");
    Check(!ApolloTextNeedsMarkdownFold(plain), @"plain text skips the markdown fold");
    Check(ApolloTextNeedsMarkdownFold(@"> Zitat"), @"a leading quote needs the fold");
    Check(!ApolloTextNeedsMarkdownFold(@"a > b"), @"'>' mid-line is not a quote marker");

    // Marker characters drop symmetrically: literal '*' on both sides still matches.
    Check(ApolloTextQualifiesAsBodyCandidate(@"5 * 3 = 15, stimmt's?", @"5 * 3 = 15, stimmt's?"), @"literal asterisks still match");
}

#pragma mark - Rendering translated markdown bodies

static NSFont *BodyFont(void) { return [NSFont systemFontOfSize:15]; }

static NSParagraphStyle *IndentStyle(CGFloat headIndent) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.headIndent = headIndent;
    style.firstLineHeadIndent = 0;
    style.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:headIndent options:@{}] ];
    return style;
}

// What Apollo's MarkdownTextNode hands over for "> quote\n\nreply\n\n* item":
// paragraph style and Apollo's own keys sit on each block line's LEADING TAB.
static NSAttributedString *ApolloLikeRender(void) {
    NSColor *quoteColor = [NSColor purpleColor];
    NSColor *textColor = [NSColor blackColor];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\t" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: quoteColor, NSParagraphStyleAttributeName: IndentStyle(15),
        @"Indent": @1, @"BlockQuote": @YES, @"QuoteDepth": @1 }]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"Zitat aus dem Artikel\n\n" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: quoteColor, @"BlockQuote": @YES, @"QuoteDepth": @1 }]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"Meine Antwort\n\n" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: textColor }]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\t" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: textColor, NSParagraphStyleAttributeName: IndentStyle(30.5),
        @"Indent": @1, @"ListDepth": @1 }]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"•\t" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: textColor, NSParagraphStyleAttributeName: IndentStyle(30.5),
        @"ListDepth": @1 }]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"Punkt" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: textColor }]];
    return s;
}

static NSRange RangeOf(NSAttributedString *s, NSString *needle) {
    NSRange r = [s.string rangeOfString:needle];
    Check(r.location != NSNotFound, [NSString stringWithFormat:@"'%@' missing from '%@'", needle, s.string]);
    return r;
}

static void TestQuoteAndReplyKeepTheirOwnStyles(void) {
    NSAttributedString *out = ApolloTranslatedMarkdownBodyAttributedString(ApolloLikeRender(),
                                                                           @"> Quote from the article\n\nMy reply\n\n* Point");
    Check([out.string isEqualToString:@"\tQuote from the article\n\nMy reply\n\n\t•\tPoint"],
          [NSString stringWithFormat:@"rendered display string: '%@'", out.string]);

    NSDictionary *lead = [out attributesAtIndex:0 effectiveRange:NULL];
    Check([lead[NSParagraphStyleAttributeName] headIndent] == 15 && lead[@"Indent"], @"quote's leading tab carries the quote paragraph style");
    NSDictionary *quote = [out attributesAtIndex:RangeOf(out, @"Quote from").location effectiveRange:NULL];
    Check(quote[@"BlockQuote"] && [quote[NSForegroundColorAttributeName] isEqual:[NSColor purpleColor]], @"quote text keeps quote attributes");
    NSDictionary *reply = [out attributesAtIndex:RangeOf(out, @"My reply").location effectiveRange:NULL];
    Check(!reply[@"BlockQuote"] && !reply[NSParagraphStyleAttributeName] && [reply[NSForegroundColorAttributeName] isEqual:[NSColor blackColor]],
          @"the reply after a quote is NOT styled as a quote (was: every line took the first run's quote style)");
    NSUInteger bulletLine = RangeOf(out, @"\t•\tPoint").location;
    NSDictionary *bulletLead = [out attributesAtIndex:bulletLine effectiveRange:NULL];
    Check([bulletLead[NSParagraphStyleAttributeName] headIndent] == 30.5 && bulletLead[@"ListDepth"], @"bullet line carries the list paragraph style");
}

static void TestBlocksRenderLikeApollo(void) {
    NSAttributedString *base = ApolloLikeRender();
    NSAttributedString *list = ApolloTranslatedMarkdownBodyAttributedString(base, @"In short:\n\n* one\n \n* two\n\n\nAfter the list");
    Check([list.string isEqualToString:@"In short:\n\n\t•\tone\n\t•\ttwo\n\nAfter the list"],
          [NSString stringWithFormat:@"loose list renders tight with one paragraph break: '%@'", list.string]);

    NSAttributedString *nested = ApolloTranslatedMarkdownBodyAttributedString(base, @">first quote paragraph\n>\n> second one\n\nreply");
    Check([nested.string isEqualToString:@"\tfirst quote paragraph\n\n\tsecond one\n\nreply"],
          [NSString stringWithFormat:@"multi-paragraph quote: '%@'", nested.string]);

    NSAttributedString *spoiler = ApolloTranslatedMarkdownBodyAttributedString(base, @">!not a quote!<");
    Check(![spoiler.string hasPrefix:@"\t"], @"a spoiler line is not rendered as a quote");

    NSAttributedString *heading = ApolloTranslatedMarkdownBodyAttributedString(base, @"## Title\n\n---\n\nText");
    Check([heading.string isEqualToString:@"Title\n\nText"], [NSString stringWithFormat:@"heading + rule: '%@'", heading.string]);

    NSAttributedString *escaped = ApolloTranslatedMarkdownBodyAttributedString(base, @"full\\_moon and 2\\*3");
    Check([escaped.string isEqualToString:@"full_moon and 2*3"], [NSString stringWithFormat:@"escapes: '%@'", escaped.string]);

    NSAttributedString *literal = ApolloTranslatedMarkdownBodyAttributedString(base, @"\\*not italic\\* here");
    Check([literal.string isEqualToString:@"*not italic* here"], [NSString stringWithFormat:@"escaped markers stay literal: '%@'", literal.string]);
    NSFont *literalFont = [literal attribute:NSFontAttributeName atIndex:1 effectiveRange:NULL];
    Check((literalFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitItalic) == 0, @"escaped markers never pair into italics");

    NSAttributedString *url = ApolloTranslatedMarkdownBodyAttributedString(base, @"see https://x.de/full\\_moon ok");
    Check([url.string isEqualToString:@"see https://x.de/full_moon ok"], [NSString stringWithFormat:@"escaped bare URL: '%@'", url.string]);
    Check([[[url attribute:NSLinkAttributeName atIndex:4 effectiveRange:NULL] description] isEqualToString:@"https://x.de/full_moon"],
          @"an escaped bare URL links to the unescaped address");
}

static BOOL FontHasTrait(NSAttributedString *s, NSUInteger index, NSFontDescriptorSymbolicTraits trait) {
    NSFont *font = [s attribute:NSFontAttributeName atIndex:index effectiveRange:NULL];
    return (font.fontDescriptor.symbolicTraits & trait) != 0;
}

static void TestInlineEmphasisAndLinks(void) {
    NSAttributedString *base = ApolloLikeRender();
    NSAttributedString *bold = ApolloTranslatedMarkdownBodyAttributedString(base, @"comment on **real** news");
    Check([bold.string isEqualToString:@"comment on real news"], @"bold markers removed");
    Check(FontHasTrait(bold, RangeOf(bold, @"real").location, NSFontDescriptorTraitBold), @"bold text is bold");
    Check(!FontHasTrait(bold, 0, NSFontDescriptorTraitBold), @"surrounding text is not bold");

    NSAttributedString *italic = ApolloTranslatedMarkdownBodyAttributedString(base, @"an *italic* and _another_ one, snake_case_name stays");
    Check([italic.string isEqualToString:@"an italic and another one, snake_case_name stays"],
          [NSString stringWithFormat:@"italic markers: '%@'", italic.string]);
    Check(FontHasTrait(italic, RangeOf(italic, @"italic").location, NSFontDescriptorTraitItalic), @"italic text is italic");

    NSAttributedString *strike = ApolloTranslatedMarkdownBodyAttributedString(base, @"~~gone~~ here");
    Check([strike.string isEqualToString:@"gone here"] &&
          [[strike attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle,
          @"strikethrough");

    NSAttributedString *link = ApolloTranslatedMarkdownBodyAttributedString(base, @"> text [Source](https://x.de/a_b_c_d) end\n\nsee https://x.de/_u_ ok");
    Check([link.string isEqualToString:@"\ttext Source end\n\nsee https://x.de/_u_ ok"],
          [NSString stringWithFormat:@"links: '%@'", link.string]);
    id sourceLink = [link attribute:NSLinkAttributeName atIndex:RangeOf(link, @"Source").location effectiveRange:NULL];
    Check([[sourceLink description] isEqualToString:@"https://x.de/a_b_c_d"], @"markdown link target kept, underscores intact");
    Check([link attribute:@"BlockQuote" atIndex:RangeOf(link, @"Source").location effectiveRange:NULL] != nil, @"a link inside a quote keeps quote attributes");
    Check([link attribute:NSLinkAttributeName atIndex:RangeOf(link, @"https://x.de/_u_").location effectiveRange:NULL] != nil,
          @"bare URL linked and its underscores not read as italics");

    NSAttributedString *relative = ApolloTranslatedMarkdownBodyAttributedString(base, @"see [r/de](/r/de)");
    Check([relative.string isEqualToString:@"see r/de"] &&
          [[[relative attribute:NSLinkAttributeName atIndex:4 effectiveRange:NULL] description] isEqualToString:@"https://www.reddit.com/r/de"],
          @"relative reddit link converted");
}

static void TestNumberedListDoesNotStyleProse(void) {
    // "\t1.\t…" (numbered item) comes first; its list paragraph style must not become
    // the "normal" style of the translated prose.
    NSMutableAttributedString *base = [[NSMutableAttributedString alloc] initWithString:@"\t1.\tErster Punkt\n" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: [NSColor blackColor], NSParagraphStyleAttributeName: IndentStyle(30.5) }];
    [base appendAttributedString:[[NSAttributedString alloc] initWithString:@"Danach normaler Text" attributes:@{
        NSFontAttributeName: BodyFont(), NSForegroundColorAttributeName: [NSColor blackColor] }]];
    NSAttributedString *out = ApolloTranslatedMarkdownBodyAttributedString(base, @"1. First point\n\nThen normal text");
    NSDictionary *prose = [out attributesAtIndex:RangeOf(out, @"Then normal").location effectiveRange:NULL];
    Check(prose[NSParagraphStyleAttributeName] == nil, @"prose after a numbered list keeps plain paragraph style");
}

static void TestTitleBuilderUnchanged(void) {
    NSAttributedString *title = ApolloTranslatedAttributedStringPreservingVisualLinks(ApolloLikeRender(), @"**Breaking** > news");
    Check([title.string isEqualToString:@"**Breaking** > news"], @"titles keep the plain builder (no markdown rendering)");
}

int main(void) {
    @autoreleasepool {
        TestRealPairsMatch();
        TestNegativeControls();
        TestQuoteAndReplyKeepTheirOwnStyles();
        TestBlocksRenderLikeApollo();
        TestInlineEmphasisAndLinks();
        TestNumberedListDoesNotStyleProse();
        TestTitleBuilderUnchanged();
        printf("translation markdown body tests passed (%lu checks)\n", (unsigned long)sChecks);
    }
    return 0;
}
