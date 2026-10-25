#import <Foundation/Foundation.h>
#import "ApolloCommentNavigationModel.h"
#include <math.h>

static NSUInteger sChecks = 0;
static NSUInteger sFailures = 0;

#define CHECK(condition, ...) do { \
    sChecks++; \
    if (!(condition)) { \
        sFailures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
    } \
} while (0)

static NSData *JSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

static NSData *Text(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static void TestBaselines(void) {
    NSData *data = JSON(@[@"other", @{@"totalComments": @42, @"timestamp": @810500000},
                         @"abc123", @{@"totalComments": @120, @"timestamp": @810521581.25}]);
    NSDate *cutoff = ApolloCommentNavigationBaseline(data, @"abc123");
    CHECK(cutoff != nil, @"native alternating array resolves a post");
    CHECK(cutoff.timeIntervalSinceReferenceDate == 810521581.25, @"native Swift Date reference epoch and fractions are preserved");
    CHECK(cutoff.timeIntervalSince1970 == 1788828781.25, @"cutoff is not interpreted as Unix timestamp");
    CHECK([ApolloCommentNavigationBaseline(data, @"t3_ABC123") isEqualToDate:cutoff], @"bare stored IDs match a prefixed case-insensitive query");
    CHECK([ApolloCommentNavigationBaseline(JSON(@[@"t3_abc123", @{@"timestamp": @810521581.25}]), @"abc123") isEqualToDate:cutoff], @"prefixed stored IDs match a bare query");
    CHECK(ApolloCommentNavigationBaseline(data, @"missing") == nil, @"missing post has no previous-visit baseline");
    CHECK(ApolloCommentNavigationBaseline(nil, @"abc123") == nil, @"missing snapshot data");
    CHECK(ApolloCommentNavigationBaseline(data, nil) == nil, @"missing post ID");
    CHECK(ApolloCommentNavigationBaseline(data, @"t3_") == nil, @"empty normalized post ID");
    CHECK(ApolloCommentNavigationBaseline(Text(@"broken"), @"abc123") == nil, @"malformed JSON");
    CHECK(ApolloCommentNavigationBaseline(JSON(@{@"abc123": @{@"timestamp": @810521581}}), @"abc123") == nil, @"wrong root shape");
    CHECK(ApolloCommentNavigationBaseline(JSON(@[@"abc123"]), @"abc123") == nil, @"incomplete alternating entry");
    CHECK(ApolloCommentNavigationBaseline(JSON(@[@"abc123", @42]), @"abc123") == nil, @"wrong snapshot type");
    for (id timestamp in @[@YES, @NO, @"810521581", NSNull.null, @0, @(-1)]) {
        CHECK(ApolloCommentNavigationBaseline(JSON(@[@"abc123", @{@"timestamp": timestamp}]), @"abc123") == nil,
              @"invalid timestamp %@ is rejected", timestamp);
    }
    CHECK(ApolloCommentNavigationBaseline(Text(@"[\"abc123\",{\"timestamp\":NaN}]"), @"abc123") == nil, @"NaN JSON cannot create a date");
    CHECK(ApolloCommentNavigationBaseline(Text(@"[\"abc123\",{\"timestamp\":1e999}]"), @"abc123") == nil, @"nonfinite timestamp cannot create a date");
    NSMutableData *oversized = [NSMutableData dataWithLength:2 * 1024 * 1024 + 1];
    CHECK(ApolloCommentNavigationBaseline(oversized, @"abc123") == nil, @"oversized preference data is rejected before parsing");
    NSData *badNeighbor = JSON(@[@7, @{@"timestamp": @1}, @"bad", NSNull.null,
                                 @"abc123", @{@"timestamp": @810521581.25}]);
    CHECK([ApolloCommentNavigationBaseline(badNeighbor, @"abc123") isEqualToDate:cutoff], @"malformed unrelated entries do not discard a good post baseline");
}

static void TestNewComments(void) {
    NSDate *baseline = [NSDate dateWithTimeIntervalSinceReferenceDate:810521581];
    NSDate *newer = [baseline dateByAddingTimeInterval:0.25];
    CHECK(ApolloCommentNavigationIsNew(newer, baseline, @"somebody", @"reader"), @"strictly newer comment qualifies");
    CHECK(!ApolloCommentNavigationIsNew(baseline, baseline, @"somebody", @"reader"), @"same timestamp stays old");
    CHECK(!ApolloCommentNavigationIsNew([baseline dateByAddingTimeInterval:-1], baseline, @"somebody", @"reader"), @"older comment stays old");
    CHECK(!ApolloCommentNavigationIsNew(newer, nil, @"somebody", @"reader"), @"first visit without baseline does not mark all replies new");
    CHECK(!ApolloCommentNavigationIsNew(nil, baseline, @"somebody", @"reader"), @"missing creation date");
    CHECK(!ApolloCommentNavigationIsNew((id)@42, baseline, nil, nil), @"wrong creation date type");
    CHECK(!ApolloCommentNavigationIsNew(newer, (id)@42, nil, nil), @"wrong baseline type");
    CHECK(!ApolloCommentNavigationIsNew([NSDate dateWithTimeIntervalSinceReferenceDate:NAN], baseline, nil, nil), @"nonfinite creation date");
    CHECK(!ApolloCommentNavigationIsNew(newer, [NSDate dateWithTimeIntervalSinceReferenceDate:INFINITY], nil, nil), @"nonfinite baseline date");
    CHECK(!ApolloCommentNavigationIsNew(newer, baseline, @"Reader", @"reader"), @"current author is excluded case-insensitively");
    CHECK(ApolloCommentNavigationIsNew(newer, baseline, @"otherreader", @"reader"), @"author exclusion uses complete usernames");
    CHECK(ApolloCommentNavigationIsNew(newer, baseline, @"somebody", nil), @"logged-out browsing can still classify new comments");
    CHECK(ApolloCommentNavigationIsNew(newer, baseline, nil, @"reader"), @"missing author does not suppress a valid new timestamp");
    CHECK(ApolloCommentNavigationIsNew(newer, baseline, @"", @""), @"empty author names are not treated as a signed-in account");
}

static void ExpectTarget(NSArray<NSNumber *> *positions, double anchor, NSInteger direction,
                         NSInteger cursor, BOOL useCursor, NSInteger expected, BOOL expectedWrap,
                         NSString *description) {
    BOOL wrapped = !expectedWrap;
    NSInteger result = ApolloCommentNavigationTargetIndex(positions, anchor, direction, cursor, useCursor, &wrapped);
    CHECK(result == expected && wrapped == expectedWrap,
          @"%@: target=%ld (expected %ld), wrap=%d (expected %d)", description,
          (long)result, (long)expected, wrapped, expectedWrap);
}

static void TestNavigation(void) {
    NSArray *positions = @[@100, @250, @500];
    ExpectTarget(positions, 0, 1, NSNotFound, NO, 0, NO, @"forward starts at first below viewport anchor");
    ExpectTarget(positions, 100, 1, NSNotFound, NO, 1, NO, @"forward skips row already at anchor");
    ExpectTarget(positions, 98, 1, NSNotFound, NO, 1, NO, @"forward dead-band boundary is strict");
    ExpectTarget(positions, 97.9, 1, NSNotFound, NO, 0, NO, @"forward row outside dead band qualifies");
    ExpectTarget(positions, 499, 1, NSNotFound, NO, 0, YES, @"forward dead band wraps past last row");
    ExpectTarget(positions, 600, 1, NSNotFound, NO, 0, YES, @"forward wraps after last row");
    ExpectTarget(positions, 600, -1, NSNotFound, NO, 2, NO, @"backward starts at last above anchor");
    ExpectTarget(positions, 250, -1, NSNotFound, NO, 0, NO, @"backward skips row already at anchor");
    ExpectTarget(positions, 252, -1, NSNotFound, NO, 0, NO, @"backward dead-band boundary is strict");
    ExpectTarget(positions, 252.1, -1, NSNotFound, NO, 1, NO, @"backward row outside dead band qualifies");
    ExpectTarget(positions, 0, -1, NSNotFound, NO, 2, YES, @"backward wraps before first row");
    ExpectTarget(positions, 900, 1, 0, YES, 1, NO, @"retained cursor takes precedence over stale geometry");
    ExpectTarget(positions, 900, -1, 1, YES, 0, NO, @"retained cursor steps backward");
    ExpectTarget(positions, 0, 1, 2, YES, 0, YES, @"retained cursor wraps forward");
    ExpectTarget(positions, 900, -1, 0, YES, 2, YES, @"retained cursor wraps backward");
    ExpectTarget(positions, 100, 1, 0, NO, 1, NO, @"scrolling invalidates cursor and resumes from viewport");
    ExpectTarget(positions, 0, 1, 99, YES, 0, NO, @"out-of-range cursor resumes from viewport");
    ExpectTarget(positions, 100, 1, -1, YES, 1, NO, @"negative cursor resumes from viewport");
    ExpectTarget(@[@100], 0, 1, NSNotFound, NO, 0, NO, @"single candidate initially ahead");
    ExpectTarget(@[@100], 100, 1, 0, YES, 0, YES, @"single selected candidate wraps to itself");
    ExpectTarget(@[@100], 100, -1, 0, YES, 0, YES, @"single selected candidate wraps backward");
    ExpectTarget(@[], 0, 1, NSNotFound, NO, NSNotFound, NO, @"empty candidates initialize wrap and return no target");
    ExpectTarget(positions, 0, 0, 0, YES, NSNotFound, NO, @"zero direction has no target");
    ExpectTarget(positions, NAN, 1, NSNotFound, NO, NSNotFound, NO, @"invalid anchor has no geometry target");
    ExpectTarget(positions, NAN, 1, 0, YES, 1, NO, @"valid cursor does not depend on anchor geometry");
    ExpectTarget(@[@100, @(INFINITY)], 0, 1, NSNotFound, NO, NSNotFound, NO, @"nonfinite row geometry is rejected");
    ExpectTarget(@[@100, @YES], 0, 1, NSNotFound, NO, NSNotFound, NO, @"boolean row geometry is rejected");
    ExpectTarget(@[@250, @100], 0, 1, NSNotFound, NO, NSNotFound, NO, @"out-of-order geometry cannot pick an arbitrary row");
    CHECK(ApolloCommentNavigationTargetIndex(positions, 0, 1, NSNotFound, NO, NULL) == 0, @"wrap output is optional");
}

int main(void) {
    @autoreleasepool {
        TestBaselines();
        TestNewComments();
        TestNavigation();
        fprintf(stdout, "Comment navigation: %lu checks, %lu failures\n", (unsigned long)sChecks, (unsigned long)sFailures);
    }
    return sFailures ? 1 : 0;
}
