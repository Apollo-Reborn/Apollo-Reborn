//
//  ApolloAICloudBridge.h
//  Cloud backend for AI summaries: an OpenAI-compatible chat-completions client
//  (OpenRouter / Google Gemini / custom base URL) with SSE streaming.
//
//  Mirrors the @objc surface of ApolloFoundationModels.swift exactly, so
//  ApolloAIBridge() in ApolloAISummary.xm can return either backend and every
//  call site works unchanged. Callbacks are always delivered on the main thread.
//
//  Error contract (NSError code, matching the FoundationModels bridge so
//  ApolloAIFriendlyError / the transient-retry check keep working):
//    5  = unknown
//    6  = cancelled (callers ignore silently)
//    8  = input too long for the model's context window
//    11 = auth/billing rejected (bad API key, out of credits)  [cloud-only]
//    12 = service unreachable / rejected request                 [cloud-only]
//    13 = model spent the whole response on internal reasoning,
//         leaving no visible summary                            [cloud-only]
//    14 = requested model is unavailable                         [cloud-only]
//    15 = provider quota/rate limit exhausted                    [cloud-only]
//  Code 9 (transient, retried in an unbounded loop by the caller) is never
//  emitted: a persistent HTTP 429/5xx would loop forever against a paid API.
//  Transient HTTP errors get ONE internal retry, then surface the final
//  provider failure through the mapped cloud error code above.
//

#import <Foundation/Foundation.h>

extern NSString *const ApolloAICloudBridgeErrorDomain;

// Keys of one custom-provider header entry (UDKeyCustomAIHeaders / sCustomAIHeaders).
extern NSString *const ApolloAICloudCustomHeaderNameKey;
extern NSString *const ApolloAICloudCustomHeaderValueKey;

#ifdef __cplusplus
extern "C" {
#endif

// Effective model for the active cloud provider: the user's stored model if
// set, else the per-provider default (nil for "custom", which has no default).
// Exposed so settings can show the default as a placeholder.
NSString *ApolloAICloudDefaultModelForProvider(NSString *provider);
NSString *ApolloAICloudEffectiveModel(void);

// Why a custom-provider header can't be sent, as one short user-facing
// sentence, or nil when it can. Pass the name and value already trimmed. A
// header can only ADD to a request: names this bridge sets or relies on
// (Authorization, Content-Type, Accept, …), ones the URL loading system
// reserves (Host, …) and connection-level ones are refused, and values must be
// printable ASCII (no line breaks).
NSString *ApolloAICloudCustomHeaderProblem(NSString *name, NSString *value);

// The stored header list minus anything malformed or invalid (see above), with
// names/values trimmed and repeated names (case-insensitive) collapsed to the
// first; nil when nothing is left. Takes any object: the defaults value can be
// hand-edited or come from a restored backup.
NSArray<NSDictionary<NSString *, NSString *> *> *ApolloAICloudSanitizedCustomHeaders(id stored);

#ifdef __cplusplus
}
#endif

@interface ApolloAICloudBridge : NSObject

+ (instancetype)shared;

// 0 = configured and ready; 4 = not configured (missing key / base URL) —
// deliberately reuses the FM "framework absent" status so ApolloAISummary.xm's
// existing status==4 silent-skip path handles the unconfigured state.
- (NSInteger)availabilityStatus;
- (BOOL)isModelAvailable;

// Prewarm has no meaning over HTTP; both are no-ops kept for surface parity.
- (void)prepareSession:(NSString *)identifier instructions:(NSString *)instructions;
- (void)discardPreparedSession:(NSString *)identifier;

// Cancels the in-flight request for this identifier (completion fires once
// with error code 6, which callers ignore).
- (void)cancelRequest:(NSString *)identifier;

- (void)summarize:(NSString *)text
       identifier:(NSString *)identifier
     instructions:(NSString *)instructions
maximumResponseTokens:(NSInteger)maximumResponseTokens
        onPartial:(void (^)(NSString *partial))onPartial
       onComplete:(void (^)(NSString *final, NSError *error))onComplete;

@end
