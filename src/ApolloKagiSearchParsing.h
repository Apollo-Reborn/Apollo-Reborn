#import <Foundation/Foundation.h>

// Kagi results-page parsing for the Search tab's "Kagi" mode, split out of
// ApolloKagiSearch.m so it stays Foundation-only: the .m compiles straight
// into a host-side harness (tests/run_kagi_search_parsing_tests.sh) and runs
// against saved Kagi pages.
//
// The page is https://kagi.com/html/search, Kagi's server-rendered results
// page (the same one kagi-cli reads with a subscriber's session cookie). Each
// result is a `div._0_SRI.search-result` block:
//
//   <a class="__sri_title_link ..." href="https://www.reddit.com/r/...">Title</a>
//   <div class="_0_DESC __sri-desc"><div>
//       <span class="__sri-time">Mar 27, 2025</span>   (optional)
//       Snippet text ...
//       <a class="_0_summarize_page summarize-link" ...>Summarize</a>
//   </div></div>
//
// Result links are the destination URLs themselves (no redirect wrapper), and
// a "More Results" link (#load_more_results, &batch=N) closes a page that has
// another one after it.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloKagiPageKind) {
    // A results page (it may still have no results).
    ApolloKagiPageKindResults = 0,
    // Kagi's signed-out page (sign-in form or the marketing landing page): the
    // session link is missing, expired or was revoked.
    ApolloKagiPageKindSignedOut,
    // A page with plenty of links but no result block Kagi's markup is known
    // to use: the markup changed and the parser needs updating.
    ApolloKagiPageKindUnreadable,
};

@interface ApolloKagiParsedResult : NSObject
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, copy) NSString *title;
// Plain text, entities decoded, whitespace collapsed; the date and the
// "Summarize" link are not part of it.
@property (nonatomic, copy) NSString *snippet;
// Kagi's date line ("Mar 27, 2025"), nil when the result has none.
@property (nonatomic, copy, nullable) NSString *dateText;
@end

@interface ApolloKagiParsedPage : NSObject
@property (nonatomic) ApolloKagiPageKind kind;
@property (nonatomic, copy) NSArray<ApolloKagiParsedResult *> *results;
// The page ends in a "More Results" link.
@property (nonatomic) BOOL hasMore;
@end

FOUNDATION_EXPORT ApolloKagiParsedPage *ApolloKagiParseResultsHTML(NSString *html);

// Accepts what the user pastes: the whole Session Link
// ("https://kagi.com/search?token=…", with or without other query items) or
// just the token. Returns the bare token, or nil when `input` is neither.
FOUNDATION_EXPORT NSString *_Nullable ApolloKagiNormalizeSessionToken(NSString *_Nullable input);

// Decodes HTML character references (named, &#NNN; and &#xHH;).
FOUNDATION_EXPORT NSString *ApolloKagiDecodeHTMLEntities(NSString *string);

NS_ASSUME_NONNULL_END
