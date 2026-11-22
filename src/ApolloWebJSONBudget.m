#import "ApolloWebJSONBudget.h"

// One report: what Reddit said, and when (epoch seconds) its window ends.
@interface ApolloWebJSONBudgetReport : NSObject
@property (nonatomic) double used;
@property (nonatomic) double limit;
@property (nonatomic) NSTimeInterval windowEnd;
@end
@implementation ApolloWebJSONBudgetReport
@end

// Two answers belong to the same window when their window ends agree to within
// this. `x-ratelimit-reset` is whole seconds and answers take a moment to
// arrive, so the computed end wobbles by a second or two; windows are ten
// minutes apart.
static const NSTimeInterval kApolloWebJSONBudgetSameWindowSlack = 30.0;
// A reset further out than one window is not a ten-minute budget report.
static const NSTimeInterval kApolloWebJSONBudgetLongestWindow = 600.0;

static NSTimeInterval sApolloWebJSONBudgetTestNow = 0;

static NSObject *ApolloWebJSONBudgetLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Lowercased username -> latest report. Guarded by ApolloWebJSONBudgetLock.
static NSMutableDictionary<NSString *, ApolloWebJSONBudgetReport *> *sApolloWebJSONBudgetReports;

static NSTimeInterval ApolloWebJSONBudgetNow(void) {
    return sApolloWebJSONBudgetTestNow > 0 ? sApolloWebJSONBudgetTestNow : [[NSDate date] timeIntervalSince1970];
}

static NSString *ApolloWebJSONBudgetKey(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *key = [[username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return key.length > 0 ? key : nil;
}

// A header Reddit sends as a decimal string ("14", "86.0"). NAN when absent or
// not a number.
static double ApolloWebJSONBudgetHeader(NSHTTPURLResponse *response, NSString *name) {
    NSString *value = [response valueForHTTPHeaderField:name];
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NAN;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double number = 0;
    return ([scanner scanDouble:&number] && scanner.isAtEnd) ? number : NAN;
}

BOOL ApolloWebJSONBudgetNoteResponse(NSString *username, NSHTTPURLResponse *response) {
    NSString *key = ApolloWebJSONBudgetKey(username);
    if (!key || ![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    double used = ApolloWebJSONBudgetHeader(response, @"x-ratelimit-used");
    double remaining = ApolloWebJSONBudgetHeader(response, @"x-ratelimit-remaining");
    double reset = ApolloWebJSONBudgetHeader(response, @"x-ratelimit-reset");
    if (isnan(used) || isnan(remaining) || isnan(reset)) return NO;
    if (used < 0 || remaining < 0 || used + remaining <= 0) return NO;
    if (reset <= 0 || reset > kApolloWebJSONBudgetLongestWindow) return NO;

    NSTimeInterval windowEnd = ApolloWebJSONBudgetNow() + reset;
    @synchronized (ApolloWebJSONBudgetLock()) {
        if (!sApolloWebJSONBudgetReports) sApolloWebJSONBudgetReports = [NSMutableDictionary dictionary];
        ApolloWebJSONBudgetReport *report = sApolloWebJSONBudgetReports[key];
        BOOL sameWindow = report && fabs(report.windowEnd - windowEnd) <= kApolloWebJSONBudgetSameWindowSlack;
        double limit = used + remaining;
        if (sameWindow) {
            // Reddit keeps separate, roomier counts for other kinds of request
            // (600 a window for its own pages, 10000 for an API key). Should an
            // answer from one of those turn up here, the tighter count stays:
            // it's the one that runs out.
            BOOL roomier = limit > report.limit + 0.5;
            BOOL tighter = limit < report.limit - 0.5;
            if (roomier) return NO;
            // Requests overlap, so an answer counted earlier can arrive later.
            if (!tighter && used <= report.used) return NO;
        }
        if (!report) {
            report = [ApolloWebJSONBudgetReport new];
            sApolloWebJSONBudgetReports[key] = report;
        }
        report.used = used;
        report.limit = limit;
        // Keep the window's first end: later answers' ends only wobble around it.
        if (!sameWindow) report.windowEnd = windowEnd;
        return YES;
    }
}

ApolloWebJSONBudgetState ApolloWebJSONBudgetCurrent(NSString *username) {
    ApolloWebJSONBudgetState state = { NO, 0, 0, 0 };
    NSString *key = ApolloWebJSONBudgetKey(username);
    if (!key) return state;
    NSTimeInterval now = ApolloWebJSONBudgetNow();
    @synchronized (ApolloWebJSONBudgetLock()) {
        ApolloWebJSONBudgetReport *report = sApolloWebJSONBudgetReports[key];
        if (!report) return state;
        if (report.windowEnd <= now) {
            // The window is over and the count with it.
            [sApolloWebJSONBudgetReports removeObjectForKey:key];
            return state;
        }
        state.known = YES;
        state.used = report.used;
        state.limit = report.limit;
        state.resetsIn = report.windowEnd - now;
    }
    return state;
}

NSTimeInterval ApolloWebJSONBudgetPause(NSString *username, NSInteger pauseAtPercent) {
    if (pauseAtPercent <= 0) return 0;
    ApolloWebJSONBudgetState state = ApolloWebJSONBudgetCurrent(username);
    if (!state.known) return 0;
    double stop = state.limit * (double)MIN(pauseAtPercent, 100) / 100.0;
    return state.used >= stop ? state.resetsIn : 0;
}

NSString *ApolloWebJSONBudgetStatusText(NSString *username) {
    ApolloWebJSONBudgetState state = ApolloWebJSONBudgetCurrent(username);
    if (!state.known) return nil;
    NSString *reset = state.resetsIn < 60.0
        ? @"under a minute"
        : [NSString stringWithFormat:@"%ld min", (long)ceil(state.resetsIn / 60.0)];
    return [NSString stringWithFormat:@"%ld of %ld used, resets in %@", lround(MIN(state.used, state.limit)), lround(state.limit), reset];
}

void ApolloWebJSONBudgetSetNowForTesting(NSTimeInterval now) {
    sApolloWebJSONBudgetTestNow = now;
}

void ApolloWebJSONBudgetResetForTesting(void) {
    @synchronized (ApolloWebJSONBudgetLock()) {
        sApolloWebJSONBudgetReports = nil;
    }
}
