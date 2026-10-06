#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloRedgifsErrorCards.h"
#import "ApolloRedgifsFailureReason.h"
#import "ApolloTextureDecls.h"
#import "Tweak.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Says why a RedGIFs post failed to load (#1340). Apollo (1.15.11) covers the
// media area with a RichMediaErrorLoadingNode: a compass icon, the title
// "<recipientOfBlame> error :(" and "Tap to open in browser" (texts set at
// 0x10073eb18, which the node's ThemeManager observer runs again on every theme
// change). For a RedGIFs post two paths build one:
//   * the gif lookup failed: the RedGIFsClient completion that
//     -didEnterPreloadState starts (0x100585af8) builds "RedGIFs error :(",
//     unless the post has a Reddit video or preview mp4, which it plays instead;
//   * the video file failed to load: -videoNode:didFailToLoadValueForKey:asset:
//     error: starts an NWPathMonitor whose update builds the generic card
//     (0x100588318), named after the post's domain: "Redgifs error :(".
// Neither says why. A video RedGIFs deleted, a region RedGIFs blocks and a
// network that can't reach RedGIFs (or only its media server) all read the
// same, and look like an app bug.
//
// The reason is recorded as the failure happens:
//   * Tweak.xm passes every lookup result (by gif id) and every token mint result
//     here; when minting fails, Apollo fails its queued lookups unsent;
//   * the video failure's NSError is kept on the RichMediaNode.
// Every creation site calls -[RichMediaNode setNeedsLayout] right after
// installing the card, so that hook reads the errorLoadingNode ivar, picks the
// reason for the post's gif id, and pins it as the card's title. The pin
// isa-swizzles the title's ASTextNode onto a subclass whose setAttributedText:
// keeps the incoming attributes but swaps in the reason, so Apollo's theme pass
// restyles the text instead of reverting it (the technique ApolloThemeRuntime
// uses for its pinned separators). "Tap to open in browser" and the tap itself
// are untouched; a reason that can't be named keeps Apollo's text.
//
// =============================================================================

@interface ApolloRedgifsFailureRecord : NSObject
@property (nonatomic, readonly) ApolloRedgifsFailure failure;
@property (nonatomic, copy, readonly) NSString *gifID;
- (instancetype)initWithFailure:(ApolloRedgifsFailure)failure gifID:(NSString *)gifID;
@end

@implementation ApolloRedgifsFailureRecord
- (instancetype)initWithFailure:(ApolloRedgifsFailure)failure gifID:(NSString *)gifID {
    if ((self = [super init])) {
        _failure = failure;
        _gifID = [gifID copy];
    }
    return self;
}
@end

static Class sCardClass;             // _TtC6Apollo25RichMediaErrorLoadingNode
static Ivar sErrorLoadingNodeIvar;  // RichMediaNode.errorLoadingNode
static Ivar sLinkIvar;              // RichMediaNode.link (RDKLink)
static Ivar sCardTitleIvar;         // RichMediaErrorLoadingNode.titleNode (ASTextNode)

static const void *kApolloRedgifsCardSeenKey = &kApolloRedgifsCardSeenKey;
static const void *kApolloRedgifsMediaFailureKey = &kApolloRedgifsMediaFailureKey;
static const void *kApolloRedgifsPinnedTitleKey = &kApolloRedgifsPinnedTitleKey;

// The title the lookup path builds; the generic card is named after the post's
// domain ("Redgifs error :(").
static NSString *const kApolloRedgifsLookupCardTitle = @"RedGIFs error :(";

#pragma mark - Recorded reasons

// Why the latest lookup of each gif failed, by lowercased gif id; removed once a
// lookup gets a usable answer. Written on Apollo's RedGIFs session queue and
// read wherever Apollo builds the card; NSCache is thread-safe. Apollo looks a
// failing gif up again every few seconds, so an evicted entry comes back with
// the next lookup.
static NSCache<NSString *, ApolloRedgifsFailureRecord *> *ApolloRedgifsLookupFailures(void) {
    static NSCache<NSString *, ApolloRedgifsFailureRecord *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

static os_unfair_lock sTokenLock = OS_UNFAIR_LOCK_INIT;
// The latest token mint's failure; kind None after a mint succeeds.
static ApolloRedgifsFailure sTokenFailure;

ApolloRedgifsLookupCompletion ApolloRedgifsCompletionRecordingLookupResult(NSURLSession *session,
                                                                          NSURLRequest *request,
                                                                          ApolloRedgifsLookupCompletion completion) {
    if (!completion) return completion;
    // ApolloHostedVideo (Share as Video, Share as Image, Gallery View) looks
    // gifs up on the shared session; those don't build Apollo's cards.
    if (session == [NSURLSession sharedSession]) return completion;
    NSString *gifID = ApolloRedgifsIDFromLookupURL(request.URL);
    if (!gifID) return completion;

    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        ApolloRedgifsFailure failure = ApolloRedgifsFailureForAPIResult(data, response, error);
        if (failure.kind != ApolloRedgifsFailureKindNone) {
            [ApolloRedgifsLookupFailures() setObject:[[ApolloRedgifsFailureRecord alloc] initWithFailure:failure gifID:gifID]
                                              forKey:gifID];
        } else if (failure.httpStatus > 0) {
            // A real answer. (A cancelled lookup says nothing, so it keeps the
            // last reason.)
            [ApolloRedgifsLookupFailures() removeObjectForKey:gifID];
        }
        completion(data, response, error);
    };
}

void ApolloRedgifsRecordTokenMintResult(NSData *data, NSURLResponse *response, NSError *error) {
    ApolloRedgifsFailure failure = ApolloRedgifsFailureForAPIResult(data, response, error);
    // A cancelled mint says nothing about the network either.
    if (failure.kind == ApolloRedgifsFailureKindNone && failure.httpStatus == 0) return;
    os_unfair_lock_lock(&sTokenLock);
    sTokenFailure = failure;
    os_unfair_lock_unlock(&sTokenLock);
}

static ApolloRedgifsFailure ApolloRedgifsTokenFailure(void) {
    os_unfair_lock_lock(&sTokenLock);
    ApolloRedgifsFailure failure = sTokenFailure;
    os_unfair_lock_unlock(&sTokenLock);
    return failure;
}

static ApolloRedgifsFailure ApolloRedgifsLookupFailure(NSString *gifID) {
    ApolloRedgifsFailureRecord *record = [ApolloRedgifsLookupFailures() objectForKey:gifID];
    if (record) return record.failure;
    ApolloRedgifsFailure none = { ApolloRedgifsFailureKindNone, 0 };
    return none;
}

static NSString *ApolloRedgifsGifIDForMediaNode(id mediaNode) {
    RDKLink *link = sLinkIvar ? object_getIvar(mediaNode, sLinkIvar) : nil;
    return link ? ApolloRedgifsIDFromPostURL(link.URL) : nil;
}

#pragma mark - Pinned card title

// One subclass per text node class (ASTextNode in 1.15.11), created on first
// use from whichever thread Apollo builds a card on.
static os_unfair_lock sPinnedClassLock = OS_UNFAIR_LOCK_INIT;

static Class ApolloRedgifsPinnedTitleClassForBase(Class base) {
    static NSMutableDictionary<NSString *, Class> *sPinnedClasses;
    NSString *baseName = NSStringFromClass(base);
    os_unfair_lock_lock(&sPinnedClassLock);
    if (!sPinnedClasses) sPinnedClasses = [NSMutableDictionary new];
    Class pinned = sPinnedClasses[baseName];
    if (!pinned) {
        NSString *name = [@"ApolloRebornRedgifsCardTitle_" stringByAppendingString:baseName];
        pinned = objc_getClass(name.UTF8String);
        SEL sel = @selector(setAttributedText:);
        Method proto = class_getInstanceMethod(base, sel);
        if (!pinned && proto) {
            pinned = objc_allocateClassPair(base, name.UTF8String, 0);
            if (pinned) {
                // Message `base` explicitly rather than the receiver's superclass,
                // so a KVO subclass stacked on top can't loop back in here.
                IMP imp = imp_implementationWithBlock(^(id node, NSAttributedString *incoming) {
                    NSString *title = objc_getAssociatedObject(node, kApolloRedgifsPinnedTitleKey);
                    NSAttributedString *outgoing = incoming;
                    if (title.length > 0 && incoming.length > 0 && ![incoming.string isEqualToString:title]) {
                        NSDictionary *attributes = [incoming attributesAtIndex:0 effectiveRange:NULL];
                        outgoing = [[NSAttributedString alloc] initWithString:title attributes:attributes];
                    }
                    struct objc_super sup = { node, base };
                    ((void (*)(struct objc_super *, SEL, NSAttributedString *))objc_msgSendSuper)(&sup, sel, outgoing);
                });
                class_addMethod(pinned, sel, imp, method_getTypeEncoding(proto));
                objc_registerClassPair(pinned);
            }
        }
        if (pinned) sPinnedClasses[baseName] = pinned;
    }
    os_unfair_lock_unlock(&sPinnedClassLock);
    return pinned;
}

static void ApolloRedgifsPinCardTitle(ASTextNode *titleNode, NSString *title) {
    NSAttributedString *current = titleNode.attributedText;
    if (current.length == 0) return;
    objc_setAssociatedObject(titleNode, kApolloRedgifsPinnedTitleKey, title, OBJC_ASSOCIATION_COPY);
    const char *className = class_getName(object_getClass(titleNode));
    BOOL pinned = strncmp(className, "ApolloRebornRedgifsCardTitle_", 29) == 0;
    if (!pinned && strncmp(className, "NSKVONotifying_", 15) != 0) {  // never slide under a KVO isa
        Class pinnedClass = ApolloRedgifsPinnedTitleClassForBase(object_getClass(titleNode));
        if (pinnedClass) {
            object_setClass(titleNode, pinnedClass);
            pinned = YES;
        }
    }
    if (pinned) {
        // The pinned setter swaps the title in, keeping the current attributes.
        titleNode.attributedText = current;
    } else {
        // Can't pin a KVO'd node: set it once (Apollo's next theme pass reverts it).
        NSDictionary *attributes = [current attributesAtIndex:0 effectiveRange:NULL];
        titleNode.attributedText = [[NSAttributedString alloc] initWithString:title attributes:attributes];
    }
}

#pragma mark - Card update

static void ApolloRedgifsLogCard(BOOL lookupCard, ApolloRedgifsFailure failure) {
    // Apollo rebuilds a failing post's card every few seconds; log a reason
    // once per change rather than once per card.
    static os_unfair_lock logLock = OS_UNFAIR_LOCK_INIT;
    static NSInteger lastKind = -1, lastStatus = -1, lastPath = -1;
    os_unfair_lock_lock(&logLock);
    BOOL changed = lastKind != failure.kind || lastStatus != failure.httpStatus || lastPath != lookupCard;
    lastKind = failure.kind;
    lastStatus = failure.httpStatus;
    lastPath = lookupCard;
    os_unfair_lock_unlock(&logLock);
    if (changed) {
        ApolloLog(@"[RedgifsCards] %@ card -> \"%@\" (HTTP %ld)", lookupCard ? @"Lookup" : @"Video",
                  ApolloRedgifsCardTitleForFailure(failure), (long)failure.httpStatus);
    }
}

static void ApolloRedgifsUpdateErrorCard(id mediaNode) {
    id card = object_getIvar(mediaNode, sErrorLoadingNodeIvar);
    // Each card is looked at once, right after Apollo installs it.
    if (![card isKindOfClass:sCardClass] || objc_getAssociatedObject(card, kApolloRedgifsCardSeenKey)) return;
    objc_setAssociatedObject(card, kApolloRedgifsCardSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *gifID = ApolloRedgifsGifIDForMediaNode(mediaNode);
    if (!gifID) return;  // not a RedGIFs post: other hosts' cards stay as they are

    ASTextNode *titleNode = object_getIvar(card, sCardTitleIvar);
    NSString *currentTitle = titleNode.attributedText.string;
    if (![currentTitle hasSuffix:@" error :("]) return;
    BOOL lookupCard = [currentTitle isEqualToString:kApolloRedgifsLookupCardTitle];

    ApolloRedgifsFailure failure = { ApolloRedgifsFailureKindNone, 0 };
    if (lookupCard) {
        failure = ApolloRedgifsLookupFailure(gifID);
        // No lookup went out: the token mint failed and Apollo failed the
        // queued lookups without sending them.
        if (failure.kind == ApolloRedgifsFailureKindNone) failure = ApolloRedgifsTokenFailure();
    } else {
        ApolloRedgifsFailureRecord *media = objc_getAssociatedObject(mediaNode, kApolloRedgifsMediaFailureKey);
        if ([media.gifID isEqualToString:gifID]) failure = media.failure;
        if (failure.kind == ApolloRedgifsFailureKindNone) failure = ApolloRedgifsLookupFailure(gifID);
    }

    NSString *title = ApolloRedgifsCardTitleForFailure(failure);
    if (!title) {
        ApolloLogDebug(@"[RedgifsCards] %@ card: no nameable reason, keeping Apollo's title",
                       lookupCard ? @"Lookup" : @"Video");
        return;
    }
    ApolloRedgifsPinCardTitle(titleNode, title);
    ApolloRedgifsLogCard(lookupCard, failure);
}

#pragma mark - Hooks

%hook RichMediaNode

// Every site that installs an error card calls this right after the store.
- (void)setNeedsLayout {
    %orig;
    if (object_getIvar(self, sErrorLoadingNodeIvar)) ApolloRedgifsUpdateErrorCard(self);
}

// Apollo builds the "Redgifs error :(" card from here (after an NWPathMonitor
// update), so the reason is recorded before %orig.
- (void)videoNode:(id)videoNode didFailToLoadValueForKey:(NSString *)key asset:(id)asset error:(NSError *)error {
    NSString *gifID = ApolloRedgifsGifIDForMediaNode(self);
    if (gifID) {
        ApolloRedgifsFailure failure = ApolloRedgifsFailureForMediaError(error);
        objc_setAssociatedObject(self, kApolloRedgifsMediaFailureKey,
                                 [[ApolloRedgifsFailureRecord alloc] initWithFailure:failure gifID:gifID],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class mediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    sCardClass = objc_getClass("_TtC6Apollo25RichMediaErrorLoadingNode");
    sErrorLoadingNodeIvar = mediaNodeClass ? class_getInstanceVariable(mediaNodeClass, "errorLoadingNode") : NULL;
    sLinkIvar = mediaNodeClass ? class_getInstanceVariable(mediaNodeClass, "link") : NULL;
    sCardTitleIvar = sCardClass ? class_getInstanceVariable(sCardClass, "titleNode") : NULL;
    if (!sErrorLoadingNodeIvar || !sLinkIvar || !sCardTitleIvar) {
        ApolloLog(@"[RedgifsCards] ctor: RichMediaNode/RichMediaErrorLoadingNode layout not found (%p %p %p); skipping hooks",
                  (void *)sErrorLoadingNodeIvar, (void *)sLinkIvar, (void *)sCardTitleIvar);
        return;
    }
    %init(RichMediaNode = mediaNodeClass);
    ApolloLog(@"[RedgifsCards] ctor: hook installed (RichMediaNode setNeedsLayout + video load failure)");
}
