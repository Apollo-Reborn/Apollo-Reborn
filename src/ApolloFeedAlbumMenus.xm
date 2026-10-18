// Media holds belong to the selected item, while holds outside the gallery retain
// Apollo's post preview/actions. Snapshot the exact displayed page before a
// menu opens so paging or cell reuse cannot change a later save/copy/share.
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloSaveAllMedia.h"
#import "ApolloSaveAllMediaItems.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloToast.h"
#import "ApolloClasses.h"
#import "ApolloMediaAutoplay.h"

// This is our own carousel class. Its native-open helper also serves its
// ordinary tap recognizer, including the correct index for pages beyond 3.
@interface ApolloFeedGalleryCarouselView : UIView
@property (nonatomic, readonly) NSInteger currentIndex;
@property (nonatomic, readonly) BOOL contentIsObscured;
@property (nonatomic, readonly) NSArray<UIImageView *> *imageViews;
- (void)apollo_openPageAtIndex:(NSInteger)index;
@end

@interface ApolloFeedAlbumMenuContext : NSObject
@property (nonatomic, strong) id link;
@property (nonatomic, copy) NSURL *albumURL;
@property (nonatomic, copy) NSArray<ApolloSaveAllMediaItem *> *items;
@property (nonatomic, strong) UIImage *previewImage;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) id cell;
@property (nonatomic, weak) id richMedia;
@property (nonatomic, weak) id thumbnail;
@property (nonatomic, weak) id videoNode;
@property (nonatomic, weak) ApolloFeedGalleryCarouselView *carousel;
@property (nonatomic) NSUInteger index;
@property (nonatomic) BOOL compact;
@property (nonatomic) BOOL collection;
@property (nonatomic) BOOL albumOverview;
@property (nonatomic) BOOL nativePreview;
@property (nonatomic) BOOL ended;
@property (nonatomic, copy) dispatch_block_t pendingAction;
@end
@implementation ApolloFeedAlbumMenuContext
@end

static char kApolloFeedAlbumMenuContext;
static char kApolloFeedAlbumShareFile;
static ApolloFeedAlbumMenuContext *sApolloFeedAlbumNativePreviewContext;

// Share files live exactly as long as the share controller, including when
// an activity reads the file after selection. Never remove another job's file.
@interface ApolloFeedAlbumShareFile : NSObject
@property (nonatomic, copy) NSURL *directory;
@end
@implementation ApolloFeedAlbumShareFile
- (void)dealloc {
    if (_directory) [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
}
@end

static UIView *ApolloFeedAlbumNodeView(id node) {
    SEL loaded = @selector(isNodeLoaded);
    if (![node respondsToSelector:loaded] || !((BOOL (*)(id, SEL))objc_msgSend)(node, loaded)) return nil;
    id view = ApolloSendObject(node, @selector(view));
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static BOOL ApolloFeedAlbumContainsPoint(UIView *view, UIView *source, CGPoint point) {
    if (!view.window || view.window != source.window || ![view isDescendantOfView:source]) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return NO;
        if (ancestor == source) break;
    }
    return CGRectContainsPoint(view.bounds, [view convertPoint:point fromView:source]);
}

static ApolloFeedGalleryCarouselView *ApolloFeedAlbumCarouselInView(UIView *view) {
    if ([view isKindOfClass:ApolloClassApolloFeedGalleryCarouselView]) return (id)view;
    for (UIView *child in view.subviews) {
        ApolloFeedGalleryCarouselView *carousel = ApolloFeedAlbumCarouselInView(child);
        if (carousel) return carousel;
    }
    return nil;
}

static id ApolloFeedAlbumLinkForCell(id cell) {
    // The comments screen puts media in its own cell. Unlike feed cells,
    // that wrapper has no link slot: its RichMediaNode owns the post model.
    if ([cell isKindOfClass:ApolloClassRichMediaHeaderCellNode]) {
        return ApolloObjectIvar(ApolloObjectIvar(cell, "richMediaNode"), "link");
    }
    return ApolloObjectIvar(cell, "link");
}

static ApolloSaveAllMediaItem *ApolloFeedAlbumSingleItem(id link, id richMedia) {
    // Media belongs to the crosspost's original post; retain the outer link in
    // the menu context separately for the cell-reuse check at preview commit.
    NSMutableArray *seen = [NSMutableArray array];
    for (NSUInteger depth = 0; link && depth < 8; depth++) {
        [seen addObject:link];
        id parent = ApolloSendObject(link, @selector(crosspostParent));
        if (!parent || [seen indexOfObjectIdenticalTo:parent] != NSNotFound) break;
        link = parent;
    }
    NSURL *URL = ApolloSendObject(link, @selector(URL));
    if (![URL isKindOfClass:NSURL.class]) return nil;
    // Prefer the original animation over the still poster or MP4 rendition
    // used for playback. The shared image writer preserves all GIF frames.
    NSURL *GIF = ApolloInlineGIFDisplayURLFromMetadata(URL, ApolloSendObject(link, @selector(mediaMetadata)));
    if ([GIF.pathExtension.lowercaseString isEqualToString:@"gif"]) URL = GIF;
    NSString *extension = URL.pathExtension.lowercaseString;
    if ([@[@"gif", @"jpg", @"jpeg", @"png", @"webp", @"heic", @"avif"] containsObject:extension]) {
        return ApolloSaveAllMediaItemsFromURLs(@[URL], nil).firstObject;
    }
    // External GIF/video pages are not downloadable images. Use the playing
    // asset when it is a file, or the API's video source for Reddit's streams.
    // Never save a preview thumbnail as though it were the video itself.
    id video = ApolloObjectIvar(richMedia, "videoNode");
    id player = ApolloSendObject(ApolloSendObject(video, @selector(playerLayer)), @selector(player))
        ?: ApolloSendObject(video, @selector(player));
    id asset = ApolloSendObject(ApolloSendObject(player, @selector(currentItem)), @selector(asset));
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSURL *playingURL = ApolloSendObject(asset, @selector(URL));
    if ([playingURL isKindOfClass:NSURL.class]) [candidates addObject:playingURL];
    const SEL sources[] = { @selector(mediaVideo), @selector(crossPostVideo), @selector(previewVideo) };
    for (SEL selector : sources) {
        id model = ApolloSendObject(link, selector);
        NSURL *fallback = ApolloSendObject(model, @selector(fallbackURL));
        if ([fallback isKindOfClass:NSURL.class]) [candidates addObject:fallback];
        NSURL *stream = ApolloSendObject(model, @selector(URL));
        if ([stream isKindOfClass:NSURL.class]) [candidates addObject:stream];
    }
    [candidates addObject:URL];
    for (NSURL *candidate in candidates) {
        // The strict saver resolves Reddit's DASH tracks and muxes audio.
        // Other manifests have no supported export path.
        if ([candidate.scheme.lowercaseString isEqualToString:@"https"] &&
            [candidate.host.lowercaseString isEqualToString:@"v.redd.it"] &&
            [candidate.pathExtension.lowercaseString isEqualToString:@"mpd"]) {
            return [[ApolloSaveAllMediaItem alloc] initWithURL:candidate isVideo:YES];
        }
        ApolloSaveAllMediaItem *item = ApolloSaveAllMediaItemsFromURLs(@[candidate], nil).firstObject;
        if (item.isVideo) return item;
    }
    return nil;
}

static ApolloFeedAlbumMenuContext *ApolloFeedAlbumContext(UIContextMenuInteraction *interaction, CGPoint location) {
    UIView *source = interaction.view;
    id cell = ApolloSendObject(source, @selector(asyncdisplaykit_node)) ?: ApolloSendObject(source, @selector(node));
    BOOL compact = [cell isKindOfClass:ApolloClassCompactPostCellNode];
    if (!compact && ![cell isKindOfClass:ApolloClassLargePostCellNode] &&
        ![cell isKindOfClass:ApolloClassRichMediaHeaderCellNode]) return nil;
    id link = ApolloFeedAlbumLinkForCell(cell);
    BOOL collection = ApolloSaveAllMediaLinkHasCollection(link);
    id rich = ApolloObjectIvar(cell, "richMediaNode");
    ApolloSaveAllMediaItem *single = collection ? nil : ApolloFeedAlbumSingleItem(link, rich);
    if (!collection && !single) return nil;
    UIViewController *presenter = ApolloSendObject(cell, @selector(closestViewController));
    if (![presenter isKindOfClass:UIViewController.class] || !presenter.viewIfLoaded.window) return nil;

    ApolloFeedAlbumMenuContext *context = [ApolloFeedAlbumMenuContext new];
    context.cell = cell;
    context.link = link;
    context.albumURL = ApolloSendObject(link, @selector(URL));
    context.presenter = presenter;
    context.compact = compact;
    context.collection = collection;
    context.albumOverview = compact && collection;
    context.items = collection ? ApolloSaveAllMediaItemsFromLink(link, nil) : @[single];
    if (compact) {
        id thumbnail = ApolloObjectIvar(cell, "thumbnailNode");
        context.sourceView = ApolloFeedAlbumNodeView(thumbnail);
        if (!ApolloFeedAlbumContainsPoint(context.sourceView, source, location)) return nil;
        // The cell's thumbnailNode is a wrapper; Apollo's tap handler sends
        // -image to its sender, so commit with the inner image node.
        id imageNode = ApolloObjectIvar(thumbnail, "thumbnailNode");
        context.thumbnail = imageNode;
        context.previewImage = ApolloSendObject(imageNode, @selector(image));
    } else {
        id album = ApolloObjectIvar(rich, "albumThumbnailsNode");
        UIView *richView = ApolloFeedAlbumNodeView(rich);
        ApolloFeedGalleryCarouselView *carousel = ApolloFeedAlbumCarouselInView(richView);
        context.richMedia = rich;
        UIView *cover = ApolloFeedAlbumNodeView(ApolloObjectIvar(rich, "obscuredContentInfoOverlayNode"));
        if (ApolloFeedAlbumContainsPoint(cover, source, location)) return nil;
        if (!collection) {
            id video = ApolloObjectIvar(rich, "videoNode");
            id thumbnail = ApolloObjectIvar(rich, "thumbnailNode");
            UIView *videoView = ApolloFeedAlbumNodeView(video);
            UIView *thumbnailView = ApolloFeedAlbumNodeView(thumbnail);
            if (ApolloFeedAlbumContainsPoint(videoView, source, location)) {
                context.sourceView = videoView;
                context.videoNode = video;
                context.previewImage = ApolloSendObject(video, @selector(placeholderImage));
            } else if (ApolloFeedAlbumContainsPoint(thumbnailView, source, location)) {
                context.sourceView = thumbnailView;
                context.thumbnail = thumbnail;
                context.previewImage = ApolloSendObject(thumbnail, @selector(image));
            } else return nil;
        } else if (carousel && ApolloFeedAlbumContainsPoint(carousel, source, location)) {
            if (carousel.contentIsObscured) return nil;
            // During a partially completed swipe, two pages can be visible.
            // Choose the image under the finger, not the last settled index.
            for (NSUInteger index = 0; index < carousel.imageViews.count; index++) {
                UIImageView *page = carousel.imageViews[index];
                if (!ApolloFeedAlbumContainsPoint(page, source, location)) continue;
                context.index = index;
                context.sourceView = page;
                context.previewImage = page.image;
                context.carousel = carousel;
                break;
            }
            if (!context.sourceView) return nil;
        } else {
            // The count badge and the space between mosaic thumbnails refer
            // to the whole album. Individual image holds retain image actions.
            UIView *cover = ApolloFeedAlbumNodeView(ApolloObjectIvar(album, "obscuredContentInfoOverlayNode"));
            if (ApolloFeedAlbumContainsPoint(cover, source, location)) return nil;
            UIView *albumView = ApolloFeedAlbumNodeView(album);
            if (!ApolloFeedAlbumContainsPoint(albumView, source, location)) return nil;
            UIView *countView = ApolloFeedAlbumNodeView(ApolloObjectIvar(album, "totalImagesNode"));
            context.albumOverview = ApolloFeedAlbumContainsPoint(countView, source, location);
            const char *slots[] = { "thumbnailNode1", "thumbnailNode2", "thumbnailNode3" };
            for (NSUInteger index = 0; !context.albumOverview && index < 3; index++) {
                id thumbnail = ApolloObjectIvar(album, slots[index]);
                UIView *view = ApolloFeedAlbumNodeView(thumbnail);
                if (!ApolloFeedAlbumContainsPoint(view, source, location)) continue;
                context.index = index;
                context.sourceView = view;
                context.thumbnail = thumbnail;
                context.previewImage = ApolloSendObject(thumbnail, @selector(image));
                break;
            }
            if (!context.sourceView) {
                context.albumOverview = YES;
                context.sourceView = albumView;
                // Committing the album preview opens its first item.
                context.thumbnail = ApolloObjectIvar(album, "thumbnailNode1");
            }
        }
        if (!context.albumOverview) {
            if (context.items.count && context.index >= context.items.count) return nil;
            // Keep an unrevealed/undownloaded placeholder on Apollo's native route.
            if (!context.previewImage && !context.videoNode) return nil;
        }
    }
    ApolloLog(@"[FeedAlbumMenu] media hold cell=%@ mode=%@ index=%lu", NSStringFromClass([cell class]), compact ? @"compact" : (!collection ? @"single" : (context.albumOverview ? @"album" : (context.carousel ? @"carousel" : @"mosaic"))), (unsigned long)context.index);
    return context;
}

static void ApolloFeedAlbumAfterMenu(ApolloFeedAlbumMenuContext *context, dispatch_block_t action) {
    if (context.ended) {
        // Keep the selection alive if UIKit has already released its menu by
        // the time this next-turn action runs.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (context.presenter.viewIfLoaded.window) action();
        });
    }
    else context.pendingAction = action;
}

static void ApolloFeedAlbumResolve(ApolloFeedAlbumMenuContext *context, void (^completion)(NSArray<ApolloSaveAllMediaItem *> *)) {
    if (!context.presenter.viewIfLoaded.window) return;
    if (context.items.count) { completion(context.items); return; }
    ApolloSaveAllMediaResolveLink(context.link, ^(NSArray *items, NSError *error) {
        if (error || !items.count) {
            ApolloShowToastWithStyle(@"Unable to Load Media", error.localizedDescription ?: @"Try opening the album again.", ApolloToastStyleError, nil);
        } else if (context.presenter.viewIfLoaded.window) completion(items);
    });
}

static void ApolloFeedAlbumImageData(ApolloFeedAlbumMenuContext *context, BOOL share) {
    ApolloFeedAlbumResolve(context, ^(NSArray<ApolloSaveAllMediaItem *> *items) {
        if (context.index >= items.count || items[context.index].isVideo) {
            ApolloShowToastWithStyle(@"Unable to Load Image", @"Open this item in full screen and try again.", ApolloToastStyleError, nil);
            return;
        }
        ApolloShowToastWithStyle(@"Loading Image…", nil, ApolloToastStyleInfo, nil);
        // Fetch original bytes without decoding a full-resolution bitmap. A
        // display cache can contain only a thumbnail or the first GIF frame.
        NSURLRequest *request = [NSURLRequest requestWithURL:items[context.index].URL
            cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60.0];
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
                NSString *identifier = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
                BOOL completeImage = source && CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
                if (source) CFRelease(source);
                if (downloadError || status < 200 || status >= 300 || !identifier || !completeImage) {
                    ApolloShowToastWithStyle(@"Unable to Load Image", @"The original image could not be downloaded.", ApolloToastStyleError, nil);
                    return;
                }
                if (!share) {
                    [UIPasteboard.generalPasteboard setData:data forPasteboardType:identifier];
                    ApolloShowToastWithStyle(@"Copied Image", nil, ApolloToastStyleSuccess, nil);
                    return;
                }
                UIViewController *owner = context.presenter;
                if (!owner.viewIfLoaded.window || owner.presentedViewController) return;
                ApolloFeedAlbumShareFile *file = [ApolloFeedAlbumShareFile new];
                file.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ApolloFeedImage-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
                NSString *extension = [UTType typeWithIdentifier:identifier].preferredFilenameExtension ?: @"image";
                NSURL *url = [file.directory URLByAppendingPathComponent:[@"Apollo-Image" stringByAppendingPathExtension:extension]];
                NSError *error = nil;
                if (![NSFileManager.defaultManager createDirectoryAtURL:file.directory withIntermediateDirectories:YES attributes:nil error:&error] || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
                    ApolloShowToastWithStyle(@"Couldn't Share Image", @"Check available storage and try again.", ApolloToastStyleError, nil);
                    return;
                }
                UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
                objc_setAssociatedObject(sheet, &kApolloFeedAlbumShareFile, file, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIView *anchor = context.sourceView.window ? context.sourceView : owner.view;
                sheet.popoverPresentationController.sourceView = anchor;
                sheet.popoverPresentationController.sourceRect = anchor.bounds;
                [owner presentViewController:sheet animated:YES completion:nil];
            });
        }] resume];
    });
}

static UIAction *ApolloFeedAlbumAction(NSString *title, NSString *symbol, ApolloFeedAlbumMenuContext *context, dispatch_block_t action) {
    // UIKit may release the configuration before invoking its selected action.
    // The action itself owns the selection; context never retains this UIAction
    // and its pending leaf block captures context weakly, so there is no cycle.
    return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil handler:^(__unused UIAction *sender) {
        ApolloFeedAlbumAfterMenu(context, action);
    }];
}

static UIMenu *ApolloFeedAlbumMenu(ApolloFeedAlbumMenuContext *context) {
    // Provider albums may not carry native RDKGallery metadata. Resolve once
    // before choosing image/GIF/video actions, rather than treating an unknown
    // item as a still image and offering Copy Image for a video.
    if (!context.albumOverview && !context.items.count) {
        UIDeferredMenuElement *loading = [UIDeferredMenuElement elementWithProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            ApolloSaveAllMediaResolveLink(context.link, ^(NSArray *items, NSError *error) {
                if (error || context.index >= items.count) {
                    UIAction *unavailable = [UIAction actionWithTitle:@"Unable to Load Media" image:nil identifier:nil handler:^(__unused UIAction *action) {}];
                    unavailable.attributes = UIMenuElementAttributesDisabled;
                    completion(@[unavailable]);
                    return;
                }
                context.items = items;
                completion(ApolloFeedAlbumMenu(context).children);
            });
        }];
        return [UIMenu menuWithTitle:@"" children:@[loading]];
    }
    // Each handler retains its immutable selection while executing. Deferred
    // actions are cleared before invocation by willEnd below.
    __weak ApolloFeedAlbumMenuContext *weakContext = context;
    UIAction *saveAll = ApolloFeedAlbumAction(@"Save All Media", @"square.and.arrow.down.on.square", context, ^{
        ApolloFeedAlbumMenuContext *live = weakContext;
        ApolloFeedAlbumResolve(live, ^(NSArray *items) { ApolloSaveAllMedia(items, live.presenter); });
    });
    if (context.albumOverview) {
        UIAction *copy = ApolloFeedAlbumAction(@"Copy Link", @"doc.on.doc", context, ^{
            UIPasteboard.generalPasteboard.URL = weakContext.albumURL;
        });
        UIAction *share = ApolloFeedAlbumAction(@"Share", @"square.and.arrow.up", context, ^{
            ApolloFeedAlbumMenuContext *live = weakContext;
            if (!live.albumURL || !live.presenter.viewIfLoaded.window) return;
            UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[live.albumURL] applicationActivities:nil];
            UIView *anchor = live.sourceView.window ? live.sourceView : live.presenter.view;
            sheet.popoverPresentationController.sourceView = anchor;
            sheet.popoverPresentationController.sourceRect = anchor.bounds;
            [live.presenter presentViewController:sheet animated:YES completion:nil];
        });
        return [UIMenu menuWithTitle:@"" children:@[copy, saveAll, share]];
    }
    ApolloSaveAllMediaItem *item = context.index < context.items.count ? context.items[context.index] : nil;
    BOOL video = item.isVideo;
    BOOL gif = [item.URL.pathExtension.lowercaseString isEqualToString:@"gif"];
    UIAction *copy = ApolloFeedAlbumAction(video ? @"Copy Link" : (gif ? @"Copy GIF" : @"Copy Image"), @"doc.on.doc", context, ^{
        if (video) UIPasteboard.generalPasteboard.URL = item.URL;
        else ApolloFeedAlbumImageData(weakContext, NO);
    });
    UIAction *save = ApolloFeedAlbumAction(video ? @"Save Video" : (gif ? @"Save GIF" : @"Save Image"), @"square.and.arrow.down", context, ^{
        ApolloFeedAlbumMenuContext *live = weakContext;
        ApolloFeedAlbumResolve(live, ^(NSArray *items) {
            if (live.index < items.count) ApolloSaveAllMedia(@[items[live.index]], live.presenter);
            else ApolloShowToastWithStyle(@"Unable to Load Image", @"Open the album again and try saving this image.", ApolloToastStyleError, nil);
        });
    });
    UIAction *share = ApolloFeedAlbumAction(@"Share", @"square.and.arrow.up", context, ^{
        if (!video) { ApolloFeedAlbumImageData(weakContext, YES); return; }
        ApolloFeedAlbumMenuContext *live = weakContext;
        if (!live.presenter.viewIfLoaded.window || live.presenter.presentedViewController) return;
        UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[item.URL] applicationActivities:nil];
        UIView *anchor = live.sourceView.window ? live.sourceView : live.presenter.view;
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
        [live.presenter presentViewController:sheet animated:YES completion:nil];
    });
    return [UIMenu menuWithTitle:@"" children:context.collection ? @[copy, save, saveAll, share] : @[copy, save, share]];
}

%hook _TtC6Apollo19PostCellActionTaker
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    ApolloFeedAlbumMenuContext *context = ApolloFeedAlbumContext(interaction, location);
    if (!context) return %orig;
    ApolloSaveAllMediaItem *item = context.index < context.items.count ? context.items[context.index] : nil;
    if (!context.albumOverview && (context.videoNode || item.isVideo ||
        [item.URL.pathExtension.lowercaseString isEqualToString:@"gif"])) {
        // A playing GIF/video's image node may contain only a white poster.
        // Keep Apollo's live preview and its playback lifecycle; replace the
        // menu actions at configuration creation, without reading private
        // UIKit preview-provider storage or flattening animation to UIImage.
        context.nativePreview = YES;
        ApolloFeedAlbumMenuContext *previous = sApolloFeedAlbumNativePreviewContext;
        sApolloFeedAlbumNativePreviewContext = context;
        @try {
            return %orig;
        } @finally {
            sApolloFeedAlbumNativePreviewContext = previous;
        }
    }
    UIContextMenuConfiguration *configuration = [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController *{
        if (!context.previewImage) return nil;
        UIViewController *preview = [UIViewController new];
        UIImageView *imageView = [[UIImageView alloc] initWithImage:context.previewImage];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.backgroundColor = UIColor.blackColor;
        preview.view = imageView;
        CGSize size = context.previewImage.size;
        CGFloat width = MIN(350.0, context.presenter.view.bounds.size.width);
        preview.preferredContentSize = CGSizeMake(width, MIN(500.0, width * size.height / MAX(1.0, size.width)));
        return preview;
    } actionProvider:^UIMenu *(__unused NSArray *suggested) { return ApolloFeedAlbumMenu(context); }];
    objc_setAssociatedObject(configuration, &kApolloFeedAlbumMenuContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context) return %orig;
    if (ApolloFeedAlbumLinkForCell(context.cell) != context.link) return nil;
    return context.sourceView.window ? [[UITargetedPreview alloc] initWithView:context.sourceView] : nil;
}
// Apollo has no dismissal-preview callback. UIKit otherwise chooses its own
// return target, which can be the complete media grid in the comments header.
%new
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context || ApolloFeedAlbumLinkForCell(context.cell) != context.link) return nil;
    return context.sourceView.window ? [[UITargetedPreview alloc] initWithView:context.sourceView] : nil;
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (context && !context.nativePreview) return;
    %orig;
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context) {
        %orig;
        return;
    }
    if (context.nativePreview) %orig;
    dispatch_block_t finish = ^{
        context.ended = YES;
        dispatch_block_t pending = context.pendingAction;
        context.pendingAction = nil;
        if (pending) pending();
    };
    if (animator) [animator addCompletion:finish];
    else dispatch_async(dispatch_get_main_queue(), finish);
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willPerformPreviewActionForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionCommitAnimating>)animator {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context) {
        %orig;
        return;
    }
    if (context.nativePreview) {
        if (ApolloFeedAlbumLinkForCell(context.cell) == context.link) %orig;
        return;
    }
    [animator addCompletion:^{
        // A recycled cell must not open another post when the preview commits.
        if (ApolloFeedAlbumLinkForCell(context.cell) != context.link) return;
        if (context.carousel) [context.carousel apollo_openPageAtIndex:(NSInteger)context.index];
        else {
            id target = context.compact ? context.cell : context.richMedia;
            SEL selector = context.compact ? @selector(thumbnailTappedWithSender:) :
                (context.collection ? @selector(albumThumbnailButtonTappedWithSender:) :
                 (context.videoNode ? @selector(didTapVideoNode:) : @selector(thumbnailTappedWithSender:)));
            id sender = context.videoNode ?: context.thumbnail;
            if (![target respondsToSelector:selector]) return;
            if (selector != @selector(didTapVideoNode:) && ![sender respondsToSelector:@selector(image)]) return;
            ((void (*)(id, SEL, id))objc_msgSend)(target, selector, sender);
        }
    }];
}
%end

%hook UIContextMenuConfiguration
+ (instancetype)configurationWithIdentifier:(id<NSCopying>)identifier previewProvider:(UIContextMenuContentPreviewProvider)previewProvider actionProvider:(UIContextMenuActionProvider)actionProvider {
    ApolloFeedAlbumMenuContext *context = sApolloFeedAlbumNativePreviewContext;
    if (!context) return %orig;
    UIContextMenuActionProvider mediaActions = ^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
        return ApolloFeedAlbumMenu(context);
    };
    UIContextMenuConfiguration *configuration = %orig(identifier, previewProvider, mediaActions);
    objc_setAssociatedObject(configuration, &kApolloFeedAlbumMenuContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}
%end
