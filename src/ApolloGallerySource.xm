#import "ApolloGallerySource.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloGalleryGridGeometry.h"
#import "ApolloAccountCredentials.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"

#import <objc/message.h>
#import <objc/runtime.h>

// Keep the fields used by Gallery's existing JSON parser on the RDKLink that
// Apollo already owns. A second listing fetch used to be required just to get
// these same fields back. There is deliberately no global listing cache: the
// metadata has the exact lifetime of the source post, including account/feed
// changes, and never carries a token or cookie.
static char kApolloGallerySourcePostKey;
static char kApolloGallerySourcePreparedKey;
static char kApolloGallerySavedSourceAccountKey;
static const NSUInteger kApolloGallerySourceMaximumWarmThumbnails = 96;
static const NSUInteger kApolloGallerySourceMaximumPosts = 10000;
static const NSTimeInterval kApolloGallerySourcePreparationLifetime = 20.0;

static NSUInteger ApolloGallerySavedAccountGeneration(void) {
    static NSUInteger generation;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *name in @[@"com.christianselig.RedditCurrentAccountChanged",
                                  @"com.christianselig.RedditAccountChanged"]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                usingBlock:^(__unused NSNotification *notification) {
                    // Invalidations are synchronous even if a notification
                    // comes off main. A -> B -> A must not revive A's old
                    // controller after it may have loaded B's rows in between.
                    __atomic_add_fetch(&generation, 1, __ATOMIC_RELAXED);
                }];
        }
    });
    return __atomic_load_n(&generation, __ATOMIC_RELAXED);
}

void ApolloGalleryBindSavedSourceToCurrentAccount(UIViewController *sourceViewController) {
    if (!NSThread.isMainThread || !sourceViewController ||
        objc_getAssociatedObject(sourceViewController, &kApolloGallerySavedSourceAccountKey)) return;
    NSArray *identity = @[ApolloActiveAccountUsername().lowercaseString ?: @"",
                          ApolloActiveAccountClient() ?: NSNull.null,
                          @(ApolloGallerySavedAccountGeneration())];
    objc_setAssociatedObject(sourceViewController, &kApolloGallerySavedSourceAccountKey,
                             identity, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloGallerySavedSourceMatchesCurrentAccount(UIViewController *owner) {
    NSArray *identity = objc_getAssociatedObject(owner, &kApolloGallerySavedSourceAccountKey);
    // Capture once before Apollo starts loading, never when Gallery is tapped:
    // a retained Saved controller may still contain the previous user's rows.
    // If Apollo reuses it after a switch, use a fresh request instead of ever
    // pairing that old array/cursor with the newly active account's credentials.
    return identity.count == 3 &&
        [identity[2] unsignedIntegerValue] == ApolloGallerySavedAccountGeneration() &&
        [identity[0] isEqualToString:ApolloActiveAccountUsername().lowercaseString ?: @""] &&
        identity[1] == (ApolloActiveAccountClient() ?: NSNull.null);
}

static NSDictionary *ApolloGallerySourceCompactPost(NSDictionary *json, BOOL includeParent) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    // Some builder paths wrap a thing in {kind, data}, others pass data alone.
    if ([json[@"data"] isKindOfClass:NSDictionary.class] && json[@"kind"]) json = json[@"data"];

    NSMutableDictionary *post = [NSMutableDictionary dictionary];
    // No self text, flair, awards, comments, account state, or unrelated
    // listing metadata is retained. Nested media dictionaries come from
    // NSJSONSerialization's immutable result and can be shared with the model.
    for (NSString *key in @[@"title", @"author", @"subreddit", @"permalink", @"name",
                            @"over_18", @"spoiler", @"is_gallery", @"gallery_data", @"media_metadata",
                            @"url", @"url_overridden_by_dest", @"post_hint", @"thumbnail",
                            @"preview", @"media", @"secure_media"]) {
        id value = json[key];
        if (value && value != NSNull.null) post[key] = value;
    }
    if (includeParent) {
        id parents = json[@"crosspost_parent_list"];
        NSDictionary *parent = [parents isKindOfClass:NSArray.class] && [parents count] > 0
            ? ApolloGallerySourceCompactPost([parents firstObject], NO) : nil;
        if (parent) post[@"crosspost_parent_list"] = @[parent];
    }
    return [post copy];
}

static void ApolloGallerySourceRememberPost(id model, NSDictionary *json) {
    if (!ApolloClassRDKLink || ![model isKindOfClass:ApolloClassRDKLink]) return;
    NSDictionary *post = ApolloGallerySourceCompactPost(json, YES);
    if (post) objc_setAssociatedObject(model, &kApolloGallerySourcePostKey, post,
                                      OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSDictionary *ApolloGallerySourcePostWithLiveFlags(NSDictionary *post, id link, BOOL includeParent) {
    NSMutableDictionary *current = [post mutableCopy];
    // Mark NSFW/Spoiler mutates an existing RDKLink without deserializing it
    // again. The response snapshot supplies media, but the source model owns
    // the flags now, including when a menu has already prepared this listing.
    if ([link respondsToSelector:@selector(isNSFW)]) {
        current[@"over_18"] = @(((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isNSFW)));
    }
    if ([link respondsToSelector:@selector(isSpoiler)]) {
        current[@"spoiler"] = @(((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isSpoiler)));
    }
    if (includeParent && [link respondsToSelector:@selector(crosspostParent)]) {
        id parentLink = ((id (*)(id, SEL))objc_msgSend)(link, @selector(crosspostParent));
        NSArray *parents = post[@"crosspost_parent_list"];
        if (parentLink && [parents isKindOfClass:NSArray.class] && parents.count > 0 &&
            [parents.firstObject isKindOfClass:NSDictionary.class]) {
            current[@"crosspost_parent_list"] =
                @[ApolloGallerySourcePostWithLiveFlags(parents.firstObject, parentLink, NO)];
        }
    }
    return current;
}

#pragma mark - Reading a complete native listing

static BOOL ApolloGallerySourceReadIvarBytes(id object, const char *name, void *bytes, size_t length) {
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t size = class_getInstanceSize(cls);
    if (offset < 0 || (size_t)offset > size || length > size - (size_t)offset) return NO;
    memcpy(bytes, (const uint8_t *)(__bridge const void *)object + offset, length);
    return YES;
}

static BOOL ApolloGallerySourcePlainObjectWord(uintptr_t word) {
    // Swift bridge-object flags must be checked BEFORE Objective-C sees the
    // value. The lazy pagination's uninitialized state is the non-pointer 1.
    return word >= 0x100000000ULL && (word & 0xF000000000000007ULL) == 0;
}

static NSArray *ApolloGallerySourceArray(UIViewController *owner, const char *name, BOOL allowEmpty) {
    uintptr_t word = 0;
    if (!ApolloGallerySourceReadIvarBytes(owner, name, &word, sizeof(word)) ||
        !ApolloGallerySourcePlainObjectWord(word)) return nil;
    // Array<RDKLink>'s native storage bridges to NSArray on Darwin, unlike
    // value-element buffers such as Array<AnyHashable>. Do not inspect raw
    // elements or assume their stride. Copy on main before Apollo can replace
    // the storage during a listing refresh.
    id storage = (__bridge id)(void *)word;
    if (![storage isKindOfClass:NSArray.class]) return nil;
    NSArray *links = storage;
    if ((!allowEmpty && links.count == 0) || links.count > kApolloGallerySourceMaximumPosts) return nil;
    return [links copy];
}

static NSArray *ApolloGallerySourceLinks(UIViewController *owner) {
    return ApolloGallerySourceArray(owner, "links", NO);
}

static BOOL ApolloGallerySourceReadCursor(UIViewController *owner, const char *name, NSString **after) {
    uintptr_t word = 0;
    if (!ApolloGallerySourceReadIvarBytes(owner, name, &word, sizeof(word))) return NO;
    if (word == 0) {
        // Initialized nil means the loaded native listing reached its end.
        if (after) *after = nil;
        return YES;
    }
    if (!ApolloGallerySourcePlainObjectWord(word)) return NO;
    id pagination = (__bridge id)(void *)word;
    if (![pagination respondsToSelector:@selector(after)]) return NO;
    id value = ((id (*)(id, SEL))objc_msgSend)(pagination, @selector(after));
    // A real pagination object with no cursor is the first-page request
    // state. Its old links may still be visible while refresh/sort completes;
    // they must not be spliced into a fresh gallery under that new sort.
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return NO;
    if (after) *after = [value copy];
    return YES;
}

static BOOL ApolloGallerySourceCursor(UIViewController *owner, NSString **after) {
    return ApolloGallerySourceReadCursor(owner, "$__lazy_storage_$_pagination", after);
}

static BOOL ApolloGallerySourceOptionalEnum(UIViewController *owner, const char *name, int64_t *value) {
    uint8_t bytes[sizeof(int64_t) + 1] = {0};
    if (!ApolloGallerySourceReadIvarBytes(owner, name, bytes, sizeof(bytes)) ||
        (bytes[sizeof(int64_t)] & 1) != 0) return NO;
    memcpy(value, bytes, sizeof(*value));
    return YES;
}

static BOOL ApolloGallerySourceSort(UIViewController *owner, ApolloGallerySort *sort,
                                    ApolloGalleryTopWindow *window) {
    int64_t nativeSort = 0;
    if (!ApolloGallerySourceOptionalEnum(owner, "currentSort", &nativeSort)) return NO;
    switch (nativeSort) {
        case 1: *sort = ApolloGallerySortHot; break;
        case 2: *sort = ApolloGallerySortBest; break;
        case 3: *sort = ApolloGallerySortNew; break;
        case 4: *sort = ApolloGallerySortRising; break;
        case 5: *sort = ApolloGallerySortControversial; break;
        case 6: *sort = ApolloGallerySortTop; break;
        default: return NO;
    }
    *window = ApolloGalleryTopWindowWeek;
    if (!ApolloGallerySortUsesWindow(*sort)) return YES;
    int64_t nativeWindow = 0;
    if (!ApolloGallerySourceOptionalEnum(owner, "currentTimeSort", &nativeWindow)) return NO;
    switch (nativeWindow) {
        case 2: *window = ApolloGalleryTopWindowDay; return YES;
        case 3: *window = ApolloGalleryTopWindowWeek; return YES;
        case 4: *window = ApolloGalleryTopWindowMonth; return YES;
        case 6: *window = ApolloGalleryTopWindowYear; return YES;
        case 7: *window = ApolloGalleryTopWindowAll; return YES;
        // Gallery's sort menu maps This Hour to Today. Those are different
        // listings, so the hour cursor must never page a day gallery.
        default: return NO;
    }
}

@interface ApolloGallerySourceSnapshot : NSObject
@property (nonatomic, copy) NSArray *links;
@property (nonatomic, copy) NSDictionary *listing;
@property (nonatomic, copy) NSString *after;
@property (nonatomic) ApolloGallerySort sort;
@property (nonatomic) ApolloGalleryTopWindow topWindow;
@property (nonatomic) BOOL savedFeed;
@property (nonatomic, copy) NSString *savedCategory;
@property (nonatomic, strong) NSMutableArray<ApolloGalleryImageRequest *> *warmRequests;
@property (nonatomic) NSUInteger warmedItemCount;
@end

@implementation ApolloGallerySourceSnapshot
- (void)dealloc {
    for (ApolloGalleryImageRequest *request in _warmRequests) [request cancel];
}
@end

static BOOL ApolloGallerySourceSameLinks(NSArray *left, NSArray *right) {
    if (left.count != right.count) return NO;
    for (NSUInteger index = 0; index < left.count; index++) {
        if (left[index] != right[index]) return NO;
    }
    return YES;
}

static ApolloGallerySourceSnapshot *ApolloGallerySourceSnapshotForOwner(UIViewController *owner) {
    if (!NSThread.isMainThread) return nil;
    BOOL saved = ApolloClassSavedPostsCommentsViewController &&
        [owner isKindOfClass:ApolloClassSavedPostsCommentsViewController];
    if (saved && !ApolloGallerySavedSourceMatchesCurrentAccount(owner)) return nil;
    if (!saved && (!ApolloClassPostsViewController || ![owner isKindOfClass:ApolloClassPostsViewController])) return nil;
    // Saved's optional array distinguishes a completed empty response from
    // the nil array before its first response. Search uses separate storage;
    // always snapshot the underlying Saved/category listing instead.
    NSArray *links = saved ? ApolloGallerySourceArray(owner, "savedPostsComments", YES) : ApolloGallerySourceLinks(owner);
    NSString *after = nil;
    ApolloGallerySort sort = ApolloGallerySortNew;
    ApolloGalleryTopWindow window = ApolloGalleryTopWindowWeek;
    if (!links) return nil;
    if (saved) {
        if (!ApolloGallerySourceReadCursor(owner, "currentPagination", &after)) return nil;
    } else if (!ApolloGallerySourceCursor(owner, &after) || !ApolloGallerySourceSort(owner, &sort, &window)) return nil;
    NSString *category = saved ? ApolloReadSwiftStringIvar(owner, "filteredSaveCategory") : nil;

    ApolloGallerySourceSnapshot *prepared = objc_getAssociatedObject(owner, &kApolloGallerySourcePreparedKey);
    BOOL reusePrepared = prepared && prepared.sort == sort && prepared.topWindow == window &&
        prepared.savedFeed == saved &&
        (prepared.savedCategory == category || [prepared.savedCategory isEqualToString:category]) &&
        [prepared.after ?: @"" isEqualToString:after ?: @""] &&
        ApolloGallerySourceSameLinks(prepared.links, links);

    NSMutableArray *children = [NSMutableArray arrayWithCapacity:links.count];
    for (id link in links) {
        // Comments never produce gallery tiles, but their native pagination
        // cursor still belongs to the complete mixed Saved response.
        if (saved && ApolloClassRDKComment && [link isKindOfClass:ApolloClassRDKComment]) continue;
        if (saved && (!ApolloClassRDKLink || ![link isKindOfClass:ApolloClassRDKLink])) return nil;
        // Archived/cold-restored models have no associated response JSON.
        // Skipping even ONE such post while inheriting the final cursor could
        // permanently omit its media, so abandon the seed as a whole.
        NSDictionary *post = objc_getAssociatedObject(link, &kApolloGallerySourcePostKey);
        if (!post) return nil;
        [children addObject:@{@"kind": @"t3", @"data": ApolloGallerySourcePostWithLiveFlags(post, link, YES)}];
    }
    NSDictionary *listing = @{@"children": children, @"after": after ?: (id)NSNull.null};
    if (reusePrepared) {
        prepared.listing = listing;
        return prepared;
    }
    ApolloGallerySourceSnapshot *snapshot = [ApolloGallerySourceSnapshot new];
    snapshot.links = links;
    snapshot.after = after;
    snapshot.sort = sort;
    snapshot.topWindow = window;
    snapshot.savedFeed = saved;
    snapshot.savedCategory = category;
    snapshot.listing = listing;
    snapshot.warmRequests = [NSMutableArray array];
    objc_setAssociatedObject(owner, &kApolloGallerySourcePreparedKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The menu may be dismissed without opening Gallery. Do not keep an old
    // account's source models or speculative requests pinned to a controller
    // that Apollo later repurposes for a different feed.
    __weak UIViewController *weakOwner = owner;
    __weak ApolloGallerySourceSnapshot *weakSnapshot = snapshot;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kApolloGallerySourcePreparationLifetime * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongOwner = weakOwner;
        ApolloGallerySourceSnapshot *strongSnapshot = weakSnapshot;
        if (strongOwner && strongSnapshot &&
            objc_getAssociatedObject(strongOwner, &kApolloGallerySourcePreparedKey) == strongSnapshot) {
            objc_setAssociatedObject(strongOwner, &kApolloGallerySourcePreparedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
    return snapshot;
}

NSDictionary *ApolloGallerySourcePreparationState(UIViewController *sourceViewController) {
    ApolloGallerySourceSnapshot *snapshot = ApolloGallerySourceSnapshotForOwner(sourceViewController);
    if (!snapshot) return nil;
    return @{@"listing": snapshot.listing, @"sort": @(snapshot.sort), @"window": @(snapshot.topWindow),
             @"saved": @(snapshot.savedFeed), @"category": snapshot.savedCategory ?: (id)NSNull.null};
}

void ApolloGalleryPrepareSource(UIViewController *sourceViewController) {
    ApolloGallerySourceSnapshot *snapshot = ApolloGallerySourceSnapshotForOwner(sourceViewController);
    if (!snapshot) return;
    // This temporary feed only runs the shared media parser. It never loads a
    // listing or resolves a video host. The image loader coalesces these warm
    // requests with the visible cells when the gallery is pushed.
    ApolloGalleryFeed *preview = snapshot.savedFeed
        ? [[ApolloGalleryFeed alloc] initWithSavedCategory:snapshot.savedCategory]
        : [[ApolloGalleryFeed alloc] initWithHomeFeed];
    BOOL seeded = snapshot.savedFeed
        ? [preview seedFromSavedListing:snapshot.listing category:snapshot.savedCategory]
        : [preview seedFromListing:snapshot.listing];
    if (!seeded) return;
    NSArray<ApolloGalleryItem *> *items = preview.items;
    CGSize viewport = sourceViewController.viewIfLoaded.bounds.size;
    NSInteger sizeIndex = ApolloGalleryGridSavedTileSizeIndex(NSUserDefaults.standardUserDefaults);
    NSUInteger count = ApolloGalleryGridWarmPrefixCount(items.count, viewport.width, viewport.height,
        sizeIndex, kApolloGallerySourceMaximumWarmThumbnails, ^CGSize(NSUInteger index) {
            return items[index].pixelSize;
        });
    if (count <= snapshot.warmedItemCount) return;
    // Four columns of landscape images can need over fifty thumbnails just
    // to cover a phone. Warm the measured viewport plus a row, not a fixed
    // 24-image batch. A later denser size/larger viewport can extend this
    // prefix without restarting cached loads (which return no handle).
    for (NSUInteger index = snapshot.warmedItemCount; index < count; index++) {
        ApolloGalleryItem *item = items[index];
        ApolloGalleryImageRequest *request = [[ApolloGalleryImageLoader sharedLoader]
            prefetchThumbnailAtURL:(item.thumbnailURL ?: item.imageURL)];
        if (request) [snapshot.warmRequests addObject:request];
    }
    snapshot.warmedItemCount = count;
    ApolloLog(@"[GallerySource] prepared %lu posts; warming up to %lu thumbnails",
              (unsigned long)snapshot.links.count, (unsigned long)count);
}

BOOL ApolloGallerySeedFeedFromSource(ApolloGalleryFeed *feed, UIViewController *sourceViewController) {
    ApolloGallerySourceSnapshot *snapshot = ApolloGallerySourceSnapshotForOwner(sourceViewController);
    if (!snapshot || feed.sort != snapshot.sort ||
        (ApolloGallerySortUsesWindow(feed.sort) && feed.topWindow != snapshot.topWindow)) return NO;
    if (!snapshot.savedFeed && !feed.supportsSorting) return NO;
    BOOL seeded = snapshot.savedFeed
        ? [feed seedFromSavedListing:snapshot.listing category:snapshot.savedCategory]
        : [feed seedFromListing:snapshot.listing];
    if (seeded) ApolloLog(@"[GallerySource] opened from %lu already-loaded posts (%lu media)",
                         (unsigned long)snapshot.links.count, (unsigned long)feed.items.count);
    return seeded;
}

#pragma mark - Preserve parser input while Apollo builds source posts

%group ApolloGallerySourceCapture
%hook MTLJSONAdapter

+ (id)modelOfClass:(Class)modelClass fromJSONDictionary:(NSDictionary *)json error:(NSError **)error {
    id model = %orig;
    ApolloGallerySourceRememberPost(model, json);
    return model;
}

+ (id)modelsOfClass:(Class)modelClass fromJSONArray:(NSArray *)json error:(NSError **)error {
    id models = %orig;
    if ([models isKindOfClass:NSArray.class] && [json isKindOfClass:NSArray.class] &&
        [models count] == [json count]) {
        for (NSUInteger index = 0; index < [models count]; index++) {
            ApolloGallerySourceRememberPost(models[index], json[index]);
        }
    }
    return models;
}

- (id)modelFromJSONDictionary:(NSDictionary *)json error:(NSError **)error {
    id model = %orig;
    ApolloGallerySourceRememberPost(model, json);
    return model;
}

%end
%end

%ctor {
    %init(ApolloGallerySourceCapture);
    ApolloLog(@"[GallerySource] source-listing capture hooks installed");
}
