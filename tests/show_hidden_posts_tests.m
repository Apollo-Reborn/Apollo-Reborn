#import <Foundation/Foundation.h>
#import "ApolloShowHiddenPosts.h"

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static void ExpectName(NSString *path, NSString *expected) {
    NSString *name = ApolloShowHiddenSubredditForListingPath(path);
    CHECK((name == nil && expected == nil) || [name isEqualToString:expected],
          @"%@ -> %@, expected %@", path, name ?: @"nil", expected ?: @"nil");
}

static void TestSubredditListings(void) {
    ExpectName(@"r/apple", @"apple");
    ExpectName(@"r/apple.json", @"apple");
    ExpectName(@"/r/apple/hot.json", @"apple");
    ExpectName(@"r/Apple/Top.json", @"apple");
    for (NSString *sort in @[ @"hot", @"new", @"rising", @"top", @"controversial", @"best", @"gilded" ]) {
        ExpectName([NSString stringWithFormat:@"r/apple/%@.json", sort], @"apple");
    }
    ExpectName(@"r/allergies/hot.json", @"allergies");
    ExpectName(@"r/randomthoughts/new.json", @"randomthoughts");
    ExpectName(@"r/popularopinion/new.json", @"popularopinion");
}

static void TestOtherFeeds(void) {
    ExpectName(nil, nil);
    ExpectName(@"", nil);
    ExpectName(@"hot.json", nil);
    ExpectName(@"best.json", nil);
    ExpectName(@"r/all/best.json", nil);
    ExpectName(@"r/All/hot.json", nil);
    ExpectName(@"r/all-funny-pics/hot.json", nil);
    ExpectName(@"r/popular/hot.json", nil);
    ExpectName(@"r/mod/new.json", nil);
    ExpectName(@"r/friends/new.json", nil);
    ExpectName(@"r/random/hot.json", nil);
    ExpectName(@"r/RandNSFW/hot.json", nil);
    ExpectName(@"r/apple+android/hot.json", nil);
    ExpectName(@"user/someone/m/tech/hot.json", nil);
    ExpectName(@"r/apple/search.json", nil);
    ExpectName(@"r/apple/comments/abc123.json", nil);
    ExpectName(@"r/apple/about/modqueue.json", nil);
    ExpectName(@"r/apple/hot.xml", nil);
    ExpectName(@"r//hot.json", nil);
}

static void TestParameters(void) {
    NSDictionary *merged = ApolloShowHiddenListingParameters(@{ @"limit": @"25", @"show": @"x" });
    CHECK([merged[@"show"] isEqualToString:@"all"], @"show is all");
    CHECK([merged[@"limit"] isEqualToString:@"25"], @"other parameters kept");
    CHECK([ApolloShowHiddenListingParameters(nil) isEqualToDictionary:@{ @"show": @"all" }], @"nil parameters");
    CHECK([ApolloShowHiddenListingParameters((NSDictionary *)@"bad") isEqualToDictionary:@{ @"show": @"all" }], @"non-dictionary parameters");
}

int main(void) {
    @autoreleasepool {
        TestSubredditListings();
        TestOtherFeeds();
        TestParameters();
    }
    if (sFailures > 0) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("show hidden posts tests passed\n");
    return 0;
}
