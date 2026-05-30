// ApolloShareAsImageGallery.xm
//
// "Share as Image" gallery support.
//
// Apollo's SaveAsImagePreviewNode (_TtC6Apollo22SaveAsImagePreviewNode) renders
// a post into a shareable image. It has a single `imageNode` (fed by the
// `imageForImagePost` ivar) plus a fallback `linkButtonNode`. For a multi-image
// GALLERY post, Apollo passes imageForImagePost = nil, so the preview falls
// back to the compact link card ("Gallery <id>") instead of showing the images.
//
// This module detects gallery posts in the preview node, fetches the gallery
// item images, composes a feed-style collage UIImage, and injects it through
// Apollo's own single-image path (imageForImagePost + imageNode) while nil-ing
// the linkButtonNode so the compact card is dropped. We re-use Apollo's native
// layout/snapshot pipeline rather than building our own layout, so the exported
// image and the live preview both pick up the collage on the next layout pass.
//
// No hardcoded binary addresses: everything is done through ObjC runtime ivar
// access (ivar names from class-dump headers) and defensive selector checks.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

// ASSizeRange is { CGSize min; CGSize max; } — replicated so we can match the
// -layoutSpecThatFits: selector ABI without pulling in AsyncDisplayKit headers.
typedef struct ApolloASSizeRange {
    CGSize min;
    CGSize max;
} ApolloASSizeRange;

// Per-preview-node state. Stored as an associated NSNumber on the node.
typedef NS_ENUM(NSInteger, ApolloShareGalleryState) {
    ApolloShareGalleryStateNone = 0,   // not yet examined / not a gallery
    ApolloShareGalleryStatePlaceholder,// placeholder injected, fetch in flight
    ApolloShareGalleryStateApplied,    // real collage injected, leave ivars as-is
};

static const char kApolloShareGalleryStateKey = 0;     // NSNumber(ApolloShareGalleryState)
static const char kApolloShareGalleryCollageKey = 0;   // strong UIImage (collage)
static const char kApolloShareGalleryImageNodeKey = 0; // strong ASImageNode

// Visual constants for the collage. Point dimensions; rendered at screen scale.
static const CGFloat kApolloShareGalleryContentWidth = 320.0;
static const CGFloat kApolloShareGalleryGap = 3.0;
static const CGFloat kApolloShareGalleryCornerRadius = 12.0;
static const NSInteger kApolloShareGalleryMaxVisible = 4; // beyond this -> "+N"

#pragma mark - Runtime ivar helpers

static id ApolloShareIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    id value = nil;
    @try { value = object_getIvar(obj, ivar); } @catch (__unused NSException *e) {}
    return value;
}

// Writes an object into a Swift STRONG ivar with balanced ARC ownership.
//
// object_setIvar() stores the raw pointer but does NOT add the +1 retain that a
// Swift `strong` ivar slot is expected to own. When the host object is later
// deallocated, Swift's deinit releases every strong ivar — including ours —
// which over-releases the value we stored and produces a delayed EXC_BAD_ACCESS.
//
// To balance that future release we CFRetain the new value (so the slot truly
// owns +1), and CFRelease whatever was already in the slot (we're taking over
// its ownership). This mirrors what an ARC strong-property setter does.
static void ApolloShareSetIvarObject(id obj, const char *name, id value) {
    if (!obj || !name) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return;
    @try {
        id previous = object_getIvar(obj, ivar);
        if (value) CFRetain((__bridge CFTypeRef)value);   // slot now owns +1 on the new value
        object_setIvar(obj, ivar, value);
        if (previous) CFRelease((__bridge CFTypeRef)previous); // release the value we replaced
    } @catch (__unused NSException *e) {}
}

// Swift Bool ivars are a single byte at the ivar offset; object_setIvar can't
// be used for non-object ivars, so write the byte directly.
static void ApolloShareSetIvarBool(id obj, const char *name, BOOL value) {
    if (!obj || !name) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    @try {
        unsigned char *base = (unsigned char *)(__bridge void *)obj;
        base[offset] = value ? 1 : 0;
    } @catch (__unused NSException *e) {}
}

#pragma mark - Gallery model extraction

// Pulls the ordered list of still-image URLs out of an RDKLink's gallery.
// Uses internalGallery.items[].image.url. Video items still expose a static
// poster via .url, so we use that for every tile. Returns nil if not a
// multi-image gallery.
static NSArray<NSURL *> *ApolloShareGalleryImageURLs(id link) {
    if (!link) return nil;

    id gallery = nil;
    @try {
        if ([link respondsToSelector:@selector(internalGallery)]) {
            gallery = [link performSelector:@selector(internalGallery)];
        }
    } @catch (__unused NSException *e) {}
    if (!gallery) return nil;

    id items = nil;
    @try {
        if ([gallery respondsToSelector:@selector(items)]) {
            items = [gallery performSelector:@selector(items)];
        }
    } @catch (__unused NSException *e) {}
    if (![items isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id item in (NSArray *)items) {
        id image = nil;
        @try {
            if ([item respondsToSelector:@selector(image)]) {
                image = [item performSelector:@selector(image)];
            }
        } @catch (__unused NSException *e) {}
        id url = nil;
        @try {
            if (image && [image respondsToSelector:@selector(url)]) {
                url = [image performSelector:@selector(url)];
            }
        } @catch (__unused NSException *e) {}
        if ([url isKindOfClass:[NSURL class]]) {
            [urls addObject:(NSURL *)url];
        }
    }

    return urls.count >= 2 ? urls : nil;
}

#pragma mark - Image fetch

// Fetches every URL concurrently, preserving order. results[i] is a UIImage or
// NSNull on failure. Calls `done` on the main queue.
static void ApolloShareGalleryFetchImages(NSArray<NSURL *> *urls,
                                          void (^done)(NSArray *images)) {
    NSUInteger count = urls.count;
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [results addObject:[NSNull null]];
    }

    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];

    for (NSUInteger i = 0; i < count; i++) {
        NSURL *url = urls[i];
        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithURL:url
          completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            if (image) {
                @synchronized (lock) { results[i] = image; }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        done(results);
    });
}

#pragma mark - Collage rendering

// Draws `image` to fill `rect` (aspectFill, center-cropped). Caller sets the
// clip rect. If image is missing, fills with a neutral placeholder.
static void ApolloShareGalleryDrawAspectFill(UIImage *image, CGRect rect) {
    if (![image isKindOfClass:[UIImage class]] ||
        image.size.width <= 0.0 || image.size.height <= 0.0) {
        [[UIColor colorWithWhite:0.5 alpha:0.25] setFill];
        UIRectFill(rect);
        return;
    }

    CGFloat scale = MAX(rect.size.width / image.size.width,
                        rect.size.height / image.size.height);
    CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
    CGRect drawRect = CGRectMake(
        rect.origin.x + (rect.size.width - drawSize.width) / 2.0,
        rect.origin.y + (rect.size.height - drawSize.height) / 2.0,
        drawSize.width,
        drawSize.height);

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    [image drawInRect:drawRect];
    CGContextRestoreGState(ctx);
}

// Builds a feed-style collage from up to kApolloShareGalleryMaxVisible images.
// Layout: 2 columns of square cells. A lone trailing image (odd count) spans
// the full width. When totalCount exceeds the visible cap, a "+N" overlay is
// drawn on the last visible tile. Returns nil if nothing renderable.
static UIImage *ApolloShareGalleryRenderCollage(NSArray *images, NSInteger totalCount) {
    if (images.count == 0) return nil;

    NSInteger visible = MIN((NSInteger)images.count, kApolloShareGalleryMaxVisible);
    if (visible < 1) return nil;

    const CGFloat width = kApolloShareGalleryContentWidth;
    const CGFloat gap = kApolloShareGalleryGap;
    const NSInteger columns = 2;
    const CGFloat cellWidth = (width - gap * (columns - 1)) / columns;
    const CGFloat cellHeight = cellWidth; // square cells, feed-like

    NSInteger rows = (visible + columns - 1) / columns;
    CGFloat totalHeight = rows * cellHeight + (rows - 1) * gap;

    // Precompute each tile's frame.
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (NSInteger i = 0; i < visible; i++) {
        NSInteger row = i / columns;
        NSInteger col = i % columns;
        BOOL loneTrailing = (i == visible - 1) && (visible % columns == 1) && (col == 0);
        CGFloat x = col * (cellWidth + gap);
        CGFloat y = row * (cellHeight + gap);
        CGFloat w = loneTrailing ? width : cellWidth;
        CGRect frame = CGRectMake(x, y, w, cellHeight);
        [frames addObject:[NSValue valueWithCGRect:frame]];
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 2.0;

    CGSize canvas = CGSizeMake(width, totalHeight);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format];

    UIImage *collage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef ctx = rendererContext.CGContext;

        // Round the outer corners to match Apollo's media cards.
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, width, totalHeight)
                                                        cornerRadius:kApolloShareGalleryCornerRadius];
        CGContextSaveGState(ctx);
        [clip addClip];

        for (NSInteger i = 0; i < visible; i++) {
            CGRect frame = [frames[i] CGRectValue];
            id obj = images[i];
            UIImage *image = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
            ApolloShareGalleryDrawAspectFill(image, frame);

            // "+N" overlay on the final visible tile when there are more.
            NSInteger remaining = totalCount - kApolloShareGalleryMaxVisible;
            if (i == visible - 1 && remaining > 0) {
                [[UIColor colorWithWhite:0.0 alpha:0.45] setFill];
                UIRectFillUsingBlendMode(frame, kCGBlendModeNormal);

                NSString *text = [NSString stringWithFormat:@"+%ld", (long)remaining];
                UIFont *font = [UIFont systemFontOfSize:cellHeight * 0.28
                                                 weight:UIFontWeightSemibold];
                NSDictionary *attrs = @{
                    NSFontAttributeName: font,
                    NSForegroundColorAttributeName: [UIColor whiteColor],
                };
                CGSize textSize = [text sizeWithAttributes:attrs];
                CGPoint textPoint = CGPointMake(
                    frame.origin.x + (frame.size.width - textSize.width) / 2.0,
                    frame.origin.y + (frame.size.height - textSize.height) / 2.0);
                [text drawAtPoint:textPoint withAttributes:attrs];
            }
        }

        CGContextRestoreGState(ctx);
    }];

    return collage;
}

#pragma mark - Apply / relayout

// Installs `image` into the preview node via Apollo's own single-image path and
// requests a relayout. MUST run on the main thread (it creates an ASImageNode
// and mutates the node tree). `isFinal` only affects the stored state and log.
//
// We keep strong associated refs to both the image and the ASImageNode so that,
// even with the balanced ivar retain in ApolloShareSetIvarObject, nothing we
// created is reclaimed out from under Apollo's layout between passes.
static void ApolloShareGalleryInstallImage(id previewNode, UIImage *image, BOOL isFinal) {
    if (!previewNode || ![image isKindOfClass:[UIImage class]]) return;

    objc_setAssociatedObject(previewNode, &kApolloShareGalleryCollageKey, image,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Build an ASImageNode for the image and route it through both the
    // imageForImagePost ivar (Apollo's single-image trigger) and the imageNode
    // ivar (the node the layout spec lays out). Setting both maximises the
    // chance the native layout spec includes the image regardless of which it
    // keys off.
    Class imageNodeClass = objc_getClass("ASImageNode");
    id imageNode = nil;
    if (imageNodeClass) {
        @try {
            imageNode = [[imageNodeClass alloc] init];
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(imageNode, @selector(setImage:), image);
            if ([imageNode respondsToSelector:@selector(setContentMode:)]) {
                ((void (*)(id, SEL, UIViewContentMode))objc_msgSend)(
                    imageNode, @selector(setContentMode:), UIViewContentModeScaleAspectFit);
            }
        } @catch (__unused NSException *e) { imageNode = nil; }
    }
    if (imageNode) {
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryImageNodeKey, imageNode,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloShareSetIvarObject(previewNode, "imageNode", imageNode);
    }

    ApolloShareSetIvarObject(previewNode, "imageForImagePost", image);
    ApolloShareSetIvarBool(previewNode, "includePostTextPollOrImage", YES);
    // Drop the compact link card so only the collage shows. Cleared through the
    // balanced helper so the old node's ownership is released, not leaked.
    ApolloShareSetIvarObject(previewNode, "linkButtonNode", nil);

    objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                             @(isFinal ? ApolloShareGalleryStateApplied
                                       : ApolloShareGalleryStatePlaceholder),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Request a fresh layout pass; the ShareAsImageViewController re-snapshots
    // the preview, so the exported image picks up the image too.
    @try {
        if ([previewNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(previewNode, @selector(invalidateCalculatedLayout));
        }
        if ([previewNode respondsToSelector:@selector(setNeedsLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(previewNode, @selector(setNeedsLayout));
        }
        if ([previewNode respondsToSelector:@selector(_u_setNeedsLayoutFromAbove)]) {
            ((void (*)(id, SEL))objc_msgSend)(previewNode, @selector(_u_setNeedsLayoutFromAbove));
        }
    } @catch (__unused NSException *e) {}

    ApolloLog(@"[ShareGallery] %@ image installed node=%p size=%@",
              isFinal ? @"final" : @"placeholder", previewNode,
              NSStringFromCGSize(image.size));
}

// Hops to the main thread (or runs immediately if already there) before
// installing — node-tree mutation must not happen on Texture's background
// layout thread.
static void ApolloShareGalleryInstallImageOnMain(id previewNode, UIImage *image, BOOL isFinal) {
    if (!previewNode || !image) return;
    if ([NSThread isMainThread]) {
        ApolloShareGalleryInstallImage(previewNode, image, isFinal);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloShareGalleryInstallImage(previewNode, image, isFinal);
        });
    }
}

// Builds a neutral grey placeholder collage with the same geometry the real
// collage will use, so the first visible frame already shows the gallery grid
// (never Apollo's compact link card) while the real images download.
static UIImage *ApolloShareGalleryRenderPlaceholder(NSInteger totalCount) {
    NSInteger visible = MIN(totalCount, kApolloShareGalleryMaxVisible);
    if (visible < 1) return nil;
    NSMutableArray *blanks = [NSMutableArray arrayWithCapacity:visible];
    for (NSInteger i = 0; i < visible; i++) [blanks addObject:[NSNull null]];
    // RenderCollage draws a neutral fill for NSNull tiles and keeps geometry.
    return ApolloShareGalleryRenderCollage(blanks, totalCount);
}

// Examines a preview node once: if it's a gallery, immediately installs a
// placeholder grid (so the link card never flashes), then fetches the real
// images and swaps in the finished collage. Safe to call repeatedly
// (state-guarded) and from Texture's background layout thread.
static void ApolloShareGalleryPrepare(id previewNode) {
    if (!previewNode) return;

    NSNumber *stateNum = objc_getAssociatedObject(previewNode, &kApolloShareGalleryStateKey);
    ApolloShareGalleryState state = stateNum ? (ApolloShareGalleryState)stateNum.integerValue
                                             : ApolloShareGalleryStateNone;
    if (state != ApolloShareGalleryStateNone) return; // already placeholder/applied

    id link = ApolloShareIvarObject(previewNode, "link");
    NSArray<NSURL *> *urls = ApolloShareGalleryImageURLs(link);
    if (urls.count < 2) {
        // Not a multi-image gallery; mark applied to avoid re-checking every
        // layout pass (cheap idempotency without a separate flag).
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStateApplied),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSInteger totalCount = (NSInteger)urls.count;
    ApolloLog(@"[ShareGallery] gallery detected node=%p items=%ld — placeholder + fetch",
              previewNode, (long)totalCount);

    // Install the placeholder grid right away so the compact link card is never
    // shown. This also flips the state to Placeholder, blocking re-entry.
    UIImage *placeholder = ApolloShareGalleryRenderPlaceholder(totalCount);
    if (placeholder) {
        ApolloShareGalleryInstallImageOnMain(previewNode, placeholder, NO);
    } else {
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStatePlaceholder),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    __weak id weakNode = previewNode;
    ApolloShareGalleryFetchImages(urls, ^(NSArray *images) {
        id strongNode = weakNode;
        if (!strongNode) return;

        NSInteger ok = 0;
        for (id img in images) { if ([img isKindOfClass:[UIImage class]]) ok++; }

        UIImage *collage = ApolloShareGalleryRenderCollage(images, totalCount);
        ApolloLog(@"[ShareGallery] fetch complete node=%p ok=%ld/%ld collage=%@",
                  strongNode, (long)ok, (long)totalCount, collage ? @"built" : @"nil");
        if (collage) {
            ApolloShareGalleryInstallImageOnMain(strongNode, collage, YES);
        } else {
            // Couldn't build anything; keep the placeholder and mark applied.
            objc_setAssociatedObject(strongNode, &kApolloShareGalleryStateKey,
                                     @(ApolloShareGalleryStateApplied),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

#pragma mark - Hooks

%hook _TtC6Apollo22SaveAsImagePreviewNode

- (id)layoutSpecThatFits:(ApolloASSizeRange)constrainedSize {
    ApolloShareGalleryPrepare(self);
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("_TtC6Apollo22SaveAsImagePreviewNode")) {
            %init();
            ApolloLog(@"[ShareGallery] module loaded");
        } else {
            ApolloLog(@"[ShareGallery] SaveAsImagePreviewNode not found — skipping");
        }
    }
}
