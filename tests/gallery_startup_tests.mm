#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloGalleryFeed.h"
#import "ApolloHostedVideo.h"
#import "ApolloGalleryGridGeometry.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

// Environment seams only. No account access, image download, or network is
// allowed in this harness; the production feed and source code run below.
static NSString *sUserAgent;
static NSString *activeTestUsername;
static NSString *ApolloActiveAccountUsername(void) { return activeTestUsername; }
static id ApolloActiveAccountClient(void) { return nil; }
static id ApolloWebSessionFor(NSString *username) { return username.length ? @YES : nil; }
static NSString *ApolloWebJSONSyntheticBearerTokenForUsername(NSString *username) {
    return username.length ? [@"test-bearer-" stringByAppendingString:username] : nil;
}
static BOOL ApolloShouldBlurNSFWMediaInSubreddit(NSString *subreddit) { return YES; }
static void ApolloLog(NSString *format, ...) {}
#define ApolloLogError ApolloLog
ApolloHostedVideoKind ApolloHostedVideoKindForURL(NSURL *url) { return ApolloHostedVideoNone; }
void ApolloHostedVideoResolve(NSURL *url, void (^completion)(NSURL *, NSURL *, CGSize, BOOL)) {
    Check(NO, @"startup must not resolve a hosted video");
}

static NSDictionary *testSavedDatabase;
@interface GalleryTestUserDefaults : NSObject
- (instancetype)initWithSuiteName:(NSString *)suite;
- (NSData *)dataForKey:(NSString *)key;
@end
@implementation GalleryTestUserDefaults
- (instancetype)initWithSuiteName:(NSString *)suite {
    Check([suite isEqualToString:@"group.com.christianselig.apollo"], @"saved categories use Apollo's group suite");
    return [super init];
}
- (NSData *)dataForKey:(NSString *)key {
    Check([key isEqualToString:@"SavedItemsCategoriesDatabase"], @"saved category database key matches native Apollo");
    return testSavedDatabase ? [NSJSONSerialization dataWithJSONObject:testSavedDatabase options:0 error:NULL] : nil;
}
@end
#define NSUserDefaults GalleryTestUserDefaults
#include "GalleryFeedProduction.inc"
#undef NSUserDefaults

@interface UIView : NSObject
@property (nonatomic) CGRect bounds;
@end
@implementation UIView @end

@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, readonly) UIView *viewIfLoaded;
@property (nonatomic, strong) NSArray *retainedLinks;
@property (nonatomic, strong) id retainedPagination;
@property (nonatomic, copy) NSString *savedCategory;
@end
@implementation UIViewController
- (UIView *)viewIfLoaded { return self.view; }
@end

@interface GalleryTestLink : NSObject
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, getter=isNSFW) BOOL NSFW;
@property (nonatomic, getter=isSpoiler) BOOL spoiler;
@property (nonatomic, strong) GalleryTestLink *crosspostParent;
@end
@implementation GalleryTestLink @end

@interface GalleryTestComment : NSObject @end
@implementation GalleryTestComment @end

@interface GalleryTestPagination : NSObject
@property (nonatomic, copy) NSString *after;
@end
@implementation GalleryTestPagination @end

@interface ApolloGalleryImageRequest : NSObject
- (void)cancel;
@end
@implementation ApolloGalleryImageRequest
- (void)cancel {}
@end
static NSUInteger warmedImages;
static BOOL warmedImagesAlreadyCached;
@interface ApolloGalleryImageLoader : NSObject
+ (instancetype)sharedLoader;
- (ApolloGalleryImageRequest *)prefetchThumbnailAtURL:(NSURL *)url;
@end
@implementation ApolloGalleryImageLoader
+ (instancetype)sharedLoader { static id loader; if (!loader) loader = [self new]; return loader; }
- (ApolloGalleryImageRequest *)prefetchThumbnailAtURL:(NSURL *)url {
    warmedImages++;
    return warmedImagesAlreadyCached ? nil : [ApolloGalleryImageRequest new];
}
@end

static Class ApolloClassRDKLink;
static Class ApolloClassRDKComment;
static Class ApolloClassPostsViewController;
static Class ApolloClassSavedPostsCommentsViewController;
static NSString *ApolloReadSwiftStringIvar(id owner, const char *name) {
    Check(strcmp(name, "filteredSaveCategory") == 0, @"Saved snapshot reads the active category");
    return [(UIViewController *)owner savedCategory];
}
#include "GallerySourceProduction.inc"

static void WriteWord(id object, const char *name, uintptr_t word) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    memcpy((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar), &word, sizeof(word));
}
static void WriteEnum(id object, const char *name, int64_t value, BOOL absent) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    uint8_t *base = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
    memcpy(base, &value, sizeof(value));
    base[sizeof(value)] = absent;
}
static UIViewController *Owner(NSArray *links, NSString *after) {
    UIViewController *owner = [ApolloClassPostsViewController new];
    owner.view = [UIView new];
    owner.view.bounds = CGRectMake(0, 0, 402, 700);
    owner.retainedLinks = [links mutableCopy]; // heap-backed NSArray, like native Swift storage
    WriteWord(owner, "links", (uintptr_t)(__bridge void *)owner.retainedLinks);
    if (after) {
        GalleryTestPagination *page = [GalleryTestPagination new];
        page.after = after;
        owner.retainedPagination = page;
    }
    WriteWord(owner, "$__lazy_storage_$_pagination", (uintptr_t)(__bridge void *)owner.retainedPagination);
    WriteEnum(owner, "currentSort", 1, NO);
    WriteEnum(owner, "currentTimeSort", 3, NO);
    return owner;
}
static NSDictionary *Photo(NSString *name) {
    return @{@"name": [@"t3_" stringByAppendingString:name], @"title": name, @"author": @"author",
             @"subreddit": @"test", @"url": [NSString stringWithFormat:@"https://i.redd.it/%@.jpg", name],
             @"over_18": @NO, @"spoiler": @NO};
}
static NSDictionary *Listing(NSArray *posts, NSString *after) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSDictionary *post in posts) [children addObject:@{@"kind": @"t3", @"data": post}];
    return @{@"children": children, @"after": after ?: (id)NSNull.null};
}
static GalleryTestLink *Captured(NSDictionary *post) {
    GalleryTestLink *link = [GalleryTestLink new];
    link.fullName = post[@"name"];
    ApolloGallerySourceRememberPost(link, post);
    return link;
}

static UIViewController *SavedOwner(NSArray *things, NSString *after, NSString *category) {
    UIViewController *owner = [ApolloClassSavedPostsCommentsViewController new];
    ApolloGalleryBindSavedSourceToCurrentAccount(owner);
    owner.view = [UIView new];
    owner.view.bounds = CGRectMake(0, 0, 402, 700);
    owner.savedCategory = category;
    owner.retainedLinks = [things mutableCopy];
    WriteWord(owner, "savedPostsComments", (uintptr_t)(__bridge void *)owner.retainedLinks);
    if (after) {
        GalleryTestPagination *page = [GalleryTestPagination new];
        page.after = after;
        owner.retainedPagination = page;
    }
    WriteWord(owner, "currentPagination", (uintptr_t)(__bridge void *)owner.retainedPagination);
    return owner;
}

@interface GalleryTestFeed : ApolloGalleryFeed
@property (nonatomic, copy) NSArray<NSDictionary *> *pages;
@property (nonatomic, strong) NSMutableArray *requestedCursors;
@end
@implementation GalleryTestFeed
- (void)fetchPageWithCursor:(NSString *)after completion:(void (^)(NSDictionary *, NSString *))completion {
    if (!self.requestedCursors) self.requestedCursors = [NSMutableArray array];
    NSUInteger index = self.requestedCursors.count;
    [self.requestedCursors addObject:after ?: (id)NSNull.null];
    Check(index < self.pages.count, @"feed requested only the supplied pages");
    completion(self.pages[index], nil);
}
@end
static NSRange Load(ApolloGalleryFeed *feed) {
    __block BOOL completed = NO;
    __block NSRange range = NSMakeRange(NSNotFound, 0);
    [feed loadNextBatchWithCompletion:^(NSRange added, NSString *error) {
        Check(error == nil, @"fixture load succeeds");
        range = added;
        completed = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    Check(completed, @"load completion reached the main queue");
    return range;
}

static void TestCaptureAndGuards(void) {
    NSMutableDictionary *post = [Photo(@"capture") mutableCopy];
    post[@"selftext"] = @"must not retain";
    post[@"access_token"] = @"must not retain";
    post[@"preview"] = @{@"images": @[@{@"source": @{@"url": @"https://preview.redd.it/a.jpg"},
                                            @"variants": @{@"gif": @{@"source": @{@"url": @"https://i.redd.it/a.gif"}}}}]};
    post[@"media_metadata"] = @{@"image": @{@"s": @{@"u": @"https://i.redd.it/b.jpg"}}};
    post[@"gallery_data"] = @{@"items": @[@{@"media_id": @"image"}]};
    post[@"is_gallery"] = @YES;
    post[@"crosspost_parent_list"] = @[@{@"url": @"https://i.redd.it/parent.jpg", @"over_18": @YES,
                                             @"selftext": @"omit parent text"}];
    NSDictionary *compact = ApolloGallerySourceCompactPost(@{@"kind": @"t3", @"data": post}, YES);
    Check(!compact[@"selftext"] && !compact[@"access_token"], @"capture excludes unrelated and credential fields");
    Check([compact[@"preview"] isEqual:post[@"preview"]] && [compact[@"media_metadata"] isEqual:post[@"media_metadata"]],
          @"capture preserves animation variants and gallery metadata");
    Check([compact[@"gallery_data"] isEqual:post[@"gallery_data"]] && [compact[@"is_gallery"] boolValue], @"capture preserves gallery order");
    Check(!compact[@"crosspost_parent_list"][0][@"selftext"] && [compact[@"crosspost_parent_list"][0][@"over_18"] boolValue],
          @"crosspost capture retains media/flags without unrelated text");
    Check(ApolloGallerySourceCompactPost((id)@"invalid", YES) == nil, @"non-dictionary capture rejected");

    UIViewController *owner = Owner(@[Captured(Photo(@"a"))], @"t3_a");
    Check(ApolloGallerySourceLinks(owner).count == 1, @"class-element array copied through NSArray");
    WriteWord(owner, "links", 1);
    Check(ApolloGallerySourceLinks(owner) == nil, @"small non-pointer array rejected");
    WriteWord(owner, "links", 0x4000000100000000ULL);
    Check(ApolloGallerySourceLinks(owner) == nil, @"Swift bridged/tagged array rejected before messaging");
    WriteWord(owner, "links", (uintptr_t)(__bridge void *)owner.retainedPagination);
    Check(ApolloGallerySourceLinks(owner) == nil, @"non-array object rejected");
    owner = Owner(@[], @"t3_a");
    Check(ApolloGallerySourceLinks(owner) == nil, @"empty source declined");

    owner = Owner(@[Captured(Photo(@"a"))], @"t3_a");
    NSString *after;
    Check(ApolloGallerySourceCursor(owner, &after) && [after isEqualToString:@"t3_a"], @"cursor copied");
    WriteWord(owner, "$__lazy_storage_$_pagination", 1);
    Check(!ApolloGallerySourceCursor(owner, &after), @"lazy-uninitialized sentinel rejected");
    WriteWord(owner, "$__lazy_storage_$_pagination", 0);
    Check(ApolloGallerySourceCursor(owner, &after) && after == nil, @"initialized nil means native exhaustion");
    WriteWord(owner, "$__lazy_storage_$_pagination", (uintptr_t)(__bridge void *)owner.retainedPagination);
    [(GalleryTestPagination *)owner.retainedPagination setAfter:nil];
    Check(!ApolloGallerySourceCursor(owner, &after), @"pending first-page cursor does not reuse old links");

    ApolloGallerySort sort;
    ApolloGalleryTopWindow window;
    for (int64_t raw = 1; raw <= 6; raw++) {
        WriteEnum(owner, "currentSort", raw, NO);
        Check(ApolloGallerySourceSort(owner, &sort, &window), @"supported native sort maps");
    }
    WriteEnum(owner, "currentSort", 6, NO);
    WriteEnum(owner, "currentTimeSort", 1, NO);
    Check(!ApolloGallerySourceSort(owner, &sort, &window), @"This Hour cannot seed Today");
    WriteEnum(owner, "currentTimeSort", 7, NO);
    Check(ApolloGallerySourceSort(owner, &sort, &window) && sort == ApolloGallerySortTop && window == ApolloGalleryTopWindowAll,
          @"Top All Time maps exactly");
    WriteEnum(owner, "currentSort", 1, YES);
    Check(!ApolloGallerySourceSort(owner, &sort, &window), @"absent optional sort declines seed");
}

static void TestSourceCoverageAndFlags(void) {
    GalleryTestLink *first = Captured(Photo(@"first"));
    GalleryTestLink *cold = [GalleryTestLink new];
    UIViewController *owner = Owner(@[first, cold], @"t3_end");
    Check(ApolloGallerySourceSnapshotForOwner(owner) == nil, @"one uncaptured link rejects the whole cursor snapshot");
    ApolloGallerySourceRememberPost(cold, @{@"name": @"t3_text", @"selftext": @"text only"});
    ApolloGallerySourceSnapshot *snapshot = ApolloGallerySourceSnapshotForOwner(owner);
    Check([snapshot.listing[@"children"] count] == 2, @"media-free posts still count toward complete cursor coverage");
    ApolloGalleryPrepareSource(owner);
    first.NSFW = YES;
    first.spoiler = YES;
    ApolloGalleryFeed *feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    Check(ApolloGallerySeedFeedFromSource(feed, owner), @"complete matching snapshot seeds immediately");
    Check(feed.items.firstObject.isNSFW && feed.items.firstObject.isSpoiler, @"native flags changed after menu preparation remain live");

    GalleryTestLink *parent = Captured(Photo(@"parent"));
    GalleryTestLink *crosspost = Captured(@{@"name": @"t3_cross", @"crosspost_parent_list": @[Photo(@"parent")]});
    crosspost.crosspostParent = parent;
    owner = Owner(@[crosspost], nil);
    ApolloGalleryPrepareSource(owner);
    parent.NSFW = YES;
    feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.items.firstObject.isNSFW,
          @"crosspost parent flag changes propagate without replacing original media");
    feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    feed.sort = ApolloGallerySortNew;
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"mismatched sort cannot inherit source cursor");

    NSMutableArray *many = [NSMutableArray array];
    for (NSUInteger i = 0; i < 40; i++) [many addObject:Captured(Photo([NSString stringWithFormat:@"warm%lu", (unsigned long)i]))];
    warmedImages = 0;
    id previousSize = [NSUserDefaults.standardUserDefaults objectForKey:kApolloGalleryTileSizeKey];
    [NSUserDefaults.standardUserDefaults setInteger:2 forKey:kApolloGalleryTileSizeKey];
    owner = Owner(many, @"t3_last");
    ApolloGalleryPrepareSource(owner);
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 8, @"two-column warming covers viewport plus one row without a fixed batch");
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kApolloGalleryTileSizeKey];
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 28, @"denser saved size extends the already-warmed prefix");
    owner.view.bounds = CGRectMake(0, 0, 402, 1500);
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 40, @"larger viewport warms the rest of a short source listing");

    [many removeAllObjects];
    for (NSUInteger i = 0; i < 120; i++) {
        NSMutableDictionary *photo = [Photo([NSString stringWithFormat:@"wide%lu", (unsigned long)i]) mutableCopy];
        photo[@"preview"] = @{@"images": @[@{@"source": @{@"width": @1000, @"height": @500,
            @"url": photo[@"url"]}}]};
        [many addObject:Captured(photo)];
    }
    owner = Owner(many, @"t3_last");
    warmedImages = 0;
    warmedImagesAlreadyCached = YES;
    ApolloGalleryPrepareSource(owner);
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 64, @"four-column landscape viewport warms beyond 24, even with cached nil handles");
    owner.view.bounds = CGRectMake(0, 0, 402, 2000);
    ApolloGalleryPrepareSource(owner);
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 96, @"larger repeat preparation remains capped and never restarts cached prefix");
    warmedImagesAlreadyCached = NO;
    if (previousSize) [NSUserDefaults.standardUserDefaults setObject:previousSize forKey:kApolloGalleryTileSizeKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kApolloGalleryTileSizeKey];
}

static void TestPreparationState(void) {
    GalleryTestLink *link = Captured(Photo(@"prepared"));
    UIViewController *owner = Owner(@[link], @"t3_cursor");
    NSDictionary *state = ApolloGallerySourcePreparationState(owner);
    Check(state && [state isEqual:ApolloGallerySourcePreparationState(owner)],
          @"unchanged live source has an equal preparation key");
    link.NSFW = YES;
    Check(![state isEqual:ApolloGallerySourcePreparationState(owner)],
          @"live NSFW changes invalidate a prepared gallery");
    link.NSFW = NO;
    link.spoiler = YES;
    Check(![state isEqual:ApolloGallerySourcePreparationState(owner)],
          @"live spoiler changes invalidate a prepared gallery");
    link.spoiler = NO;
    [(GalleryTestPagination *)owner.retainedPagination setAfter:@"t3_next"];
    Check(![state isEqual:ApolloGallerySourcePreparationState(owner)],
          @"source pagination invalidates a prepared continuation");
    [(GalleryTestPagination *)owner.retainedPagination setAfter:@"t3_cursor"];
    WriteEnum(owner, "currentSort", 2, NO);
    Check(![state isEqual:ApolloGallerySourcePreparationState(owner)],
          @"source sort changes invalidate preparation");
    owner = Owner(@[link, [GalleryTestLink new]], @"t3_cursor");
    Check(ApolloGallerySourcePreparationState(owner) == nil,
          @"incomplete captured source cannot validate a prepared gallery");
}

static void TestFeedPaging(void) {
    GalleryTestFeed *feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    NSDictionary *seed = Listing(@[Photo(@"one"), Photo(@"two"), Photo(@"one")], @"t3_end");
    Check([feed seedFromListing:seed] && feed.items.count == 2, @"seed deduplicates media");
    Check([feed.items[0].postTitle isEqualToString:@"one"] && [feed.items[1].postTitle isEqualToString:@"two"], @"seed retains source ordering");
    Check(![feed seedFromListing:seed], @"populated feed cannot be reseeded");
    feed.pages = @[Listing(@[Photo(@"two"), Photo(@"three")], nil)];
    NSRange range = Load(feed);
    Check([feed.requestedCursors.firstObject isEqualToString:@"t3_end"], @"continuation starts after all seeded source posts");
    Check(range.location == 2 && range.length == 1 && feed.items.count == 3 && feed.isExhausted, @"continuation deduplicates and appends exactly once");
    [feed reset];
    Check(feed.items.count == 0 && !feed.isExhausted && !feed.isLoading, @"reset clears seed state");
    feed.pages = @[Listing(@[Photo(@"fresh")], @"t3_fresh"), Listing(@[Photo(@"unused")], nil)];
    feed.requestedCursors = nil;
    range = Load(feed);
    Check(feed.requestedCursors.firstObject == NSNull.null && feed.requestedCursors.count == 1,
          @"first cold page renders without waiting for 24 media or another request");
    Check(range.location == 0 && range.length == 1 && !feed.isExhausted, @"first cold page keeps continuation available");

    feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    Check(![feed seedFromListing:Listing(@[@{@"name": @"t3_text"}], nil)] && !feed.isExhausted,
          @"media-free seed cannot exhaust fresh gallery");
    feed.pages = @[Listing(@[@{@"name": @"t3_text"}], @"t3_text"), Listing(@[Photo(@"found")], @"t3_found"),
                   Listing(@[Photo(@"unused")], nil)];
    range = Load(feed);
    Check(feed.requestedCursors.count == 2 && range.length == 1, @"cold load walks empty page then returns first usable page");
    [feed reset];
    Check([feed seedFromListing:Listing(@[Photo(@"found")], nil)] && feed.isExhausted, @"reset clears dedup keys and nil seed cursor is exhausted");

    // A small source listing can underfill a four-column viewport. The next
    // useful page must be visible without waiting for yet another request.
    NSMutableArray *seedPhotos = [NSMutableArray array];
    NSMutableArray *nextPhotos = [NSMutableArray array];
    for (NSUInteger index = 0; index < 12; index++) {
        [seedPhotos addObject:Photo([NSString stringWithFormat:@"seed%lu", (unsigned long)index])];
    }
    for (NSUInteger index = 0; index < 6; index++) {
        [nextPhotos addObject:Photo([NSString stringWithFormat:@"next%lu", (unsigned long)index])];
    }
    feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    Check([feed seedFromListing:Listing(seedPhotos, @"t3_seed12")], @"short source listing seeds successfully");
    feed.pages = @[Listing(nextPhotos, @"t3_next6"), Listing(@[Photo(@"not_requested_yet")], nil)];
    range = Load(feed);
    Check(feed.requestedCursors.count == 1 && range.location == 12 && range.length == 6 && feed.items.count == 18,
          @"seeded continuation publishes six new tiles before requesting another page");
    Check(!feed.isLoading && !feed.isExhausted, @"useful page completion leaves continuation available");

    feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    Check([feed seedFromListing:Listing(seedPhotos, @"t3_seed12")], @"sparse continuation starts from a seed");
    feed.pages = @[Listing(@[@{@"name": @"t3_text"}], @"t3_text"),
                   Listing(@[seedPhotos.firstObject], @"t3_duplicate"),
                   Listing(nextPhotos, @"t3_next6"), Listing(@[Photo(@"unused")], nil)];
    range = Load(feed);
    Check(feed.requestedCursors.count == 3 && range.location == 12 && range.length == 6 && !feed.isExhausted,
          @"seeded continuation skips empty and duplicate-only pages then publishes first useful page");

    feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    Check([feed seedFromListing:Listing(seedPhotos, @"t3_seed12")], @"empty-page limit starts from seed");
    feed.pages = @[Listing(@[], @"t3_empty1"), Listing(@[], @"t3_empty2"),
                   Listing(@[], @"t3_empty3"), Listing(nextPhotos, nil)];
    range = Load(feed);
    Check(feed.requestedCursors.count == 3 && range.length == 0 && feed.isExhausted && !feed.isLoading,
          @"three consecutive empty pages still stop continuation without a fourth request");

    // The mocked network callback enqueues production processing on main.
    // Change the filter before that queued page is admitted, then verify its
    // stale completion cannot append or advance the inherited cursor.
    feed = [[GalleryTestFeed alloc] initWithHomeFeed];
    Check([feed seedFromListing:Listing(seedPhotos, @"t3_seed12")], @"filter race starts from seed");
    feed.pages = @[Listing(@[Photo(@"stale")], @"t3_stale"), Listing(nextPhotos, @"t3_next6")];
    __block BOOL staleCompletion = NO;
    [feed loadNextBatchWithCompletion:^(__unused NSRange added, __unused NSString *error) { staleCompletion = YES; }];
    feed.allowedKinds = ApolloGalleryMediaKindVideo;
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    Check(drained && !staleCompletion && feed.items.count == 0 && feed.allItems.count == 12 && !feed.isLoading,
          @"filter change cancels a queued useful page without appending or completing it");
    feed.allowedKinds = ApolloGalleryMediaKindAll;
    range = Load(feed);
    Check([feed.requestedCursors.lastObject isEqualToString:@"t3_seed12"] && range.location == 12 && range.length == 6,
          @"load after filter cancellation refetches the unchanged source cursor");
}

static void TestSavedFeed(void) {
    activeTestUsername = @"gallery_first";
    ApolloGalleryFeed *feed = [[ApolloGalleryFeed alloc] initWithSavedCategory:nil];
    activeTestUsername = @"gallery_second";
    NSURLRequest *request = [feed requestForCursor:@"t1_comment" useOAuthHost:YES];
    Check([request.URL.path isEqualToString:@"/user/gallery_first/saved"], @"Saved endpoint stays bound to the opening account");
    Check([[request valueForHTTPHeaderField:@"Authorization"] isEqualToString:@"Bearer test-bearer-gallery_first"],
          @"Saved authentication stays bound after switching active account");
    Check([request.URL.query containsString:@"after=t1_comment"] && ![request.URL.query containsString:@"sort="] &&
          ![request.URL.query containsString:@"&t="], @"Saved preserves native mixed-list cursor without subreddit sort parameters");
    Check(!feed.supportsSorting && !feed.supportsBestSort && !feed.supportsRisingSort, @"Saved offers no listing sorts");
    [feed setSort:ApolloGallerySortTop topWindow:ApolloGalleryTopWindowAll];
    Check(feed.sort == ApolloGallerySortNew && [feed.sortDisplayName isEqualToString:@"Saved"], @"Saved ignores unsupported sort changes");
    Check([feed requestForCursor:nil useOAuthHost:NO] == nil, @"Saved cannot fall back to another account or anonymous transport");

    activeTestUsername = nil;
    feed = [[ApolloGalleryFeed alloc] initWithSavedCategory:nil];
    __block BOOL completed = NO;
    [feed fetchPageWithCursor:nil completion:^(NSDictionary *listing, NSString *error) {
        completed = listing == nil && error.length > 0;
    }];
    Check(completed && [feed requestForCursor:nil useOAuthHost:YES] == nil, @"signed-out Saved fails before creating a request");

    activeTestUsername = @"gallery_first";
    testSavedDatabase = @{@"categories": @{@"Trips": @[@"T3_SECOND", @"t1_comment", @"t3_first", @"t3_second", @"t3_stale", @"t3_bad&sort=top", @42],
                                            @"Empty": @[]}};
    feed = [[ApolloGalleryFeed alloc] initWithSavedCategory:@"Trips"];
    Check([feed.savedCategoryPostIDs isEqual:[NSSet setWithArray:@[@"t3_second", @"t3_first", @"t3_stale"]]],
          @"local category captures case-insensitive post membership, excluding comments and malformed values");
    request = [feed requestForCursor:nil useOAuthHost:YES];
    Check([request.URL.path isEqualToString:@"/user/gallery_first/saved"] &&
          ![request.URL.query containsString:@"category="] && ![request.URL.query containsString:@"id="],
          @"local category filters the bound Saved listing instead of Premium categories or stale-ID lookups");
    NSDictionary *mixed = @{@"children": @[@{@"kind": @"t1", @"data": Photo(@"comment")},
                                             @{@"kind": @"t3", @"data": Photo(@"outside")},
                                             @{@"kind": @"t3", @"data": Photo(@"first")},
                                             @{@"kind": @"t3", @"data": Photo(@"second")}], @"after": NSNull.null};
    [feed appendItemsFromListing:mixed];
    Check(feed.allItems.count == 2 && [feed.allItems[0].postFullname isEqualToString:@"t3_first"] &&
          [feed.allItems[1].postFullname isEqualToString:@"t3_second"],
          @"category preserves Saved-list order, excludes comments/non-members, and never resurrects stale saved IDs");

    feed = [[ApolloGalleryFeed alloc] initWithSavedCategory:@"Empty"];
    Check(feed.isExhausted && !feed.isLoading, @"empty category is ready before Gallery can start its spinner");
    Check(Load(feed).length == 0 && feed.isExhausted && feed.lastErrorMessage == nil,
          @"empty local category finishes without a network request or falling back to All");
    feed = [[ApolloGalleryFeed alloc] initWithSavedCategory:@"Missing"];
    completed = NO;
    [feed fetchPageWithCursor:nil completion:^(NSDictionary *listing, NSString *error) {
        completed = listing == nil && error.length > 0;
    }];
    Check(completed && [feed requestForCursor:nil useOAuthHost:YES] == nil,
          @"missing category reports an error and never falls back to All");

    testSavedDatabase = @{@"categories": @{@"Trips": @[@"t3_changed"]}};
    feed = [[ApolloGalleryFeed alloc] initWithSavedCategory:@"Trips"];
    testSavedDatabase = @{@"categories": @{@"Trips": @[@"T3_REFRESHED"]}};
    [feed reset];
    Check([feed.savedCategoryPostIDs isEqual:[NSSet setWithObject:@"t3_refreshed"]], @"refresh rereads category membership");

    GalleryTestFeed *paging = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    paging.pages = @[Listing(@[], @"t1_a"), Listing(@[], @"t1_b"), Listing(@[], @"t1_c"),
                     Listing(@[], @"t1_d"), Listing(@[Photo(@"later")], nil)];
    Check(Load(paging).length == 1 && paging.isExhausted && paging.requestedCursors.count == 5,
          @"a single Saved load reaches media beyond four text/comment pages without needing a grid scroll");
    paging = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    paging.pages = @[Listing(@[], @"t1_same"), Listing(@[], @"t1_same")];
    Check(Load(paging).length == 0 && paging.isExhausted && paging.requestedCursors.count == 2,
          @"a repeated Saved cursor cannot create an endless scan of empty pages");
    testSavedDatabase = @{@"categories": @{@"Later": @[@"T3_MATCH"]}};
    paging = [[GalleryTestFeed alloc] initWithSavedCategory:@"Later"];
    paging.pages = @[Listing(@[Photo(@"outside1")], @"t3_outside1"), Listing(@[Photo(@"outside2")], @"t3_outside2"),
                     Listing(@[Photo(@"outside3")], @"t3_outside3"), Listing(@[Photo(@"outside4")], @"t3_outside4"),
                     Listing(@[Photo(@"match")], nil)];
    Check(Load(paging).length == 1 && paging.isExhausted && paging.requestedCursors.count == 5 &&
          [paging.items.firstObject.postFullname isEqualToString:@"t3_match"],
          @"category scanning reaches its first member beyond four pages of other saved media");
    testSavedDatabase = @{@"categories": @{@"Early": @[@"t3_early", @"t3_note"]}};
    paging = [[GalleryTestFeed alloc] initWithSavedCategory:@"Early"];
    paging.pages = @[Listing(@[Photo(@"early"), @{@"name": @"t3_note"}], @"t3_note"),
                     Listing(@[Photo(@"unrelated")], @"t3_unrelated"), Listing(@[Photo(@"tail")], nil)];
    Check(Load(paging).length == 1 && paging.isExhausted && paging.requestedCursors.count == 1,
          @"category stops paging Saved once every member has been met, media or not");
    paging = [[GalleryTestFeed alloc] initWithSavedCategory:@"Early"];
    paging.pages = @[Listing(@[@{@"name": @"t3_note"}], @"t3_note"), Listing(@[], @"t3_gap"),
                     Listing(@[@{@"name": @"t3_early"}], @"t3_early"), Listing(@[Photo(@"tail")], nil)];
    Check(Load(paging).length == 0 && paging.isExhausted && paging.requestedCursors.count == 3,
          @"text-only category finishes at its last member instead of walking all of Saved");
    activeTestUsername = nil;
    testSavedDatabase = nil;
}

static void TestSavedSourceStartup(void) {
    activeTestUsername = @"gallery_first";
    GalleryTestLink *photo = Captured(Photo(@"first"));
    GalleryTestLink *text = Captured(@{@"name": @"t3_text", @"title": @"Text only"});
    UIViewController *owner = SavedOwner(@[photo, [GalleryTestComment new], text], @"t1_cursor", nil);
    GalleryTestFeed *feed = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.items.count == 1 && !feed.isLoading,
          @"Saved media is available synchronously at selection without refetching the listing");
    Check(!feed.isExhausted && feed.requestedCursors.count == 0,
          @"Saved source keeps its mixed-list continuation without a startup request");
    feed.pages = @[Listing(@[Photo(@"second")], nil)];
    Check(Load(feed).length == 1 && [feed.requestedCursors.firstObject isEqualToString:@"t1_cursor"] &&
          feed.items.count == 2, @"Saved continues after the native cursor and retains its first media");

    testSavedDatabase = @{@"categories": @{@"Text": @[@"T3_TEXT", @"t1_comment"],
                                            @"Photos": @[@"t3_first"], @"Partial": @[@"t3_text", @"t3_later"]}};
    owner = SavedOwner(@[text, [GalleryTestComment new]], @"t1_more", @"Text");
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:@"Text"];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.isExhausted && feed.items.count == 0,
          @"all text-only category members prove emptiness immediately even before Saved ends");
    Check(Load(feed).length == 0 && feed.requestedCursors.count == 0,
          @"known empty category never fetches another Saved page");

    owner = SavedOwner(@[text], @"t3_cursor", @"Partial");
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:@"Partial"];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && !feed.isExhausted && feed.items.count == 0,
          @"a partial text-only category cannot be mistaken for a complete empty category");
    feed.pages = @[Listing(@[Photo(@"later")], nil)];
    Check(Load(feed).length == 1 && [feed.requestedCursors.firstObject isEqualToString:@"t3_cursor"],
          @"partial category skips already-inspected text and discovers later media");

    owner = SavedOwner(@[photo], @"t1_more", @"Photos");
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:@"Photos"];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.items.count == 1 && feed.isExhausted,
          @"complete media category opens with its tiles immediately and needs no unrelated Saved pages");
    warmedImages = 0;
    ApolloGalleryPrepareSource(owner);
    Check(warmedImages == 1, @"Saved preparation warms its category's first-screen thumbnail before selection");
    owner.savedCategory = @"Text";
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:@"Photos"];
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"category changed before selection cannot seed the wrong gallery");

    owner = SavedOwner(@[], nil, @"Partial");
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:@"Partial"];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.isExhausted && feed.items.count == 0,
          @"completed empty category response does not resurrect stale category IDs");
    owner = SavedOwner(@[], nil, nil);
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    Check(ApolloGallerySeedFeedFromSource(feed, owner) && feed.isExhausted,
          @"completed empty All Saved response displays an immediate empty state");
    owner = SavedOwner(nil, nil, nil);
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    Check(!ApolloGallerySeedFeedFromSource(feed, owner) && !feed.isExhausted,
          @"unloaded optional Saved array cannot prove emptiness");
    owner = SavedOwner(@[photo], @"", nil);
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"pending initial/refresh cursor cannot reuse old Saved posts");
    owner = SavedOwner(@[photo, [GalleryTestLink new]], nil, nil);
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"uncaptured Saved post prevents consuming a possibly incomplete snapshot");
    owner = SavedOwner(@[photo, [NSObject new]], nil, nil);
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"unknown Saved thing is not silently skipped as a comment");

    owner = SavedOwner(@[photo], @"t1_more", nil);
    activeTestUsername = @"gallery_second";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.christianselig.RedditCurrentAccountChanged" object:nil];
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"Saved source cannot seed a feed bound before an account switch");
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    ApolloGalleryBindSavedSourceToCurrentAccount(owner);
    Check(!ApolloGallerySeedFeedFromSource(feed, owner),
          @"a new feed after account switch cannot adopt the retained previous account's Saved rows or cursor");
    UIViewController *newOwner = SavedOwner(@[Captured(Photo(@"newaccount"))], nil, nil);
    Check(ApolloGallerySeedFeedFromSource(feed, newOwner) && feed.items.count == 1,
          @"a fresh Saved controller under the new account can seed immediately");
    owner.retainedLinks = [@[Captured(Photo(@"secondaccount"))] mutableCopy];
    WriteWord(owner, "savedPostsComments", (uintptr_t)(__bridge void *)owner.retainedLinks);
    activeTestUsername = @"gallery_first";
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.christianselig.RedditAccountChanged" object:nil];
    feed = [[GalleryTestFeed alloc] initWithSavedCategory:nil];
    Check(!ApolloGallerySeedFeedFromSource(feed, owner),
          @"switching back to the original account cannot revive a controller that may now contain another account's rows");
    owner = Owner(@[photo], @"t3_more");
    WriteEnum(owner, "currentSort", 3, NO);
    Check(!ApolloGallerySeedFeedFromSource(feed, owner), @"ordinary posts cannot become a private Saved listing");
    owner = SavedOwner(@[photo], @"t3_more", nil);
    ApolloGalleryFeed *home = [[ApolloGalleryFeed alloc] initWithHomeFeed];
    home.sort = ApolloGallerySortNew;
    Check(!ApolloGallerySeedFeedFromSource(home, owner), @"private Saved source cannot seed an ordinary gallery");
    activeTestUsername = nil;
    testSavedDatabase = nil;
}

int main(void) {
    @autoreleasepool {
        ApolloClassRDKLink = GalleryTestLink.class;
        ApolloClassRDKComment = GalleryTestComment.class;
        ApolloClassPostsViewController = objc_allocateClassPair(UIViewController.class, "GalleryTestPostsController", 0);
        class_addIvar(ApolloClassPostsViewController, "links", sizeof(uintptr_t), 3, "Q");
        class_addIvar(ApolloClassPostsViewController, "$__lazy_storage_$_pagination", sizeof(uintptr_t), 3, "Q");
        class_addIvar(ApolloClassPostsViewController, "currentSort", 9, 3, "[9C]");
        class_addIvar(ApolloClassPostsViewController, "currentTimeSort", 9, 3, "[9C]");
        objc_registerClassPair(ApolloClassPostsViewController);
        ApolloClassSavedPostsCommentsViewController = objc_allocateClassPair(UIViewController.class, "GalleryTestSavedController", 0);
        class_addIvar(ApolloClassSavedPostsCommentsViewController, "savedPostsComments", sizeof(uintptr_t), 3, "Q");
        class_addIvar(ApolloClassSavedPostsCommentsViewController, "currentPagination", sizeof(uintptr_t), 3, "Q");
        objc_registerClassPair(ApolloClassSavedPostsCommentsViewController);
        TestCaptureAndGuards();
        TestSourceCoverageAndFlags();
        TestPreparationState();
        TestFeedPaging();
        TestSavedFeed();
        TestSavedSourceStartup();
        printf("gallery_startup_tests: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
