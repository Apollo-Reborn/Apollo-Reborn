#import "ApolloImageActions.h"
#import "ApolloToast.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static char kApolloImageShareFile;

// Keep each share file alive while an extension may still be reading it.
@interface ApolloImageShareFile : NSObject
@property (nonatomic, copy) NSURL *directory;
@end

@implementation ApolloImageShareFile
- (void)dealloc {
    if (_directory) [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
}
@end

void ApolloCopyOrShareImage(NSURL *URL, UIViewController *presenter, UIView *sourceView, BOOL share) {
    if (!URL) return;
    ApolloShowToastWithStyle(@"Loading Image…", nil, ApolloToastStyleInfo, nil);
    __weak UIViewController *weakPresenter = presenter;
    __weak UIView *weakSourceView = sourceView;
    // Download original bytes: the display cache may contain only one GIF frame.
    NSURLRequest *request = [NSURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60.0];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *downloadError) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
        NSString *identifier = source ? [(__bridge NSString *)CGImageSourceGetType(source) copy] : nil;
        BOOL completeImage = source && CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
        if (source) CFRelease(source);
        if (downloadError || status < 200 || status >= 300 || !identifier || !completeImage) {
            ApolloShowToastWithStyle(@"Unable to Load Image", @"The original image could not be downloaded.", ApolloToastStyleError, nil);
            return;
        }
        if (!share) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIPasteboard.generalPasteboard setData:data forPasteboardType:identifier];
                ApolloShowToastWithStyle(@"Copied Image", nil, ApolloToastStyleSuccess, nil);
            });
            return;
        }

        ApolloImageShareFile *file = [ApolloImageShareFile new];
        file.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ApolloImage-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        NSString *extension = [UTType typeWithIdentifier:identifier].preferredFilenameExtension ?: @"image";
        NSURL *fileURL = [file.directory URLByAppendingPathComponent:[@"Apollo-Image" stringByAppendingPathExtension:extension]];
        if (![NSFileManager.defaultManager createDirectoryAtURL:file.directory withIntermediateDirectories:YES attributes:nil error:nil] || ![data writeToURL:fileURL options:NSDataWritingAtomic error:nil]) {
            ApolloShowToastWithStyle(@"Couldn't Share Image", @"Check available storage and try again.", ApolloToastStyleError, nil);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *owner = weakPresenter;
            if (!owner.viewIfLoaded.window || owner.presentedViewController) return;
            UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
            objc_setAssociatedObject(sheet, &kApolloImageShareFile, file, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *sourceView = weakSourceView;
            UIView *anchor = sourceView.window ? sourceView : owner.view;
            sheet.popoverPresentationController.sourceView = anchor;
            sheet.popoverPresentationController.sourceRect = anchor.bounds;
            [owner presentViewController:sheet animated:YES completion:nil];
        });
    }] resume];
}
