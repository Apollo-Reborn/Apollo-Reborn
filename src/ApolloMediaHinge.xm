// Fullscreen media keeps native aspect-fit, zoom, and pan behavior while
// excluding the presenting page's trailing tab rail from its fit calculation.
#import <UIKit/UIKit.h>
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoSplitView.h"
#import "ApolloTextureDecls.h"
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

@interface ApolloDuoMediaOwner : NSObject
@property (nonatomic, weak) ASDisplayNode *cell;
@end
@implementation ApolloDuoMediaOwner
@end

struct ApolloDuoMediaDimension { NSInteger unit; CGFloat value; };

@interface ASLayoutElementStyle (ApolloDuoMedia)
@property (nonatomic) CGSize preferredSize;
- (void)setMaxHeight:(struct ApolloDuoMediaDimension)height;
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

static NSNumber *ApolloDuoMediaCurrentHeight(id node) {
    ApolloDuoMediaOwner *owner = objc_getAssociatedObject(node, &kApolloDuoMediaOwnerKey);
    id tableNode = ApolloDuoMediaOwningTable(owner.cell);
    return tableNode ? objc_getAssociatedObject(tableNode, &kApolloDuoMediaHeightKey) : nil;
}

static void ApolloDuoMediaRefreshAfterGeometryChange(UITableView *table);

static BOOL ApolloDuoMediaUpdateViewport(UITableView *table) {
    if (![NSThread isMainThread]) return NO;
    SEL selector = NSSelectorFromString(@"tableNode");
    id node = [table respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(table, selector) : nil;
    if (!node) return NO;
    CGFloat height = 0.0;
    UIWindow *window = table.window;
    if (window && ApolloDuoSplitIsUnfolded() && !ApolloDuoSplitIsUnfoldedPortrait()
        && CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds)) {
        // The requested limit is the full display height, not the currently
        // unobscured table area. Do not subtract the navigation/search bar or
        // home-indicator insets, which vary as the feed scrolls.
        height = floor(CGRectGetHeight(window.bounds));
        if (!isfinite(height) || height < 100.0) height = 0.0;
    }
    NSNumber *previous = objc_getAssociatedObject(node, &kApolloDuoMediaHeightKey);
    BOOL changed = fabs(previous.doubleValue - height) > 0.5;
    if (!previous || changed) {
        objc_setAssociatedObject(node, &kApolloDuoMediaHeightKey, @(height), OBJC_ASSOCIATION_RETAIN);
    }
    if (changed) ApolloDuoMediaRefreshAfterGeometryChange(table);
    return changed;
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
            id tableNode = ((id (*)(id, SEL))objc_msgSend)(liveTable, NSSelectorFromString(@"tableNode"));
            NSArray *cells = nil;
            @synchronized (tableNode) {
                NSHashTable *tracked = objc_getAssociatedObject(tableNode, &kApolloDuoMediaTrackedCellsKey);
                cells = tracked.allObjects;
            }
            CGFloat height = [objc_getAssociatedObject(tableNode, &kApolloDuoMediaHeightKey) doubleValue];
            for (ASDisplayNode *cell in cells) {
                ASDisplayNode *rich = ApolloDuoMediaObjectIvar(cell, "richMediaNode");
                NSNumber *measured = objc_getAssociatedObject(rich, &kApolloDuoMediaHeightKey);
                if (!rich || (measured && fabs(measured.doubleValue - height) <= 0.5)) continue;
                // A parent/child may still hold a valid Texture layout for
                // the same width. Invalidate that cache, then let ASCellNode's
                // normal size-invalidation path batch the table height update.
                // Do not synchronously relayout every row from a UIKit callback.
                ASDisplayNode *album = ApolloDuoMediaObjectIvar(rich, "albumThumbnailsNode");
                [album invalidateCalculatedLayout];
                [rich invalidateCalculatedLayout];
                [cell setNeedsLayout];
            }
        }
        objc_setAssociatedObject(liveTable, &kApolloDuoMediaRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
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

static id ApolloDuoMediaFitFixedBranch(id element, NSArray *mediaNodes, CGFloat height) {
    CGSize nativeSize = ApolloDuoMediaFixedSize(element, mediaNodes);
    if (nativeSize.width <= 0.0 || nativeSize.height <= height) return element;
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
                                 CGFloat height) {
    if (!ApolloDuoMediaIsSpec(element)) return ApolloDuoMediaFitFixedBranch(element, mediaNodes, height);
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
        id fit = ApolloDuoMediaFitFixedBranch(element, mediaNodes, height);
        if (fit != element) return fit;
    }
    NSArray *children = [(ASLayoutSpec *)element children];
    NSMutableArray *replacement = [NSMutableArray arrayWithCapacity:children.count];
    BOOL changed = NO;
    for (id child in children) {
        id limited = ApolloDuoMediaLimitSpec(child, mediaNodes, textNodes, height);
        [replacement addObject:limited];
        changed |= limited != child;
    }
    if (changed) [(ASLayoutSpec *)element setChildren:replacement];
    return element;
}

%hook ASTableView
- (void)didMoveToWindow {
    %orig;
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
    id richMedia = ApolloDuoMediaObjectIvar(self, "richMediaNode");
    id tableNode = ApolloDuoMediaOwningTable(self);
    if (richMedia) {
        ApolloDuoMediaOwner *owner = objc_getAssociatedObject(richMedia, &kApolloDuoMediaOwnerKey);
        if (!owner) {
            owner = [[ApolloDuoMediaOwner alloc] init];
            objc_setAssociatedObject(richMedia, &kApolloDuoMediaOwnerKey, owner, OBJC_ASSOCIATION_RETAIN);
        }
        owner.cell = (ASDisplayNode *)self;
        if (tableNode) {
            @synchronized (tableNode) {
                NSHashTable *tracked = objc_getAssociatedObject(tableNode, &kApolloDuoMediaTrackedCellsKey);
                if (!tracked) {
                    tracked = [NSHashTable weakObjectsHashTable];
                    objc_setAssociatedObject(tableNode, &kApolloDuoMediaTrackedCellsKey, tracked, OBJC_ASSOCIATION_RETAIN);
                }
                [tracked addObject:self];
            }
        }
    }
    return %orig(range);
}
%end

%hook _TtC6Apollo13RichMediaNode
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    BOOL comments = ApolloDuoMediaIsCommentsHeader(self);
    // Read the table's CURRENT immutable snapshot through the weak cell owner.
    // Texture can remeasure this child without rebuilding the parent's spec;
    // copying its height in LargePostCellNode left stale portrait values here.
    NSNumber *height = comments ? nil : ApolloDuoMediaCurrentHeight(self);
    objc_setAssociatedObject(self, &kApolloDuoMediaHeightKey, height, OBJC_ASSOCIATION_RETAIN);
    id album = ApolloDuoMediaObjectIvar(self, "albumThumbnailsNode");
    if (album) {
        id owner = comments ? nil : objc_getAssociatedObject(self, &kApolloDuoMediaOwnerKey);
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
    return ApolloDuoMediaLimitSpec(spec, media, text, height.doubleValue);
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
        return ApolloDuoMediaLimitSpec(spec, @[], @[], height);
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
}
