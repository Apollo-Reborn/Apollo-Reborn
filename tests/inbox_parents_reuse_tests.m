#import <Foundation/Foundation.h>
#import <objc/message.h>

// Exercises the shipping Inbox reply-parent reuse helpers from ApolloChatsFilter.xm (issue #1573)
// with an RDKClient double and a stubbed web-session store.
@interface TestUser : NSObject
@property(copy) NSString *username;
@end
@implementation TestUser
@end

@interface TestClient : NSObject
@property(strong) TestUser *currentUser;
@end
@implementation TestClient
@end

static NSSet<NSString *> *sKeylessUsers;
static id ApolloWebSessionFor(NSString *username) {
    return [sKeylessUsers containsObject:username.lowercaseString] ? @YES : nil;
}

#include "InboxParents.inc"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { failures++; NSLog(@"FAIL: %s", msg); } } while (0)

static TestClient *Client(NSString *username) {
    TestClient *client = [TestClient new];
    client.currentUser = [TestUser new];
    client.currentUser.username = username;
    return client;
}

int main(void) {
    @autoreleasepool {
        sKeylessUsers = [NSSet setWithObjects:@"keyless", @"other", nil];
        NSArray *things = @[@"t3_parent", @"t1_parent"];

        CHECK(ApolloInboxParentsReuseKey(Client(@"OAuthUser"), @[@"t3_a"]) == nil, "an OAuth account never reuses");
        CHECK(ApolloInboxParentsReuseKey(Client(@"keyless"), @[]) == nil, "an empty lookup has no key");
        CHECK(ApolloInboxParentsReuseKey(Client(@"keyless"), @[@"t3_a", @1]) == nil, "non-string names have no key");
        CHECK(ApolloInboxParentsReuseKey(Client(nil), @[@"t3_a"]) == nil, "a client without a user has no key");

        NSString *key = ApolloInboxParentsReuseKey(Client(@"Keyless"), @[@"t3_b", @"t1_a", @"t3_a"]);
        NSString *reordered = ApolloInboxParentsReuseKey(Client(@"keyless"), @[@"t3_a", @"t3_b", @"t1_a"]);
        CHECK(key != nil && [key isEqualToString:reordered], "the Set's order doesn't change the key");

        CHECK(ApolloInboxParentsReusable(key, NULL) == nil, "nothing to reuse before an answer");
        ApolloInboxParentsRemember(key, @[]);
        CHECK(ApolloInboxParentsReusable(key, NULL) == nil, "an empty answer is never reused");
        ApolloInboxParentsRemember(key, things);
        NSTimeInterval age = -1;
        CHECK([ApolloInboxParentsReusable(reordered, &age) isEqualToArray:things], "the same parents reuse the answer");
        CHECK(age >= 0 && age < 5, "the reuse reports the answer's age");

        NSString *newReply = ApolloInboxParentsReuseKey(Client(@"keyless"), @[@"t3_a", @"t3_b", @"t1_a", @"t1_new"]);
        CHECK(ApolloInboxParentsReusable(newReply, NULL) == nil, "a new reply asks Reddit again");
        NSString *otherAccount = ApolloInboxParentsReuseKey(Client(@"other"), @[@"t3_a", @"t3_b", @"t1_a"]);
        CHECK(ApolloInboxParentsReusable(otherAccount, NULL) == nil, "another account never gets this answer");

        sApolloInboxParentsAnsweredAt[key] = [NSDate dateWithTimeIntervalSinceNow:-(kApolloInboxParentsReuseTTL + 1)];
        CHECK(ApolloInboxParentsReusable(key, NULL) == nil, "an answer past the TTL is not reused");

        for (NSUInteger i = 0; i < kApolloInboxParentsReuseMaxEntries + 3; i++) {
            NSString *k = ApolloInboxParentsReuseKey(Client(@"keyless"), @[[NSString stringWithFormat:@"t1_%lu", (unsigned long)i]]);
            ApolloInboxParentsRemember(k, things);
            sApolloInboxParentsAnsweredAt[k] = [NSDate dateWithTimeIntervalSinceNow:-(double)(100 - i)];
        }
        CHECK(sApolloInboxParentsAnsweredAt.count == kApolloInboxParentsReuseMaxEntries, "the cache stays capped");
        CHECK(sApolloInboxParentsByKey.count == kApolloInboxParentsReuseMaxEntries, "answers are evicted with their dates");
        NSString *newest = ApolloInboxParentsReuseKey(Client(@"keyless"), @[[NSString stringWithFormat:@"t1_%lu", (unsigned long)(kApolloInboxParentsReuseMaxEntries + 2)]]);
        CHECK(ApolloInboxParentsReusable(newest, NULL) != nil, "the newest answer survives eviction");
    }
    if (failures) {
        NSLog(@"%d inbox parent reuse check(s) failed", failures);
        return 1;
    }
    NSLog(@"inbox parent reuse tests passed");
    return 0;
}
