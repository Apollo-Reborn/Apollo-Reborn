// Host-side checks for the All+ r/all merge core (src/ApolloAllPlusMerge.m):
// Reddit's hot rank, the per-sort merge key, and placement, plus the shared
// vectors in tests/fixtures/allplus_conformance.json.
#import <Foundation/Foundation.h>
#import <math.h>
#import "ApolloAllPlusMerge.h"

static void Require(BOOL cond, NSString *msg) {
    if (!cond) { @throw [NSException exceptionWithName:@"AllPlusTestFailure" reason:msg userInfo:nil]; }
}

static void RequireClose(double a, double b, double tol, NSString *msg) {
    Require(fabs(a - b) <= tol, [NSString stringWithFormat:@"%@: %f vs %f (tol %g)", msg, a, b, tol]);
}

static NSDictionary *Child(NSString *name, double score, double created, BOOL nsfw) {
    return @{ @"kind": @"t3", @"data": @{ @"name": name, @"score": @(score),
              @"created_utc": @(created), @"over_18": @(nsfw) } };
}

static void TestHotRank(void) {
    double older = ApolloAPHotRank(100, 1700000000);
    double newer = ApolloAPHotRank(100, 1700045000); // +45000s == +1.0 term
    Require(newer > older, @"newer post ranks higher at equal score");
    Require(fabs((newer - older) - 1.0) < 1e-6, @"45000s == +1.0 hot term");
    Require(ApolloAPHotRank(1000, 1700000000) > ApolloAPHotRank(10, 1700000000), @"higher score ranks higher");
}

static void TestSortKey(void) {
    NSDictionary *a = Child(@"t3_a", 500, 1700000000, NO);
    NSDictionary *b = Child(@"t3_b", 50, 1700040000, NO);
    Require(ApolloAPSortKey(a, @"top") > ApolloAPSortKey(b, @"top"), @"top keys by score");
    Require(ApolloAPSortKey(b, @"new") > ApolloAPSortKey(a, @"new"), @"new keys by created_utc");
    Require(ApolloAPSortKey(a, @"hot") == ApolloAPHotRank(500, 1700000000), @"hot key == hot rank");
    Require(ApolloAPSortKey(a, @"unknown") == ApolloAPHotRank(500, 1700000000), @"default sort == hot");
}

#pragma mark - conformance vectors

// A missing/unparsable file fails LOUDLY -- a silently-skipped conformance
// suite would report green while proving nothing.
static NSDictionary *LoadConformanceVectors(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        @throw [NSException exceptionWithName:@"AllPlusTestFailure"
                                        reason:[NSString stringWithFormat:@"could not read %@", path]
                                      userInfo:nil];
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        @throw [NSException exceptionWithName:@"AllPlusTestFailure"
                                        reason:[NSString stringWithFormat:@"%@ failed to parse: %@", path, err]
                                      userInfo:nil];
    }
    return obj;
}

static void TestConformanceNum(NSDictionary *vectors, double tol) {
    for (NSDictionary *v in vectors[@"num"]) {
        NSDictionary *child = @{ @"kind": @"t3", @"data": v[@"data"] };
        double got = ApolloAPNumFromData(child, v[@"key"]);
        RequireClose(got, [v[@"expected"] doubleValue], tol,
            [NSString stringWithFormat:@"conformance num(%@) of %@: %f vs %@", v[@"key"], v[@"data"], got, v[@"expected"]]);
    }
}

static void TestConformanceHotRank(NSDictionary *vectors, double tol) {
    for (NSDictionary *v in vectors[@"hotRank"]) {
        double got = ApolloAPHotRank([v[@"score"] doubleValue], [v[@"created_utc"] doubleValue]);
        RequireClose(got, [v[@"expected"] doubleValue], tol,
            [NSString stringWithFormat:@"conformance hotRank(%@,%@)", v[@"score"], v[@"created_utc"]]);
    }
}

static void TestConformancePlacement(NSDictionary *vectors) {
    for (NSDictionary *v in vectors[@"placement"]) {
        NSUInteger got = ApolloAPSlotFor(v[@"nativeHots"], [v[@"candHot"] doubleValue], [v[@"boost"] doubleValue]);
        Require(got == [v[@"expected"] unsignedIntegerValue],
            [NSString stringWithFormat:@"conformance placement slotFor(candHot=%@, B=%@): %lu vs %@",
                v[@"candHot"], v[@"boost"], (unsigned long)got, v[@"expected"]]);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TestHotRank();
        TestSortKey();

        NSString *path = argc > 1 ? @(argv[1]) : @"tests/fixtures/allplus_conformance.json";
        NSDictionary *vectors = LoadConformanceVectors(path);
        double tol = [vectors[@"tolerance"][@"hot"] doubleValue];
        TestConformanceNum(vectors, tol);
        TestConformanceHotRank(vectors, tol);
        TestConformancePlacement(vectors);

        printf("OK: allplus merge tests passed (%lu num, %lu hotRank, %lu placement vectors)\n",
               (unsigned long)[vectors[@"num"] count], (unsigned long)[vectors[@"hotRank"] count],
               (unsigned long)[vectors[@"placement"] count]);
    }
    return 0;
}
