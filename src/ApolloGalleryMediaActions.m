#import "ApolloGalleryMediaActions.h"

#import "ApolloCommon.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloSaveAllMedia.h"
#import "ApolloState.h"
#import "ApolloToast.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Hosted-video resolution mutates the feed's item. A menu keeps the media and
// post that were offered when it opened, even if the feed or viewer advances.
@interface ApolloGalleryActionItemSnapshot : ApolloGalleryItem
@property (nonatomic, copy) NSURL *originalHostedVideoPageURL;
@property (nonatomic) BOOL originalPlaysAsVideo;
@end

@implementation ApolloGalleryActionItemSnapshot
- (NSURL *)hostedVideoPageURL { return self.originalHostedVideoPageURL; }
- (BOOL)playsAsVideo { return self.originalPlaysAsVideo; }
@end

static ApolloGalleryItem *ApolloGallerySnapshotItem(ApolloGalleryItem *item) {
    ApolloGalleryActionItemSnapshot *snapshot = [ApolloGalleryActionItemSnapshot new];
    snapshot.kind = item.kind;
    snapshot.imageURL = item.imageURL;
    snapshot.videoURL = item.videoURL;
    snapshot.videoDownloadURL = item.videoDownloadURL;
    snapshot.gifMP4URL = item.gifMP4URL;
    snapshot.thumbnailURL = item.thumbnailURL;
    snapshot.duration = item.duration;
    snapshot.pixelSize = item.pixelSize;
    snapshot.postTitle = item.postTitle;
    snapshot.author = item.author;
    snapshot.subreddit = item.subreddit;
    snapshot.permalink = item.permalink;
    snapshot.postFullname = item.postFullname;
    snapshot.isNSFW = item.isNSFW;
    snapshot.isSpoiler = item.isSpoiler;
    snapshot.galleryIndex = item.galleryIndex;
    snapshot.galleryCount = item.galleryCount;
    snapshot.originalHostedVideoPageURL = item.hostedVideoPageURL;
    snapshot.originalPlaysAsVideo = item.playsAsVideo;
    return snapshot;
}

static void ApolloGalleryRemoveShareDirectory(NSURL *directory) {
    if (!directory) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
    });
}

// Infer the extension from the original bytes, without decoding pixels. URLs
// frequently have no extension or describe a JPEG that was served as WebP.
static NSString *ApolloGalleryShareExtension(NSData *data, NSURL *imageURL) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    NSString *type = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
    NSString *extension = type ? [UTType typeWithIdentifier:type].preferredFilenameExtension : nil;
    if (source) CFRelease(source);
    if (!extension.length) extension = imageURL.pathExtension.lowercaseString;
    NSCharacterSet *invalid = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    if (!extension.length || extension.length > 10 || [extension rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        extension = @"img";
    }
    return extension;
}

@interface ApolloGalleryMediaActions ()
@property (nonatomic, strong, readwrite) ApolloGalleryItem *item;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, copy) NSURL *imageURL;
@property (nonatomic, copy) NSURL *videoDownloadURL;
@property (nonatomic, copy) NSURL *videoShareURL;
@property (nonatomic, copy) NSURL *postURL;
@property (nonatomic) BOOL video;
@property (nonatomic) BOOL menuEnded;
@property (nonatomic) BOOL selectionTaken;
@property (nonatomic, copy) dispatch_block_t pendingAction;
@property (nonatomic, strong) NSURLSessionDataTask *imageTask;
@end

@implementation ApolloGalleryMediaActions

- (instancetype)initWithItem:(ApolloGalleryItem *)item presenter:(UIViewController *)presenter sourceView:(UIView *)sourceView {
    self = [super init];
    if (self) {
        _item = ApolloGallerySnapshotItem(item);
        _presenter = presenter;
        _sourceView = sourceView;
        _imageURL = [item.imageURL copy];
        _videoDownloadURL = [item.videoDownloadURL copy];
        _videoShareURL = [(item.videoURL ?: item.hostedVideoPageURL) copy];
        _postURL = [item.postURL copy];
        _video = item.playsAsVideo;
    }
    return self;
}

- (void)dealloc {
    [self.imageTask cancel];
}

- (UIViewController *)availablePresenter {
    UIViewController *presenter = self.presenter;
    if (!presenter.viewIfLoaded.window || presenter.presentedViewController ||
        presenter.isBeingDismissed || presenter.isMovingFromParentViewController) return nil;
    UINavigationController *navigation = presenter.navigationController;
    if (navigation && (navigation.topViewController != presenter || navigation.isBeingDismissed)) return nil;
    for (UIViewController *parent = presenter.parentViewController; parent; parent = parent.parentViewController) {
        if (parent.isBeingDismissed) return nil;
    }
    return presenter;
}

- (void)runPendingAction {
    if (!self.menuEnded || !self.pendingAction) return;
    dispatch_block_t action = self.pendingAction;
    self.pendingAction = nil;
    // UIKit can invoke an action on either side of its dismissal completion.
    // Always cross one main-queue turn so the presenter is available again.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self availablePresenter]) action();
    });
}

- (void)performAfterMenu:(dispatch_block_t)action {
    if (!action || self.selectionTaken) return;
    self.selectionTaken = YES;
    self.pendingAction = action;
    [self runPendingAction];
}

- (void)menuDidEnd {
    self.menuEnded = YES;
    [self runPendingAction];
}

- (UIAction *)actionWithTitle:(NSString *)title symbol:(NSString *)symbol handler:(dispatch_block_t)handler {
    return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil
                           handler:^(__unused UIAction *action) {
        [self performAfterMenu:handler];
    }];
}

- (UIMenu *)menu {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    if (self.video) {
        if (self.videoDownloadURL) {
            [children addObject:[self actionWithTitle:@"Save Video" symbol:@"arrow.down.to.line" handler:^{
                [self saveOriginalMedia];
            }]];
        }
        if (self.videoShareURL) {
            [children addObject:[self actionWithTitle:@"Share Video Link" symbol:@"square.and.arrow.up" handler:^{
                [self presentActivityWithItems:@[self.videoShareURL] temporaryDirectory:nil];
            }]];
        }
    } else {
        [children addObject:[self actionWithTitle:@"Save Image" symbol:@"arrow.down.to.line" handler:^{
            [self saveOriginalMedia];
        }]];
        [children addObject:[self actionWithTitle:@"Share Image" symbol:@"square.and.arrow.up" handler:^{
            [self shareOriginalImage];
        }]];
    }
    if (self.postURL) {
        [children addObject:[self actionWithTitle:@"Share Post Link" symbol:@"link" handler:^{
            [self presentActivityWithItems:@[self.postURL] temporaryDirectory:nil];
        }]];
        [children addObject:[self actionWithTitle:@"Open Post" symbol:@"arrow.up.right.square" handler:^{
            if (self.openPostHandler) {
                self.openPostHandler();
            } else if (!ApolloRouteResolvedURLViaApolloScheme(self.postURL) && !ApolloRouteURLThroughApp(self.postURL)) {
                ApolloShowToastWithStyle(@"Couldn't Open Post", @"Please try again.", ApolloToastStyleError, nil);
            }
        }]];
    }
    return [UIMenu menuWithTitle:@"" children:children];
}

- (void)saveOriginalMedia {
    UIViewController *presenter = [self availablePresenter];
    NSURL *URL = self.video ? self.videoDownloadURL : self.imageURL;
    if (!presenter) return;
    if (!URL) {
        ApolloShowToastWithStyle(@"Couldn't Save Media", @"Open the post and try again.", ApolloToastStyleError, nil);
        return;
    }
    ApolloSaveAllMediaItem *item = [[ApolloSaveAllMediaItem alloc] initWithURL:URL isVideo:self.video];
    ApolloSaveAllMedia(@[item], presenter);
}

- (void)shareOriginalImage {
    if (![self availablePresenter]) return;
    if (!self.imageURL) {
        ApolloShowToastWithStyle(@"Couldn't Share Image", @"Open the post and try again.", ApolloToastStyleError, nil);
        return;
    }
    ApolloGalleryImageLoader *loader = [ApolloGalleryImageLoader sharedLoader];
    NSData *data = [loader cachedDataForURL:self.imageURL];
    if (data.length) {
        [self shareOriginalImageData:data];
        return;
    }
    ApolloShowToastWithStyle(@"Loading image…", nil, ApolloToastStyleInfo, nil);
    // The decoded-image and original-byte caches evict independently. A full
    // image-loader request can return a decoded hit with no bytes, so fetch the
    // original directly here; sharing does not need another pixel decode.
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.imageURL];
    request.timeoutInterval = 30.0;
    [request setValue:(sUserAgent.length ? sUserAgent : @"ApolloGallery/1.0") forHTTPHeaderField:@"User-Agent"];
    // The task retains this completion through the request, preserving the
    // action session after UIKit releases the menu while its VC remains weak.
    self.imageTask = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *originalData, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        BOOL success = !error && status >= 200 && status < 300 && originalData.length > 0;
        // Reject a provider's HTML/error body without decoding any pixels.
        CGImageSourceRef source = success ? CGImageSourceCreateWithData((__bridge CFDataRef)originalData, NULL) : NULL;
        success = source && CGImageSourceGetCount(source) > 0;
        if (source) CFRelease(source);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.imageTask = nil;
            if (![self availablePresenter]) return;
            if (!success) {
                ApolloShowToastWithStyle(@"Couldn't Load Image", @"Please try sharing again.", ApolloToastStyleError, nil);
                return;
            }
            [self shareOriginalImageData:originalData];
        });
    }];
    [self.imageTask resume];
}

- (void)shareOriginalImageData:(NSData *)data {
    NSURL *imageURL = self.imageURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[@"ApolloGalleryShare-" stringByAppendingString:NSUUID.UUID.UUIDString]
                            isDirectory:YES];
        NSString *filename = [@"image" stringByAppendingPathExtension:ApolloGalleryShareExtension(data, imageURL)];
        NSURL *fileURL = [directory URLByAppendingPathComponent:filename isDirectory:NO];
        BOOL written = [[NSFileManager defaultManager] createDirectoryAtURL:directory
            withIntermediateDirectories:NO attributes:nil error:nil] &&
            [data writeToURL:fileURL options:NSDataWritingAtomic error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!written) {
                ApolloGalleryRemoveShareDirectory(directory);
                if ([self availablePresenter]) {
                    ApolloShowToastWithStyle(@"Couldn't Share Image", @"Check available storage and try again.", ApolloToastStyleError, nil);
                }
                return;
            }
            [self presentActivityWithItems:@[fileURL] temporaryDirectory:directory];
        });
    });
}

- (void)presentActivityWithItems:(NSArray *)items temporaryDirectory:(NSURL *)directory {
    UIViewController *presenter = [self availablePresenter];
    if (!presenter) {
        ApolloGalleryRemoveShareDirectory(directory);
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activity.completionWithItemsHandler = ^(__unused UIActivityType type, __unused BOOL completed,
                                           __unused NSArray *returnedItems, __unused NSError *error) {
        ApolloGalleryRemoveShareDirectory(directory);
    };
    UIView *source = self.sourceView;
    if (!source.window || source.window != presenter.view.window) source = presenter.view;
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    popover.sourceView = source;
    popover.sourceRect = source == presenter.view
        ? CGRectMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds), 1, 1) : source.bounds;
    [presenter presentViewController:activity animated:YES completion:nil];
}

@end
