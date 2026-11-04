#import <Foundation/Foundation.h>
#define ApolloLog(...) do {} while (0)
// kApolloReportMaxLogBytes + ApolloReportLogForAttachment, extracted from
// src/settings/ApolloReportViewController.m by run_report_log_trim_tests.sh.
#include "ReportLogTrim.inc"

static int checks;
static void Check(BOOL result, NSString *message) {
    checks++;
    if (!result) { NSLog(@"FAIL: %@", message); exit(1); }
}

static NSUInteger UTF8Length(NSString *s) { return [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]; }

// Exported logs are "[HH:mm:ss.SSS] message" lines. Byte count is kept
// incrementally; re-measuring the growing string each line is quadratic.
static NSString *LogOfAtLeast(NSUInteger bytes, NSString *lineBody) {
    NSMutableString *log = [NSMutableString string];
    NSUInteger length = 0;
    for (NSUInteger i = 0; length < bytes; i++) {
        NSString *line = [NSString stringWithFormat:@"[18:%02lu:%02lu.%03lu] %@ %lu\n", (unsigned long)(i / 3600 % 60),
            (unsigned long)(i / 60 % 60), (unsigned long)(i % 1000), lineBody, (unsigned long)i];
        [log appendString:line];
        length += UTF8Length(line);
    }
    return log;
}

static NSString *Repeat(NSString *unit, NSUInteger minimumBytes) {
    NSUInteger unitBytes = UTF8Length(unit);
    NSUInteger count = minimumBytes / unitBytes + 1;
    return [@"" stringByPaddingToLength:count * unit.length withString:unit startingAtIndex:0];
}

static NSString *Header(NSString *trimmed) {
    NSRange newline = [trimmed rangeOfString:@"\n"];
    return newline.location == NSNotFound ? @"" : [trimmed substringToIndex:newline.location];
}

static NSString *Body(NSString *trimmed) {
    NSRange newline = [trimmed rangeOfString:@"\n"];
    return newline.location == NSNotFound ? trimmed : [trimmed substringFromIndex:NSMaxRange(newline)];
}

int main(void) { @autoreleasepool {
    // Typical logs (20 KB - 1 MB) and the boundary pass through untouched.
    NSString *small = LogOfAtLeast(800 * 1024, @"[Media] player state");
    Check(ApolloReportLogForAttachment(small) == small, @"a normal-size log is attached as is");
    NSString *exact = [Repeat(@"a", kApolloReportMaxLogBytes) substringToIndex:kApolloReportMaxLogBytes];
    Check(UTF8Length(exact) == kApolloReportMaxLogBytes, @"fixture is exactly at the cap");
    Check(ApolloReportLogForAttachment(exact) == exact, @"a log exactly at the cap is attached as is");

    // Oversized ASCII log: newest part kept, cut on a line boundary, under the cap.
    NSString *big = LogOfAtLeast(kApolloReportMaxLogBytes * 2, @"[Media] player state");
    NSString *trimmed = ApolloReportLogForAttachment(big);
    Check(trimmed != big, @"an oversized log is trimmed");
    Check([Header(trimmed) hasPrefix:@"[Apollo Reborn: older log lines removed to fit the report form"], @"trim is announced on the first line");
    Check(UTF8Length(Body(trimmed)) <= kApolloReportMaxLogBytes, @"kept part fits the cap");
    Check(UTF8Length(trimmed) < 20 * 1024 * 1024, @"result stays under the form's 20 MB file limit");
    Check([big hasSuffix:Body(trimmed)], @"the newest lines are the ones kept");
    Check([Body(trimmed) hasPrefix:@"[18:"], @"kept part starts on a whole line");

    // Multi-byte text near the cut never splits a character.
    NSString *unicode = LogOfAtLeast(kApolloReportMaxLogBytes + 4096, @"[Translate] café 👋 日本語");
    NSString *unicodeTrimmed = ApolloReportLogForAttachment(unicode);
    Check(unicodeTrimmed != unicode && [unicode hasSuffix:Body(unicodeTrimmed)], @"multi-byte log keeps its newest lines");
    Check([Body(unicodeTrimmed) hasPrefix:@"[18:"], @"multi-byte log is cut on a whole line");

    // No line break at all in the kept window: still lands on a character.
    NSString *noBreaks = Repeat(@"é👋", kApolloReportMaxLogBytes + 3);
    NSString *noBreaksTrimmed = ApolloReportLogForAttachment(noBreaks);
    Check(noBreaksTrimmed != noBreaks, @"a log with no line breaks is still trimmed");
    Check([noBreaks hasSuffix:Body(noBreaksTrimmed)], @"cut without a line break keeps the newest characters intact");
    Check(UTF8Length(Body(noBreaksTrimmed)) <= kApolloReportMaxLogBytes, @"cut without a line break fits the cap");

    NSLog(@"report log trim tests passed (%d checks)", checks);
    return 0;
} }
