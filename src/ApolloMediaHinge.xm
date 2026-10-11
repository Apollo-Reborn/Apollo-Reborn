// Fullscreen media keeps native aspect-fit, zoom, and pan behavior while
// excluding the presenting page's trailing tab rail from its fit calculation.
#import <UIKit/UIKit.h>
#import "ApolloDuoCompatibility.h"
#import "ApolloMediaHinge.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoSplitView.h"
#import "ApolloTextureDecls.h"
#import "ApolloState.h"
#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>


// Native large cards assign image/video preferredSize from the feed width.
// On the unfolded landscape display that can make one preview several screens
// tall. Keep the row/text width, but cap media to the full landscape display
// height. Navigation/search bars may collapse while scrolling; their insets
// must not change the size of an already measured preview.
// The main-thread table callback publishes immutable geometry; Texture's
// background layout only reads that snapshot, never a UIView or UIWindow.
static char kApolloDuoMediaHeightKey;
static char kApolloDuoMediaRefreshPendingKey;
static char kApolloDuoMediaOwnerKey;
static char kApolloDuoMediaTrackedCellsKey;
static char kApolloDuoFeedGeometryKey;
static NSHashTable<UITableView *> *sApolloDuoFeedTables;

// Published once per geometry/settings change on the main thread. Texture
// measures nodes on background threads, which must never read UIKit geometry.
@interface ApolloDuoFeedGeometry : NSObject
@property (nonatomic) CGFloat height;
@property (nonatomic) CGFloat width;
@property (nonatomic) CGFloat centerOffset;
@property (nonatomic) NSInteger layout;
@property (nonatomic) BOOL comments;
@end
@implementation ApolloDuoFeedGeometry
@end

@interface ApolloDuoMediaOwner : NSObject
@property (nonatomic, weak) ASDisplayNode *cell;
@end
@implementation ApolloDuoMediaOwner
@end

struct ApolloDuoMediaDimension { NSInteger unit; CGFloat value; };

@interface ASLayoutElementStyle (ApolloDuoMedia)
@property (nonatomic) CGSize preferredSize;
- (void)setMaxHeight:(struct ApolloDuoMediaDimension)height;
- (void)setWidth:(struct ApolloDuoMediaDimension)width;
@end

@interface ASCenterLayoutSpec : ASLayoutSpec
+ (instancetype)centerLayoutSpecWithCenteringOptions:(NSUInteger)centering
                                      sizingOptions:(NSUInteger)sizing
                                              child:(id)child NS_RETURNS_RETAINED;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
@property (nonatomic) CGFloat ratio;
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child NS_RETURNS_RETAINED;
@end

@interface ASWrapperLayoutSpec : ASLayoutSpec
+ (instancetype)wrapperWithLayoutElement:(id)element;
@end

static id ApolloDuoMediaObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    // Apollo's Swift optional ASDisplayNode ivars have an empty ObjC type
    // encoding (verified on LargePostCellNode/RichMediaNode). These callers
    // use only the known object fields declared in Apollo's class dump.
    if (type && type[0] && type[0] != '@') return nil;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < 0 || (size_t)offset + sizeof(id) > class_getInstanceSize([object class])) return nil;
    return object_getIvar(object, ivar);
}

static BOOL ApolloDuoMediaIsCommentsHeader(id node) {
    Ivar ivar = class_getInstanceVariable([node class], "isShownInCommentsHeader");
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    // The native Swift Bool also has an empty ObjC encoding; its one-byte
    // representation is the same field used by the existing gallery module.
    if (type && type[0] && type[0] != 'B' && type[0] != 'c') return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < 0 || (size_t)offset + sizeof(uint8_t) > class_getInstanceSize([node class])) return NO;
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)node;
    return bytes[offset] != 0;
}

static id ApolloDuoMediaOwningTable(id node) {
    SEL selector = NSSelectorFromString(@"owningNode");
    return [node respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(node, selector) : nil;
}

static ApolloDuoFeedGeometry *ApolloDuoMediaCurrentGeometry(id node) {
    ApolloDuoMediaOwner *owner = objc_getAssociatedObject(node, &kApolloDuoMediaOwnerKey);
    id tableNode = ApolloDuoMediaOwningTable(owner.cell);
    return objc_getAssociatedObject(tableNode, &kApolloDuoFeedGeometryKey);
}

static NSNumber *ApolloDuoMediaCurrentHeight(id node) {
    ApolloDuoFeedGeometry *geometry = ApolloDuoMediaCurrentGeometry(node);
    // Original comments keep their native media size. The focus choice uses
    // the same media budget as the feed, published with the table geometry.
    if (geometry.comments && geometry.layout != 2) return nil;
    return geometry ? @(geometry.height) : nil;
}

static void ApolloDuoMediaRefreshAfterGeometryChange(UITableView *table);

static UIViewController *ApolloDuoMediaTableController(UITableView *table) {
    for (UIResponder *responder = table; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

static CGFloat ApolloDuoFeedCenterOffset(UITableView *table, UIWindow *window, UIViewController *owner) {
    // This existing ownership signal identifies the live feed beside comments.
    // Its card remains centered inside that column, even while UIKit reparents it.
    if (ApolloDuoSplitSuppressesFeedActions(owner)) return 0.0;
    // The split helper includes the trailing rail in the alignment band, while
    // excluding any leading sidebar. A full-width feed therefore targets the
    // window midpoint; other native columns retain their own alignment band.
    CGRect pane = ApolloDuoSplitContentFrame(owner, window);
    if (CGRectIsNull(pane)) pane = window.bounds;
    CGRect content = UIEdgeInsetsInsetRect(table.bounds, table.safeAreaInsets);
    CGFloat contentWidth = ApolloDuoRailFeedContentWidth(table);
    if (!isfinite(contentWidth) || contentWidth <= 0.0) contentWidth = CGRectGetWidth(content);
    CGFloat target = [table convertPoint:CGPointMake(CGRectGetMidX(pane), CGRectGetMidY(pane))
                               fromView:window].x;
    CGFloat offset = target - (CGRectGetMinX(content) + contentWidth * 0.5);
    return isfinite(offset) && contentWidth > 0.0 ? offset : 0.0;
}

static BOOL ApolloDuoMediaUpdateViewport(UITableView *table) {
    if (![NSThread isMainThread] || !table.window) return NO;
    // UIKit detaches retained tables while moving navigation columns. A nil
    // window is not a switch to Original/phone layout: keep the last immutable
    // geometry until the table attaches to its destination and publishes it.
    SEL selector = NSSelectorFromString(@"tableNode");
    id node = [table respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(table, selector) : nil;
    if (!node) return NO;
    if (!sApolloDuoFeedTables) sApolloDuoFeedTables = [NSHashTable weakObjectsHashTable];
    [sApolloDuoFeedTables addObject:table];
    CGFloat height = 0.0;
    CGFloat centerOffset = 0.0;
    NSInteger layout = 0;
    UIWindow *window = table.window;
    UIViewController *owner = ApolloDuoMediaTableController(table);
    BOOL comments = [owner isKindOfClass:NSClassFromString(@"Apollo.CommentsViewController")];
    if (window && ApolloDuoSplitIsUnfolded() && !ApolloDuoSplitIsUnfoldedPortrait()
        && CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds)) {
        // The requested limit is the full display height, not the currently
        // unobscured table area. Do not subtract the navigation/search bar or
        // home-indicator insets, which vary as the feed scrolls.
        height = floor(CGRectGetHeight(window.bounds));
        if (!isfinite(height) || height < 100.0) height = 0.0;
        if (height > 0.0 && sDuoLandscapeFeedLayout == 2) {
            layout = sDuoLandscapeFeedLayout;
            height = floor(height * 0.60);
            centerOffset = ApolloDuoFeedCenterOffset(table, window, owner);
        }
    }
    ApolloDuoFeedGeometry *previous = objc_getAssociatedObject(node, &kApolloDuoFeedGeometryKey);
    CGFloat width = CGRectGetWidth(table.bounds);
    BOOL changed = !previous || fabs(previous.height - height) > 0.5
        || fabs(previous.width - width) > 0.5
        || fabs(previous.centerOffset - centerOffset) > 0.5 || previous.layout != layout
        || previous.comments != comments;
    if (changed) {
        ApolloDuoFeedGeometry *geometry = [ApolloDuoFeedGeometry new];
        geometry.height = height;
        geometry.width = width;
        geometry.centerOffset = centerOffset;
        geometry.layout = layout;
        geometry.comments = comments;
        objc_setAssociatedObject(node, &kApolloDuoFeedGeometryKey, geometry, OBJC_ASSOCIATION_RETAIN);
    }
    if (changed) ApolloDuoMediaRefreshAfterGeometryChange(table);
    return changed;
}

static void ApolloDuoMediaInvalidateChangedCells(UITableView *table) {
    id tableNode = ((id (*)(id, SEL))objc_msgSend)(table, NSSelectorFromString(@"tableNode"));
    NSArray *cells = nil;
    @synchronized (tableNode) {
        NSHashTable *tracked = objc_getAssociatedObject(tableNode, &kApolloDuoMediaTrackedCellsKey);
        cells = tracked.allObjects;
    }
    ApolloDuoFeedGeometry *geometry = objc_getAssociatedObject(tableNode, &kApolloDuoFeedGeometryKey);
    for (ASDisplayNode *cell in cells) {
        ASDisplayNode *rich = ApolloDuoMediaObjectIvar(cell, "richMediaNode");
        NSNumber *measuredHeight = objc_getAssociatedObject(rich, &kApolloDuoMediaHeightKey);
        if (objc_getAssociatedObject(cell, &kApolloDuoFeedGeometryKey) == geometry
            && (!rich || (measuredHeight && fabs(measuredHeight.doubleValue - geometry.height) <= 0.5))) continue;
        // A parent/child may hold a valid Texture layout for the same width.
        // Invalidate it through ASCellNode's native size-update transaction.
        ASDisplayNode *album = ApolloDuoMediaObjectIvar(rich, "albumThumbnailsNode");
        [album invalidateCalculatedLayout];
        [rich invalidateCalculatedLayout];
        [cell setNeedsLayout];
    }
}

static void ApolloDuoMediaRefreshAfterGeometryChange(UITableView *table) {
    if (!table.window || [objc_getAssociatedObject(table, &kApolloDuoMediaRefreshPendingKey) boolValue]) return;
    objc_setAssociatedObject(table, &kApolloDuoMediaRefreshPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITableView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *liveTable = weakTable;
        if (!liveTable) return;
        if (liveTable.window) {
            ApolloDuoMediaUpdateViewport(liveTable);
            ApolloDuoMediaInvalidateChangedCells(liveTable);
        }
        objc_setAssociatedObject(liveTable, &kApolloDuoMediaRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

void ApolloDuoMediaPrepareTableForTransition(UITableView *table) {
    if (!NSThread.isMainThread || !table.window || !ApolloDuoSplitIsUnfolded()
        || ![table respondsToSelector:NSSelectorFromString(@"tableNode")]) return;
    ApolloDuoMediaUpdateViewport(table);
    // The column transition captures its endpoints in this turn. Waiting for
    // the usual deferred invalidation would expose native-width cells first,
    // then snap them into Focused after the comments surface starts sliding.
    // Ordinary scrolling keeps the coalesced asynchronous path above.
    ApolloDuoMediaInvalidateChangedCells(table);
}

static id ApolloDuoMediaCentered(id child) {
    // Texture: CenteringX = 1, SizingOptionMinimumY = 2. Keeping the outer
    // width releases the child's minimum width and centers its smaller fit.
    Class cls = NSClassFromString(@"ASCenterLayoutSpec");
    return cls ? [cls centerLayoutSpecWithCenteringOptions:1 sizingOptions:2 child:child] : child;
}

static BOOL ApolloDuoMediaIsSpec(id object) {
    return [object isKindOfClass:NSClassFromString(@"ASLayoutSpec")];
}

static BOOL ApolloDuoMediaContains(id element, id candidate) {
    if (!candidate) return NO;
    if (element == candidate) return YES;
    if (ApolloDuoMediaIsSpec(element)) {
        for (id child in [(ASLayoutSpec *)element children]) {
            if (ApolloDuoMediaContains(child, candidate)) return YES;
        }
    }
    return NO;
}

static CGSize ApolloDuoMediaFixedSize(id element, NSArray *mediaNodes) {
    if ([mediaNodes containsObject:element]) {
        CGSize size = [(ASDisplayNode *)element style].preferredSize;
        if (isfinite(size.width) && size.width > 0.0 && isfinite(size.height) && size.height > 0.0) return size;
    }
    CGSize largest = CGSizeZero;
    if (ApolloDuoMediaIsSpec(element)) {
        for (id child in [(ASLayoutSpec *)element children]) {
            CGSize size = ApolloDuoMediaFixedSize(child, mediaNodes);
            if (size.height > largest.height) largest = size;
        }
    }
    return largest;
}

static id ApolloDuoMediaFitFixedBranch(id element, NSArray *mediaNodes, CGFloat height, CGFloat width) {
    CGSize nativeSize = ApolloDuoMediaFixedSize(element, mediaNodes);
    if (nativeSize.width <= 0.0 || (nativeSize.height <= height && fabs(nativeSize.width - width) <= 0.5)) return element;
    Class ratioClass = NSClassFromString(@"ASRatioLayoutSpec");
    if (!ratioClass) return element;
    // Constrain the branch through a transient ratio spec, leaving the native
    // node's preferredSize untouched. Editing preferredSize left Texture's
    // old calculated image layout valid across folding; an exact ratio fit
    // instead supplies the new child constraints and preserves every overlay.
    ASLayoutSpec *fit = [ratioClass ratioLayoutSpecWithRatio:nativeSize.height / nativeSize.width child:element];
    fit.style.maxHeight = (struct ApolloDuoMediaDimension){1, height};
    return ApolloDuoMediaCentered(fit);
}

static id ApolloDuoMediaLimitSpec(id element, NSArray *mediaNodes, NSArray *textNodes,
                                 CGFloat height, CGFloat width) {
    if (!ApolloDuoMediaIsSpec(element)) return ApolloDuoMediaFitFixedBranch(element, mediaNodes, height, width);
    if ([element isKindOfClass:NSClassFromString(@"ASRatioLayoutSpec")]) {
        // Gallery/embedded-image ratios are layout specs recreated per pass;
        // no persistent node dimensions need changing for these previews.
        [(ASLayoutSpec *)element style].maxHeight = (struct ApolloDuoMediaDimension){1, height};
        return ApolloDuoMediaCentered(element);
    }
    BOOL hasText = NO;
    for (id textNode in textNodes) hasText |= ApolloDuoMediaContains(element, textNode);
    BOOL stack = [element isKindOfClass:NSClassFromString(@"ASStackLayoutSpec")];
    if (!hasText && !stack) {
        id fit = ApolloDuoMediaFitFixedBranch(element, mediaNodes, height, width);
        if (fit != element) return fit;
    }
    NSArray *children = [(ASLayoutSpec *)element children];
    NSMutableArray *replacement = [NSMutableArray arrayWithCapacity:children.count];
    BOOL changed = NO;
    for (id child in children) {
        id limited = ApolloDuoMediaLimitSpec(child, mediaNodes, textNodes, height, width);
        [replacement addObject:limited];
        changed |= limited != child;
    }
    if (changed) [(ASLayoutSpec *)element setChildren:replacement];
    return element;
}

static ASLayoutSpec *ApolloDuoFeedColumn(id child, CGFloat width) {
    // Size a transient wrapper rather than persisting dimensions on a native
    // node. Closing/folding or opening comments can then restore native layout.
    // Apollo's bundled inset spec bypasses style-size resolution. The wrapper
    // spec inherits that stage and passes the exact column width to its child.
    ASLayoutSpec *column = [NSClassFromString(@"ASWrapperLayoutSpec") wrapperWithLayoutElement:child];
    [column.style setWidth:(struct ApolloDuoMediaDimension){1, width}];
    return column;
}

static ApolloDuoFeedGeometry *ApolloDuoFeedPrepareCell(id cell, struct ApolloTextureSizeRange *range) {
    id richMedia = ApolloDuoMediaObjectIvar(cell, "richMediaNode");
    id tableNode = ApolloDuoMediaOwningTable(cell);
    ApolloDuoFeedGeometry *geometry = objc_getAssociatedObject(tableNode, &kApolloDuoFeedGeometryKey);
    objc_setAssociatedObject(cell, &kApolloDuoFeedGeometryKey, geometry, OBJC_ASSOCIATION_RETAIN);
    if (richMedia) {
        ApolloDuoMediaOwner *owner = objc_getAssociatedObject(richMedia, &kApolloDuoMediaOwnerKey);
        if (!owner) {
            owner = [[ApolloDuoMediaOwner alloc] init];
            objc_setAssociatedObject(richMedia, &kApolloDuoMediaOwnerKey, owner, OBJC_ASSOCIATION_RETAIN);
        }
        owner.cell = (ASDisplayNode *)cell;
    }
    if (tableNode) {
        @synchronized (tableNode) {
            NSHashTable *tracked = objc_getAssociatedObject(tableNode, &kApolloDuoMediaTrackedCellsKey);
            if (!tracked) {
                tracked = [NSHashTable weakObjectsHashTable];
                objc_setAssociatedObject(tableNode, &kApolloDuoMediaTrackedCellsKey, tracked, OBJC_ASSOCIATION_RETAIN);
            }
            // Text-only rows still need invalidation when the live layout
            // choice, column, or center offset changes.
            [tracked addObject:cell];
        }
    }
    if (range && geometry.layout == 2 && isfinite(range->max.width) && range->max.width > 0.0) {
        range->max.width = MIN(range->max.width, 640.0);
        range->min.width = MIN(range->min.width, range->max.width);
    }
    return geometry;
}

static ApolloDuoFeedGeometry *ApolloDuoCommentsPrepareCell(id cell, struct ApolloTextureSizeRange *range) {
    id tableNode = ApolloDuoMediaOwningTable(cell);
    ApolloDuoFeedGeometry *geometry = objc_getAssociatedObject(tableNode, &kApolloDuoFeedGeometryKey);
    // These node classes also appear in account comment lists and exported
    // Share as Image previews. Only a live comment thread owns this column.
    if (!geometry.comments) {
        // Register even before the table attaches to its controller/window.
        // The first published comments geometry must invalidate these cells;
        // otherwise their initial full-width measurement can remain cached.
        ApolloDuoFeedPrepareCell(cell, NULL);
        return nil;
    }
    return ApolloDuoFeedPrepareCell(cell, range);
}

static id ApolloDuoFeedLayoutSpec(id spec, CGFloat availableWidth, ApolloDuoFeedGeometry *geometry) {
    if (!spec || geometry.layout != 2 || !isfinite(availableWidth) || availableWidth <= 0.0) return spec;
    // Wrap either native post style wholesale: compact keeps its thumbnail,
    // title, metadata, vote controls, and gestures in their original hierarchy.
    CGFloat columnWidth = MIN(availableWidth, 640.0);
    id column = ApolloDuoFeedColumn(spec, columnWidth);
    CGFloat margin = MAX(0.0, (availableWidth - columnWidth) * 0.5);
    CGFloat offset = MIN(margin, MAX(-margin, geometry.centerOffset));
    if (fabs(offset) <= 0.5) return ApolloDuoMediaCentered(column);
    // Consume only the spare space around the card. If the pane is too narrow
    // to reach its target center, clamp at its edge instead of entering the rail.
    return [NSClassFromString(@"ASInsetLayoutSpec")
        insetLayoutSpecWithInsets:UIEdgeInsetsMake(0.0, margin + offset, 0.0, margin - offset)
                            child:column];
}

%hook ASTableView
- (void)didMoveToWindow {
    %orig;
    UITableView *table = (id)self;
    ApolloDuoMediaUpdateViewport(table);
    // A queued invalidation can run while this retained table is detached.
    // Recheck on attachment even if its published geometry is unchanged;
    // the shared pass skips every cell already measured for that snapshot.
    if (table.window) ApolloDuoMediaRefreshAfterGeometryChange(table);
}
- (void)safeAreaInsetsDidChange {
    %orig;
    // A column can move without changing the table's backing width.
    ApolloDuoMediaUpdateViewport((UITableView *)self);
}
- (void)didLayoutSubviewsOfTableViewCell:(UITableViewCell *)cell {
    // Texture can remeasure retained cells directly here when their content
    // width changes, bypassing dataController's constraint callback. Publish
    // the new pose before that measurement so portrait never inherits a cap.
    // This writes only an immutable snapshot, not view/layout geometry.
    ApolloDuoMediaUpdateViewport((UITableView *)self);
    %orig(cell);
}
- (struct ApolloTextureSizeRange)dataController:(id)controller constrainedSizeForNodeAtIndexPath:(NSIndexPath *)path {
    ApolloDuoMediaUpdateViewport((UITableView *)self);
    return %orig(controller, path);
}
%end

%hook _TtC6Apollo17LargePostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoFeedPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

// Large and Compact are sibling ASCellNode subclasses. Each implements this
// selector itself, so their own %orig calls wrap a native spec exactly once.
%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoFeedPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

// Wrap each native comment-row spec as a unit. Comment depth indicators,
// collapsing, bylines, vote controls, and links keep their original layout
// within the focused column, including rows added by Load More Comments.
%hook _TtC6Apollo15CommentCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoCommentsPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoCommentsPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

%hook _TtC6Apollo23RichMediaHeaderCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoCommentsPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

%hook _TtC6Apollo20MoreCommentsCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoCommentsPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

%hook _TtC6Apollo26ViewParentCommentsCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoCommentsPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

%hook _TtC6Apollo18NoCommentsCellNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat availableWidth = range.max.width;
    ApolloDuoFeedGeometry *geometry = ApolloDuoCommentsPrepareCell(self, &range);
    return ApolloDuoFeedLayoutSpec(%orig(range), availableWidth, geometry);
}
%end

%hook _TtC6Apollo13RichMediaNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    BOOL comments = ApolloDuoMediaIsCommentsHeader(self);
    // Read the table's CURRENT immutable snapshot through the weak cell owner.
    // Texture can remeasure this child without rebuilding the parent's spec;
    // copying its height in LargePostCellNode left stale portrait values here.
    ApolloDuoFeedGeometry *geometry = ApolloDuoMediaCurrentGeometry(self);
    BOOL focusedComments = geometry.comments && geometry.layout == 2;
    NSNumber *height = comments && !focusedComments ? nil : ApolloDuoMediaCurrentHeight(self);
    objc_setAssociatedObject(self, &kApolloDuoMediaHeightKey, height, OBJC_ASSOCIATION_RETAIN);
    id album = ApolloDuoMediaObjectIvar(self, "albumThumbnailsNode");
    if (album) {
        id owner = comments && !focusedComments ? nil : objc_getAssociatedObject(self, &kApolloDuoMediaOwnerKey);
        objc_setAssociatedObject(album, &kApolloDuoMediaOwnerKey, owner, OBJC_ASSOCIATION_RETAIN);
    }
    id spec = %orig(range);
    if (!spec || height.doubleValue <= 0.0) return spec;
    NSMutableArray *media = [NSMutableArray array];
    NSMutableArray *text = [NSMutableArray array];
    const char *mediaNames[] = {"thumbnailNode", "videoNode"};
    for (const char *name : mediaNames) {
        id node = ApolloDuoMediaObjectIvar(self, name);
        if (node) [media addObject:node];
    }
    const char *textNames[] = {"selfPostPreviewNode", "linkButtonNode"};
    for (const char *name : textNames) {
        id node = ApolloDuoMediaObjectIvar(self, name);
        if (node) [text addObject:node];
    }
    return ApolloDuoMediaLimitSpec(spec, media, text, height.doubleValue, range.max.width);
}
%end

%hook _TtC6Apollo19AlbumThumbnailsNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat height = ApolloDuoMediaCurrentHeight(self).doubleValue;
    if (height <= 0.0) return %orig(range);
    // Native mosaic is 16:9; the carousel has that same minimum height/width
    // ratio. Limit its input width first, so the original builds every native
    // thumbnail and gap proportionally in one pass. A taller carousel ratio
    // receives the additional height cap below.
    CGFloat width = MIN(range.max.width, height * (16.0 / 9.0));
    BOOL narrowed = isfinite(width) && width > 0.0 && width < range.max.width - 0.5;
    if (narrowed) {
        range.max.width = width;
        range.min.width = MIN(range.min.width, width);
    }
    id spec = %orig(range);
    if ([spec isKindOfClass:NSClassFromString(@"ASRatioLayoutSpec")]) {
        return ApolloDuoMediaLimitSpec(spec, @[], @[], height, range.max.width);
    }
    return spec && narrowed ? ApolloDuoMediaCentered(spec) : spec;
}
%end

// Native SMScrollView::_setMinimumZoomScaleToFit subtracts safeAreaInsets
// from its viewport before fitting (Apollo 1.15.11, 0x100042e08). On Duo the
// fullscreen viewer inherits the presenting tab controller's trailing rail
// inset, although the rail is not part of the viewer. The transition uses the
// full bounds, then this native fit shrinks even a square image by 84pt.
// Correct the geometry read at its source. Keep native aspect-fit, zoom and
// pan behavior; tall images should not be forcibly cropped to fill the width.
%hook SMScrollView
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = %orig;
    if (ApolloDuoCurrentMode() == ApolloDuoModePhone) return insets;
    Class viewerClass = NSClassFromString(@"_TtC6Apollo21MediaViewerController");
    BOOL fullscreenImage = [(id)((UIScrollView *)self).delegate isKindOfClass:viewerClass];
    if (!fullscreenImage) {
        for (UIResponder *next = ((UIView *)self).nextResponder; next; next = next.nextResponder) {
            if ([next isKindOfClass:viewerClass]) { fullscreenImage = YES; break; }
        }
    }
    if (fullscreenImage) {
        insets.left = 0.0;
        insets.right = 0.0;
    }
    return insets;
}
%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloDuoFeedLayoutDidChange"
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            for (UITableView *table in sApolloDuoFeedTables.allObjects) ApolloDuoMediaUpdateViewport(table);
            ApolloLog(@"[DuoFeed] landscape layout changed to %ld", (long)sDuoLandscapeFeedLayout);
        }];
}
