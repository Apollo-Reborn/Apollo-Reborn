#import "ApolloCommentsAccordion.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

// UIKit's own table update spring (the CASpringAnimation it installs for a row
// batch on iOS 26 and 27), so the accordion moves like any other batch.
static const CGFloat kAccordionSpringMass = 1.0;
static const CGFloat kAccordionSpringStiffness = 438.6;
static const CGFloat kAccordionSpringDamping = 41.9;

static NSString *const kAccordionAnimationKey = @"apolloAccordion";
static NSString *const kAccordionFadeKey = @"apolloAccordionFade";
static const void *kAccordionMaskKey = &kAccordionMaskKey;

#pragma mark - batch recording

// One Texture batch on its way to UIKit: everything between [super beginUpdates]
// and the matching [super endUpdates].
@interface ApolloAccordionBatch : NSObject
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic) NSUInteger depth;
// Something in the batch the accordion does not model: an explicit animation,
// a table outside a regular comments thread, a section operation or a move.
@property (nonatomic) BOOL foreign;
@property (nonatomic) BOOL sawAccordionOperation;
@property (nonatomic, strong) NSMutableArray<NSIndexPath *> *reloaded;
@property (nonatomic, strong) NSMutableArray<NSIndexPath *> *deleted;
@property (nonatomic, strong) NSMutableArray<NSIndexPath *> *inserted;
@end

@implementation ApolloAccordionBatch
- (instancetype)init {
    if ((self = [super init])) {
        _reloaded = [NSMutableArray array];
        _deleted = [NSMutableArray array];
        _inserted = [NSMutableArray array];
    }
    return self;
}
@end

// A running accordion: the views it added and the layers it animates.
@interface ApolloAccordionRun : NSObject
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<UIView *> *overlays;
@property (nonatomic, strong) NSHashTable<CALayer *> *animatedLayers;
@property (nonatomic, weak) UITableViewCell *maskedCell;
@property (nonatomic, weak) CALayer *mask;
// The expanded comment is raised above the rows-below picture for the run.
@property (nonatomic, weak) CALayer *raisedLayer;
@property (nonatomic) CGFloat raisedLayerZPosition;
@end

@implementation ApolloAccordionRun
- (instancetype)init {
    if ((self = [super init])) {
        _overlays = [NSMutableArray array];
        _animatedLayers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}
@end

static ApolloAccordionBatch *sBatch = nil;
static ApolloAccordionRun *sRun = nil;
// Rows drawn ahead while the accordion's batch commits; set only for the
// duration of that commit.
static __weak UITableView *sPredrawTable = nil;
static NSMutableSet<NSIndexPath *> *sPredrawRows = nil;

void ApolloAccordionTableWillBeginUpdates(UITableView *tableView) {
    if (![NSThread isMainThread]) return;
    if (sBatch && sBatch.tableView == tableView) {
        sBatch.depth++;
        return;
    }
    // Only the outermost batch of a single table is ever taken over.
    if (sBatch && sBatch.tableView && sBatch.depth > 0) return;
    sBatch = [ApolloAccordionBatch new];
    sBatch.tableView = tableView;
    sBatch.depth = 1;
}

static ApolloAccordionBatch *BatchFor(UITableView *tableView) {
    ApolloAccordionBatch *batch = sBatch;
    return (batch && batch.tableView == tableView && batch.depth > 0) ? batch : nil;
}

UITableViewRowAnimation ApolloAccordionAnimationForRows(UITableView *tableView,
                                                        ApolloListRowOperation operation,
                                                        NSArray<NSIndexPath *> *indexPaths,
                                                        UITableViewRowAnimation requested,
                                                        ApolloListRowScope scope) {
    UITableViewRowAnimation resolved = (UITableViewRowAnimation)ApolloListRowAnimationForOperation(
        operation, requested, scope);
    if (![NSThread isMainThread]) return resolved;
    ApolloAccordionBatch *batch = BatchFor(tableView);
    if (!batch) return resolved;
    if (scope != ApolloListRowScopeAccordion || requested != UITableViewRowAnimationAutomatic) {
        batch.foreign = YES;
        return resolved;
    }
    batch.sawAccordionOperation = YES;
    switch (operation) {
        case ApolloListRowOperationReload: [batch.reloaded addObjectsFromArray:indexPaths]; break;
        case ApolloListRowOperationInsert: [batch.inserted addObjectsFromArray:indexPaths]; break;
        case ApolloListRowOperationDelete: [batch.deleted addObjectsFromArray:indexPaths]; break;
    }
    return resolved;
}

void ApolloAccordionTableDidChangeSectionsOrMoveRows(UITableView *tableView) {
    if (![NSThread isMainThread]) return;
    BatchFor(tableView).foreign = YES;
}

static NSMutableData *RowsOf(NSArray<NSIndexPath *> *paths, NSInteger section, BOOL *otherSection) {
    NSMutableData *rows = [NSMutableData data];
    for (NSIndexPath *path in paths) {
        if (path.section != section) {
            *otherSection = YES;
            continue;
        }
        long row = path.row;
        [rows appendBytes:&row length:sizeof(row)];
    }
    return rows;
}

// The row of the comment a batch shaped like one comment collapsing or
// expanding changes (the same before and after), or nil.
static NSIndexPath *CandidateCommentRow(ApolloAccordionBatch *batch) {
    NSIndexPath *any = batch.deleted.firstObject ?: batch.inserted.firstObject;
    if (!any) return nil;
    BOOL otherSection = NO;
    NSMutableData *deleted = RowsOf(batch.deleted, any.section, &otherSection);
    NSMutableData *inserted = RowsOf(batch.inserted, any.section, &otherSection);
    if (otherSection) return nil;
    BOOL ignored = NO;
    NSMutableData *reloaded = RowsOf(batch.reloaded, any.section, &ignored);
    long row = ApolloAccordionBatchCommentRow(
        (const long *)reloaded.bytes, reloaded.length / sizeof(long),
        (const long *)deleted.bytes, deleted.length / sizeof(long),
        (const long *)inserted.bytes, inserted.length / sizeof(long));
    return row >= 0 ? [NSIndexPath indexPathForRow:row inSection:any.section] : nil;
}

// The top safe area of the view of the controller showing the table, which
// Apollo scrolls a comment's top to (ApolloAccordionRevealFor).
static CGFloat RevealTopInset(UITableView *tableView) {
    for (UIResponder *responder = tableView.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            UIView *view = ((UIViewController *)responder).viewIfLoaded;
            if (view) return view.safeAreaInsets.top;
            break;
        }
    }
    return tableView.adjustedContentInset.top;
}

#pragma mark - rows on screen

// One row on screen, before or after the batch.
@interface ApolloAccordionRow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CGRect frame;
@property (nonatomic, weak) UITableViewCell *cell;
@property (nonatomic, strong) NSIndexPath *indexPath;
@end

@implementation ApolloAccordionRow
@end

static NSArray<ApolloAccordionRow *> *RowsOnScreen(UITableView *tableView, ApolloAccordionRowIdentity identity) {
    NSMutableArray<ApolloAccordionRow *> *rows = [NSMutableArray array];
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell.hidden) continue;
        NSString *name = identity(cell);
        NSIndexPath *path = [tableView indexPathForCell:cell];
        if (name.length == 0 || !path) continue;
        ApolloAccordionRow *row = [ApolloAccordionRow new];
        row.name = name;
        row.frame = cell.frame;
        row.cell = cell;
        row.indexPath = path;
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(ApolloAccordionRow *a, ApolloAccordionRow *b) {
        return [@(CGRectGetMinY(a.frame)) compare:@(CGRectGetMinY(b.frame))];
    }];
    return rows;
}

static long KeyFor(NSString *string, NSMutableDictionary<NSString *, NSNumber *> *ids) {
    NSNumber *number = ids[string];
    if (!number) {
        number = @(ids.count + 1);
        ids[string] = number;
    }
    return number.longValue;
}

// Keys for the pure matcher. A comment is its name; any other row is its kind
// at its row counted from the top (head) and from the end of its section (tail).
static NSMutableData *GeometryForRows(NSArray<ApolloAccordionRow *> *rows,
                                      NSDictionary<NSNumber *, NSNumber *> *rowCounts,
                                      NSMutableDictionary<NSString *, NSNumber *> *ids) {
    NSMutableData *geometry = [NSMutableData dataWithLength:rows.count * sizeof(ApolloAccordionRowGeometry)];
    ApolloAccordionRowGeometry *out = (ApolloAccordionRowGeometry *)geometry.mutableBytes;
    for (NSUInteger i = 0; i < rows.count; i++) {
        ApolloAccordionRow *row = rows[i];
        if ([row.name hasPrefix:@"~"]) {
            NSInteger section = row.indexPath.section;
            NSInteger fromEnd = rowCounts[@(section)].integerValue - row.indexPath.row;
            out[i].headKey = KeyFor([NSString stringWithFormat:@"%@#%ld:%ld", row.name, (long)section, (long)row.indexPath.row], ids);
            out[i].tailKey = KeyFor([NSString stringWithFormat:@"%@#%ld:-%ld", row.name, (long)section, (long)fromEnd], ids);
        } else {
            out[i].headKey = out[i].tailKey = KeyFor(row.name, ids);
        }
        out[i].y = CGRectGetMinY(row.frame);
        out[i].height = CGRectGetHeight(row.frame);
    }
    return geometry;
}

// "4-9,12" for a log line.
static NSString *RowList(NSArray<NSIndexPath *> *paths) {
    if (paths.count == 0) return @"-";
    NSArray<NSIndexPath *> *sorted = [paths sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < sorted.count) {
        NSUInteger j = i;
        while (j + 1 < sorted.count && sorted[j + 1].section == sorted[i].section &&
               sorted[j + 1].row == sorted[j].row + 1) j++;
        NSString *prefix = sorted[i].section ? [NSString stringWithFormat:@"%ld:", (long)sorted[i].section] : @"";
        [parts addObject:(j == i) ? [NSString stringWithFormat:@"%@%ld", prefix, (long)sorted[i].row]
                                  : [NSString stringWithFormat:@"%@%ld-%ld", prefix, (long)sorted[i].row, (long)sorted[j].row]];
        i = j + 1;
    }
    return [parts componentsJoinedByString:@","];
}

#pragma mark - animation

static CASpringAnimation *AccordionSpring(NSString *keyPath, id fromValue, id toValue, BOOL additive) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:keyPath];
    spring.mass = kAccordionSpringMass;
    spring.stiffness = kAccordionSpringStiffness;
    spring.damping = kAccordionSpringDamping;
    spring.initialVelocity = 0;
    spring.duration = spring.settlingDuration;
    spring.fromValue = fromValue;
    spring.toValue = toValue;
    spring.additive = additive;
    spring.fillMode = kCAFillModeBackwards;
    return spring;
}

static CFTimeInterval AccordionDuration(void) {
    return AccordionSpring(@"opacity", @0, @0, NO).duration;
}

// Animate a layer that already sits at its final place from `offsetY` above
// or below it.
static void SlideLayerIn(ApolloAccordionRun *run, CALayer *layer, CGFloat offsetY) {
    if (fabs(offsetY) < 0.5) return;
    CASpringAnimation *slide = AccordionSpring(@"position",
                                               [NSValue valueWithCGPoint:CGPointMake(0, offsetY)],
                                               [NSValue valueWithCGPoint:CGPointZero],
                                               YES);
    [layer addAnimation:slide forKey:kAccordionAnimationKey];
    [run.animatedLayers addObject:layer];
}

// A clip that keeps its top edge put while its height animates.
static void AnimateTopPinnedHeight(CALayer *layer, CGFloat fromHeight, CGFloat toHeight) {
    [layer addAnimation:AccordionSpring(@"bounds.size.height", @(fromHeight), @(toHeight), NO)
                 forKey:kAccordionAnimationKey];
}

static void PinLayerTop(CALayer *layer, CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    layer.anchorPoint = CGPointMake(0.5, 0.0);
    layer.bounds = CGRectMake(0, 0, width, height);
    layer.position = CGPointMake(x + width / 2.0, y);
}

// The collapsed row takes over from the comment's picture in place: the
// picture fades out over `[from, to]` of the spring (fractions of its
// duration). The header pixels of both line up, so only the reply count
// changes.
static void FadeOutDuring(CALayer *layer, double from, double to) {
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@1, @1, @0];
    fade.keyTimes = @[@0, @(from), @(to)];
    fade.duration = AccordionDuration();
    fade.fillMode = kCAFillModeBoth;
    fade.removedOnCompletion = NO;
    [layer addAnimation:fade forKey:kAccordionFadeKey];
}

static UIView *LowestCell(UITableView *tableView) {
    UIView *lowest = nil;
    NSUInteger lowestIndex = NSNotFound;
    NSArray<UIView *> *subviews = tableView.subviews;
    for (UITableViewCell *cell in tableView.visibleCells) {
        NSUInteger index = [subviews indexOfObjectIdenticalTo:cell];
        if (index != NSNotFound && index < lowestIndex) {
            lowestIndex = index;
            lowest = cell;
        }
    }
    return lowest;
}

// Lands a run at its end state at once: pictures gone, every row at its place.
static void FinishRun(ApolloAccordionRun *run) {
    if (!run) return;
    for (UIView *overlay in run.overlays) [overlay removeFromSuperview];
    [run.overlays removeAllObjects];
    for (CALayer *layer in run.animatedLayers) [layer removeAnimationForKey:kAccordionAnimationKey];
    [run.animatedLayers removeAllObjects];
    UITableViewCell *cell = run.maskedCell;
    CALayer *mask = run.mask;
    if (cell && mask && cell.layer.mask == mask) cell.layer.mask = nil;
    if (cell) objc_setAssociatedObject(cell, kAccordionMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CALayer *raised = run.raisedLayer;
    if (raised) raised.zPosition = run.raisedLayerZPosition;
    run.raisedLayer = nil;
    if (sRun == run) sRun = nil;
}

static UIView *PrepareOverlayView(UIView *view) {
    view.userInteractionEnabled = NO;
    return view;
}

#pragma mark - pictures

// The rows as they were before the batch: one picture of the table from the
// top of the batch's first changed row down to the bottom of the screen,
// rendered from the cells' own layers just before the commit. Being drawn from
// the layers the screen shows, a crop of it lines up with the screen pixel for
// pixel, minus the touch highlight the tap can leave on the comment (cleared
// first). Screen snapshots are not used: a snapshot of the table shown inside
// the table can come up blank on a device.
@interface ApolloAccordionPictures : NSObject
@property (nonatomic) CGRect visibleRect;
@property (nonatomic) CGFloat top;
@property (nonatomic, strong) UIImage *image;
@end

@implementation ApolloAccordionPictures
@end

// A view showing the rows as they were inside `region` (table content
// coordinates), sized to it; nil when the picture does not cover it.
static UIView *PictureOfRegion(ApolloAccordionPictures *pictures, CGRect region) {
    UIImage *image = pictures.image;
    if (!image || CGRectGetHeight(region) < 0.5) return nil;
    CGFloat scale = image.scale;
    CGFloat y = CGRectGetMinY(region) - pictures.top;
    if (y < -0.5 || y + CGRectGetHeight(region) > image.size.height + 0.5) return nil;
    CGRect pixels = CGRectIntegral(CGRectMake(0, MAX(0, y) * scale, image.size.width * scale, CGRectGetHeight(region) * scale));
    CGImageRef cropped = CGImageCreateWithImageInRect(image.CGImage, pixels);
    if (!cropped) return nil;
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp]];
    CGImageRelease(cropped);
    view.frame = CGRectMake(0, 0, CGRectGetWidth(region), CGRectGetHeight(region));
    return PrepareOverlayView(view);
}

// Layers a render cannot reproduce (video, backdrop blur, portals). A comment
// showing one keeps Apollo's own animation.
static BOOL LayerTreeHasLiveContent(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > 24) return NO;
    NSString *name = NSStringFromClass(layer.class);
    if ([name containsString:@"AVPlayerLayer"] || [name containsString:@"Backdrop"] || [name containsString:@"Portal"]) {
        return YES;
    }
    for (CALayer *sublayer in layer.sublayers) {
        if (LayerTreeHasLiveContent(sublayer, depth + 1)) return YES;
    }
    return NO;
}

// Captured just before the commit. Returns nil when the rows cannot be drawn
// faithfully; the batch then keeps Apollo's own animation.
static ApolloAccordionPictures *CapturePictures(UITableView *tableView, ApolloAccordionBatch *batch,
                                                NSArray<ApolloAccordionRow *> *oldRows) {
    ApolloAccordionPictures *pictures = [ApolloAccordionPictures new];
    pictures.visibleRect = tableView.bounds;
    CGFloat visibleTop = CGRectGetMinY(pictures.visibleRect);
    CGFloat visibleBottom = CGRectGetMaxY(pictures.visibleRect);

    // Everything above the batch's first changed row stays put, so only the
    // rows from there down to the bottom of the screen are drawn (at most two
    // screens, whatever the length of the comment).
    NSMutableSet<NSIndexPath *> *changed = [NSMutableSet setWithArray:batch.reloaded];
    [changed addObjectsFromArray:batch.deleted];
    CGFloat top = visibleBottom;
    for (ApolloAccordionRow *row in oldRows) {
        if ([changed containsObject:row.indexPath]) top = MIN(top, CGRectGetMinY(row.frame));
    }
    if (top >= visibleBottom) top = visibleTop;
    // A comment whose top is above the screen is drawn from its top, up to a
    // screen above it, for the scroll that brings that top into view
    // (ApolloAccordionRevealFor).
    top = MAX(top, visibleTop - CGRectGetHeight(pictures.visibleRect));
    pictures.top = top;
    CGFloat width = CGRectGetWidth(tableView.bounds);
    CGFloat height = visibleBottom - top;
    if (height < 0.5) return pictures;

    CGRect region = CGRectMake(0, top, width, height);
    for (ApolloAccordionRow *row in oldRows) {
        if (CGRectIntersectsRect(row.frame, region) && LayerTreeHasLiveContent(row.cell.layer, 0)) return nil;
    }
    // The tapped comment can still show the touch highlight or the selection
    // gray. Only rows the batch reloads or deletes are cleared: their old
    // cells are discarded by the commit, so the table's own selection state
    // never disagrees with a cell it keeps.
    for (ApolloAccordionRow *row in oldRows) {
        UITableViewCell *cell = row.cell;
        if (![changed containsObject:row.indexPath]) continue;
        if (cell.highlighted) [cell setHighlighted:NO animated:NO];
        if (cell.selected) [cell setSelected:NO animated:NO];
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:tableView.traitCollection];
    if (@available(iOS 12.0, *)) format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height) format:format];
    UIColor *background = [tableView.backgroundColor resolvedColorWithTraitCollection:tableView.traitCollection];
    pictures.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        if (background) {
            [background setFill];
            UIRectFill(CGRectMake(0, 0, width, height));
        }
        for (ApolloAccordionRow *row in oldRows) {
            UITableViewCell *cell = row.cell;
            if (!cell || !CGRectIntersectsRect(row.frame, region)) continue;
            CGContextSaveGState(context.CGContext);
            CGContextTranslateCTM(context.CGContext, CGRectGetMinX(row.frame), CGRectGetMinY(row.frame) - top);
            [cell.layer renderInContext:context.CGContext];
            CGContextRestoreGState(context.CGContext);
        }
    }];
    return pictures;
}

#pragma mark - lining up the two states of the comment

static const CGFloat kAccordionMatchRowsPerPoint = 2;
static const CGFloat kAccordionMatchMaxOffset = 24;   // points

// `region` (points, from the image's top) of `image` as one byte of gray per
// pixel at kAccordionMatchRowsPerPoint pixels per point.
static NSMutableData *GrayPixels(UIImage *image, CGRect region, long *columns, long *rows) {
    CGFloat scale = kAccordionMatchRowsPerPoint;
    long width = (long)floor(CGRectGetWidth(region) * scale);
    long height = (long)floor(CGRectGetHeight(region) * scale);
    if (!image.CGImage || width <= 0 || height <= 0) return nil;
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)(width * height)];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, (size_t)width, (size_t)height, 8, (size_t)width,
                                                 gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGFloat imageHeight = image.size.height * scale;
    CGContextDrawImage(context, CGRectMake(-CGRectGetMinX(region) * scale,
                                           height - imageHeight + CGRectGetMinY(region) * scale,
                                           image.size.width * scale, imageHeight), image.CGImage);
    CGContextRelease(context);
    *columns = width;
    *rows = height;
    return pixels;
}

static UIImage *RenderCellTop(UITableViewCell *cell, CGFloat height) {
    if (!cell || height <= 0) return nil;
    [cell layoutIfNeeded];   // a reused cell may still carry its previous row's layout
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:cell.traitCollection];
    if (@available(iOS 12.0, *)) format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(CGRectGetWidth(cell.bounds), MIN(height, CGRectGetHeight(cell.bounds))) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [cell.layer renderInContext:context.CGContext];
    }];
}

// How the expanded comment's header lines up with the collapsed row's, in
// points; confident is false when it cannot be told (no text, ambiguous).
typedef struct AccordionHeaderAlignment {
    BOOL confident;
    CGFloat offset;        // move the expanded header down by this to sit on the collapsed one
    CGFloat headerHeight;  // the expanded comment's header band
    CGFloat chipX;         // where the reply count area starts (points from the left)
} AccordionHeaderAlignment;

static AccordionHeaderAlignment AlignHeaders(UIImage *collapsed, CGRect collapsedRegion,
                                             UIImage *expanded, CGRect expandedRegion) {
    AccordionHeaderAlignment none = {NO, 0, 0, 0};
    long cw = 0, ch = 0, ew = 0, eh = 0;
    NSMutableData *a = GrayPixels(collapsed, collapsedRegion, &cw, &ch);
    NSMutableData *b = GrayPixels(expanded, expandedRegion, &ew, &eh);
    if (!a || !b || cw != ew) return none;
    ApolloAccordionHeaderMatch match = ApolloAccordionMatchHeaders(
        (const unsigned char *)a.bytes, ch, (const unsigned char *)b.bytes, eh, cw, (long)(cw * 0.6),
        (long)(kAccordionMatchMaxOffset * kAccordionMatchRowsPerPoint), (long)kAccordionMatchRowsPerPoint);
    if (!match.confident) return none;
    AccordionHeaderAlignment alignment = {YES,
                                          match.offset / kAccordionMatchRowsPerPoint,
                                          match.headerRows / kAccordionMatchRowsPerPoint,
                                          match.chipColumn / kAccordionMatchRowsPerPoint};
    return alignment;
}

#pragma mark - the accordion

static void AnimateCollapse(UITableView *tableView, ApolloAccordionRun *run, ApolloAccordionPictures *pictures,
                            ApolloAccordionPlan plan, CGRect oldParentFrame, CGRect newParentFrame,
                            UITableViewCell *newParentCell, NSArray<ApolloAccordionRow *> *newRows) {
    CGFloat width = CGRectGetWidth(tableView.bounds);
    CGFloat top = CGRectGetMinY(oldParentFrame);
    CGFloat oldBottom = CGRectGetMaxY(oldParentFrame);
    CGFloat newBottom = CGRectGetMaxY(newParentFrame);

    // The comment as it was stays on top, exactly where it was, clipped from
    // the bottom; the collapsed row underneath takes over as the picture fades
    // at the very end. When the two headers line up, the picture's header
    // glides onto the collapsed row's while the clip closes on the end of that
    // header, so the name never jumps and the bar settles at its own height.
    UIView *parentPicture = PictureOfRegion(pictures, CGRectMake(0, top, width, plan.parentFrom));
    if (parentPicture) {
        CGFloat clipTo = plan.parentTo;
        CGFloat glide = 0;
        CGFloat newHeight = CGRectGetHeight(newParentFrame);
        UIImage *collapsedRow = RenderCellTop(newParentCell, newHeight);
        if (collapsedRow) {
            CGFloat oldSample = MIN(plan.parentFrom, newHeight + kAccordionMatchMaxOffset * 2);
            AccordionHeaderAlignment alignment = AlignHeaders(collapsedRow, CGRectMake(0, 0, width, newHeight),
                                                              pictures.image,
                                                              CGRectMake(0, top - pictures.top, width, oldSample));
            if (alignment.confident) {
                glide = alignment.offset;
                clipTo = MIN(newHeight, MAX(0, glide + alignment.headerHeight));
            }
        }
        UIView *clip = PrepareOverlayView([UIView new]);
        clip.clipsToBounds = YES;
        PinLayerTop(clip.layer, 0, top, width, clipTo);
        CGRect pictureFrame = parentPicture.frame;
        pictureFrame.origin.y = glide;
        parentPicture.frame = pictureFrame;
        [clip addSubview:parentPicture];
        if (newParentCell.superview == tableView) [tableView insertSubview:clip aboveSubview:newParentCell];
        else [tableView addSubview:clip];
        AnimateTopPinnedHeight(clip.layer, plan.parentFrom, clipTo);
        SlideLayerIn(run, parentPicture.layer, -glide);
        FadeOutDuring(clip.layer, 0.6, 0.9);
        [run.overlays addObject:clip];
    }

    // The replies that were on screen ride under the comment's bottom edge,
    // beneath every row, clipped where the rows below begin (which moves with
    // them), so near the end of the list they never show past the last row.
    UIView *replies = PictureOfRegion(pictures, CGRectMake(0, oldBottom, width, plan.repliesHeight));
    if (replies) {
        UIView *clip = PrepareOverlayView([UIView new]);
        clip.clipsToBounds = YES;
        CGFloat endOfList = MAX(tableView.contentSize.height, newBottom);
        PinLayerTop(clip.layer, 0, newBottom, width, endOfList - newBottom);
        [clip addSubview:replies];
        UIView *lowest = LowestCell(tableView);
        if (lowest) [tableView insertSubview:clip belowSubview:lowest];
        else [tableView insertSubview:clip atIndex:0];
        AnimateTopPinnedHeight(clip.layer, endOfList - newBottom + plan.rowsBelowOffset, endOfList - newBottom);
        SlideLayerIn(run, replies.layer, oldBottom - newBottom);
        [run.overlays addObject:clip];
    }

    // The rows below close up over them.
    for (ApolloAccordionRow *row in newRows) {
        if (CGRectGetMinY(row.frame) >= newBottom - 0.5 && row.cell) SlideLayerIn(run, row.cell.layer, plan.rowsBelowOffset);
    }
    UIView *footer = tableView.tableFooterView;
    if (footer && CGRectGetMinY(footer.frame) >= newBottom - 0.5) SlideLayerIn(run, footer.layer, plan.rowsBelowOffset);
}

static void AnimateExpand(UITableView *tableView, ApolloAccordionRun *run, ApolloAccordionPictures *pictures,
                          ApolloAccordionPlan plan, CGRect oldParentFrame, CGRect newParentFrame,
                          UITableViewCell *newParentCell, NSArray<ApolloAccordionRow *> *newRows) {
    CGFloat width = CGRectGetWidth(tableView.bounds);
    CGFloat oldBottom = CGRectGetMaxY(oldParentFrame);
    CGFloat newBottom = CGRectGetMaxY(newParentFrame);

    // The live expanded comment, on top of everything below it, is revealed
    // from the top down: clipped from the bottom to a height that grows to its
    // own, so nothing ever covers its text. When its header lines up with the
    // collapsed row's, the reveal starts at its header band, the comment glides
    // from the collapsed header's place to its own, the collapsed row stays
    // underneath to fill around it, and only the reply count fades out on top.
    // Otherwise the reveal starts at the collapsed row's height.
    CGFloat top = CGRectGetMinY(oldParentFrame);
    CGFloat oldHeight = CGRectGetHeight(oldParentFrame);
    CGFloat revealFrom = plan.parentFrom;
    AccordionHeaderAlignment alignment = {NO, 0, 0, 0};
    UIImage *expandedTop = RenderCellTop(newParentCell, MIN(plan.parentTo, oldHeight + kAccordionMatchMaxOffset * 2));
    if (expandedTop && oldHeight > 0) {
        alignment = AlignHeaders(pictures.image, CGRectMake(0, top - pictures.top, width, oldHeight),
                                 expandedTop, CGRectMake(0, 0, width, expandedTop.size.height));
        if (alignment.confident) revealFrom = MIN(plan.parentTo, alignment.headerHeight);
    }
    BOOL revealed = NO;
    if (newParentCell && !newParentCell.layer.mask && plan.parentTo > revealFrom + 0.5) {
        revealed = YES;
        CALayer *mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        PinLayerTop(mask, 0, 0, CGRectGetWidth(newParentCell.bounds), plan.parentTo);
        newParentCell.layer.mask = mask;
        objc_setAssociatedObject(newParentCell, kAccordionMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AnimateTopPinnedHeight(mask, revealFrom, plan.parentTo);
        run.maskedCell = newParentCell;
        run.mask = mask;
        run.raisedLayer = newParentCell.layer;
        run.raisedLayerZPosition = newParentCell.layer.zPosition;
        newParentCell.layer.zPosition = 2;
    }
    // (Only around a comment that is being revealed: the picture under it
    // would otherwise sit over a comment shown whole.)
    if (alignment.confident && revealed) {
        SlideLayerIn(run, newParentCell.layer, alignment.offset);
        // The collapsed row as it was, under the comment, fills whatever the
        // comment does not cover yet.
        UIView *under = PictureOfRegion(pictures, CGRectMake(0, top, width, oldHeight));
        if (under) {
            under.frame = CGRectMake(0, top, width, oldHeight);
            under.layer.zPosition = 1.5;
            [tableView addSubview:under];
            [run.overlays addObject:under];
        }
        // The reply count fades out on top, over the header band only.
        CGFloat chipHeight = MIN(oldHeight, alignment.offset + alignment.headerHeight);
        UIView *chip = alignment.chipX < width - 0.5
            ? PictureOfRegion(pictures, CGRectMake(0, top, width, chipHeight)) : nil;
        if (chip) {
            UIView *chipClip = PrepareOverlayView([UIView new]);
            chipClip.clipsToBounds = YES;
            chipClip.frame = CGRectMake(alignment.chipX, top, width - alignment.chipX, chipHeight);
            chip.frame = CGRectMake(-alignment.chipX, 0, width, chipHeight);
            [chipClip addSubview:chip];
            chipClip.layer.zPosition = 3;
            [tableView addSubview:chipClip];
            FadeOutDuring(chipClip.layer, 0.0, 0.35);
            [run.overlays addObject:chipClip];
        }
    }
    // The new replies ride under its bottom edge, already in place underneath.
    CGFloat repliesEnd = oldBottom + plan.belowTravel;
    for (ApolloAccordionRow *row in newRows) {
        CGFloat y = CGRectGetMinY(row.frame);
        if (y >= newBottom - 0.5 && y < MAX(repliesEnd, newBottom) - 0.5 && row.cell) {
            SlideLayerIn(run, row.cell.layer, plan.repliesOffset);
        }
    }

    // The rows below, as they were, slide down with the comment's growing edge
    // over its new replies (but under the comment) until they reach their
    // place or leave the screen, uncovering the replies.
    UIView *below = PictureOfRegion(pictures, CGRectMake(0, oldBottom, width, plan.belowHeight));
    if (below) {
        below.frame = CGRectMake(0, oldBottom + plan.belowTravel, width, plan.belowHeight);
        below.layer.zPosition = 1;
        [tableView addSubview:below];
        SlideLayerIn(run, below.layer, -plan.belowTravel);
        [run.overlays addObject:below];
    }
}

// Not one comment collapsing or expanding after all, but the batch is already
// committed: rows that were on screen glide from where they were to where they
// are now.
static void AnimateRowsGlide(ApolloAccordionRun *run, NSArray<ApolloAccordionRow *> *oldRows,
                             NSArray<ApolloAccordionRow *> *newRows,
                             const ApolloAccordionRowGeometry *oldGeometry,
                             const ApolloAccordionRowGeometry *newGeometry) {
    for (NSUInteger j = 0; j < newRows.count; j++) {
        for (NSUInteger i = 0; i < oldRows.count; i++) {
            if (oldGeometry[i].tailKey != newGeometry[j].tailKey) continue;
            if (newRows[j].cell) SlideLayerIn(run, newRows[j].cell.layer, oldGeometry[i].y - newGeometry[j].y);
            break;
        }
    }
}

static void PredrawCell(UITableViewCell *cell) {
    if (![cell respondsToSelector:@selector(node)]) return;
    id node = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node));
    SEL ensureDisplay = NSSelectorFromString(@"recursivelyEnsureDisplaySynchronously:");
    if (![node respondsToSelector:@selector(layoutIfNeeded)] || ![node respondsToSelector:ensureDisplay]) return;
    ((void (*)(id, SEL))objc_msgSend)(node, @selector(layoutIfNeeded));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(node, ensureDisplay, YES);
}

void ApolloAccordionTableWillDisplayCell(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (![NSThread isMainThread]) return;
    if (sPredrawRows && tableView == sPredrawTable) {
        if ([sPredrawRows containsObject:indexPath]) {
            [sPredrawRows removeObject:indexPath];
            PredrawCell(cell);
        }
        return;
    }
    // A cell that comes on screen (again) while or after an accordion ran, or
    // is reused for another row, must not carry its clip, its slide or its
    // raised layer into it: the run may have set them for its previous row.
    ApolloAccordionRun *run = sRun;
    CALayer *mask = objc_getAssociatedObject(cell, kAccordionMaskKey);
    if (mask) {
        if (cell.layer.mask == mask) cell.layer.mask = nil;
        objc_setAssociatedObject(cell, kAccordionMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (run && run.maskedCell == cell) {
        run.maskedCell = nil;
        run.mask = nil;
    }
    if (run && run.raisedLayer == cell.layer) {
        cell.layer.zPosition = run.raisedLayerZPosition;
        run.raisedLayer = nil;
    }
    if ([cell.layer animationForKey:kAccordionAnimationKey]) [cell.layer removeAnimationForKey:kAccordionAnimationKey];
}

// The rows to draw ahead: inserted rows (new index paths) and reloaded rows
// above the change (whose index is the same before and after), first few only.
static NSMutableSet<NSIndexPath *> *PredrawRows(ApolloAccordionBatch *batch) {
    NSInteger firstChange = NSIntegerMax;
    for (NSIndexPath *path in [batch.deleted arrayByAddingObjectsFromArray:batch.inserted]) {
        firstChange = MIN(firstChange, path.row);
    }
    NSMutableArray<NSIndexPath *> *fresh = [NSMutableArray arrayWithArray:batch.inserted];
    for (NSIndexPath *path in batch.reloaded) {
        if (path.row < firstChange) [fresh addObject:path];
    }
    [fresh sortUsingSelector:@selector(compare:)];
    NSMutableSet<NSIndexPath *> *rows = [NSMutableSet set];
    size_t count = ApolloAccordionPredrawRowCount(fresh.count);
    for (size_t i = 0; i < count; i++) [rows addObject:fresh[i]];
    return rows;
}

void ApolloAccordionTableEndUpdates(UITableView *tableView,
                                    ApolloAccordionRowIdentity identity, NS_NOESCAPE dispatch_block_t commit) {
    ApolloAccordionBatch *batch = [NSThread isMainThread] ? BatchFor(tableView) : nil;
    if (!batch) {
        commit();
        return;
    }
    if (--batch.depth > 0) {
        commit();
        return;
    }
    sBatch = nil;
    if (!batch.sawAccordionOperation) {
        commit();
        return;
    }
    NSString *operations = [NSString stringWithFormat:@"reload=%@ delete=%@ insert=%@%@",
                            RowList(batch.reloaded), RowList(batch.deleted), RowList(batch.inserted),
                            batch.foreign ? @" +other" : @""];
    NSString *declined = batch.foreign ? @"other operations"
                       : UIAccessibilityIsReduceMotionEnabled() ? @"Reduce Motion"
                       : !tableView.window ? @"not on screen"
                       : ApolloRowMeasureInProgress() ? @"rows being measured"
                       : nil;
    NSIndexPath *commentRow = declined ? nil : CandidateCommentRow(batch);
    if (!declined && !commentRow) declined = @"not one comment collapsing or expanding";
    if (declined) {
        commit();
        os_log_debug(ApolloFixLog(), "[ApolloFix] [CommentsAccordion] batch %{public}@ -> Apollo's animations (%{public}@)",
                     operations, declined);
        return;
    }

    CFTimeInterval started = CACurrentMediaTime();
    // A running accordion lands at its end state first, so nothing below is
    // measured or drawn mid-flight.
    if (sRun) FinishRun(sRun);
    NSArray<ApolloAccordionRow *> *oldRows = RowsOnScreen(tableView, identity);
    CGFloat revealInset = RevealTopInset(tableView);
    ApolloAccordionRow *oldComment = nil;
    for (ApolloAccordionRow *row in oldRows) {
        if ([row.indexPath isEqual:commentRow]) oldComment = row;
    }
    declined = !oldComment ? @"comment not on screen"
             : ApolloAccordionRevealFor(CGRectGetMinY(oldComment.frame), tableView.contentOffset.y, revealInset,
                                        CGRectGetHeight(tableView.bounds)).kind == ApolloAccordionRevealTooFar
                 ? @"comment starts more than a screen above"
             : nil;
    if (declined) {
        commit();
        os_log_debug(ApolloFixLog(), "[ApolloFix] [CommentsAccordion] batch %{public}@ -> Apollo's animations (%{public}@)",
                     operations, declined);
        return;
    }
    ApolloAccordionPictures *pictures = CapturePictures(tableView, batch, oldRows);
    if (!pictures) {
        commit();
        os_log_debug(ApolloFixLog(), "[ApolloFix] [CommentsAccordion] batch %{public}@ -> Apollo's animations (live content on screen)",
                     operations);
        return;
    }
    CGFloat oldOffsetY = tableView.contentOffset.y;

    // Commit the batch in one step (UIKit's row animations would fight the
    // accordion), drawing its first fresh rows before anything is shown.
    sPredrawTable = tableView;
    sPredrawRows = PredrawRows(batch);
    @try {
        [UIView performWithoutAnimation:^{
            commit();
            // Apollo's scroll to the top of a comment that starts above the
            // screen, made now and animated with the rest.
            if (commentRow.section < tableView.numberOfSections &&
                commentRow.row < [tableView numberOfRowsInSection:commentRow.section]) {
                ApolloAccordionReveal reveal = ApolloAccordionRevealFor(
                    CGRectGetMinY([tableView rectForRowAtIndexPath:commentRow]), tableView.contentOffset.y,
                    revealInset, CGFLOAT_MAX);
                if (reveal.kind == ApolloAccordionRevealScroll) {
                    tableView.contentOffset = CGPointMake(tableView.contentOffset.x, reveal.offset);
                }
            }
            [tableView layoutIfNeeded];
        }];
    } @finally {
        sPredrawTable = nil;
        sPredrawRows = nil;
    }

    NSArray<ApolloAccordionRow *> *newRows = RowsOnScreen(tableView, identity);
    NSMutableDictionary<NSNumber *, NSNumber *> *newCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *oldCounts = [NSMutableDictionary dictionary];
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        NSInteger rows = [tableView numberOfRowsInSection:section];
        newCounts[@(section)] = @(rows);
        NSInteger change = 0;
        for (NSIndexPath *path in batch.deleted) if (path.section == section) change++;
        for (NSIndexPath *path in batch.inserted) if (path.section == section) change--;
        oldCounts[@(section)] = @(rows + change);
    }
    NSMutableDictionary<NSString *, NSNumber *> *ids = [NSMutableDictionary dictionary];
    NSMutableData *oldGeometry = GeometryForRows(oldRows, oldCounts, ids);
    NSMutableData *newGeometry = GeometryForRows(newRows, newCounts, ids);
    ApolloAccordionLayoutChange change = ApolloAccordionLayoutChangeForRows(
        (const ApolloAccordionRowGeometry *)oldGeometry.bytes, oldRows.count,
        (const ApolloAccordionRowGeometry *)newGeometry.bytes, newRows.count);
    // A collapse near the end of the list can shrink the content past the
    // scroll position, and UIKit then pulls the list down to its new end; a
    // comment that started above the screen was scrolled into view. Rows are
    // compared in place, and the list glides there.
    CGFloat offsetShift = tableView.contentOffset.y - oldOffsetY;

    ApolloAccordionRun *run = [ApolloAccordionRun new];
    run.tableView = tableView;
    sRun = run;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        FinishRun(run);
    }];
    if (change.kind != ApolloAccordionKindNone) {
        ApolloAccordionRow *oldParent = oldRows[change.oldParent];
        ApolloAccordionRow *newParent = newRows[change.newParent];
        ApolloAccordionPlan plan = ApolloAccordionPlanFor(change.kind,
                                                          CGRectGetMinY(oldParent.frame),
                                                          CGRectGetMaxY(oldParent.frame),
                                                          CGRectGetMaxY(newParent.frame),
                                                          change.hasAnchor, change.anchorOldY, change.anchorNewY,
                                                          CGRectGetMaxY(pictures.visibleRect));
        if (change.kind == ApolloAccordionKindCollapse) {
            AnimateCollapse(tableView, run, pictures, plan, oldParent.frame, newParent.frame, newParent.cell, newRows);
        } else {
            AnimateExpand(tableView, run, pictures, plan, oldParent.frame, newParent.frame, newParent.cell, newRows);
        }
        os_log_debug(ApolloFixLog(), "[ApolloFix] [CommentsAccordion] batch %{public}@ -> accordion %{public}s, comment row %ld -> %ld, scrolled %.0f, set up in %.1f ms",
                     operations, change.kind == ApolloAccordionKindCollapse ? "collapse" : "expand",
                     (long)oldParent.indexPath.row, (long)newParent.indexPath.row, offsetShift,
                     (CACurrentMediaTime() - started) * 1000.0);
    } else {
        AnimateRowsGlide(run, oldRows, newRows,
                         (const ApolloAccordionRowGeometry *)oldGeometry.bytes,
                         (const ApolloAccordionRowGeometry *)newGeometry.bytes);
        // The one line that is kept in exported logs: a batch shaped like a
        // collapse or expand that did not read as one on screen.
        ApolloLog(@"[CommentsAccordion] batch %@ -> glide (not one comment collapsing or expanding on screen)", operations);
    }
    if (fabs(offsetShift) > 0.5) {
        [tableView.layer addAnimation:AccordionSpring(@"bounds.origin.y", @(-offsetShift), @0, YES)
                               forKey:kAccordionAnimationKey];
        [run.animatedLayers addObject:tableView.layer];
    }
    [CATransaction commit];

    // A safety net if the completion never comes (the table leaves the screen
    // mid-flight): the run is landed shortly after it should have ended.
    __weak ApolloAccordionRun *weakRun = run;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((AccordionDuration() + 0.2) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloAccordionRun *pending = weakRun;
        if (pending && sRun == pending) FinishRun(pending);
    });
}
