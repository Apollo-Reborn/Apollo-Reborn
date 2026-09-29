// ApolloActionMenu — see ApolloActionMenu.h for the ownership contract this
// module exists to enforce (single owner of _TtC6Apollo16ActionController's
// table geometry and ActionControllerPresentationController's frame, on both
// the Liquid Glass and legacy-sheet rendering paths).
//
// THE REGISTRY: feature modules call ApolloActionMenuRegister() from their
// %ctor with an ApolloActionMenuSpec. Read lazily, so %ctor/Makefile link order
// never matters (mirrors src/settings/ApolloSettingsGeneralTable.xm's registry).
//
// PER-CONTROLLER SLOTS: ApolloActionMenuSlotsForController() runs every spec's
// `matches` exactly once per actionController instance, on whichever call site
// asks first (glass's ApolloActionMenuInjectMenuElements, or any of the legacy
// table hooks below), and memoizes the result via an associated object. This is
// deliberately NOT a side effect of tableView:numberOfRowsInSection: — the
// presentation-controller frame hook needs the matched spec count before the
// table has necessarily reloaded, and computing on demand instead of on that
// one call site removes the order dependency entirely.
//
// THE DONOR CELL: an injected row's declarative title/image blocks receive the
// LIVE row-0 cell as `donor` on the legacy path, fetched by calling the
// controller's own (real, un-hooked-for-row-0) cellForRowAtIndexPath: — never
// captured opportunistically off whatever row happened to build first. Same
// technique as ApolloSettingsGeneralTable.xm's factory(vc, donor).
//
// TAP DISPATCH: an injected row's tap is handled in
// tableView:willSelectRowAtIndexPath: (added to ActionController at %ctor) and
// answered with nil, so UIKit never sends tableView:didSelectRowAtIndexPath:
// for it — see ApolloActionMenuWillSelectRow for why (#1071: a third-party
// tweak's didSelect hook wrapping ours crashed on our row's index).
//
// GEOMETRY: legacy rows are always appended after the last native row (Apollo's
// own cellForRow dequeues with the index path it's handed; UIKit asserts if a
// native row's index shifts) and the presented sheet's frame grows by
// rowHeight * matchedSpecCount. Nothing here grows the inner tableView's own
// frame — an earlier version of this feature set (ApolloPublicStickyAsSubreddit)
// did that via viewDidLayoutSubviews and it visibly ate the gap Apollo leaves
// between the rows card and the Cancel button (confirmed on-device); Gallery's
// and DeletedComments' outer-frame-only growth was correct all along.

#import "ApolloActionMenu.h"
#import <dlfcn.h>
#import "ApolloActionMenuLayout.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"

#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Registry

@implementation ApolloActionMenuSpec
@end

static NSMutableArray<ApolloActionMenuSpec *> *sApolloActionMenuRegistry;

void ApolloActionMenuRegister(ApolloActionMenuSpec *spec) {
    if (!spec.identifier.length || !spec.matches || !spec.perform) {
        ApolloLog(@"[ActionMenu] Refusing to register an incomplete spec (%@)", spec.identifier);
        return;
    }
    if (!sApolloActionMenuRegistry) sApolloActionMenuRegistry = [NSMutableArray array];
    [sApolloActionMenuRegistry addObject:spec];
}

UIImage *ApolloActionMenuSymbolIcon(NSString *symbolName) {
    if (symbolName.length == 0) return nil;

    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    @synchronized (cache) {
        UIImage *cached = cache[symbolName];
        if (cached) return cached;
    }

    // Apollo's option-* art fills its canvas edge-to-edge, while an SF Symbol
    // image carries baseline/side padding inside its bounds — so matching
    // image sizes still leaves the symbol's GLYPH visibly lighter than the
    // rasters next to it. Match the glyphs instead: render the symbol large,
    // find the drawn pixels' bounding box, and scale so that box's long edge
    // is exactly the shared icon-box side, the same rule
    // ApolloNativeActionMenuSizedIcon applies to the assets.
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:40.0
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *symbol = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    if (!symbol) return nil;
    UIImage *drawableSymbol = [symbol imageWithTintColor:UIColor.blackColor
                                           renderingMode:UIImageRenderingModeAlwaysOriginal];

    CGSize symbolSize = symbol.size;
    if (symbolSize.width <= 0.0 || symbolSize.height <= 0.0) return nil;

    // One probe render at 1px/pt to locate the glyph within the padded image.
    // Rendered through UIGraphicsImageRenderer and blitted with
    // CGContextDrawImage so buffer row 0 is unambiguously the image's TOP —
    // the bounding box below is directly in UIKit-oriented points.
    NSInteger probeWidth = (NSInteger)ceil(symbolSize.width);
    NSInteger probeHeight = (NSInteger)ceil(symbolSize.height);
    UIGraphicsImageRendererFormat *probeFormat = [UIGraphicsImageRendererFormat preferredFormat];
    probeFormat.opaque = NO;
    probeFormat.scale = 1.0;
    UIGraphicsImageRenderer *probeRenderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(probeWidth, probeHeight)
                                               format:probeFormat];
    UIImage *probeImage = [probeRenderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [drawableSymbol drawInRect:CGRectMake(0, 0, probeWidth, probeHeight)];
    }];
    CGImageRef probeCGImage = probeImage.CGImage;
    if (!probeCGImage) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSMutableData *probe = [NSMutableData dataWithLength:(NSUInteger)(probeWidth * probeHeight * 4)];
    CGContextRef probeContext = CGBitmapContextCreate(probe.mutableBytes,
                                                      (size_t)probeWidth, (size_t)probeHeight,
                                                      8, (size_t)(probeWidth * 4), colorSpace,
                                                      kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!probeContext) return nil;
    CGContextDrawImage(probeContext, CGRectMake(0, 0, probeWidth, probeHeight), probeCGImage);
    CGContextRelease(probeContext);

    const uint8_t *pixels = (const uint8_t *)probe.bytes;
    NSInteger minX = probeWidth, minY = probeHeight, maxX = -1, maxY = -1;
    for (NSInteger y = 0; y < probeHeight; y++) {
        for (NSInteger x = 0; x < probeWidth; x++) {
            if (pixels[(y * probeWidth + x) * 4 + 3] > 16) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
    }
    if (maxX < 0) return nil;
    CGRect glyphBox = CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);

    CGFloat scale = ApolloActionMenuIconBoxSide / MAX(glyphBox.size.width, glyphBox.size.height);
    CGSize canvasSize = CGSizeMake(round(glyphBox.size.width * scale),
                                   round(glyphBox.size.height * scale));
    CGRect drawRect = CGRectMake(-glyphBox.origin.x * scale,
                                 -glyphBox.origin.y * scale,
                                 probeWidth * scale,
                                 probeHeight * scale);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:format];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [drawableSymbol drawInRect:drawRect];
    }];
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    @synchronized (cache) {
        cache[symbolName] = image;
    }
    return image;
}

#pragma mark - Customised layouts (Settings → Interface → Action Menus)

// The user's saved order/hidden set for a menu context is applied in two
// places, both driven from the memoised slot state so each sheet is touched
// exactly once:
//   • Apollo's NATIVE rows: the controller's Swift `actions` array is permuted
//     (and hidden rows dropped) IN PLACE before either path reads it — the
//     legacy table and the glass UIMenu builder both walk that buffer, and
//     Apollo's own didSelect finds a row's handler by a key built from the
//     row's title + kind (a dictionary, not a parallel array — verified in
//     Hopper: sub_10079f330 ← tableView:didSelectRowAtIndexPath:), so moving
//     an element can never mismatch it with another row's handler. Same
//     technique ApolloTranslation.xm and ApolloNativeActionMenus.xm's saved-
//     category sort already rely on.
//   • Apollo Reborn's rows (specs): hidden ones are not matched; the rest sort
//     by their rank in the saved order. On the glass path a ranked spec is
//     then spliced among the native elements at its rank (see
//     ApolloActionMenuInjectMenuElements); on the legacy sheet injected rows
//     always follow the native ones (header note), so only their relative
//     order applies there.
//
// Native rows the catalogue doesn't know (a moderator-only row, a kind added
// by a future Apollo build) are never dropped: they keep Apollo's relative
// order after every catalogued item. A context with no saved layout is left
// exactly as Apollo built it.

// Apollo flags its moderator sheets (the shield buttons' and the Moderator
// row's) on the controller itself.
static BOOL ApolloActionMenuControllerIsModeratorOnly(id controller) {
    if (!controller) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "isShowingOnlyModeratorActions");
    if (!ivar) return NO;
    return *(BOOL *)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
}

static char kApolloActionMenuControllerContextKey;

void ApolloActionMenuCaptureContextForController(id controller) {
    if (![controller isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) return;
    if (objc_getAssociatedObject(controller, &kApolloActionMenuControllerContextKey)) return;
    ApolloActionMenuContext context = ApolloActionMenuTakeArmedContext();
    if (!context) return;
    // A moderator context fits only a sheet Apollo flagged moderator-only, and
    // such a sheet takes only a moderator context. The Moderator row arms its
    // follow-up while the ••• sheet is still dismissing, so a sheet that isn't
    // the mod sheet leaves the context armed for the one that is (within the
    // arm window); a ••• context landing on a mod sheet is dropped, never
    // misapplied.
    BOOL moderatorSheet = ApolloActionMenuControllerIsModeratorOnly(controller);
    if (ApolloActionMenuContextIsModerator(context) != moderatorSheet) {
        ApolloLog(@"[ActionMenu] armed context %@ does not fit a %@ sheet — %@", context,
                  moderatorSheet ? @"moderator" : @"regular", moderatorSheet ? @"dropped" : @"left armed");
        if (!moderatorSheet) ApolloActionMenuArmContext(context);
        return;
    }
    objc_setAssociatedObject(controller, &kApolloActionMenuControllerContextKey, context, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// The Moderator row of a ••• sheet opens that object's moderator sheet once
// the ••• sheet has dismissed — too late for the tap hooks' synchronous arm —
// so the row's handlers (the glass action, the legacy willSelect) arm it
// here; the capture above lets only a moderator-flagged sheet claim it.
void ApolloActionMenuArmModeratorFollowUp(id actionController) {
    ApolloActionMenuContext context = objc_getAssociatedObject(actionController, &kApolloActionMenuControllerContextKey);
    ApolloActionMenuContext moderator = ApolloActionMenuModeratorContextFollowing(context);
    if (!moderator) return;
    ApolloLog(@"[ActionMenu] Moderator row of the %@ sheet — arming %@ for the sheet it opens", context, moderator);
    ApolloActionMenuArmContext(moderator);
}

static char kApolloActionMenuElementKindKey;
static char kApolloActionMenuElementSpecKey;

void ApolloActionMenuTagElementWithNativeKind(UIMenuElement *element, NSUInteger kind) {
    if (!element) return;
    objc_setAssociatedObject(element, &kApolloActionMenuElementKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloActionMenuTagElementWithSpec(UIMenuElement *element, NSString *specIdentifier) {
    if (!element || specIdentifier.length == 0) return;
    objc_setAssociatedObject(element, &kApolloActionMenuElementSpecKey, [specIdentifier copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// Rank of a glass element in the context's saved order; NSNotFound for an
// element that carries no tag or whose item isn't catalogued for the context.
static NSUInteger ApolloActionMenuRankForElement(UIMenuElement *element, ApolloActionMenuContext context) {
    if (!context) return NSNotFound;
    NSNumber *kind = objc_getAssociatedObject(element, &kApolloActionMenuElementKindKey);
    if (kind) {
        return ApolloActionMenuRankForItemID(context, ApolloActionMenuItemIDForKind(context, kind.unsignedIntegerValue));
    }
    NSString *specIdentifier = objc_getAssociatedObject(element, &kApolloActionMenuElementSpecKey);
    if (specIdentifier) {
        return ApolloActionMenuRankForItemID(context, ApolloActionMenuItemIDForSpec(specIdentifier));
    }
    return NSNotFound;
}

static NSUInteger ApolloActionMenuRankForSpec(ApolloActionMenuSpec *spec, ApolloActionMenuContext context) {
    if (!context || !ApolloActionMenuContextIsCustomized(context)) return NSNotFound;
    return ApolloActionMenuRankForItemID(context, ApolloActionMenuItemIDForSpec(spec.identifier));
}

// Element layout of Apollo's `[Action]` buffer (verified in Hopper against
// -[ActionController tableView:cellForRowAtIndexPath:] → sub_1007985fc):
// Swift array header (isa, refcount, count @+0x10, capacity @+0x18), then
// 0x30-byte elements from +0x20 — kind (UInt16) @+0, title (String) @+0x08,
// subtitle (String?) @+0x18, accessory (UInt8) @+0x28.
static const NSUInteger kApolloActionMenuNativeElementsOffset = 0x20;
static const NSUInteger kApolloActionMenuNativeElementStride = 0x30;

typedef struct {
    int64_t index;
    uint16_t kind;
    NSUInteger rank;
} ApolloActionMenuNativeEntry;

static NSString *ApolloActionMenuDescribeKinds(const ApolloActionMenuNativeEntry *entries, NSUInteger count) {
    NSMutableArray<NSString *> *kinds = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [kinds addObject:[NSString stringWithFormat:@"%u", entries[i].kind]];
    return [kinds componentsJoinedByString:@","];
}

// Fills `entries` with every native row (index, kind, rank in the saved
// order; unknown kinds rank after every catalogued item), skipping hidden
// items when `applyHidden`. Returns how many were kept.
static NSUInteger ApolloActionMenuCollectNativeEntries(uint8_t *elements, int64_t count,
                                                       ApolloActionMenuContext context,
                                                       NSArray<NSString *> *order, NSSet<NSString *> *hidden,
                                                       BOOL applyHidden,
                                                       ApolloActionMenuNativeEntry *entries,
                                                       NSMutableArray<NSString *> *droppedKinds) {
    NSUInteger kept = 0;
    NSUInteger unknownRank = order.count;
    for (int64_t i = 0; i < count; i++) {
        uint16_t kind = *(uint16_t *)(elements + (NSUInteger)i * kApolloActionMenuNativeElementStride);
        NSString *itemID = ApolloActionMenuItemIDForKind(context, kind);
        if (applyHidden && itemID && [hidden containsObject:itemID]) {
            [droppedKinds addObject:[NSString stringWithFormat:@"%u", kind]];
            continue;
        }
        NSUInteger rank = itemID ? [order indexOfObject:itemID] : NSNotFound;
        entries[kept++] = (ApolloActionMenuNativeEntry){ .index = i, .kind = kind,
                                                          .rank = rank == NSNotFound ? unknownRank : rank };
    }
    return kept;
}

// Permutes/compacts the controller's native actions to the context's saved
// layout. Returns YES when the buffer changed.
static BOOL ApolloActionMenuApplyNativeLayout(id controller, ApolloActionMenuContext context) {
    if (!controller || !context) return NO;
    void *buffer = ApolloReadRawIvar(controller, "actions");
    int64_t count = ApolloSwiftArrayCount(buffer);
    if (count <= 0 || count > 512) return NO;

    // Swift arrays may share storage. Never mutate another owner's copy.
    // These runtime entry points also handle tagged/inline String words.
    typedef bool (*UniqueFn)(void *);
    typedef void (*ReleaseFn)(void *);
    static UniqueFn isUnique;
    static ReleaseFn releaseBridge;
    static dispatch_once_t runtimeOnce;
    dispatch_once(&runtimeOnce, ^{
        isUnique = (UniqueFn)dlsym(RTLD_DEFAULT, "swift_isUniquelyReferenced_nonNull_native");
        releaseBridge = (ReleaseFn)dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease");
    });
    if (!isUnique || !releaseBridge || !isUnique(buffer)) {
        ApolloLog(@"[ActionMenu] %@ left unchanged: native actions storage is shared or Swift runtime is unavailable", context);
        return NO;
    }

    NSArray<NSString *> *order = ApolloActionMenuHasCustomOrder(context) ? ApolloActionMenuResolvedOrder(context) : @[];
    NSSet<NSString *> *hidden = ApolloActionMenuHiddenItemIDs(context);
    uint8_t *elements = (uint8_t *)buffer + kApolloActionMenuNativeElementsOffset;

    ApolloActionMenuNativeEntry *entries = (ApolloActionMenuNativeEntry *)calloc((size_t)count, sizeof(ApolloActionMenuNativeEntry));
    if (!entries) return NO;
    NSMutableArray<NSString *> *droppedKinds = [NSMutableArray array];
    NSUInteger kept = ApolloActionMenuCollectNativeEntries(elements, count, context, order, hidden, YES, entries, droppedKinds);
    // Never present an empty sheet: if every native row is hidden, show them
    // all (in the saved order) rather than nothing.
    if (kept == 0) {
        [droppedKinds removeAllObjects];
        kept = ApolloActionMenuCollectNativeEntries(elements, count, context, order, hidden, NO, entries, droppedKinds);
    }
    // Stable insertion sort by rank (a sheet has a few dozen rows at most), so
    // rows sharing an item — or unknown to it — keep Apollo's relative order.
    for (NSUInteger i = 1; i < kept; i++) {
        ApolloActionMenuNativeEntry moving = entries[i];
        NSUInteger j = i;
        while (j > 0 && entries[j - 1].rank > moving.rank) {
            entries[j] = entries[j - 1];
            j--;
        }
        entries[j] = moving;
    }

    BOOL identity = (kept == (NSUInteger)count);
    for (NSUInteger i = 0; identity && i < kept; i++) {
        if (entries[i].index != (int64_t)i) identity = NO;
    }
    if (identity) {
        free(entries);
        return NO;
    }

    NSMutableArray<NSString *> *beforeKinds = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int64_t i = 0; i < count; i++) {
        [beforeKinds addObject:[NSString stringWithFormat:@"%u",
                                *(uint16_t *)(elements + (NSUInteger)i * kApolloActionMenuNativeElementStride)]];
    }

    // Transfer surviving elements through scratch storage without retaining
    // them. Release both String bridge words of every removed Action before
    // overwriting its slot; lowering count alone leaks heap-backed titles.
    uint8_t *scratch = (uint8_t *)malloc(kept * kApolloActionMenuNativeElementStride);
    if (!scratch) {
        free(entries);
        return NO;
    }
    for (NSUInteger i = 0; i < kept; i++) {
        memcpy(scratch + i * kApolloActionMenuNativeElementStride,
               elements + (NSUInteger)entries[i].index * kApolloActionMenuNativeElementStride,
               kApolloActionMenuNativeElementStride);
    }
    for (int64_t i = 0; i < count; i++) {
        BOOL survives = NO;
        for (NSUInteger j = 0; j < kept; j++) {
            if (entries[j].index == i) { survives = YES; break; }
        }
        if (!survives) {
            uint8_t *removed = elements + (NSUInteger)i * kApolloActionMenuNativeElementStride;
            releaseBridge(*(void **)(removed + 0x10)); // title String's bridge word
            releaseBridge(*(void **)(removed + 0x20)); // optional subtitle (nil is safe)
        }
    }
    memcpy(elements, scratch, kept * kApolloActionMenuNativeElementStride);
    memset(elements + kept * kApolloActionMenuNativeElementStride, 0,
           ((NSUInteger)count - kept) * kApolloActionMenuNativeElementStride);
    *(int64_t *)((uint8_t *)buffer + 0x10) = (int64_t)kept;
    free(scratch);

    ApolloLog(@"[ActionMenu] %@ layout applied: kinds %@ -> %@%@", context,
              [beforeKinds componentsJoinedByString:@","], ApolloActionMenuDescribeKinds(entries, kept),
              droppedKinds.count ? [NSString stringWithFormat:@" (hidden %@)", [droppedKinds componentsJoinedByString:@","]] : @"");
    free(entries);
    return YES;
}

#pragma mark - Per-controller slot memoization

@interface ApolloActionMenuSlotState : NSObject
@property (nonatomic, copy) NSArray<ApolloActionMenuSpec *> *specs; // matched, ordered
// Which ••• menu this sheet is (ApolloActionMenuLayout.h), nil when it was not
// opened from one of the customisable entry points.
@property (nonatomic, copy) ApolloActionMenuContext context;
@property (nonatomic, assign) NSInteger nativeRowCount; // -1 until numberOfRows(section 0) has run
// A standalone (never dequeued, never added to any table) snapshot cell
// carrying row 0's captured text/font/color/frame, rebuilt every time row 0
// naturally renders. NOT a live cell — see ApolloActionMenuCaptureDonorSnapshot
// for why an injected row's cellForRow can never fetch row 0 "live".
@property (nonatomic, strong) UITableViewCell *donorSnapshot;
@end
@implementation ApolloActionMenuSlotState
- (instancetype)init {
    self = [super init];
    if (self) _nativeRowCount = -1;
    return self;
}
@end

static const void *kApolloActionMenuSlotStateKey = &kApolloActionMenuSlotStateKey;

// Apollo's own actionsDescription Swift string for the sheet, falling back to
// probing titleForHeaderInSection: the way ApolloPublicStickyAsSubreddit used to
// on every delegate call — here it only runs once, at memoization time.
static NSString *ApolloActionMenuTitleForController(id controller) {
    NSString *title = ApolloReadSwiftStringIvar(controller, "actionsDescription");
    if (title.length > 0) return title;

    if ([controller respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
        UITableView *tableView = ApolloReadObjectIvar(controller, "tableView");
        @try {
            NSString *header = [(id<UITableViewDataSource>)controller tableView:tableView
                                                       titleForHeaderInSection:0];
            if ([header isKindOfClass:[NSString class]]) return header;
        } @catch (__unused NSException *exception) {
        }
    }
    return @"";
}

// menuTitleHint: pass the already-known title from the glass path to skip the
// re-derivation above; pass nil from the legacy hooks (memoized either way, so
// this only ever runs once per controller regardless).
static ApolloActionMenuSlotState *ApolloActionMenuSlotsForController(id controller, NSString *menuTitleHint) {
    if (!controller) return nil;

    ApolloActionMenuSlotState *state = objc_getAssociatedObject(controller, kApolloActionMenuSlotStateKey);
    if (state) return state;

    NSString *menuTitle = menuTitleHint.length > 0 ? menuTitleHint : ApolloActionMenuTitleForController(controller);

    // Which ••• menu is this? Armed by the tap hooks at the bottom of this
    // file moments before Apollo built the sheet. Resolved here — the first
    // time anything asks about the controller — so the native permutation
    // below lands before either rendering path reads the actions.
    ApolloActionMenuCaptureContextForController(controller);
    ApolloActionMenuContext context = objc_getAssociatedObject(controller, &kApolloActionMenuControllerContextKey);
    BOOL customized = context && ApolloActionMenuContextIsCustomized(context);
    // What Apollo put in this sheet, for the settings preview — read before
    // the saved layout drops anything.
    NSMutableArray<NSString *> *presentedItemIDs = context ? [NSMutableArray array] : nil;
    if (context) {
        void *buffer = ApolloReadRawIvar(controller, "actions");
        int64_t count = ApolloSwiftArrayCount(buffer);
        for (int64_t i = 0; i < count && i < 512; i++) {
            uint16_t kind = *(uint16_t *)((uint8_t *)buffer + kApolloActionMenuNativeElementsOffset
                                          + (NSUInteger)i * kApolloActionMenuNativeElementStride);
            NSString *itemID = ApolloActionMenuItemIDForKind(context, kind);
            if (itemID && ![presentedItemIDs containsObject:itemID]) [presentedItemIDs addObject:itemID];
        }
    }
    NSMutableArray<ApolloActionMenuSpec *> *matched = [NSMutableArray array];
    for (ApolloActionMenuSpec *spec in sApolloActionMenuRegistry) {
        BOOL (^matches)(id, NSString *) = spec.matches;
        if (!matches) continue;
        BOOL specMatches = NO;
        @try {
            specMatches = matches(controller, menuTitle);
        } @catch (NSException *exception) {
            ApolloLog(@"[ActionMenu] spec '%@' matches: threw %@", spec.identifier, exception);
        }
        if (!specMatches) continue;
        NSString *specItemID = ApolloActionMenuItemIDForSpec(spec.identifier);
        if (presentedItemIDs && ![presentedItemIDs containsObject:specItemID]) {
            NSUInteger index = presentedItemIDs.count;
            if (IsLiquidGlass() && spec.placement == ApolloActionMenuPlacementAfterLeadingSubmitAffordance) {
                NSUInteger submit = [presentedItemIDs indexOfObject:@"submit"];
                index = submit == NSNotFound ? 0 : submit + 1;
            }
            [presentedItemIDs insertObject:specItemID atIndex:index];
        }
        if (customized && ApolloActionMenuIsItemHidden(context, specItemID)) {
            ApolloLog(@"[ActionMenu] spec '%@' hidden by the %@ layout", spec.identifier, context);
            continue;
        }
        [matched addObject:spec];
    }
    if (context) ApolloActionMenuRecordPresentedItemIDs(context, presentedItemIDs);
    // Match tweak rows against Apollo’s original actions; hiding a native
    // affordance must not change whether an independent feature belongs here.
    if (customized) ApolloActionMenuApplyNativeLayout(controller, context);
    [matched sortUsingComparator:^NSComparisonResult(ApolloActionMenuSpec *a, ApolloActionMenuSpec *b) {
        // Saved layout first (ranked rows before unranked), then the specs'
        // own order/identifier tiebreak.
        NSUInteger rankA = ApolloActionMenuRankForSpec(a, context);
        NSUInteger rankB = ApolloActionMenuRankForSpec(b, context);
        if (rankA != rankB) return rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
        if (a.order != b.order) return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
        return [a.identifier compare:b.identifier];
    }];

    state = [ApolloActionMenuSlotState new];
    state.specs = matched;
    state.context = context;
    objc_setAssociatedObject(controller, kApolloActionMenuSlotStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (matched.count > 0) {
        ApolloLog(@"[ActionMenu] %lu spec(s) matched '%@': %@", (unsigned long)matched.count, menuTitle,
                  [matched valueForKey:@"identifier"]);
    }
    {
        // Diagnostic for the Action Menus catalogue: the kinds EVERY sheet
        // presents (no titles — those can carry user/subreddit names), the
        // context it resolved to (none = left untouched) and whether Apollo
        // flagged it as one of its moderator sheets.
        void *buffer = ApolloReadRawIvar(controller, "actions");
        int64_t count = ApolloSwiftArrayCount(buffer);
        NSMutableArray<NSString *> *kinds = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(count, 0)];
        for (int64_t i = 0; i < count && i < 512; i++) {
            uint16_t kind = *(uint16_t *)((uint8_t *)buffer + kApolloActionMenuNativeElementsOffset
                                          + (NSUInteger)i * kApolloActionMenuNativeElementStride);
            [kinds addObject:[NSString stringWithFormat:@"%u", kind]];
        }
        ApolloLog(@"[ActionMenu] context=%@ customized=%d moderatorOnly=%d kinds=[%@] specs=%@", context ?: @"(none)", customized,
                  ApolloActionMenuControllerIsModeratorOnly(controller),
                  [kinds componentsJoinedByString:@","], [matched valueForKey:@"identifier"]);
    }
    return state;
}

void ApolloActionMenuPrepareController(id actionController, NSString *menuTitleHint) {
    (void)ApolloActionMenuSlotsForController(actionController, menuTitleHint);
}

static CGFloat ApolloActionMenuNativeRowHeight(id controller) {
    id tableView = ApolloReadObjectIvar(controller, "tableView");
    if (![tableView isKindOfClass:[UITableView class]]) return 0.0;
    if (![controller respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)]) return 0.0;
    @try {
        return [(id<UITableViewDelegate>)controller tableView:(UITableView *)tableView
                                    heightForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

#pragma mark - Legacy path: donor-styled lookalike cell

static UIView *ApolloActionMenuFirstSubviewOfClass(UIView *root, Class cls, BOOL requireLabelText) {
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:cls]) {
            if (!requireLabelText) return subview;
            if ([subview isKindOfClass:[UILabel class]] && ((UILabel *)subview).text.length > 0) return subview;
        }
        UIView *nested = ApolloActionMenuFirstSubviewOfClass(subview, cls, requireLabelText);
        if (nested) return nested;
    }
    return nil;
}

@interface ApolloActionMenuRowCell : UITableViewCell
@property (nonatomic, strong) UILabel *apolloTitleLabel;
@property (nonatomic, strong) UIImageView *apolloIconView;
@property (nonatomic, assign) CGRect apolloTitleFrame;
@property (nonatomic, assign) CGRect apolloIconFrame;
@end

@implementation ApolloActionMenuRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _apolloIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _apolloIconView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_apolloIconView];

        _apolloTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_apolloTitleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;

    if (!CGRectIsEmpty(self.apolloIconFrame)) {
        // The donor frame is row 0's icon frame — the right COLUMN anchor, but
        // the wrong SIZE to force on our image: Apollo sizes each row's icon
        // view to its own icon, so row 0 can be a narrow glyph (the comments
        // sheet leads with Upvote's slim arrow) and fitting into it shrank
        // every injected icon below its ~24pt neighbours (#985 review). Show
        // the image at its own size — specs pre-normalize their icons to
        // ApolloActionMenuIconBoxSide — centered on the donor column; the
        // box-side cap is just a guard against an oversized stray.
        CGRect anchorFrame = self.apolloIconFrame;
        CGRect iconFrame = anchorFrame;
        CGSize imageSize = self.apolloIconView.image.size;
        if (imageSize.width > 0.5 && imageSize.height > 0.5) {
            CGFloat fit = MIN(1.0, ApolloActionMenuIconBoxSide / MAX(imageSize.width, imageSize.height));
            CGSize displaySize = CGSizeMake(imageSize.width * fit, imageSize.height * fit);
            iconFrame = CGRectMake(round(CGRectGetMidX(anchorFrame) - displaySize.width / 2.0),
                                   round((bounds.size.height - displaySize.height) / 2.0),
                                   displaySize.width, displaySize.height);
        } else {
            iconFrame.origin.y = (bounds.size.height - iconFrame.size.height) / 2.0;
        }
        self.apolloIconView.frame = iconFrame;
        self.apolloIconView.hidden = NO;
    } else {
        self.apolloIconView.hidden = YES;
    }

    CGFloat titleLeft = CGRectIsEmpty(self.apolloTitleFrame) ? 16.0 : CGRectGetMinX(self.apolloTitleFrame);
    CGFloat titleHeight = CGRectIsEmpty(self.apolloTitleFrame) ? 22.0 : CGRectGetHeight(self.apolloTitleFrame);
    self.apolloTitleLabel.frame = CGRectMake(titleLeft,
                                             (bounds.size.height - titleHeight) / 2.0,
                                             MAX(0.0, bounds.size.width - titleLeft - 16.0),
                                             titleHeight);
}

@end

// Snapshots row 0's rendered text/style into a standalone UITableViewCell that
// is never dequeued and never added to any table — just a carrier
// ApolloActionMenuFirstSubviewOfClass / ApolloActionMenuDonorLabelText can walk
// exactly like a live cell.
//
// This exists because an injected row's cellForRowAtIndexPath: CANNOT fetch a
// "live" row-0 cell by calling %orig with row 0's index path: Apollo's cell
// builder calls -[UITableView dequeueReusableCellWithIdentifier:forIndexPath:],
// and that method asserts if the index path it's given doesn't match whatever
// row the table's internal state currently believes it's preparing — which,
// mid-build of the INJECTED row, is never row 0. Doing that crashed with
// NSInternalInconsistencyException the moment a subreddit "..." sheet's Gallery
// View row (or any injected row) was built. So the ONLY safe capture point is
// the table's own natural, non-reentrant ask for row 0 itself — see the
// cellForRowAtIndexPath: hook below, which calls this only from that ask.
static UITableViewCell *ApolloActionMenuCaptureDonorSnapshot(UITableViewCell *realRow0Cell) {
    if (![realRow0Cell isKindOfClass:[UITableViewCell class]]) return nil;
    [realRow0Cell layoutIfNeeded];

    UILabel *label = (UILabel *)ApolloActionMenuFirstSubviewOfClass(realRow0Cell, [UILabel class], YES);
    UIImageView *icon = (UIImageView *)ApolloActionMenuFirstSubviewOfClass(realRow0Cell, [UIImageView class], NO);
    if (!label && !icon) return nil;

    UITableViewCell *snapshot = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (label) {
        UILabel *snapshotLabel = [[UILabel alloc] initWithFrame:[label convertRect:label.bounds toView:realRow0Cell]];
        snapshotLabel.text = label.text;
        snapshotLabel.textColor = label.textColor;
        snapshotLabel.font = label.font;
        snapshotLabel.textAlignment = label.textAlignment;
        [snapshot.contentView addSubview:snapshotLabel];
    }
    if (icon && icon.bounds.size.width > 1.0) {
        UIImageView *snapshotIcon = [[UIImageView alloc] initWithFrame:[icon convertRect:icon.bounds toView:realRow0Cell]];
        snapshotIcon.tintColor = icon.tintColor;
        [snapshot.contentView addSubview:snapshotIcon];
    }
    return snapshot;
}

// Style captured from the donor (Apollo's own row-0 cell — custom-drawn icon +
// accent-tinted label at its own insets, so a stock UITableViewCell.textLabel
// would land in the wrong place with the wrong color) and applied to `cell`.
static void ApolloActionMenuConfigureRowCell(ApolloActionMenuRowCell *cell, NSString *title,
                                             UIImage *image, UITableViewCell *donor) {
    UIColor *titleColor = nil;
    UIFont *titleFont = nil;
    NSTextAlignment alignment = NSTextAlignmentLeft;
    CGRect titleFrame = CGRectZero;
    CGRect iconFrame = CGRectZero;
    UIColor *iconTint = nil;

    if ([donor isKindOfClass:[UITableViewCell class]]) {
        [donor layoutIfNeeded];
        UILabel *label = (UILabel *)ApolloActionMenuFirstSubviewOfClass(donor, [UILabel class], YES);
        if (label) {
            titleColor = label.textColor;
            titleFont = label.font;
            alignment = label.textAlignment;
            titleFrame = [label convertRect:label.bounds toView:donor];
        }
        UIImageView *icon = (UIImageView *)ApolloActionMenuFirstSubviewOfClass(donor, [UIImageView class], NO);
        if (icon && icon.bounds.size.width > 1.0) {
            iconFrame = [icon convertRect:icon.bounds toView:donor];
            iconTint = icon.tintColor;
        }
    }

    // The accent is the right last resort: Apollo tints these rows with the
    // theme accent, so it matches even when the donor capture came up empty.
    UIColor *tint = titleColor ?: ApolloThemeAccentColor() ?: UIColor.labelColor;

    cell.apolloTitleLabel.text = title;
    cell.apolloTitleLabel.textColor = tint;
    cell.apolloTitleLabel.font = titleFont ?: [UIFont systemFontOfSize:17.0];
    cell.apolloTitleLabel.textAlignment = alignment;
    cell.apolloIconView.image = image;
    cell.apolloIconView.tintColor = iconTint ?: tint;
    cell.apolloTitleFrame = titleFrame;
    cell.apolloIconFrame = iconFrame;
    cell.accessibilityLabel = title;
    [cell setNeedsLayout];
}

NSString *ApolloActionMenuDonorLabelText(UITableViewCell *donor) {
    if (![donor isKindOfClass:[UITableViewCell class]]) return nil;
    UILabel *label = (UILabel *)ApolloActionMenuFirstSubviewOfClass(donor, [UILabel class], YES);
    return label.text;
}

#pragma mark - Legacy path: invoking a native row's own handler

void ApolloActionMenuInvokeNativeRow(id actionController, NSInteger row) {
    if (!actionController) return;
    if (![actionController respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        ApolloLog(@"[ActionMenu] Cannot invoke native row %ld — no didSelectRowAtIndexPath:", (long)row);
        return;
    }
    UITableView *tableView = ApolloReadObjectIvar(actionController, "tableView");
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
    // Re-enters this file's own didSelectRowAtIndexPath: hook below at `row`,
    // which — being a native index, not an injected slot — falls straight
    // through to %orig. Deliberately a plain dispatch, not
    // ApolloNativeActionMenuSelectRow's "invoking" flag (ApolloNativeActionMenus.xm,
    // glass-only): the legacy sheet is genuinely on screen and must actually
    // dismiss when the native handler dismisses it.
    ((void (*)(id, SEL, id, id))objc_msgSend)(actionController, @selector(tableView:didSelectRowAtIndexPath:),
                                              tableView, indexPath);
}

#pragma mark - Glass path

static NSUInteger ApolloActionMenuLeadingSubmitAffordanceIndex(NSArray<UIMenuElement *> *children) {
    NSUInteger index = 0;
    while (index < children.count) {
        UIMenuElement *element = children[index];
        if ([element isKindOfClass:[UIMenu class]]) { index++; continue; }
        if ([element isKindOfClass:[UIAction class]] &&
            [((UIAction *)element).title hasPrefix:@"Submit"]) { index++; continue; }
        break;
    }
    return index;
}

// Under a saved layout: the slot right after the last element that ranks
// before `rank` (untagged elements — text actions, report sections — don't
// take part and stay where they are).
static NSUInteger ApolloActionMenuRankedInsertionIndex(NSArray<UIMenuElement *> *children, NSUInteger rank,
                                                       ApolloActionMenuContext context) {
    NSUInteger index = 0;
    for (NSUInteger i = 0; i < children.count; i++) {
        NSUInteger childRank = ApolloActionMenuRankForElement(children[i], context);
        if (childRank != NSNotFound && childRank < rank) index = i + 1;
    }
    return index;
}

void ApolloActionMenuInjectMenuElements(NSMutableArray<UIMenuElement *> *children,
                                        NSString *menuTitle,
                                        id actionController) {
    if (![children isKindOfClass:[NSMutableArray class]] || !actionController) return;

    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(actionController, menuTitle);
    if (state.specs.count == 0) return;

    for (ApolloActionMenuSpec *spec in state.specs) {
        @try {
            NSUInteger rank = ApolloActionMenuRankForSpec(spec, state.context);
            if (spec.buildElement) {
                // A custom builder places its own element(s) — Gallery View's
                // combined section lands after the leading Submit affordance.
                // Under a saved layout, re-home whatever it inserted at the
                // spec's rank, tagged, so it reorders like a declarative row
                // and later specs' rank scans see it. Without a rank the
                // builder's own placement stands.
                NSArray<UIMenuElement *> *before = [children copy];
                spec.buildElement(actionController, children);
                NSMutableArray<UIMenuElement *> *inserted = [NSMutableArray array];
                for (UIMenuElement *element in children) {
                    if ([before indexOfObjectIdenticalTo:element] == NSNotFound) [inserted addObject:element];
                }
                for (UIMenuElement *element in inserted) ApolloActionMenuTagElementWithSpec(element, spec.identifier);
                if (rank != NSNotFound && inserted.count > 0) {
                    for (UIMenuElement *element in inserted) {
                        NSUInteger at = [children indexOfObjectIdenticalTo:element];
                        if (at != NSNotFound) [children removeObjectAtIndex:at];
                    }
                    NSUInteger index = ApolloActionMenuRankedInsertionIndex(children, rank, state.context);
                    [children insertObjects:inserted
                                  atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, inserted.count)]];
                    ApolloLog(@"[ActionMenu] spec '%@' re-homed by the %@ layout: rank %lu -> index %lu",
                              spec.identifier, state.context, (unsigned long)rank, (unsigned long)index);
                }
                continue;
            }

            NSString *title = spec.title ? spec.title(actionController, nil) : nil;
            if (title.length == 0) continue;
            UIImage *image = spec.image ? spec.image(actionController, nil) : nil;

            void (^perform)(id) = spec.perform;
            UIAction *action = [UIAction actionWithTitle:title
                                                    image:image
                                               identifier:nil
                                                  handler:^(__unused __kindof UIAction *sender) {
                if (perform) perform(actionController);
            }];

            UIMenuElement *element = action;
            if (spec.inlineSection) {
                element = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                        options:UIMenuOptionsDisplayInline children:@[action]];
            }
            ApolloActionMenuTagElementWithSpec(element, spec.identifier);

            NSUInteger index;
            if (rank != NSNotFound) {
                index = ApolloActionMenuRankedInsertionIndex(children, rank, state.context);
            } else {
                index = (spec.placement == ApolloActionMenuPlacementAfterLeadingSubmitAffordance)
                    ? ApolloActionMenuLeadingSubmitAffordanceIndex(children)
                    : children.count;
            }
            [children insertObject:element atIndex:MIN(index, children.count)];
        } @catch (NSException *exception) {
            ApolloLog(@"[ActionMenu] spec '%@' build threw: %@", spec.identifier, exception);
        }
    }
}

#pragma mark - Legacy path: the single table/geometry owner

#pragma mark - Injected-row tap dispatch

// The spec behind `indexPath`, or nil when the row is native or was appended
// by someone else (a third-party tweak stacking its own row after ours).
static ApolloActionMenuSpec *ApolloActionMenuSpecAtIndexPath(id controller, NSIndexPath *indexPath) {
    if (!indexPath || indexPath.section != 0) return nil;
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(controller, nil);
    NSInteger nativeCount = state.nativeRowCount;
    if (state.specs.count == 0 || nativeCount < 0 || indexPath.row < nativeCount) return nil;
    NSInteger slotIndex = indexPath.row - nativeCount;
    if (slotIndex < 0 || (NSUInteger)slotIndex >= state.specs.count) return nil;
    return state.specs[(NSUInteger)slotIndex];
}

// Run an injected row's tap: dismiss-then-perform (the default), or perform in
// place for a spec whose perform forwards into a native row's own
// self-dismissing flow (PublicSticky).
static void ApolloActionMenuPerformSpec(id controller, UITableView *tableView,
                                        ApolloActionMenuSpec *spec, NSIndexPath *indexPath) {
    // Keep the tap feedback native rows get. On the didSelect path UIKit has
    // selected the row and this deselect fades it out under the dismissal; on
    // the willSelect path the row is never selected (UIKit already dropped the
    // touch-down highlight before asking willSelect, and nil stops it there),
    // so re-arm the cell's own highlight and fade that instead — cell-level
    // state only, nothing re-entrant on the table's selection bookkeeping.
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell && !cell.isSelected) {
        [cell setHighlighted:YES animated:NO];
        [cell setHighlighted:NO animated:YES];
    }

    __strong id strongSelf = controller;
    void (^perform)(id) = spec.perform;
    if (spec.legacyDismissesSheet) {
        [(UIViewController *)controller dismissViewControllerAnimated:YES completion:^{
            if (perform) perform(strongSelf);
        }];
    } else if (perform) {
        perform(strongSelf);
    }
}

// tableView:willSelectRowAtIndexPath: on ActionController — where an injected
// row's tap is handled. Returning nil makes UIKit skip both the selection and
// the tableView:didSelectRowAtIndexPath: send for that row
// (-[UITableView _selectRowAtIndexPath:…notifyDelegate:] consults willSelect
// first and bails on nil), so the tap never reaches ANY didSelect
// implementation: not Apollo's, and not one another tweak installed on top of
// ours.
//
// Why (#1071): Translomatic hooks this class's didSelectRowAtIndexPath: too.
// Loading after the IPA-embedded tweak, its replacement wraps ours — UIKit
// calls it first — and it doesn't expect rows past Apollo's own action list:
// the crash report shows it null-dereferencing inside its own code, called
// straight from UIKit's row selection, on our "Keep in Floating Tab" row.
// Whoever ends up outermost on didSelect, an injected row now never gets there.
//
// Apollo's ActionController doesn't implement willSelect (1.15.11 headers), so
// this is ADDED at %ctor rather than hooked; should some build or tweak have
// implemented it first, that implementation is wrapped and still consulted for
// every non-injected row.
typedef NSIndexPath *(*ApolloActionMenuWillSelectIMP)(id, SEL, UITableView *, NSIndexPath *);
static ApolloActionMenuWillSelectIMP sApolloActionMenuOrigWillSelect = NULL;

// The native kind at a row of the (already permuted) actions buffer.
static uint16_t ApolloActionMenuNativeKindAtRow(id controller, NSInteger row) {
    void *buffer = ApolloReadRawIvar(controller, "actions");
    int64_t count = buffer ? ApolloSwiftArrayCount(buffer) : 0;
    if (row < 0 || row >= count) return UINT16_MAX;
    return *(uint16_t *)((uint8_t *)buffer + kApolloActionMenuNativeElementsOffset
                         + (NSUInteger)row * kApolloActionMenuNativeElementStride);
}

static NSIndexPath *ApolloActionMenuWillSelectRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    ApolloActionMenuSpec *spec = ApolloActionMenuSpecAtIndexPath(self, indexPath);
    if (!spec) {
        // A native row. The Moderator row (kind 124) opens the moderator sheet
        // after this sheet dismisses: arm that sheet's context now.
        if (indexPath.section == 0 && ApolloActionMenuNativeKindAtRow(self, indexPath.row) == 124) {
            ApolloActionMenuArmModeratorFollowUp(self);
        }
        if (sApolloActionMenuOrigWillSelect) return sApolloActionMenuOrigWillSelect(self, _cmd, tableView, indexPath);
        return indexPath;
    }
    ApolloLog(@"[ActionMenu] Injected row %ld ('%@') tapped — handled at willSelect, not delivered to didSelectRowAtIndexPath:",
              (long)indexPath.row, spec.identifier);
    ApolloActionMenuPerformSpec(self, tableView, spec, indexPath);
    return nil;
}

static void ApolloActionMenuInstallWillSelect(void) {
    Class cls = objc_getClass("_TtC6Apollo16ActionController");
    if (!cls) {
        ApolloLog(@"[ActionMenu] ActionController class missing — willSelect dispatch not installed");
        return;
    }
    SEL sel = @selector(tableView:willSelectRowAtIndexPath:);
    Method existing = class_getInstanceMethod(cls, sel);
    if (!existing) {
        BOOL added = class_addMethod(cls, sel, (IMP)ApolloActionMenuWillSelectRow, "@@:@@");
        ApolloLog(@"[ActionMenu] willSelectRowAtIndexPath: %@ on ActionController", added ? @"added" : @"NOT added");
        return;
    }
    // Already implemented (own or inherited): keep it reachable for native rows.
    if (class_addMethod(cls, sel, (IMP)ApolloActionMenuWillSelectRow, method_getTypeEncoding(existing))) {
        sApolloActionMenuOrigWillSelect = (ApolloActionMenuWillSelectIMP)method_getImplementation(existing); // inherited
    } else {
        sApolloActionMenuOrigWillSelect = (ApolloActionMenuWillSelectIMP)method_setImplementation(existing, (IMP)ApolloActionMenuWillSelectRow); // own
    }
    ApolloLog(@"[ActionMenu] willSelectRowAtIndexPath: wrapped an existing implementation on ActionController");
}

%hook _TtC6Apollo16ActionController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    ApolloActionMenuSlotState *state = section == 0 ? ApolloActionMenuSlotsForController(self, nil) : nil;
    NSInteger nativeCount = %orig;
    if (section != 0) return nativeCount;
    state.nativeRowCount = nativeCount;
    if (state.specs.count == 0) return nativeCount;
    return nativeCount + (NSInteger)state.specs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(self, nil);
    NSInteger nativeCount = state.nativeRowCount;

    if (state.specs.count == 0 || indexPath.section != 0 || nativeCount < 0 || indexPath.row < nativeCount) {
        UITableViewCell *cell = %orig;
        // Opportunistically snapshot row 0's real rendered style/text — the ONLY
        // safe way to get a donor for the injected rows below. This must run on
        // UIKit's OWN, non-reentrant ask for row 0; see
        // ApolloActionMenuCaptureDonorSnapshot for why an injected row's own
        // cellForRow can never re-invoke %orig for row 0 (it crashes). Captured
        // fresh every time row 0 builds so a live theme change never leaves the
        // snapshot stale.
        if (state.specs.count > 0 && indexPath.row == 0) {
            state.donorSnapshot = ApolloActionMenuCaptureDonorSnapshot(cell);
        }
        return cell;
    }

    NSInteger slotIndex = indexPath.row - nativeCount;
    if (slotIndex < 0 || (NSUInteger)slotIndex >= state.specs.count) return %orig; // fail-soft, shouldn't happen

    ApolloActionMenuSpec *spec = state.specs[(NSUInteger)slotIndex];
    // nil until row 0 has naturally rendered at least once (e.g. a restored
    // scroll position skipping straight past it) — every consumer already
    // falls back gracefully on a nil donor.
    UITableViewCell *donor = state.donorSnapshot;

    NSString *title = spec.title ? spec.title(self, donor) : nil;
    if (title.length == 0) {
        // Fail-soft: UIKit's non-nil-cell contract applies to every spec, not
        // just the ones whose state happens to still resolve.
        UITableViewCell *inert = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:@"ApolloActionMenuInert"];
        inert.userInteractionEnabled = NO;
        inert.selectionStyle = UITableViewCellSelectionStyleNone;
        return inert;
    }
    UIImage *image = spec.image ? spec.image(self, donor) : nil;

    ApolloActionMenuRowCell *cell = [[ApolloActionMenuRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                                    reuseIdentifier:spec.identifier];
    ApolloActionMenuConfigureRowCell(cell, title, image, donor);
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(self, nil);
    NSInteger nativeCount = state.nativeRowCount;

    if (state.specs.count == 0 || indexPath.section != 0 || nativeCount < 0 || indexPath.row < nativeCount) {
        return %orig;
    }
    // Ask Apollo how tall its own rows are rather than guessing.
    return %orig(tableView, [NSIndexPath indexPathForRow:0 inSection:0]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloActionMenuSpec *spec = ApolloActionMenuSpecAtIndexPath(self, indexPath);
    if (!spec) {
        // Keep the Logos directive on its own line. Logos 2.4.1 consumes the
        // remainder of a line containing %orig, which previously dropped the
        // return and closing brace from generated Objective-C++.
        %orig;
        return;
    }
    // Normally unreachable: ApolloActionMenuWillSelectRow returns nil for
    // injected rows, so UIKit never sends didSelect for them. Kept as the
    // fallback for any selection path that skips willSelect, so a tap still
    // does something rather than falling into Apollo's native handler with an
    // out-of-range row.
    ApolloLog(@"[ActionMenu] Injected row %ld ('%@') reached didSelect (willSelect bypassed) — performing here",
              (long)indexPath.row, spec.identifier);
    ApolloActionMenuPerformSpec(self, tableView, spec, indexPath);
}
%end

%hook _TtC6Apollo38ActionControllerPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    UIViewController *presented = [(UIPresentationController *)self presentedViewController];
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(presented, nil);
    CGRect frame = %orig;
    if (frame.size.height <= 0.0 || !presented) return frame;

    if (state.specs.count == 0) return frame;

    CGFloat rowHeight = ApolloActionMenuNativeRowHeight(presented);
    if (rowHeight <= 0.0) return frame;

    CGFloat growth = rowHeight * (CGFloat)state.specs.count;
    frame.origin.y -= growth;
    frame.size.height += growth;
    return frame;
}

%end

#pragma mark - Which ••• menu is opening (customised layouts)

// The customisable menus are identified by where they are opened FROM, not by
// what they contain (a moderator, the post's author and a logged-out user all
// see different rows from the same button). Each entry point arms its context
// (ApolloActionMenuArmContext) just before Apollo builds the sheet and disarms
// it in @finally; the slot state claims it (ApolloActionMenuSlotsForController).
// Entry points confirmed in Hopper: the feed cells and the comments header's
// media node all route through PostCellActionTaker's post-options builder
// (sub_100325e84), the comments nav-bar ••• through CommentsViewController's
// own (sub_100727984), the feed nav-bar ••• through PostsViewController's
// (sub_1005c06d4), and a comment's ••• through CommentSectionController's
// (sub_1005ee890).
//
// The arm/disarm calls live in ApolloNativeActionMenus.xm, inside the hooks it
// already has on those six tap selectors (source-view capture for the glass
// morph) — one hook per selector, no second module wrapping the same method.
// Likewise the legacy sheet's prepare: that module's existing
// -[ActionController viewWillAppear:] hook calls ApolloActionMenuPrepareController
// first thing, so the native actions are permuted before Apollo's own
// appearance work sizes the table from actions.count (the presentation
// controller's frame reads the live count on every pass). On the glass path the
// controller is never presented — ApolloNativeActionMenuBuildMenu calls the same
// memoised prepare — so that hook is a no-op there.

%ctor {
    %init;
    ApolloActionMenuInstallWillSelect();
    ApolloLog(@"[ActionMenu] Action-menu registry hooks installed");
}
