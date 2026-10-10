#import <Foundation/Foundation.h>

__BEGIN_DECLS

// Clears generated summaries, extracted article text, transient comment data,
// and the persisted summary plist. Returns the number of generated summaries
// removed from the in-memory cache.
NSUInteger ApolloAIClearSummaryCache(void);

// The language AI summaries are written in right now: an identifier such as
// "en", "pt" or "zh-Hant", or nil when the prompts name none (the model then
// answers in the text's own language). *picked (may be NULL) is YES when it is
// the language picked in Apollo AI → Summaries → Language, NO when it is the
// device language. Main thread only.
NSString *ApolloAISummaryLanguage(BOOL *picked);

// Whether Apple's on-device model can write summaries in `identifier` ("pt",
// "no", "zh-Hant"). YES when the OS can't say (before iOS 26). Main thread only.
BOOL ApolloAIOnDeviceCanWrite(NSString *identifier);

__END_DECLS
