#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// The runner places the production string hook and its installer immediately
// before this file, after processing them with the selected Logos generator.
// A private probe class keeps the test from replacing Foundation globally.
@interface FICStringProbe : NSObject
@property (nonatomic, copy) NSString *text;
- (NSRange)rangeOfString:(NSString *)needle options:(NSStringCompareOptions)options range:(NSRange)range;
@end
@implementation FICStringProbe
- (NSRange)rangeOfString:(NSString *)needle options:(NSStringCompareOptions)options range:(NSRange)range {
    return [self.text rangeOfString:needle options:options range:range];
}
@end

@interface FICInheritedStringProbe : FICStringProbe
@end
@implementation FICInheritedStringProbe
@end

static NSUInteger checks;
static NSUInteger priorCalls;
static NSUInteger trampolineCalls;
static NSUInteger laterCalls;
static NSUInteger installerReentries;
static FICStringProbe *installationProbe;
static FICRangeOfStringIMP nativeOriginal;
static FICRangeOfStringIMP trampolineOriginal;
static FICRangeOfStringIMP laterOriginal;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSRange PriorHook(NSString *receiver, SEL selector, NSString *needle,
                         NSStringCompareOptions options, NSRange range) {
    priorCalls++;
    return nativeOriginal(receiver, selector, needle, options, range);
}

static NSRange InstallerTrampoline(NSString *receiver, SEL selector, NSString *needle,
                                  NSStringCompareOptions options, NSRange range) {
    trampolineCalls++;
    return trampolineOriginal(receiver, selector, needle, options, range);
}

static NSRange LaterHook(NSString *receiver, SEL selector, NSString *needle,
                         NSStringCompareOptions options, NSRange range) {
    laterCalls++;
    return laterOriginal(receiver, selector, needle, options, range);
}

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    trampolineOriginal = (FICRangeOfStringIMP)method_getImplementation(method);
    Check(*original == NULL, @"Logos original is uninitialized before publication");
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));

    // Reproduce the reported ElleKit order exactly: publish, synchronously use
    // the replaced method while formatting its log, then fill the orig slot.
    // Calling through this slot directly here used to jump to address zero.
    Check(*original == NULL, @"installer has not filled the original during reentry");
    NSRange result = [installationProbe rangeOfString:@"cats" options:0
                                               range:NSMakeRange(0, installationProbe.text.length)];
    installerReentries++;
    Check(NSEqualRanges(result, NSMakeRange(0, 4)), @"installation reentry reaches the seeded original");
    Check(priorCalls == 1, @"installation reentry preserves the preexisting hook");
    Check(trampolineCalls == 0, @"trampoline is not used before installer returns it");

    // A hook engine may supply a callable trampoline distinct from the IMP
    // captured before installation. Steady-state calls must use that result.
    *original = (IMP)InstallerTrampoline;
}

static NSRange Find(FICStringProbe *probe, NSString *needle, NSRange range) {
    return [probe rangeOfString:needle options:NSCaseInsensitiveSearch range:range];
}

int main(void) {
    @autoreleasepool {
        SEL selector = @selector(rangeOfString:options:range:);
        Method method = class_getInstanceMethod(FICStringProbe.class, selector);
        nativeOriginal = (FICRangeOfStringIMP)method_setImplementation(method, (IMP)PriorHook);
        installationProbe = [FICInheritedStringProbe new];
        installationProbe.text = @"cats and DOGS; cat";
        NSRange fullRange = NSMakeRange(0, installationProbe.text.length);

        Check(!FICInstallStringHook(NSObject.class), @"missing method is never hooked");
        Check(FICInstallStringHook(FICInheritedStringProbe.class), @"inherited method installs");
#if FIC_TEST_SUBSTRATE
        Check(installerReentries == 1, @"fake ElleKit reentered during installation");
#else
        Check(installerReentries == 0, @"internal generator needs no Substrate dependency");
#endif
        Check(class_getMethodImplementation(FICStringProbe.class, selector) == (IMP)PriorHook,
              @"hooking an inherited method does not replace the superclass method");
        Check(NSEqualRanges(Find(installationProbe, @"dogs", fullRange), NSMakeRange(9, 4)),
              @"ordinary search preserves comparison options");
        Check(NSEqualRanges(Find(installationProbe, @"cat", NSMakeRange(4, fullRange.length - 4)),
                            NSMakeRange(15, 3)), @"ordinary search preserves the search range");
        Check(Find(installationProbe, @"cat, cats", fullRange).location == NSNotFound,
              @"comma query remains literal outside the native rebuild");

        sFICMultiTerms = @[@"cat", @"cats"];
        sFICMultiQuery = @"cat, cats";
        sFICMultiActive = YES;
        Check(NSEqualRanges(Find(installationProbe, @"cat, cats", fullRange), NSMakeRange(0, 4)),
              @"multi-term ties choose the longer match");
        Check(NSEqualRanges(Find(installationProbe, @"CAT, CATS", NSMakeRange(4, fullRange.length - 4)),
                            NSMakeRange(15, 3)), @"subsequent multi-term match preserves query comparison");
        Check(NSEqualRanges(Find(installationProbe, @"dogs", fullRange), NSMakeRange(9, 4)),
              @"unrelated searches remain literal while multi-term search is armed");
        __block NSRange backgroundResult;
        dispatch_semaphore_t backgroundDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            backgroundResult = Find(installationProbe, @"cat, cats", fullRange);
            dispatch_semaphore_signal(backgroundDone);
        });
        Check(dispatch_semaphore_wait(backgroundDone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              @"background search completed");
        Check(backgroundResult.location == NSNotFound, @"background searches never use the main-thread query");

        sFICMultiTerms = @[@"dogs", @"cat"];
        sFICMultiQuery = @"dogs, cat";
        Check(NSEqualRanges(Find(installationProbe, @"dogs, cat", fullRange), NSMakeRange(0, 3)),
              @"earliest match wins regardless of term order");
        sFICMultiTerms = @[@"absent", @"missing"];
        sFICMultiQuery = @"absent, missing";
        Check(Find(installationProbe, sFICMultiQuery, fullRange).location == NSNotFound,
              @"unmatched multi-term query returns not found");
#if FIC_TEST_SUBSTRATE
        Check(trampolineCalls > 0, @"completed installation uses the hook engine trampoline");
#endif

        method = class_getInstanceMethod(FICInheritedStringProbe.class, selector);
        laterOriginal = (FICRangeOfStringIMP)method_setImplementation(method, (IMP)LaterHook);
        sFICMultiTerms = @[@"dogs", @"cat"];
        sFICMultiQuery = @"dogs, cat";
        Check(NSEqualRanges(Find(installationProbe, sFICMultiQuery, fullRange), NSMakeRange(0, 3)),
              @"a later hook can chain through multi-term matching");
        Check(laterCalls == 1, @"later hook executes exactly once");
        sFICMultiActive = NO;
        sFICMultiTerms = nil;
        sFICMultiQuery = nil;
        Check(NSEqualRanges(Find(installationProbe, @"cat", fullRange), NSMakeRange(0, 3)),
              @"normal searches resume after the native rebuild ends");
        BOOL threwRangeException = NO;
        @try {
            (void)Find(installationProbe, @"cat", NSMakeRange(fullRange.length + 1, 1));
        } @catch (NSException *exception) {
            threwRangeException = [exception.name isEqualToString:NSRangeException];
        }
        Check(threwRangeException, @"underlying Foundation exception behavior is preserved");
        printf("PASS: %lu Find in Comments hook checks (%s)\n", (unsigned long)checks,
               FIC_TEST_SUBSTRATE ? "Substrate with synchronous reentry" : "internal generator");
    }
    return 0;
}
