#import <Foundation/Foundation.h>
#import <math.h>

#import "ApolloNativeSubredditIcons.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *label) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", label.UTF8String);
        exit(1);
    }
    checks++;
}

static NSString *ApolloActiveAccountUsername(void) { return @"TestAccount"; }
static NSString *ApolloActiveAccountRedditBearerToken(void) { return nil; }
static BOOL ApolloWebJSONHasUsableSession(void) { return NO; }
static NSString *ApolloActiveWebSessionUsername(void) { return nil; }
static NSString *sUserAgent = @"ApolloSubredditInfoTests/1.0";
#define ApolloLog(...) do {} while (0)

// INSERT_PRODUCTION_MODEL
// INSERT_PRODUCTION_CONSTANTS

@interface SubredditInfoHarness : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, ApolloSubredditInfo *> *diskInfo;
- (ApolloSubredditInfo *)infoFromResponseData:(NSData *)data fallbackSubredditName:(NSString *)name;
- (NSDictionary *)dictionaryForInfo:(ApolloSubredditInfo *)info;
- (ApolloSubredditInfo *)infoFromDictionary:(NSDictionary *)dict fallbackSubredditName:(NSString *)name;
- (BOOL)isFreshInfo:(ApolloSubredditInfo *)info;
- (NSURLRequest *)requestForSubreddit:(NSString *)name;
- (NSMutableURLRequest *)requestForRedditPath:(NSString *)path;
- (NSString *)webSessionUsernameForRequest:(NSURLRequest *)request;
- (void)pruneDiskInfoLocked;
@end

@implementation SubredditInfoHarness
// INSERT_PRODUCTION_METHODS
@end

static ApolloSubredditInfo *Parse(SubredditInfoHarness *cache, NSDictionary *fields) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"data": fields} options:0 error:NULL];
    Check(data != nil, @"fixture is valid JSON");
    return [cache infoFromResponseData:data fallbackSubredditName:@"example"];
}

static ApolloSubredditInfo *CheckArtworkPriority(SubredditInfoHarness *cache) {
    NSString *modernIcon = @"https://styles.redditmedia.com/communityIcon.png";
    NSString *legacyIcon = @"https://b.thumbs.redditmedia.com/icon.png";
    NSString *mobileBanner = @"https://styles.redditmedia.com/mobileBanner.png";
    NSString *desktopBanner = @"https://styles.redditmedia.com/bannerBackgroundImage.png";
    NSString *legacyBanner = @"https://b.thumbs.redditmedia.com/banner.png";
    NSMutableDictionary *fields = [@{
        @"community_icon": modernIcon, @"icon_img": legacyIcon,
        @"mobile_banner_image": mobileBanner,
        @"banner_background_image": desktopBanner, @"banner_img": legacyBanner,
    } mutableCopy];
    ApolloSubredditInfo *info = Parse(cache, fields);
    Check([info.iconURL.absoluteString isEqualToString:modernIcon], @"current icon wins over legacy icon");
    Check([info.bannerURL.absoluteString isEqualToString:mobileBanner], @"mobile banner wins over desktop and legacy");

    fields[@"community_icon"] = [NSNull null];
    fields[@"mobile_banner_image"] = @"";
    ApolloSubredditInfo *fallback = Parse(cache, fields);
    Check([fallback.iconURL.absoluteString isEqualToString:legacyIcon], @"missing modern icon uses legacy icon");
    Check([fallback.bannerURL.absoluteString isEqualToString:desktopBanner], @"missing mobile banner uses desktop banner");
    fields[@"banner_background_image"] = [NSNull null];
    Check([Parse(cache, fields).bannerURL.absoluteString isEqualToString:legacyBanner],
          @"missing modern banners use legacy banner");
    return info;
}

static void CheckMetadataMigration(SubredditInfoHarness *cache, ApolloSubredditInfo *fresh) {
    NSMutableDictionary *stored = [[cache dictionaryForInfo:fresh] mutableCopy];
    ApolloSubredditInfo *restored = [cache infoFromDictionary:stored fallbackSubredditName:@"example"];
    Check([cache isFreshInfo:restored] && restored.assetSelectionVersion == 1,
          @"new metadata persists with the current artwork version");

    [stored removeObjectForKey:@"assetSelectionVersion"];
    ApolloSubredditInfo *legacy = [cache infoFromDictionary:stored fallbackSubredditName:@"example"];
    Check(![cache isFreshInfo:legacy], @"old artwork refreshes before its normal TTL expires");
    cache.diskInfo = [@{@"example": legacy} mutableCopy];
    for (NSUInteger launch = 0; launch < 2; launch++) {
        [cache pruneDiskInfoLocked];
        Check(cache.diskInfo[@"example"] == legacy, @"migration retains the entry for failed-fetch fallback");
        NSDictionary *saved = [cache dictionaryForInfo:cache.diskInfo[@"example"]];
        Check([saved[@"assetSelectionVersion"] isEqual:@0], @"saving cannot mark old artwork as refreshed");
        legacy = [cache infoFromDictionary:saved fallbackSubredditName:@"example"];
        Check(![cache isFreshInfo:legacy], @"saved old artwork still needs a refresh on relaunch");
        Check(fabs([legacy.fetchedAt timeIntervalSinceDate:fresh.fetchedAt]) < 0.001,
              @"migration preserves the original age");
        Check([legacy.iconURL isEqual:fresh.iconURL] && [legacy.bannerURL isEqual:fresh.bannerURL],
              @"cached artwork remains available offline");
        cache.diskInfo[@"example"] = legacy;
    }
    cache.diskInfo[@"example"] = fresh;
    [cache pruneDiskInfoLocked];
    restored = [cache infoFromDictionary:[cache dictionaryForInfo:cache.diskInfo[@"example"]]
                  fallbackSubredditName:@"example"];
    Check([cache isFreshInfo:restored], @"a successful refresh persists as fresh");
}

static NSData *TrackerBlob(NSArray *entries) {
    return [NSKeyedArchiver archivedDataWithRootObject:entries requiringSecureCoding:NO error:NULL];
}

static NSArray *TrackerEntries(NSData *blob) {
    NSSet *classes = [NSSet setWithObjects:NSArray.class, NSString.class, NSURL.class, NSNull.class, nil];
    return [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:blob error:NULL];
}

static NSData *InfoResponse(NSArray<NSDictionary *> *subreddits) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSDictionary *fields in subreddits) [children addObject:@{@"kind": @"t5", @"data": fields}];
    [children addObject:@"not a child"];
    return [NSJSONSerialization dataWithJSONObject:@{@"kind": @"Listing", @"data": @{@"children": children}}
                                           options:0 error:NULL];
}

static void CheckNativeIconTracker(void) {
    NSString *oldIcon = @"https://styles.redditmedia.com/t5_1/styles/communityIcon_old.png?width=256&s=a";
    NSString *newIcon = @"https://styles.redditmedia.com/t5_1/styles/communityIcon_new.png?width=256&s=b";
    NSString *legacyIcon = @"https://b.thumbs.redditmedia.com/pics.png";
    NSString *keptIcon = @"https://styles.redditmedia.com/t5_3/styles/communityIcon_kept.png";
    // Apollo's shape: [name, iconURL, keyColor]; "https://null.org" marks no icon.
    NSArray *entries = @[
        @[@"apolloreborn", [NSURL URLWithString:oldIcon], @"8400ff"],
        @[@"pics", [NSURL URLWithString:@"https://null.org"], @""],
        @[@"AskReddit", [NSURL URLWithString:keptIcon], @"ff4500"],
        @[@"noicon", [NSURL URLWithString:@"https://null.org"], @""],
        @"unknown entry shape",
    ];
    NSData *blob = TrackerBlob(entries);
    Check([ApolloNativeSubredditIconNames(blob) isEqual:(@[@"apolloreborn", @"pics", @"AskReddit", @"noicon"])],
          @"tracker names are read in blob order");
    Check(ApolloNativeSubredditIconNames(nil).count == 0 &&
          ApolloNativeSubredditIconNames([@"junk" dataUsingEncoding:NSUTF8StringEncoding]).count == 0,
          @"missing or unreadable tracker data has no names");

    NSDictionary *found = ApolloNativeSubredditIconURLsFromInfoResponse(InfoResponse(@[
        @{@"display_name": @"ApolloReborn", @"community_icon": newIcon, @"icon_img": legacyIcon},
        @{@"display_name": @"pics", @"community_icon": @"", @"icon_img": legacyIcon},
        @{@"display_name": @"AskReddit", @"community_icon": keptIcon},
        @{@"display_name": @"noicon", @"community_icon": [NSNull null], @"icon_img": @""},
        @{@"display_name": @"insecure", @"community_icon": @"http://example.com/icon.png"},
    ]));
    Check([found isEqual:(@{@"apolloreborn": newIcon, @"pics": legacyIcon, @"askreddit": keptIcon})],
          @"info lookup prefers community_icon, falls back to icon_img, and skips missing or non-https icons");
    Check(ApolloNativeSubredditIconURLsFromInfoResponse([@"<html>" dataUsingEncoding:NSUTF8StringEncoding]).count == 0,
          @"a non-JSON response finds nothing");

    NSUInteger changed = 0;
    NSArray *updated = TrackerEntries(ApolloNativeSubredditIconDataApplyingURLs(blob, found, &changed));
    Check(changed == 2, @"only icons that differ are replaced");
    Check([updated[0] isEqual:(@[@"apolloreborn", [NSURL URLWithString:newIcon], @"8400ff"])],
          @"a replaced icon keeps its name and key color");
    Check([updated[1][1] isEqual:[NSURL URLWithString:legacyIcon]], @"a subreddit that gained an icon gets it");
    Check([updated[2] isEqual:entries[2]] && [updated[3] isEqual:entries[3]] && [updated[4] isEqual:entries[4]],
          @"unchanged, iconless and unrecognized entries are kept");
    Check(ApolloNativeSubredditIconDataApplyingURLs(blob, @{@"askreddit": keptIcon}, &changed) == nil && changed == 0,
          @"no rewrite when nothing changed");

    NSString *suite = [@"com.apollofix.tests.icons." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSDate *now = [NSDate date];
    Check(ApolloNativeSubredditIconRefreshIsDue(defaults, now), @"a lookup is due when none has run");
    ApolloNativeSubredditIconRecordRefresh(defaults, @{@"apolloreborn": newIcon}, NO, now);
    Check(ApolloNativeSubredditIconRefreshIsDue(defaults, now), @"a partial lookup retries next launch");
    ApolloNativeSubredditIconRecordRefresh(defaults, @{@"pics": legacyIcon}, YES, now);
    Check(!ApolloNativeSubredditIconRefreshIsDue(defaults, [now dateByAddingTimeInterval:6 * 86400]),
          @"a finished lookup is not repeated within a week");
    Check(ApolloNativeSubredditIconRefreshIsDue(defaults, [now dateByAddingTimeInterval:7 * 86400]),
          @"the lookup repeats after a week");
    Check(ApolloNativeSubredditIconRefreshIsDue(defaults, [now dateByAddingTimeInterval:-60]),
          @"a refresh date in the future counts as due");

    NSDictionary *unrelated = @{@"ShowSubredditIconsForPosts": @NO};
    for (NSString *key in unrelated) [defaults setObject:unrelated[key] forKey:key];
    [defaults setObject:blob forKey:@"SubredditIconData"];
    Check(ApolloNativeSubredditIconApplyPendingRefresh(defaults) == 2,
          @"pending icons from both lookups are written at launch");
    NSArray *applied = TrackerEntries([defaults dataForKey:@"SubredditIconData"]);
    Check([applied[0][1] isEqual:[NSURL URLWithString:newIcon]] && [applied[1][1] isEqual:[NSURL URLWithString:legacyIcon]],
          @"tracker data holds the current icons after launch");
    Check([defaults objectForKey:@"ApolloNativeSubredditIconPendingURLs"] == nil, @"pending icons are cleared once applied");
    Check([[defaults objectForKey:@"ShowSubredditIconsForPosts"] isEqual:@NO], @"unrelated preferences are untouched");
    Check(ApolloNativeSubredditIconApplyPendingRefresh(defaults) == 0, @"nothing is applied twice");

    [defaults removeObjectForKey:@"SubredditIconData"];
    ApolloNativeSubredditIconRecordRefresh(defaults, @{@"pics": legacyIcon}, YES, now);
    Check(ApolloNativeSubredditIconApplyPendingRefresh(defaults) == 0 &&
          [defaults objectForKey:@"ApolloNativeSubredditIconPendingURLs"] == nil &&
          [defaults objectForKey:@"SubredditIconData"] == nil,
          @"without tracker data the pending icons are dropped, not written");
    [defaults removePersistentDomainForName:suite];
}

static void CheckRequests(SubredditInfoHarness *cache) {
    NSURLRequest *about = [cache requestForSubreddit:@"example"];
    Check([about.URL.absoluteString isEqualToString:@"https://www.reddit.com/r/example/about.json?raw_json=1"],
          @"about request keeps its URL");
    Check([[about valueForHTTPHeaderField:@"User-Agent"] isEqualToString:sUserAgent], @"about request sends the user agent");
    Check([cache webSessionUsernameForRequest:about] == nil, @"no web session without one signed in");
}

int main(void) {
    @autoreleasepool {
        SubredditInfoHarness *cache = [SubredditInfoHarness new];
        ApolloSubredditInfo *fresh = CheckArtworkPriority(cache);
        CheckMetadataMigration(cache, fresh);
        CheckNativeIconTracker();
        CheckRequests(cache);
        printf("PASS: %lu subreddit info cache checks\n", (unsigned long)checks);
    }
}
