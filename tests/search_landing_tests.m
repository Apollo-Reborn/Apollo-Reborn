#import <Foundation/Foundation.h>
#import "ApolloSearchLandingPreferences.h"
#import "ApolloSearchRecents.h"
#import "UserDefaultConstants.h"

// The real model reads the same launch-loaded preference as the app. Keeping
// this single global here leaves the harness Foundation-only.
NSString *sRecentlyVisitedSubredditsLimit = @"5";

static NSUInteger sChecks;
static NSUInteger sFailures;
#define CHECK(condition, message) do { \
    sChecks++; \
    if (!(condition)) { sFailures++; fprintf(stderr, "FAIL: %s\n", message); } \
} while (0)

static void ClearHistory(NSString *notification) {
    [NSNotificationCenter.defaultCenter postNotificationName:notification object:nil];
}

static void TestSectionOrder(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id original = [defaults objectForKey:UDKeySearchTabSectionOrder];
    [defaults removeObjectForKey:UDKeySearchTabSectionOrder];
    NSArray *defaultOrder = @[@"trending", @"random", @"recent"];
    CHECK([ApolloSearchLandingSectionOrder() isEqualToArray:defaultOrder], "default section order");

    [defaults setObject:@[@"recent", @"bogus", @"recent", @42, @"trending"] forKey:UDKeySearchTabSectionOrder];
    CHECK(([ApolloSearchLandingSectionOrder() isEqualToArray:@[@"recent", @"trending", @"random"]]),
        "discard unknowns/duplicates and append missing sections");
    [defaults setObject:@"invalid" forKey:UDKeySearchTabSectionOrder];
    CHECK([ApolloSearchLandingSectionOrder() isEqualToArray:defaultOrder], "malformed saved order resets safely");

    __block NSUInteger notifications = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:ApolloSearchLandingSettingsDidChangeNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) { notifications++; }];
    ApolloSearchLandingSetSectionOrder(@[@"random", @"recent", @"trending"]);
    CHECK(([ApolloSearchLandingSectionOrder() isEqualToArray:@[@"random", @"recent", @"trending"]]), "order saves immediately");
    CHECK(notifications == 1, "changed order emits one live refresh");
    ApolloSearchLandingSetSectionOrder(@[@"random", @"recent", @"trending"]);
    CHECK(notifications == 1, "unchanged order does not refresh");
    ApolloSearchLandingSetSectionOrder(@[@"recent"]);
    CHECK(([[defaults objectForKey:UDKeySearchTabSectionOrder] isEqual:@[@"recent", @"trending", @"random"]]),
        "setter persists normalized complete order");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    if (original) [defaults setObject:original forKey:UDKeySearchTabSectionOrder];
    else [defaults removeObjectForKey:UDKeySearchTabSectionOrder];
}

static void TestHistory(void) {
    CHECK(ApolloSearchLandingRecentlyVisitedLimit() == 5, "recent limit defaults to five");
    CHECK(ApolloSearchRecentSubreddits().count == 0, "new process has no history");
    __block NSUInteger changes = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:ApolloSearchRecentsDidChangeNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) { changes++; }];
    for (NSString *name in @[@"Apple", @"ApolloReborn", @"iPhone", @"ios", @"technology", @"pics", @"aww"]) {
        ApolloSearchRecordVisit(name);
    }
    CHECK(([[ApolloSearchRecentSubreddits() firstObject] isEqualToString:@"aww"]), "newest visit first");
    CHECK(ApolloSearchRecentSubreddits().count == 5, "default limits visible history");
    NSArray *snapshot = ApolloSearchRecentSubreddits();
    ApolloSearchRecordVisit(@"  aPpLe \n");
    CHECK(([[ApolloSearchRecentSubreddits() firstObject] isEqualToString:@"aPpLe"]), "trimmed, case-insensitive revisit moves to front");
    CHECK([[snapshot firstObject] isEqualToString:@"aww"], "published snapshots remain immutable");
    NSUInteger before = changes;
    ApolloSearchRecordVisit(@"APPLE");
    CHECK(changes == before, "revisiting current top does not trigger redundant reload");

    sRecentlyVisitedSubredditsLimit = @"";
    CHECK(ApolloSearchLandingRecentlyVisitedLimit() == NSNotFound, "blank means unlimited");
    CHECK(ApolloSearchRecentSubreddits().count == 7, "raising limit restores earlier visits without duplicates");
    for (NSString *name in @[@"", @"  ", @"HOME", @"all", @"popular", @"mod", @"friends", @"random", @"randnsfw",
                              @"profile", @"settings", @"inbox", @"search", @"u/someone", @"r/Apple", @"a+b", @"bad name"]) {
        ApolloSearchRecordVisit(name);
    }
    CHECK(ApolloSearchRecentSubreddits().count == 7, "pseudo-feeds and invalid subreddit names rejected");
    CHECK(changes == before, "invalid visits emit no notification");

    sRecentlyVisitedSubredditsLimit = @"0";
    CHECK(ApolloSearchRecentSubreddits().count == 0, "zero hides recent rows");
    ApolloSearchRecordVisit(@"ask_reddit");
    sRecentlyVisitedSubredditsLimit = @"2";
    CHECK(ApolloSearchRecentSubreddits().count == 2, "smaller limit takes effect immediately");
    CHECK([[ApolloSearchRecentSubreddits() firstObject] isEqualToString:@"ask_reddit"], "valid underscore name recorded while hidden");
    sRecentlyVisitedSubredditsLimit = @"   ";
    CHECK(ApolloSearchRecentSubreddits().count == 8, "whitespace behaves like blank");
    sRecentlyVisitedSubredditsLimit = @"-4";
    CHECK(ApolloSearchLandingRecentlyVisitedLimit() == 0, "negative legacy value cannot underflow");
    sRecentlyVisitedSubredditsLimit = nil;
    CHECK(ApolloSearchLandingRecentlyVisitedLimit() == 5, "missing startup value falls back to five");

    before = changes;
    dispatch_semaphore_t backgroundDone = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        ApolloSearchRecordVisit(@"backgroundVisit");
        CHECK(ApolloSearchRecentSubreddits().count == 0, "off-main snapshot is safe and empty");
        dispatch_semaphore_signal(backgroundDone);
    });
    dispatch_semaphore_wait(backgroundDone, DISPATCH_TIME_FOREVER);
    CHECK(changes == before, "off-main recording cannot race history");
    ClearHistory(@"com.christianselig.RedditCurrentAccountChanged");
    CHECK(ApolloSearchRecentSubreddits().count == 0, "current account change clears history");
    CHECK(changes == before + 1, "clearing history notifies observers");
    ClearHistory(@"com.christianselig.RedditCurrentAccountChanged");
    CHECK(changes == before + 1, "empty history does not reload on account notification");
    ApolloSearchRecordVisit(@"otherAccount");
    ClearHistory(@"com.christianselig.RedditAccountChanged");
    CHECK(ApolloSearchRecentSubreddits().count == 0, "legacy account change clears history too");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

int main(void) {
    @autoreleasepool {
        TestSectionOrder();
        TestHistory();
        printf("%s: %lu checks\n", sFailures ? "FAILED" : "OK", (unsigned long)sChecks);
        return sFailures ? 1 : 0;
    }
}
