#import <Foundation/Foundation.h>

typedef void (^ApolloTranslationLegCompletion)(NSString *, NSString *, NSError *);

static NSString *sTranslationProvider = @"google";
static NSMutableDictionary<NSString *, NSMutableArray *> *sPendingTranslationCallbacks;
static NSMutableDictionary<NSString *, NSDictionary *> *sTranslationFailureCooldowns;
static NSMutableDictionary<NSString *, NSString *> *sTestCache;
static dispatch_queue_t sDetectionQueue;
static uint32_t sTranslationCacheGeneration;
static id sCurrentAccount;
static NSString *sCurrentTarget = @"en";
static NSUInteger sPreparationCount;
static NSUInteger sProviderCount;
static BOOL sPreparationRanOnMain;

static NSString *ApolloRawTranslationCacheGet(NSString *key);
static void ApolloRawTranslationCacheSet(NSString *key, NSString *value);
static NSError *ApolloRecentTranslationFailure(NSString *key);
static NSString *ApolloTranslationFailureCooldownKey(NSString *key);
static void ApolloNoteTranslationSuccessForToast(void);
static void ApolloRecordTranslationFailure(NSString *key, NSError *error);
static void ApolloNoteTranslationFailureForToast(NSError *error);
static NSString *ApolloRestoreTranslationLinks(NSString *text, NSDictionary *links);
static NSString *ApolloRestoreTranslationNames(NSString *text, NSDictionary *names);
static NSString *ApolloNormalizedReportedSourceLanguage(NSString *source);
static void ApolloRecordTranslationSourceLanguage(NSString *text, NSString *language);
static BOOL ApolloLanguageCodeIsInSkipList(NSString *language);
static void ApolloTranslateTextWithFallbackPrepared(NSString *text, NSString *target,
                                                     BOOL skipKnown, BOOL shouldSkip,
                                                     NSString *provider, NSString *appleSource,
                                                     ApolloTranslationLegCompletion completion);
static dispatch_queue_t ApolloTranslationDetectionQueue(void);
static NSString *ApolloStripInlineMediaTokens(NSString *text);
static NSString *ApolloProtectTranslationNames(NSString *text, NSDictionary **names);
static NSString *ApolloProtectTranslationLinks(NSString *text, NSDictionary **links);
static BOOL ApolloTitleLooksLikeProperNouns(NSString *text);
static NSString *ApolloDominantLanguageWithConfidence(NSString *text, double *confidence);
static BOOL ApolloProtectedTextIsOnlyProtectedTokens(NSString *text, NSDictionary *names, NSDictionary *links);
static BOOL ApolloShouldSkipTranslationForText(NSString *text, NSString *target);
static NSString *ApolloDetectSourceLanguageForApple(NSString *text);
static id ApolloActiveAccountClient(void);
static NSString *ApolloResolvedTargetLanguageCode(void);

#define ApolloTranslationVerboseLog(...) do {} while (0)
#import "TranslationRequest.inc"

static NSString *ApolloRawTranslationCacheGet(NSString *key) { return sTestCache[key]; }
static void ApolloRawTranslationCacheSet(NSString *key, NSString *value) { if (key && value) sTestCache[key] = value; }
static NSError *ApolloRecentTranslationFailure(__unused NSString *key) { return nil; }
static NSString *ApolloTranslationFailureCooldownKey(NSString *key) { return key; }
static void ApolloNoteTranslationSuccessForToast(void) {}
static void ApolloRecordTranslationFailure(__unused NSString *key, __unused NSError *error) {}
static void ApolloNoteTranslationFailureForToast(__unused NSError *error) {}
static NSString *ApolloRestoreTranslationLinks(NSString *text, __unused NSDictionary *links) { return text; }
static NSString *ApolloRestoreTranslationNames(NSString *text, __unused NSDictionary *names) { return text; }
static NSString *ApolloNormalizedReportedSourceLanguage(NSString *source) { return source; }
static void ApolloRecordTranslationSourceLanguage(__unused NSString *text, __unused NSString *language) {}
static BOOL ApolloLanguageCodeIsInSkipList(__unused NSString *language) { return NO; }
static void ApolloTranslateTextWithFallbackPrepared(__unused NSString *text, __unused NSString *target,
                                                     __unused BOOL skipKnown, __unused BOOL shouldSkip,
                                                     __unused NSString *provider, __unused NSString *appleSource,
                                                     ApolloTranslationLegCompletion completion) {
    sProviderCount++;
    completion(@"translated", @"es", nil);
}
static dispatch_queue_t ApolloTranslationDetectionQueue(void) { return sDetectionQueue; }
static NSString *ApolloStripInlineMediaTokens(NSString *text) { return text; }
static NSString *ApolloProtectTranslationNames(NSString *text, NSDictionary **names) {
    sPreparationCount++;
    sPreparationRanOnMain |= [NSThread isMainThread];
    [NSThread sleepForTimeInterval:0.08];
    if (names) *names = @{};
    return text;
}
static NSString *ApolloProtectTranslationLinks(NSString *text, NSDictionary **links) {
    if (links) *links = @{};
    return text;
}
static BOOL ApolloTitleLooksLikeProperNouns(__unused NSString *text) { return NO; }
static NSString *ApolloDominantLanguageWithConfidence(__unused NSString *text, double *confidence) {
    if (confidence) *confidence = 0.0;
    return nil;
}
static BOOL ApolloProtectedTextIsOnlyProtectedTokens(__unused NSString *text, __unused NSDictionary *names,
                                                      __unused NSDictionary *links) { return NO; }
static BOOL ApolloShouldSkipTranslationForText(__unused NSString *text, __unused NSString *target) { return NO; }
static NSString *ApolloDetectSourceLanguageForApple(__unused NSString *text) { return nil; }
static id ApolloActiveAccountClient(void) { return sCurrentAccount; }
static NSString *ApolloResolvedTargetLanguageCode(void) { return sCurrentTarget; }

static NSUInteger sChecks;
static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static BOOL SpinUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static void TestCoalescingAndCache(void) {
    __block NSUInteger callbacks = 0;
    __block NSMutableArray<NSString *> *results = [NSMutableArray array];
    void (^completion)(NSString *, NSError *) = ^(NSString *translated, NSError *error) {
        Check([NSThread isMainThread], @"completion returns on main");
        Check(error == nil, @"coalesced request succeeds");
        [results addObject:translated ?: @""];
        callbacks++;
    };

    ApolloRequestTranslation(@"same-key", @"Hola mundo", @"en", completion);
    ApolloRequestTranslation(@"same-key", @"Hola mundo", @"en", completion);
    Check(SpinUntil(^BOOL{ return callbacks == 2; }, 3.0), @"both duplicate callbacks finish");
    Check(sPreparationCount == 1, @"duplicate requests share one preparation pass");
    Check(sProviderCount == 1, @"duplicate requests share one provider request");
    Check(!sPreparationRanOnMain, @"name/language preparation stays off main");
    Check([results isEqualToArray:@[ @"translated", @"translated" ]], @"both callbacks receive the same result");

    __block BOOL cacheHit = NO;
    ApolloRequestTranslation(@"same-key", @"Hola mundo", @"en", ^(NSString *translated, NSError *error) {
        cacheHit = [translated isEqualToString:@"translated"] && error == nil;
    });
    Check(cacheHit, @"completed translation is returned synchronously from cache");
    Check(sPreparationCount == 1 && sProviderCount == 1, @"cache hit starts no new work");
}

static void TestSettingsChangeCancelsInFlightWork(void) {
    __block BOOL staleCallbackFinished = NO;
    __block BOOL currentCallbackFinished = NO;
    __block NSString *staleResult = @"not-called";
    __block NSString *currentResult = @"not-called";
    ApolloRequestTranslation(@"settings-change", @"Bonjour monde", @"en", ^(NSString *translated, NSError *error) {
        Check(error == nil, @"settings cancellation is silent and retryable");
        staleResult = translated;
        staleCallbackFinished = YES;
    });
    sTranslationProvider = @"apple";
    ApolloRequestTranslation(@"settings-change", @"Bonjour monde", @"en", ^(NSString *translated, NSError *error) {
        Check(error == nil, @"replacement request succeeds");
        currentResult = translated;
        currentCallbackFinished = YES;
    });
    Check(SpinUntil(^BOOL{ return staleCallbackFinished && currentCallbackFinished; }, 3.0),
          @"both stale and replacement requests are drained");
    Check(staleResult == nil, @"stale request produces no translated result");
    Check([currentResult isEqualToString:@"translated"], @"new settings context starts an independent request");
    Check(sProviderCount == 2, @"old provider is skipped and replacement provider runs once");
    Check([ApolloRawTranslationCacheGet(@"settings-change") isEqualToString:@"translated"],
          @"only the current-context result populates the cache");
    sTranslationProvider = @"google";
}

static void TestCompletionContextGuard(void) {
    NSObject *account = [NSObject new];
    NSObject *otherAccount = [NSObject new];
    Check(ApolloTranslationContextMatches(@"  Hola   Mundo ", @"hola mundo", @"en", @"en",
                                          @"google", @"google", 4, 4, account, account),
          @"matching node/settings/account context is accepted");
    Check(!ApolloTranslationContextMatches(@"Hola", @"Adios", @"en", @"en", @"google", @"google", 4, 4, account, account),
          @"reused node text is rejected");
    Check(!ApolloTranslationContextMatches(@"Hola", @"Hola", @"en", @"fr", @"google", @"google", 4, 4, account, account),
          @"target-language change is rejected");
    Check(!ApolloTranslationContextMatches(@"Hola", @"Hola", @"en", @"en", @"google", @"apple", 4, 4, account, account),
          @"provider change is rejected");
    Check(!ApolloTranslationContextMatches(@"Hola", @"Hola", @"en", @"en", @"google", @"google", 4, 5, account, account),
          @"cache-generation/settings change is rejected");
    Check(!ApolloTranslationContextMatches(@"Hola", @"Hola", @"en", @"en", @"google", @"google", 4, 4, account, otherAccount),
          @"account change is rejected");
}

int main(void) {
    @autoreleasepool {
        sPendingTranslationCallbacks = [NSMutableDictionary dictionary];
        sTranslationFailureCooldowns = [NSMutableDictionary dictionary];
        sTestCache = [NSMutableDictionary dictionary];
        sDetectionQueue = dispatch_queue_create("test.translation.detect", DISPATCH_QUEUE_SERIAL);
        sCurrentAccount = [NSObject new];
        TestCoalescingAndCache();
        TestSettingsChangeCancelsInFlightWork();
        TestCompletionContextGuard();
        printf("translation request concurrency tests passed (%lu checks)\n", (unsigned long)sChecks);
    }
    return 0;
}
