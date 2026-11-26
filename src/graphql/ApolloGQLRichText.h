#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Reddit's GraphQL answers carry a post's or comment's text as Markdown and as
// "RTJSON", its rich-text document ({"document":[{"e":"par","c":[…]}, …]}).
// They don't carry the HTML the legacy API sends as selftext_html / body_html,
// and Apollo draws a comment from that HTML (ApolloDeletedCommentsData.m), so
// the GraphQL route (ApolloGQLLegacy.h) builds it from the rich-text document.
// The output follows what Reddit's own Markdown renderer emits for the same
// text: <div class="md"><p>…</p>\n</div>, with <strong>, <em>, <del>, <sup>,
// <code>, <a href>, <blockquote>, <ul>/<ol>, <h1>…<h6>, <pre><code>, <table>,
// <hr/> and <span class="md-spoiler-text">.
// Foundation-only: tests/run_gql_legacy_tests.sh.

// The HTML for an RTJSON document, given as its JSON text (how GraphQL sends
// it) or as the parsed dictionary. `media` is the answer's richtextMedia list
// (the images and GIFs the document embeds by id), or nil. `selfPost` adds the
// <!-- SC_OFF --> … <!-- SC_ON --> markers Reddit puts around a post's body.
// nil when the document can't be read or has no content. The HTML is raw (the
// form raw_json=1 gives); ApolloGQLLegacy escapes it like every other string
// when the request didn't ask for raw JSON.
NSString *_Nullable ApolloGQLRichTextHTML(id _Nullable document, NSArray *_Nullable media, BOOL selfPost);

// The Markdown for an RTJSON document, given the same two ways, or nil when it
// can't be read or has no content. GraphQL sends the Markdown next to nearly
// every document; the one that arrives without it is an interactive post's
// text fallback (ApolloGQLLegacy.m), and the legacy API serves that as
// Markdown, written the way this writes it: blocks a blank line apart, "## "
// headings, tables as |a|b| rows under a |:-|:-| rule, "* * *" for a rule.
// Text is copied as it is, with no Markdown escaping.
NSString *_Nullable ApolloGQLRichTextMarkdown(id _Nullable document);

// The fallback when an answer has Markdown but no usable rich-text document:
// one <p> per paragraph with the text escaped and nothing else rendered, so
// the body is readable (its Markdown marks show as typed).
NSString *_Nullable ApolloGQLPlainTextHTML(NSString *_Nullable markdown, BOOL selfPost);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
