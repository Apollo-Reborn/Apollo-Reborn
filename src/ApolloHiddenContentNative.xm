#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/lock.h>

#import "ApolloHiddenContentNative.h"
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"
#import "ApolloUpvotedPostsFeed.h"

// MARK: - Native Hidden & Deleted lists
//
// Posts go in a PostsViewController built as the Upvoted list of a placeholder
// user (the Recently Read approach): that list loads every page through
// -[RDKClient upvotedLinksForUser:pagination:completion:]. Comments go in a
// UserCommentsViewController, the profile's Comments list, built for another
// placeholder; it loads through
// -[RDKClient commentsByUserWithUsername:pagination:completion:]. The hooks
// below answer both for the placeholders with RDKLink/RDKComment models made
// from the archive results, so every feed and comment setting, theme, swipe
// and menu applies to them as it does in a profile.
//
// Placeholders start with '~', which never appears in a Reddit username, and
// stay within 15 bytes so Swift stores them inline (no reference to manage).

@interface RDKPagination (ApolloHiddenContent)
@property (nonatomic) unsigned long long limit;
@property (copy, nonatomic) NSString *after;
+ (instancetype)paginationWithLimit:(unsigned long long)limit;
@end

typedef void (^ApolloHiddenListingCompletion)(NSArray *things, RDKPagination *pagination, NSError *error);

static const NSUInteger kApolloHiddenDefaultPageSize = 25;
static const NSUInteger kApolloHiddenMaxPageSize = 100;
static char kApolloHiddenListStateKey;

@interface ApolloHiddenNativeList : NSObject
@property (nonatomic) ApolloHiddenContentKind kind;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, weak) UIViewController *list;
@property (nonatomic, weak) id<ApolloHiddenContentNativeListOwner> owner;
// Read from Texture's node-allocation threads, so swapped whole, never mutated.
@property (atomic, copy) NSArray<ApolloHiddenContentItem *> *items;
@property (atomic, copy) NSDictionary<NSString *, ApolloHiddenContentItem *> *itemsByFullName;
// Main thread only.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *models;
@property (nonatomic) NSUInteger version;
@property (nonatomic) NSUInteger shownVersion;
@property (nonatomic, copy) ApolloHiddenListingCompletion pendingFirstPage;
// The list's first page request (its initial load) has come in.
@property (nonatomic) BOOL requestedFirstPage;
@end

@implementation ApolloHiddenNativeList
@end

// Placeholder -> list state, for the RDKClient hooks.
static os_unfair_lock sApolloHiddenListsLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSString *, ApolloHiddenNativeList *> *sApolloHiddenLists;
static NSUInteger sApolloHiddenListCounter;

static ApolloHiddenNativeList *ApolloHiddenListForPlaceholder(id user, ApolloHiddenContentKind kind) {
    if (![user isKindOfClass:NSString.class] || ![(NSString *)user hasPrefix:@"~hd"]) return nil;
    os_unfair_lock_lock(&sApolloHiddenListsLock);
    ApolloHiddenNativeList *state = [sApolloHiddenLists objectForKey:user];
    os_unfair_lock_unlock(&sApolloHiddenListsLock);
    return state.kind == kind ? state : nil;
}

static NSString *ApolloHiddenThingFullName(id thing) {
    if (![thing respondsToSelector:@selector(fullName)]) return nil;
    id name = ((id (*)(id, SEL))objc_msgSend)(thing, @selector(fullName));
    return [name isKindOfClass:NSString.class] ? name : nil;
}

// MARK: Comments list
//
// UserCommentsViewController's ObjC initializers trap, so its Swift designated
// initializer, init(username:), is called directly: allocated self in x20, the
// String in x0/x1. It is found from the class's initWithCoder: thunk at a fixed
// distance and checked by prologue, which pins Apollo 1.15.11; any other binary
// fails closed and Hidden & Deleted reports itself unavailable. (The posts list
// is ApolloMakeUpvotedPostsFeed.)
typedef void *__attribute__((swiftcall)) (*ApolloHiddenUserCommentsInit)(uint64_t stringLow, uint64_t stringHigh,
                                                                         void *self __attribute__((swift_context)));

static ApolloHiddenUserCommentsInit ApolloHiddenUserCommentsInitEntry(void) {
    static ApolloHiddenUserCommentsInit entry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method coder = class_getInstanceMethod(ApolloClassUserCommentsViewController, @selector(initWithCoder:));
        const uint8_t *coderIMP = coder ? (const uint8_t *)method_getImplementation(coder) : NULL;
        Dl_info binary;
        if (!coderIMP || !dladdr(coderIMP, &binary) || !binary.dli_fbase ||
            coderIMP - (const uint8_t *)binary.dli_fbase != 0x41f444) {
            ApolloLog(@"[HiddenContent] UserCommentsViewController initializer not found (unsupported Apollo binary)");
            return;
        }
        static const uint32_t prologue[] = {0xd101c3ff, 0xa9016ffc, 0xa90267fa, 0xa9035ff8, 0xa90457f6,
                                            0xa9054ff4, 0xa9067bfd, 0x910183fd, 0xaa1403f5};
        const uint8_t *candidate = coderIMP - 0x494;
        if (memcmp(candidate, prologue, sizeof(prologue)) != 0) {
            ApolloLog(@"[HiddenContent] UserCommentsViewController initializer prologue mismatch");
            return;
        }
        entry = (ApolloHiddenUserCommentsInit)candidate;
    });
    return entry;
}

static UIViewController *ApolloHiddenMakeCommentsList(NSString *placeholder) {
    ApolloHiddenUserCommentsInit init = ApolloHiddenUserCommentsInitEntry();
    const char *bytes = placeholder.UTF8String;
    size_t length = bytes ? strlen(bytes) : 0;
    if (!init || length == 0 || length > 15) return nil;
    // A Swift small string: the bytes inline, the length in the top byte with
    // the ASCII/small flags (0xE0).
    uint8_t string[16] = {0};
    memcpy(string, bytes, length);
    string[15] = (uint8_t)(0xE0 | length);
    uint64_t low, high;
    memcpy(&low, string, 8);
    memcpy(&high, string + 8, 8);
    void *allocated = (__bridge_retained void *)[ApolloClassUserCommentsViewController alloc];
    return CFBridgingRelease(init(low, high, allocated));
}

// MARK: Models

static id ApolloHiddenModelForItem(ApolloHiddenNativeList *state, ApolloHiddenContentItem *item) {
    id model = state.models[item.fullName];
    if (model) return model;
    if (!item.redditData || !ApolloClassRDKObjectBuilder) return nil;
    NSDictionary *json = @{
        @"kind": item.kind == ApolloHiddenContentKindPost ? @"t3" : @"t1",
        @"data": item.redditData,
    };
    @try {
        model = ((id (*)(id, SEL, id))objc_msgSend)(ApolloClassRDKObjectBuilder, @selector(objectFromJSON:), json);
    } @catch (NSException *exception) {
        ApolloLogError(@"[HiddenContent] Couldn't build a model for %@: %@", item.fullName, exception.reason);
        model = nil;
    }
    Class expected = item.kind == ApolloHiddenContentKindPost ? ApolloClassRDKLink : ApolloClassRDKComment;
    if (![model isKindOfClass:expected]) return nil;
    state.models[item.fullName] = model;
    return model;
}

// MARK: Post size
//
// Apollo's feeds read the global UseCompactThumbnails (an Upvoted list has no
// per-feed RememberRedditPostSize entry) while building a page's sections, on
// the main thread, from either the page's completion or ListAdapter's row
// count. While either runs for the Posts list, that read answers with the
// list's own size instead (as Recently Read does).
static NSUInteger sApolloHiddenSizeScope;
static NSString *const kApolloHiddenUseCompactThumbnailsKey = @"UseCompactThumbnails";

static BOOL ApolloHiddenBeginSizeScope(ApolloHiddenNativeList *state) {
    if (state.kind != ApolloHiddenContentKindPost || ![NSThread isMainThread]) return NO;
    sApolloHiddenSizeScope++;
    return YES;
}

static void ApolloHiddenEndSizeScope(BOOL began) {
    if (began) sApolloHiddenSizeScope--;
}

BOOL ApolloHiddenContentNativePostsCompact(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // objectForKey: rather than boolForKey:, which the override below answers.
    id own = [defaults objectForKey:UDKeyHiddenContentCompactPosts];
    return [(own ?: [defaults objectForKey:kApolloHiddenUseCompactThumbnailsKey]) boolValue];
}

static void ApolloHiddenReloadList(UIViewController *list);

void ApolloHiddenContentNativePostsSetCompact(UIViewController *list, BOOL compact) {
    [[NSUserDefaults standardUserDefaults] setBool:compact forKey:UDKeyHiddenContentCompactPosts];
    ApolloLog(@"[HiddenContent] Post size -> %@", compact ? @"compact" : @"large");
    ApolloHiddenNativeList *state = objc_getAssociatedObject(list, &kApolloHiddenListStateKey);
    if (!state) return;
    BOOL redrawn = ApolloPostsFeedRedrawInPlace(list, ^(dispatch_block_t rebuild) {
        BOOL began = ApolloHiddenBeginSizeScope(state);
        rebuild();
        ApolloHiddenEndSizeScope(began);
    });
    if (!redrawn) {
        ApolloLog(@"[HiddenContent] Can't redraw posts in place; reloading instead");
        state.shownVersion = 0;
        ApolloHiddenReloadList(list);
    }
}

// MARK: Serving pages (main thread)

static void ApolloHiddenServePage(ApolloHiddenNativeList *state, NSString *after, NSUInteger pageSize, ApolloHiddenListingCompletion completion) {
    NSArray<ApolloHiddenContentItem *> *items = state.items ?: @[];
    NSUInteger start = 0;
    if (after.length) {
        start = items.count;
        for (NSUInteger i = 0; i < items.count; i++) {
            if ([items[i].fullName isEqualToString:after]) { start = i + 1; break; }
        }
    }
    NSUInteger end = MIN(items.count, start + pageSize);
    NSMutableArray *models = [NSMutableArray arrayWithCapacity:end - start];
    for (NSUInteger i = start; i < end; i++) {
        id model = ApolloHiddenModelForItem(state, items[i]);
        if (model) [models addObject:model];
    }
    // Nil pagination ends the list.
    RDKPagination *next = nil;
    if (end < items.count && ApolloClassRDKPagination) {
        next = [ApolloClassRDKPagination paginationWithLimit:pageSize];
        next.after = items[end - 1].fullName;
    }
    ApolloLog(@"[HiddenContent] Served %lu %@ (%lu-%lu of %lu)", (unsigned long)models.count,
              state.kind == ApolloHiddenContentKindPost ? @"posts" : @"comments",
              (unsigned long)start, (unsigned long)end, (unsigned long)items.count);
    BOOL began = ApolloHiddenBeginSizeScope(state);
    completion(models, next, nil);
    ApolloHiddenEndSizeScope(began);
}

static void ApolloHiddenHandleRequest(ApolloHiddenNativeList *state, RDKPagination *pagination, ApolloHiddenListingCompletion completion) {
    NSString *after = pagination.after;
    NSUInteger pageSize = pagination.limit > 0 ? MIN((NSUInteger)pagination.limit, kApolloHiddenMaxPageSize) : kApolloHiddenDefaultPageSize;
    if (after.length) {
        ApolloHiddenServePage(state, after, pageSize, completion);
        return;
    }
    if (state.version > 0 && state.shownVersion < state.version) {
        // Results the list hasn't shown yet: its first load, or the reload
        // that follows new results.
        state.shownVersion = state.version;
        ApolloHiddenServePage(state, nil, pageSize, completion);
        return;
    }
    // Answered once results arrive: the initial load, or a pull to refresh
    // (including one after the initial load failed).
    ApolloHiddenListingCompletion previous = state.pendingFirstPage;
    state.pendingFirstPage = completion;
    if (previous) ApolloHiddenServePage(state, nil, pageSize, previous);
    BOOL initialLoad = !state.requestedFirstPage;
    state.requestedFirstPage = YES;
    if (!initialLoad) {
        UIViewController *list = state.list;
        if (list) [state.owner apollo_nativeListRequestedRefresh:list];
    }
}

static void ApolloHiddenRequest(ApolloHiddenNativeList *state, RDKPagination *pagination, ApolloHiddenListingCompletion completion) {
    ApolloHiddenListingCompletion copied = [completion copy];
    if ([NSThread isMainThread]) {
        ApolloHiddenHandleRequest(state, pagination, copied);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloHiddenHandleRequest(state, pagination, copied); });
    }
}

// Pull to refresh, driven programmatically: a fresh first page.
static void ApolloHiddenReloadList(UIViewController *list) {
    UIRefreshControl *refreshControl = ApolloObjectIvar(list, "refreshControl");
    if (![refreshControl isKindOfClass:UIRefreshControl.class]) return;
    [refreshControl beginRefreshing];
    [refreshControl sendActionsForControlEvents:UIControlEventValueChanged];
}

// MARK: Public API

UIViewController *ApolloHiddenContentMakeNativeList(ApolloHiddenContentKind kind, id<ApolloHiddenContentNativeListOwner> owner) {
    ApolloHiddenNativeList *state = [ApolloHiddenNativeList new];
    state.kind = kind;
    state.owner = owner;
    state.models = [NSMutableDictionary dictionary];
    state.items = @[];
    state.itemsByFullName = @{};
    os_unfair_lock_lock(&sApolloHiddenListsLock);
    if (!sApolloHiddenLists) sApolloHiddenLists = [NSMapTable strongToWeakObjectsMapTable];
    NSUInteger number = ++sApolloHiddenListCounter;
    state.placeholder = [NSString stringWithFormat:@"~hd%@%lu", kind == ApolloHiddenContentKindPost ? @"p" : @"c", (unsigned long)number];
    [sApolloHiddenLists setObject:state forKey:state.placeholder];
    os_unfair_lock_unlock(&sApolloHiddenListsLock);

    UIViewController *list = kind == ApolloHiddenContentKindPost
        ? ApolloMakeUpvotedPostsFeed(state.placeholder)
        : ApolloHiddenMakeCommentsList(state.placeholder);
    if (!list) return nil;
    state.list = list;
    objc_setAssociatedObject(list, &kApolloHiddenListStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The adapter's row-factory and row-count hooks find the list through it.
    id adapter = ApolloObjectIvar(list, "listAdapter");
    if (adapter) {
        objc_setAssociatedObject(adapter, &kApolloHiddenListStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        ApolloLog(@"[HiddenContent] %@ list has no listAdapter; pills and post size are off", state.placeholder);
    }
    ApolloLog(@"[HiddenContent] Built native %@ list %@", kind == ApolloHiddenContentKindPost ? @"posts" : @"comments", state.placeholder);
    return list;
}

void ApolloHiddenContentNativeListSetItems(UIViewController *list, NSArray<ApolloHiddenContentItem *> *items) {
    ApolloHiddenNativeList *state = objc_getAssociatedObject(list, &kApolloHiddenListStateKey);
    if (!state) return;
    NSMutableDictionary *byName = [NSMutableDictionary dictionaryWithCapacity:items.count];
    for (ApolloHiddenContentItem *item in items) {
        if (item.fullName.length) byName[item.fullName] = item;
    }
    state.items = items ?: @[];
    state.itemsByFullName = byName;
    [state.models removeAllObjects];
    state.version++;
    ApolloHiddenListingCompletion pending = state.pendingFirstPage;
    state.pendingFirstPage = nil;
    if (pending) {
        state.shownVersion = state.version;
        ApolloHiddenServePage(state, nil, kApolloHiddenDefaultPageSize, pending);
    } else if (list.isViewLoaded) {
        ApolloHiddenReloadList(list);
    }
}

void ApolloHiddenContentNativeListEndRefresh(UIViewController *list) {
    ApolloHiddenNativeList *state = objc_getAssociatedObject(list, &kApolloHiddenListStateKey);
    ApolloHiddenListingCompletion pending = state.pendingFirstPage;
    if (!pending) return;
    state.pendingFirstPage = nil;
    ApolloHiddenServePage(state, nil, kApolloHiddenDefaultPageSize, pending);
}

UIScrollView *ApolloHiddenContentNativeListScrollView(UIViewController *list) {
    UIView *view = list.viewIfLoaded;
    if ([view isKindOfClass:UIScrollView.class]) return (UIScrollView *)view;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UITableView.class]) return (UIScrollView *)subview;
    }
    return nil;
}

// MARK: Status pills
//
// Each row carries the item's HIDDEN / REMOVED / DELETED pill, drawn like a
// flair: after a post's title, after a comment's author. It is added to the
// node's text as soon as Apollo's row factory builds it, before Texture
// measures the row, so the row is laid out with it.

static UIColor *ApolloHiddenPillColor(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return [UIColor colorWithRed:1.0 green:0.66 blue:0.64 alpha:1.0];
        case ApolloHiddenContentReasonRemoved: return [UIColor colorWithRed:1.0 green:0.71 blue:0.42 alpha:1.0];
        case ApolloHiddenContentReasonHidden: default: return [UIColor colorWithRed:1.0 green:0.84 blue:0.55 alpha:1.0];
    }
}

static NSString *ApolloHiddenPillText(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return @"DELETED";
        case ApolloHiddenContentReasonRemoved: return @"REMOVED";
        case ApolloHiddenContentReasonHidden: default: return @"HIDDEN";
    }
}

static NSAttributedString *ApolloHiddenPill(ApolloHiddenContentReason reason, UIFont *hostFont) {
    UIFont *host = hostFont ?: [UIFont systemFontOfSize:15];
    // One size everywhere (posts' titles and comments' ages differ in size),
    // following Dynamic Type like the text around it.
    UIFont *font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2]
        scaledFontForFont:[UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold]];
    NSString *text = ApolloHiddenPillText(reason);
    NSDictionary *attributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.blackColor};
    CGSize textSize = [text sizeWithAttributes:attributes];
    CGSize size = CGSizeMake(ceil(textSize.width + 10), ceil(font.lineHeight + 3));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [ApolloHiddenPillColor(reason) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:4] fill];
        [text drawAtPoint:CGPointMake((size.width - textSize.width) / 2, (size.height - textSize.height) / 2) withAttributes:attributes];
    }];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    // Centered on the host text's cap height.
    attachment.bounds = CGRectMake(0, round((host.capHeight - size.height) / 2), size.width, size.height);
    return [NSAttributedString attributedStringWithAttachment:attachment];
}

static NSAttributedString *ApolloHiddenNodeText(id node) {
    if (![node respondsToSelector:@selector(attributedText)]) return nil;
    id text = ((id (*)(id, SEL))objc_msgSend)(node, @selector(attributedText));
    return [text isKindOfClass:NSAttributedString.class] ? text : nil;
}

// The first text node, searching `node` and its subnodes breadth first, whose
// text passes `match`.
static id ApolloHiddenFindTextNode(id root, BOOL (^match)(NSString *text)) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count && visited < 64) {
        id node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        NSString *text = ApolloHiddenNodeText(node).string;
        if (text.length && match(text)) return node;
        if ([node respondsToSelector:@selector(subnodes)]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
            if ([subnodes isKindOfClass:NSArray.class]) [queue addObjectsFromArray:subnodes];
        }
    }
    return nil;
}

// The pill goes after a post's title (where Apollo then adds the flair), and
// before a comment's age, where the old Hidden & Deleted rows showed it. The
// text node is tagged rather than edited once: Apollo sets a row's text again
// later (a post's title when it turns read), and the ASTextNode hook below puts
// a fresh pill on every text it is given.
static NSString *const kApolloHiddenPillAttribute = @"ApolloHiddenContentPill";
static char kApolloHiddenPillNodeKey;

static NSAttributedString *ApolloHiddenTextWithPill(NSAttributedString *text, ApolloHiddenContentReason reason, BOOL leading) {
    NSMutableAttributedString *updated = [text mutableCopy];
    // Drop a pill from an earlier pass (Apollo rebuilds from the text it was given).
    [text enumerateAttribute:kApolloHiddenPillAttribute inRange:NSMakeRange(0, text.length)
                     options:NSAttributedStringEnumerationReverse
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (value) [updated deleteCharactersInRange:range];
    }];
    if (!updated.length) return updated;
    NSMutableDictionary *attributes = [[updated attributesAtIndex:leading ? 0 : updated.length - 1 effectiveRange:NULL] mutableCopy];
    [attributes removeObjectForKey:NSAttachmentAttributeName];
    attributes[kApolloHiddenPillAttribute] = @YES;
    NSMutableAttributedString *pill = [[NSMutableAttributedString alloc] initWithAttributedString:ApolloHiddenPill(reason, attributes[NSFontAttributeName])];
    [pill addAttribute:kApolloHiddenPillAttribute value:@YES range:NSMakeRange(0, pill.length)];
    NSAttributedString *space = [[NSAttributedString alloc] initWithString:@" " attributes:attributes];
    if (leading) {
        [pill appendAttributedString:space];
        [updated insertAttributedString:pill atIndex:0];
    } else {
        [updated appendAttributedString:space];
        [updated appendAttributedString:pill];
    }
    return updated;
}

static void ApolloHiddenAddPill(id textNode, ApolloHiddenContentReason reason, BOOL leading) {
    NSAttributedString *text = ApolloHiddenNodeText(textNode);
    if (!text.length) return;
    objc_setAssociatedObject(textNode, &kApolloHiddenPillNodeKey, @((NSInteger)reason * 2 + (leading ? 1 : 0)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The hook adds the pill.
    ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), text);
}

static void ApolloHiddenDecorateNode(ApolloHiddenNativeList *state, id node) {
    BOOL isPost = state.kind == ApolloHiddenContentKindPost;
    id model = ApolloObjectIvar(node, isPost ? "link" : "comment");
    NSString *fullName = ApolloHiddenThingFullName(model);
    ApolloHiddenContentItem *item = fullName ? state.itemsByFullName[fullName] : nil;
    if (!item) return;

    id textNode = nil;
    if (isPost) {
        NSString *title = [(RDKLink *)model title];
        if (!title.length) return;
        NSString *prefix = [title substringToIndex:MIN(title.length, (NSUInteger)24)];
        id titleNode = ApolloObjectIvar(node, "titleNode");
        textNode = ApolloHiddenFindTextNode(titleNode ?: node, ^BOOL(NSString *text) { return [text hasPrefix:prefix]; });
    } else {
        id ageNode = ApolloObjectIvar(node, "ageNode");
        textNode = ApolloHiddenNodeText(ageNode).length ? ageNode : nil;
    }
    if (!textNode) {
        ApolloLog(@"[HiddenContent] No text node for the %@ pill on %@ (%@)", ApolloHiddenPillText(item.reason), fullName, NSStringFromClass([node class]));
        return;
    }
    ApolloHiddenAddPill(textNode, item.reason, !isPost);
}

@interface ASTextNode : NSObject
@end

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)text {
    NSNumber *pill = text.length ? objc_getAssociatedObject(self, &kApolloHiddenPillNodeKey) : nil;
    if (!pill) {
        %orig;
        return;
    }
    NSInteger value = pill.integerValue;
    %orig(ApolloHiddenTextWithPill(text, (ApolloHiddenContentReason)(value / 2), (value & 1) != 0));
}

%end

@interface _TtC6Apollo11ListAdapter : NSObject
@end

%hook _TtC6Apollo11ListAdapter

- (id)tableNode:(id)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    id (^block)(void) = %orig;
    ApolloHiddenNativeList *state = block ? objc_getAssociatedObject(self, &kApolloHiddenListStateKey) : nil;
    if (!state) return block;
    return [^id {
        id node = block();
        ApolloHiddenDecorateNode(state, node);
        return node;
    } copy];
}

- (NSInteger)tableNode:(id)tableNode numberOfRowsInSection:(NSInteger)section {
    ApolloHiddenNativeList *state = objc_getAssociatedObject(self, &kApolloHiddenListStateKey);
    if (!state) return %orig;
    BOOL began = ApolloHiddenBeginSizeScope(state);
    NSInteger rows = %orig;
    ApolloHiddenEndSizeScope(began);
    return rows;
}

%end

@interface _TtC6Apollo19PostsViewController : UIViewController
@end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    ApolloHiddenNativeList *state = objc_getAssociatedObject(self, &kApolloHiddenListStateKey);
    // Before Apollo's viewDidLoad, which builds the first sections.
    BOOL began = state ? ApolloHiddenBeginSizeScope(state) : NO;
    %orig;
    ApolloHiddenEndSizeScope(began);
}

%end

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)key {
    if (sApolloHiddenSizeScope > 0 && [NSThread isMainThread] && [key isEqualToString:kApolloHiddenUseCompactThumbnailsKey]) {
        return ApolloHiddenContentNativePostsCompact();
    }
    return %orig;
}

%end

// MARK: Threads keep the archived post
//
// A thread opened from these lists re-fetches its post live, and Reddit's live
// copy of a removed post has its title rewritten ("[ Removed by moderator ]")
// and its media dropped. The thread's first fetch comes back as
// @{ @"link": RDKLink, ... }; for a post these lists hold, the archived model
// takes the live one's place (with the live counts it already carries).
static id ApolloHiddenArchivedLinkForIdentifier(id identifier) {
    if (![identifier isKindOfClass:NSString.class] || ![NSThread isMainThread]) return nil;
    NSString *fullName = [(NSString *)identifier hasPrefix:@"t3_"] ? identifier : [@"t3_" stringByAppendingString:identifier];
    os_unfair_lock_lock(&sApolloHiddenListsLock);
    NSArray<ApolloHiddenNativeList *> *states = sApolloHiddenLists.objectEnumerator.allObjects;
    os_unfair_lock_unlock(&sApolloHiddenListsLock);
    for (ApolloHiddenNativeList *state in states) {
        if (state.kind != ApolloHiddenContentKindPost) continue;
        ApolloHiddenContentItem *item = state.itemsByFullName[fullName];
        if (item) return ApolloHiddenModelForItem(state, item);
    }
    return nil;
}

static id ApolloHiddenWrapThreadCompletion(id identifier, id completion) {
    id archived = completion ? ApolloHiddenArchivedLinkForIdentifier(identifier) : nil;
    if (!archived) return completion;
    void (^original)(id, id) = [completion copy];
    return [^(id result, id error) {
        if ([result isKindOfClass:NSDictionary.class] && [((NSDictionary *)result)[@"link"] isKindOfClass:ApolloClassRDKLink]) {
            NSMutableDictionary *patched = [(NSDictionary *)result mutableCopy];
            patched[@"link"] = archived;
            ApolloLog(@"[HiddenContent] Thread for %@ keeps its archived post", identifier);
            original(patched, error);
            return;
        }
        original(result, error);
    } copy];
}

%hook RDKClient

- (id)linkAndCommentsForLinkWithIdentifier:(id)identifier commentSort:(long long)commentSort pagination:(id)pagination completion:(id)completion {
    return %orig(identifier, commentSort, pagination, ApolloHiddenWrapThreadCompletion(identifier, completion));
}

- (id)upvotedLinksForUser:(id)user pagination:(RDKPagination *)pagination completion:(ApolloHiddenListingCompletion)completion {
    ApolloHiddenNativeList *state = ApolloHiddenListForPlaceholder(user, ApolloHiddenContentKindPost);
    if (!state || !completion) return %orig;
    ApolloHiddenRequest(state, pagination, completion);
    // Apollo discards the returned task.
    return nil;
}

- (id)commentsByUserWithUsername:(id)username pagination:(RDKPagination *)pagination completion:(ApolloHiddenListingCompletion)completion {
    ApolloHiddenNativeList *state = ApolloHiddenListForPlaceholder(username, ApolloHiddenContentKindComment);
    if (!state || !completion) return %orig;
    ApolloHiddenRequest(state, pagination, completion);
    return nil;
}

%end
