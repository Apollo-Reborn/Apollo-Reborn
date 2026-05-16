#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "fishhook.h"

@class PHAssetCollection;
@class PHPhotoLibrary;

@interface PHFetchOptions : NSObject <NSCopying>
@property (nonatomic, copy) NSPredicate *predicate;
@end

@interface PHAsset : NSObject
+ (id)fetchAssetsWithMediaType:(NSInteger)mediaType options:(PHFetchOptions *)options;
+ (id)fetchAssetsWithOptions:(PHFetchOptions *)options;
+ (id)fetchAssetsInAssetCollection:(PHAssetCollection *)assetCollection options:(PHFetchOptions *)options;
@end

@interface PHPickerFilter : NSObject
+ (PHPickerFilter *)anyFilterMatchingSubfilters:(NSArray<PHPickerFilter *> *)subfilters;
+ (PHPickerFilter *)imagesFilter;
+ (PHPickerFilter *)videosFilter;
@end

@interface PHPickerConfiguration : NSObject
@property (nonatomic, strong) PHPickerFilter *filter;
- (instancetype)init;
- (instancetype)initWithPhotoLibrary:(PHPhotoLibrary *)photoLibrary;
@end

@interface PHPickerViewController : UIViewController
- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration;
- (void)setDelegate:(id)delegate;
@end

@interface PHPickerResult : NSObject
@property (nonatomic, readonly) NSItemProvider *itemProvider;
@property (nonatomic, readonly) NSString *assetIdentifier;
@end

@interface PHPhotoLibrary : NSObject
+ (NSInteger)authorizationStatusForAccessLevel:(NSInteger)accessLevel;
@end

static char kApolloPhotoComposerLoggedControllerKey;
static char kApolloPhotoComposerScrollFixAppliedKey;
static char kApolloPhotoComposerWordingLoggedControllerKey;
static char kApolloPhotoComposerLoggedPresentedPickerKey;
static BOOL sApolloMediaComposerContextActive = NO;
static BOOL sApolloMediaComposerPickerActive = NO;
static BOOL sApolloMediaComposerLoggedPhotoFetchRewrite = NO;
static BOOL sApolloMediaComposerLoggedPredicateRewrite = NO;
static BOOL sApolloMediaComposerLoggedPickerFilterRewrite = NO;
static BOOL sApolloMediaComposerLoggedPickerInitOverride = NO;
static BOOL sApolloMediaComposerLoggedPickerConfigInitOverride = NO;
static BOOL sApolloMediaComposerLoggedPhotoAuthState = NO;
static BOOL sApolloMediaComposerLoggedEarlyContext = NO;
static BOOL sApolloMediaComposerLoggedButtonTitleRewrite = NO;
static BOOL sApolloMediaComposerLoggedProviderProbe = NO;
static NSMutableSet<NSString *> *sApolloMediaComposerWrappedPickerDelegateClasses = nil;
static NSMutableSet<NSString *> *sApolloMediaComposerLoggedTextCandidates = nil;
static NSMutableArray<NSMutableDictionary *> *sApolloMediaComposerPendingVideoContexts = nil;

static char kApolloMediaComposerProviderContextKey;
static char kApolloMediaComposerPosterImageContextKey;
static char kApolloMediaComposerPosterPayloadContextKey;

static NSData *(*orig_UIImageJPEGRepresentation)(UIImage *image, CGFloat compressionQuality) = NULL;
static NSData *(*orig_UIImagePNGRepresentation)(UIImage *image) = NULL;

static BOOL ApolloMediaComposerRedditUploadSelected(void);
static BOOL ApolloMediaComposerShouldWidenPicker(void);

static NSObject *ApolloMediaComposerVideoBridgeLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL ApolloMediaComposerTypeIdentifierIsVideo(NSString *typeIdentifier) {
    if (![typeIdentifier isKindOfClass:[NSString class]]) return NO;
    NSString *lower = typeIdentifier.lowercaseString;
    return [lower isEqualToString:@"public.movie"] ||
        [lower isEqualToString:@"public.video"] ||
        [lower isEqualToString:@"public.mpeg-4"] ||
        [lower isEqualToString:@"com.apple.quicktime-movie"] ||
        [lower containsString:@"movie"] ||
        [lower containsString:@"video"] ||
        [lower containsString:@"mpeg-4"];
}

static BOOL ApolloMediaComposerTypeIdentifierIsImageRequest(NSString *typeIdentifier) {
    if (![typeIdentifier isKindOfClass:[NSString class]]) return NO;
    NSString *lower = typeIdentifier.lowercaseString;
    return [lower isEqualToString:@"public.image"] ||
        [lower isEqualToString:@"public.jpeg"] ||
        [lower isEqualToString:@"public.png"] ||
        [lower containsString:@"image"] ||
        [lower containsString:@"jpeg"] ||
        [lower containsString:@"png"];
}

static NSString *ApolloMediaComposerVideoMIMETypeForTypeIdentifier(NSString *typeIdentifier, NSURL *fileURL) {
    NSString *lower = typeIdentifier.lowercaseString;
    NSString *extension = fileURL.pathExtension.lowercaseString;
    if ([lower containsString:@"quicktime"] || [extension isEqualToString:@"mov"]) return @"video/quicktime";
    return @"video/mp4";
}

static NSString *ApolloMediaComposerVideoExtensionForTypeIdentifier(NSString *typeIdentifier, NSURL *fileURL) {
    NSString *mimeType = ApolloMediaComposerVideoMIMETypeForTypeIdentifier(typeIdentifier, fileURL);
    return [mimeType isEqualToString:@"video/quicktime"] ? @"mov" : @"mp4";
}

static NSString *ApolloMediaComposerFirstVideoTypeIdentifier(NSItemProvider *provider) {
    NSArray<NSString *> *types = provider.registeredTypeIdentifiers;
    for (NSString *type in types) {
        if (ApolloMediaComposerTypeIdentifierIsVideo(type)) return type;
    }
    return nil;
}

static NSURL *ApolloMediaComposerCopyVideoFileToStableTempURL(NSURL *sourceURL, NSString *typeIdentifier) {
    if (![sourceURL isKindOfClass:[NSURL class]]) return nil;
    NSString *extension = ApolloMediaComposerVideoExtensionForTypeIdentifier(typeIdentifier, sourceURL);
    NSString *filename = [[@"apollo-selected-video-" stringByAppendingString:NSUUID.UUID.UUIDString] stringByAppendingPathExtension:extension ?: @"mp4"];
    NSURL *targetURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
    if (![[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:targetURL error:&copyError]) {
        ApolloLog(@"[MediaComposer] failed to copy selected video file: %@", copyError.localizedDescription ?: @"unknown error");
        return nil;
    }
    return targetURL;
}

static UIImage *ApolloMediaComposerPosterImageForVideoURL(NSURL *videoURL) {
    if (![videoURL isKindOfClass:[NSURL class]]) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(1600.0, 1600.0);
    NSError *error = nil;
    CGImageRef cgImage = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:NULL error:&error];
    if (!cgImage) {
        cgImage = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
    }
    if (!cgImage) {
        ApolloLog(@"[MediaComposer] failed to generate selected-video poster: %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static void ApolloMediaComposerRegisterPendingVideoContext(NSMutableDictionary *context) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return;
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (!sApolloMediaComposerPendingVideoContexts) sApolloMediaComposerPendingVideoContexts = [NSMutableArray new];
        [sApolloMediaComposerPendingVideoContexts addObject:context];
    }
}

static NSMutableDictionary *ApolloMediaComposerContextForProvider(NSItemProvider *provider) {
    NSMutableDictionary *context = objc_getAssociatedObject(provider, &kApolloMediaComposerProviderContextKey);
    return [context isKindOfClass:[NSMutableDictionary class]] ? context : nil;
}

static BOOL ApolloMediaComposerProviderIsMarkedVideo(NSItemProvider *provider) {
    return ApolloMediaComposerContextForProvider(provider) != nil;
}

static void ApolloMediaComposerAttachPosterPayload(NSData *payload, NSMutableDictionary *context) {
    if (payload.length == 0 || ![context isKindOfClass:[NSMutableDictionary class]]) return;
    context[@"posterLength"] = @(payload.length);
    context[@"posterData"] = payload;
    objc_setAssociatedObject(payload, &kApolloMediaComposerPosterPayloadContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloMediaComposerAttachContextToPosterImage(UIImage *image, NSMutableDictionary *context) {
    if (!image || ![context isKindOfClass:[NSMutableDictionary class]]) return;
    objc_setAssociatedObject(image, &kApolloMediaComposerPosterImageContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloMediaComposerRegisterPosterPayloadForImage(UIImage *image, NSData *payload) {
    NSMutableDictionary *context = objc_getAssociatedObject(image, &kApolloMediaComposerPosterImageContextKey);
    if (![context isKindOfClass:[NSMutableDictionary class]] || payload.length == 0) return;
    ApolloMediaComposerAttachPosterPayload(payload, context);
}

static NSData *hooked_UIImageJPEGRepresentation(UIImage *image, CGFloat compressionQuality) {
    NSData *data = orig_UIImageJPEGRepresentation ? orig_UIImageJPEGRepresentation(image, compressionQuality) : nil;
    ApolloMediaComposerRegisterPosterPayloadForImage(image, data);
    return data;
}

static NSData *hooked_UIImagePNGRepresentation(UIImage *image) {
    NSData *data = orig_UIImagePNGRepresentation ? orig_UIImagePNGRepresentation(image) : nil;
    ApolloMediaComposerRegisterPosterPayloadForImage(image, data);
    return data;
}

static NSMutableDictionary *ApolloMediaComposerConsumeContextLocked(NSMutableDictionary *context) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return nil;
    if ([context[@"consumed"] boolValue]) return nil;
    if (![context[@"fileURL"] isKindOfClass:[NSURL class]]) return nil;
    context[@"consumed"] = @YES;
    [sApolloMediaComposerPendingVideoContexts removeObjectIdenticalTo:context];
    return [context mutableCopy];
}

extern "C" NSDictionary *ApolloMediaComposerConsumePendingVideoUploadContext(NSData *posterData, NSURL *posterFileURL) {
    if (!ApolloMediaComposerRedditUploadSelected()) return nil;

    NSMutableDictionary *associatedContext = objc_getAssociatedObject(posterData, &kApolloMediaComposerPosterPayloadContextKey);
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        NSMutableDictionary *consumed = ApolloMediaComposerConsumeContextLocked(associatedContext);
        if (consumed) return consumed;

        NSData *fileData = nil;
        if (posterData.length > 0) fileData = posterData;
        else if ([posterFileURL isKindOfClass:[NSURL class]]) fileData = [NSData dataWithContentsOfURL:posterFileURL];

        NSMutableDictionary *fallback = nil;
        for (NSMutableDictionary *context in [sApolloMediaComposerPendingVideoContexts copy]) {
            if ([context[@"consumed"] boolValue]) continue;
            NSData *contextPosterData = context[@"posterData"];
            if (fileData.length > 0 && [contextPosterData isKindOfClass:[NSData class]] && [contextPosterData isEqualToData:fileData]) {
                return ApolloMediaComposerConsumeContextLocked(context);
            }
            if (!fallback) fallback = context;
        }

        if (sApolloMediaComposerPendingVideoContexts.count == 1 && fallback) {
            ApolloLog(@"[MediaComposer] using only pending selected-video context for upload fallback");
            return ApolloMediaComposerConsumeContextLocked(fallback);
        }
    }
    return nil;
}

static void ApolloMediaComposerMarkVideoProvider(NSItemProvider *provider, NSString *assetIdentifier, NSString *typeIdentifier) {
    if (!provider || typeIdentifier.length == 0) return;
    NSMutableDictionary *context = [@{
        @"assetIdentifier": assetIdentifier ?: @"",
        @"typeIdentifier": typeIdentifier,
        @"createdAt": @([[NSDate date] timeIntervalSince1970])
    } mutableCopy];
    objc_setAssociatedObject(provider, &kApolloMediaComposerProviderContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloMediaComposerRegisterPendingVideoContext(context);
}

static void ApolloMediaComposerInspectPickerResults(NSArray *results, id delegate) {
    if (![results isKindOfClass:[NSArray class]]) return;
    NSMutableArray<NSDictionary *> *videoEntries = [NSMutableArray array];
    NSUInteger index = 0;
    for (id result in results) {
        NSItemProvider *provider = [result respondsToSelector:@selector(itemProvider)] ? [result itemProvider] : nil;
        NSString *assetIdentifier = [result respondsToSelector:@selector(assetIdentifier)] ? [result assetIdentifier] : nil;
        NSArray<NSString *> *types = [provider respondsToSelector:@selector(registeredTypeIdentifiers)] ? provider.registeredTypeIdentifiers : @[];
        NSString *videoType = ApolloMediaComposerFirstVideoTypeIdentifier(provider);
        ApolloLog(@"[MediaComposer] picker result[%lu] asset=%@ types=%@", (unsigned long)index, assetIdentifier ?: @"(none)", types ?: @[]);
        if (videoType.length > 0 && provider) {
            [videoEntries addObject:@{@"provider": provider, @"assetIdentifier": assetIdentifier ?: @"", @"typeIdentifier": videoType}];
        }
        index++;
    }

    ApolloLog(@"[MediaComposer] picker didFinishPicking delegate=%@ results=%lu videos=%lu", NSStringFromClass([delegate class]) ?: @"(unknown)", (unsigned long)results.count, (unsigned long)videoEntries.count);
    if (videoEntries.count == 1 && results.count == 1) {
        NSDictionary *entry = videoEntries.firstObject;
        ApolloMediaComposerMarkVideoProvider(entry[@"provider"], entry[@"assetIdentifier"], entry[@"typeIdentifier"]);
        ApolloLog(@"[MediaComposer] marked single selected video provider type=%@ asset=%@", entry[@"typeIdentifier"], [entry[@"assetIdentifier"] length] > 0 ? entry[@"assetIdentifier"] : @"(none)");
    } else if (videoEntries.count > 0) {
        ApolloLog(@"[MediaComposer] refusing unsupported multi/mixed video picker selection (results=%lu videos=%lu)", (unsigned long)results.count, (unsigned long)videoEntries.count);
    }
}

static void ApolloMediaComposerWrapPickerDelegateIfNeeded(id delegate) {
    if (!delegate || !ApolloMediaComposerShouldWidenPicker()) return;
    Class cls = [delegate class];
    NSString *className = NSStringFromClass(cls);
    if (className.length == 0) return;

    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (!sApolloMediaComposerWrappedPickerDelegateClasses) sApolloMediaComposerWrappedPickerDelegateClasses = [NSMutableSet new];
        if ([sApolloMediaComposerWrappedPickerDelegateClasses containsObject:className]) return;
        [sApolloMediaComposerWrappedPickerDelegateClasses addObject:className];
    }

    SEL selector = @selector(picker:didFinishPicking:);
    Method method = class_getInstanceMethod(cls, selector);
    IMP originalIMP = method ? method_getImplementation(method) : NULL;
    const char *types = method ? method_getTypeEncoding(method) : "v@:@@";
    IMP replacementIMP = imp_implementationWithBlock(^(id selfObject, id picker, NSArray *results) {
        ApolloMediaComposerInspectPickerResults(results, selfObject);
        if (originalIMP) {
            ((void (*)(id, SEL, id, NSArray *))originalIMP)(selfObject, selector, picker, results);
        }
    });
    class_replaceMethod(cls, selector, replacementIMP, types);
    ApolloLog(@"[MediaComposer] wrapped PHPicker delegate class %@", className);
}

static BOOL ApolloPhotoComposerStringContains(NSString *haystack, NSString *needle) {
    return [haystack isKindOfClass:[NSString class]] && needle.length > 0 &&
        [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL ApolloMediaComposerShouldWidenPicker(void) {
    return ApolloMediaComposerRedditUploadSelected() && (sApolloMediaComposerContextActive || sApolloMediaComposerPickerActive);
}

static BOOL ApolloMediaComposerRedditUploadSelected(void) {
    return sImageUploadProvider == ImageUploadProviderReddit;
}

static BOOL ApolloPhotoComposerClassLooksLikeComposer(NSString *className) {
    return ApolloPhotoComposerStringContains(className, @"ComposePostViewController");
}

static NSString *ApolloPhotoComposerTextForView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    if ([view isKindOfClass:[UITextField class]]) return ((UITextField *)view).text;
    if ([view isKindOfClass:[UITextView class]]) return ((UITextView *)view).text;
    if ([view isKindOfClass:[UIButton class]]) return [(UIButton *)view currentTitle];
    NSString *accessibilityLabel = view.accessibilityLabel;
    return accessibilityLabel.length > 0 ? accessibilityLabel : nil;
}

static BOOL ApolloPhotoComposerViewContainsText(UIView *rootView, NSString *needle) {
    if (!rootView || needle.length == 0) return NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if (ApolloPhotoComposerStringContains(ApolloPhotoComposerTextForView(view), needle)) return YES;
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return NO;
}

static BOOL ApolloPhotoComposerControllerIsInScope(UIViewController *controller) {
    if (!controller.isViewLoaded || !controller.view.window) return NO;

    NSString *title = controller.navigationItem.title ?: controller.title;
    if (ApolloPhotoComposerStringContains(title, @"Photo Post")) return YES;
    if (ApolloPhotoComposerStringContains(title, @"Media Post")) return YES;

    UIView *view = controller.view;
    BOOL hasPhotoChooser = ApolloPhotoComposerViewContainsText(view, @"Choose from Photos") ||
        ApolloPhotoComposerViewContainsText(view, @"Choose Photos") ||
        ApolloPhotoComposerViewContainsText(view, @"Choose Media");
    if (!hasPhotoChooser) return NO;

    BOOL hasPostingContext = ApolloPhotoComposerViewContainsText(view, @"Posting in") ||
        ApolloPhotoComposerViewContainsText(view, @"Set Flair") ||
        ApolloPhotoComposerViewContainsText(view, @"Flair");
    BOOL hasPostMode = (ApolloPhotoComposerViewContainsText(view, @"Photo") || ApolloPhotoComposerViewContainsText(view, @"Media")) &&
        ApolloPhotoComposerViewContainsText(view, @"Link") &&
        ApolloPhotoComposerViewContainsText(view, @"Text");
    return hasPostingContext || hasPostMode;
}

static NSString *ApolloPhotoComposerReplacementText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    if ([text isEqualToString:@"Photo"]) return @"Media";
    if (sApolloMediaComposerPickerActive && [text isEqualToString:@"Photos"]) return @"Media";
    if ([text isEqualToString:@"Photo Post"]) return @"Media Post";
    if ([text isEqualToString:@"Choose from Photos"]) return @"Choose Media";
    if ([text isEqualToString:@"Choose Photos"]) return @"Choose Media";
    if ([text isEqualToString:@"Select Photos"]) return @"Select Media";
    if ([text isEqualToString:@"Select up to 10 photos."]) return @"Select photos or 1 video.";
    return nil;
}

// Substring replacements for Texture nodes. Composer labels often have
// surrounding whitespace, attachment glyphs, or punctuation, so exact-equality
// matching misses them. This list is intentionally narrow so we never rename
// unrelated "Photo" labels elsewhere in Apollo.
static NSArray<NSArray<NSString *> *> *ApolloPhotoComposerInlineSubstringReplacements(void) {
    static NSArray<NSArray<NSString *> *> *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Order matters: longer phrases first so they win over their substrings.
        list = @[
            @[@"Choose from Photos", @"Choose Media"],
            @[@"Select up to 10 photos.", @"Select photos or 1 video."],
            @[@"Select up to 10 photos", @"Select photos or 1 video"],
            @[@"Choose Photos", @"Choose Media"],
            @[@"Select Photos", @"Select Media"],
        ];
    });
    return list;
}

static BOOL ApolloPhotoComposerFindInlineReplacement(NSString *text, NSRange *outMatchRange, NSString **outReplacement) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    for (NSArray<NSString *> *pair in ApolloPhotoComposerInlineSubstringReplacements()) {
        NSString *needle = pair.firstObject;
        NSRange r = [text rangeOfString:needle];
        if (r.location != NSNotFound) {
            if (outMatchRange) *outMatchRange = r;
            if (outReplacement) *outReplacement = pair.lastObject;
            return YES;
        }
    }
    return NO;
}

static NSAttributedString *ApolloPhotoComposerAttributedReplacement(NSAttributedString *attributedText) {
    if (attributedText.length == 0) return attributedText;
    NSRange matchRange = NSMakeRange(NSNotFound, 0);
    NSString *replacement = nil;
    if (!ApolloPhotoComposerFindInlineReplacement(attributedText.string, &matchRange, &replacement)) return attributedText;
    if (replacement.length == 0 || matchRange.location == NSNotFound) return attributedText;

    NSMutableAttributedString *mutableText = [attributedText mutableCopy];
    [mutableText replaceCharactersInRange:matchRange withString:replacement];
    return mutableText;
}

static NSString *ApolloPhotoComposerPlainReplacement(NSString *text) {
    NSRange matchRange = NSMakeRange(NSNotFound, 0);
    NSString *replacement = nil;
    if (!ApolloPhotoComposerFindInlineReplacement(text, &matchRange, &replacement)) return text;
    if (replacement.length == 0 || matchRange.location == NSNotFound) return text;
    return [text stringByReplacingCharactersInRange:matchRange withString:replacement];
}

static void ApolloMediaComposerLogTextCandidateOnce(NSString *selectorName, id object, NSString *text) {
    if (!ApolloMediaComposerShouldWidenPicker()) return;
    NSString *replacement = ApolloPhotoComposerPlainReplacement(text);
    if (![replacement isKindOfClass:[NSString class]] || [replacement isEqualToString:text]) return;

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", selectorName ?: @"(unknown)", NSStringFromClass([object class]) ?: @"(unknown)", text ?: @"(nil)"];
    BOOL shouldLog = NO;
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (!sApolloMediaComposerLoggedTextCandidates) sApolloMediaComposerLoggedTextCandidates = [NSMutableSet new];
        if (![sApolloMediaComposerLoggedTextCandidates containsObject:key] && sApolloMediaComposerLoggedTextCandidates.count < 40) {
            [sApolloMediaComposerLoggedTextCandidates addObject:key];
            shouldLog = YES;
        }
    }
    if (shouldLog) {
        ApolloLog(@"[MediaComposer] text candidate selector=%@ class=%@ text=%@ replacement=%@", selectorName ?: @"(unknown)", NSStringFromClass([object class]) ?: @"(unknown)", text ?: @"(nil)", replacement ?: @"(nil)");
    }
}

static NSString *ApolloPhotoComposerVisibleReplacementText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    NSString *inlineReplacement = ApolloPhotoComposerPlainReplacement(text);
    if ([inlineReplacement isKindOfClass:[NSString class]] && ![inlineReplacement isEqualToString:text]) return inlineReplacement;
    return ApolloPhotoComposerReplacementText(text);
}

static NSUInteger ApolloPhotoComposerApplyMediaWordingToView(UIView *rootView) {
    if (!rootView) return 0;
    NSUInteger changes = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *replacement = ApolloPhotoComposerVisibleReplacementText(label.text);
            if (replacement.length > 0) { label.text = replacement; changes++; }
        } else if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            NSString *replacement = ApolloPhotoComposerVisibleReplacementText([button currentTitle]);
            if (replacement.length > 0) { [button setTitle:replacement forState:UIControlStateNormal]; changes++; }
        } else if ([view isKindOfClass:[UISegmentedControl class]]) {
            UISegmentedControl *segmentedControl = (UISegmentedControl *)view;
            for (NSUInteger index = 0; index < segmentedControl.numberOfSegments; index++) {
                NSString *replacement = ApolloPhotoComposerVisibleReplacementText([segmentedControl titleForSegmentAtIndex:index]);
                if (replacement.length > 0) { [segmentedControl setTitle:replacement forSegmentAtIndex:index]; changes++; }
            }
        }

        NSString *accessibilityReplacement = ApolloPhotoComposerVisibleReplacementText(view.accessibilityLabel);
        if (accessibilityReplacement.length > 0) { view.accessibilityLabel = accessibilityReplacement; changes++; }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return changes;
}

static void ApolloMediaComposerMarkContextActive(UIViewController *controller, NSString *reason) {
    if (!ApolloMediaComposerRedditUploadSelected()) {
        sApolloMediaComposerContextActive = NO;
        sApolloMediaComposerPickerActive = NO;
        return;
    }

    if (!controller) return;
    NSString *className = NSStringFromClass(controller.class);
    if (!ApolloPhotoComposerClassLooksLikeComposer(className) && !ApolloPhotoComposerControllerIsInScope(controller)) return;

    sApolloMediaComposerContextActive = YES;
    if (!sApolloMediaComposerLoggedEarlyContext) {
        sApolloMediaComposerLoggedEarlyContext = YES;
        ApolloLog(@"[MediaComposer] composer context active early reason=%@ controller=%@ title=%@",
            reason ?: @"(unknown)", className ?: @"(unknown)", controller.navigationItem.title ?: controller.title ?: @"(none)");
    }
}

static void ApolloPhotoComposerApplyMediaWording(UIViewController *controller) {
    if (!ApolloMediaComposerRedditUploadSelected()) return;
    if (!ApolloPhotoComposerControllerIsInScope(controller)) return;

    NSUInteger changes = 0;
    NSString *navReplacement = ApolloPhotoComposerReplacementText(controller.navigationItem.title);
    if (navReplacement.length > 0) { controller.navigationItem.title = navReplacement; changes++; }
    NSString *titleReplacement = ApolloPhotoComposerReplacementText(controller.title);
    if (titleReplacement.length > 0) { controller.title = titleReplacement; changes++; }
    changes += ApolloPhotoComposerApplyMediaWordingToView(controller.view);

    NSNumber *logged = objc_getAssociatedObject(controller, &kApolloPhotoComposerWordingLoggedControllerKey);
    if (changes > 0 && ![logged boolValue]) {
        ApolloLog(@"[MediaComposer] renamed Photo composer wording to Media (changes=%lu)", (unsigned long)changes);
        objc_setAssociatedObject(controller, &kApolloPhotoComposerWordingLoggedControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL ApolloPhotoComposerClassLooksLikeMediaPicker(NSString *className) {
    return ApolloPhotoComposerStringContains(className, @"ActionController") ||
        ApolloPhotoComposerStringContains(className, @"Photo") ||
        ApolloPhotoComposerStringContains(className, @"Image") ||
        ApolloPhotoComposerStringContains(className, @"Picker") ||
        ApolloPhotoComposerStringContains(className, @"Asset") ||
        ApolloPhotoComposerStringContains(className, @"Media");
}

static void ApolloPhotoComposerMarkPickerActive(NSString *reason) {
    if (!ApolloMediaComposerRedditUploadSelected()) return;
    if (!sApolloMediaComposerPickerActive) {
        ApolloLog(@"[MediaComposer] custom media picker context active reason=%@", reason ?: @"(unknown)");
    }
    sApolloMediaComposerPickerActive = YES;
}

static NSPredicate *ApolloMediaComposerPredicateAllowingImagesAndVideos(NSPredicate *predicate) {
    NSString *format = predicate.predicateFormat ?: @"";
    if (![format containsString:@"mediaType"]) return predicate;
    if (![format containsString:@"1"]) return predicate;

    if (!sApolloMediaComposerLoggedPredicateRewrite) {
        sApolloMediaComposerLoggedPredicateRewrite = YES;
        ApolloLog(@"[MediaComposer] widening Photos predicate to include videos format=%@", format);
    }
    return [NSPredicate predicateWithFormat:@"mediaType == 1 OR mediaType == 2"];
}

static PHFetchOptions *ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(PHFetchOptions *options) {
    if (!ApolloMediaComposerShouldWidenPicker() || ![options isKindOfClass:objc_getClass("PHFetchOptions")]) return options;

    NSPredicate *predicate = options.predicate;
    NSPredicate *rewritten = ApolloMediaComposerPredicateAllowingImagesAndVideos(predicate);
    if (!rewritten || rewritten == predicate || [rewritten isEqual:predicate]) return options;

    PHFetchOptions *copy = [options copy];
    copy.predicate = rewritten;
    return copy;
}

static UICollectionView *ApolloPhotoComposerFindImageStrip(UIViewController *controller) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    NSUInteger inspected = 0;
    UICollectionView *fallback = nil;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)view;
            CGRect bounds = collectionView.bounds;
            BOOL hasStripShape = bounds.size.width >= 220.0 && bounds.size.height >= 70.0 && bounds.size.height <= 340.0;
            BOOL hasHorizontalOverflow = collectionView.contentSize.width > bounds.size.width + 8.0;
            if (hasStripShape && hasHorizontalOverflow) {
                NSString *delegateClass = collectionView.delegate ? NSStringFromClass([collectionView.delegate class]) : @"";
                if (ApolloPhotoComposerStringContains(delegateClass, @"ImageSlider")) return collectionView;
                if (!fallback) fallback = collectionView;
            }
        }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return fallback;
}

static BOOL ApolloPhotoComposerStripShouldCancelContentTouch(id self, SEL _cmd, UIView *view) {
    return YES;
}

static BOOL ApolloPhotoComposerRecognizerCompetesWithStripPan(UIGestureRecognizer *recognizer) {
    NSString *className = NSStringFromClass(recognizer.class);
    return [className isEqualToString:@"UIPanGestureRecognizer"] ||
        [className isEqualToString:@"_UISwipeActionPanGestureRecognizer"] ||
        [className isEqualToString:@"_UIParallaxTransitionPanGestureRecognizer"];
}

static NSUInteger ApolloPhotoComposerPreferStripPan(UIScrollView *scrollView) {
    UIPanGestureRecognizer *stripPan = scrollView.panGestureRecognizer;
    if (!stripPan) return 0;

    NSUInteger requiredCount = 0;
    for (UIView *ancestor = scrollView.superview; ancestor; ancestor = ancestor.superview) {
        for (UIGestureRecognizer *recognizer in ancestor.gestureRecognizers) {
            if (recognizer == stripPan || !ApolloPhotoComposerRecognizerCompetesWithStripPan(recognizer)) continue;
            [recognizer requireGestureRecognizerToFail:stripPan];
            requiredCount++;
        }
    }
    return requiredCount;
}

static void ApolloPhotoComposerApplyScrollFix(UICollectionView *collectionView) {
    if (!collectionView) return;
    if (objc_getAssociatedObject(collectionView, &kApolloPhotoComposerScrollFixAppliedKey)) return;

    collectionView.delaysContentTouches = NO;
    collectionView.canCancelContentTouches = YES;
    collectionView.alwaysBounceHorizontal = YES;

    Class originalClass = object_getClass(collectionView);
    NSString *subclassName = [NSString stringWithFormat:@"ApolloComposerStripScrollFix_%@", NSStringFromClass(originalClass)];
    Class subclass = objc_getClass(subclassName.UTF8String);
    if (!subclass) {
        subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
        if (subclass) {
            SEL selector = @selector(touchesShouldCancelInContentView:);
            Method method = class_getInstanceMethod([UIScrollView class], selector);
            const char *types = method ? method_getTypeEncoding(method) : "c@:@";
            class_addMethod(subclass, selector, (IMP)ApolloPhotoComposerStripShouldCancelContentTouch, types);
            objc_registerClassPair(subclass);
        }
    }
    if (subclass && object_getClass(collectionView) != subclass) {
        object_setClass(collectionView, subclass);
    }

    NSUInteger requiredCount = ApolloPhotoComposerPreferStripPan(collectionView);
    objc_setAssociatedObject(collectionView, &kApolloPhotoComposerScrollFixAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[PhotoComposerScroll] enabled selected-photo strip horizontal scrolling (ancestor recognizers=%lu)", (unsigned long)requiredCount);
}

static void ApolloPhotoComposerRepairController(UIViewController *controller, NSString *reason) {
    if (!ApolloPhotoComposerControllerIsInScope(controller)) return;

    ApolloPhotoComposerApplyMediaWording(controller);

    NSNumber *logged = objc_getAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey);
    if (![logged boolValue]) {
        ApolloLog(@"[PhotoComposerScroll] composer in scope controller=%@ reason=%@ title=%@",
            NSStringFromClass(controller.class), reason ?: @"(unknown)",
            controller.navigationItem.title ?: controller.title ?: @"(none)");
        objc_setAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloPhotoComposerApplyScrollFix(ApolloPhotoComposerFindImageStrip(controller));
}

static void ApolloPhotoComposerRepairControllerSoon(UIViewController *controller, NSString *reason) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController) ApolloPhotoComposerRepairController(strongController, reason);
    });
}

static void ApolloPhotoComposerRepairControllerAfterDelay(UIViewController *controller, NSString *reason, NSTimeInterval delay) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController) ApolloPhotoComposerRepairController(strongController, reason);
    });
}

static void ApolloPhotoComposerRepairControllerBurst(UIViewController *controller, NSString *reason) {
    if (!controller) return;
    NSTimeInterval delays[] = { 0.10, 0.40, 1.00, 1.80 };
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        ApolloPhotoComposerRepairControllerAfterDelay(controller, reason, delays[i]);
    }
}

static void ApolloPhotoComposerMaybeEnableMoviePicking(UIViewController *presenter, UIViewController *presented) {
    ApolloMediaComposerMarkContextActive(presenter, @"present");
    if (!ApolloPhotoComposerControllerIsInScope(presenter) || !presented) return;

    ApolloPhotoComposerRepairControllerBurst(presenter, @"present");

    if (!ApolloMediaComposerRedditUploadSelected()) return;

    ApolloPhotoComposerMarkPickerActive(@"present");

    NSString *presentedClass = NSStringFromClass(presented.class);
    if (ApolloPhotoComposerClassLooksLikeMediaPicker(presentedClass)) {
        ApolloPhotoComposerMarkPickerActive(presentedClass);
    }
    NSMutableSet *loggedClasses = objc_getAssociatedObject(presenter, &kApolloPhotoComposerLoggedPresentedPickerKey);
    if (![loggedClasses isKindOfClass:[NSMutableSet class]]) {
        loggedClasses = [NSMutableSet set];
        objc_setAssociatedObject(presenter, &kApolloPhotoComposerLoggedPresentedPickerKey, loggedClasses, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![loggedClasses containsObject:presentedClass ?: @"(unknown)"]) {
        ApolloLog(@"[MediaComposer] presenting picker controller=%@", presentedClass ?: @"(unknown)");
        [loggedClasses addObject:presentedClass ?: @"(unknown)"];
    }

    if (![presented isKindOfClass:[UIImagePickerController class]]) return;

    UIImagePickerController *picker = (UIImagePickerController *)presented;
    NSMutableOrderedSet<NSString *> *mediaTypes = [NSMutableOrderedSet orderedSetWithArray:picker.mediaTypes ?: @[]];
    [mediaTypes addObject:@"public.image"];
    [mediaTypes addObject:@"public.movie"];
    picker.mediaTypes = mediaTypes.array;
    ApolloLog(@"[MediaComposer] enabled UIImagePickerController image/movie media types");
}

%hook UIViewController

- (void)viewDidLoad {
    %orig;
    ApolloMediaComposerMarkContextActive(self, @"viewDidLoad");
    ApolloPhotoComposerRepairControllerSoon(self, @"viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloMediaComposerMarkContextActive(self, @"viewWillAppear");
    ApolloPhotoComposerRepairControllerSoon(self, @"viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloMediaComposerMarkContextActive(self, @"viewDidAppear");
    NSString *className = NSStringFromClass(self.class);
    if (ApolloMediaComposerShouldWidenPicker() && ApolloPhotoComposerClassLooksLikeMediaPicker(className)) {
        ApolloLog(@"[MediaComposer] picker-ish controller appeared %@", className ?: @"(unknown)");
    }
    ApolloPhotoComposerRepairControllerSoon(self, @"viewDidAppear");
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMediaComposerMarkContextActive(self, @"viewDidLayoutSubviews");
    ApolloPhotoComposerRepairController(self, @"viewDidLayoutSubviews");
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    ApolloPhotoComposerMaybeEnableMoviePicking(self, viewControllerToPresent);
    %orig;
}

- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    __weak UIViewController *weakRepairTarget = self.presentingViewController ?: self;
    void (^wrappedCompletion)(void) = ^{
        if (completion) completion();
        UIViewController *repairTarget = weakRepairTarget;
        if (repairTarget) ApolloPhotoComposerRepairControllerBurst(repairTarget, @"dismiss");
    };
    %orig(flag, wrappedCompletion);
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UILabel setText:", self, text);
    %orig(ApolloPhotoComposerPlainReplacement(text));
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UILabel setAttributedText:", self, attributedText.string);
    %orig(ApolloPhotoComposerAttributedReplacement(attributedText));
}

%end

%hook UIButton

- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UIButton setTitle:forState:", self, title);
    %orig(ApolloPhotoComposerPlainReplacement(title), state);
}

- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UIButton setAttributedTitle:forState:", self, title.string);
    %orig(ApolloPhotoComposerAttributedReplacement(title), state);
}

%end

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode setAttributedText:", self, attributedText.string);
    %orig(ApolloPhotoComposerAttributedReplacement(attributedText));
}

- (void)setText:(NSString *)text {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode setText:", self, text);
    %orig(ApolloPhotoComposerPlainReplacement(text));
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode2 setAttributedText:", self, attributedText.string);
    %orig(ApolloPhotoComposerAttributedReplacement(attributedText));
}

- (void)setText:(NSString *)text {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode2 setText:", self, text);
    %orig(ApolloPhotoComposerPlainReplacement(text));
}

%end

%hook ASButtonNode

- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASButtonNode setAttributedTitle:forState:", self, title.string);
    %orig(ApolloPhotoComposerAttributedReplacement(title), state);
}

- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASButtonNode setTitle:withFont:withColor:forState:", self, title);
    NSString *replacement = ApolloPhotoComposerPlainReplacement(title);
    if (!sApolloMediaComposerLoggedButtonTitleRewrite && [replacement isKindOfClass:[NSString class]] && ![replacement isEqualToString:title]) {
        sApolloMediaComposerLoggedButtonTitleRewrite = YES;
        ApolloLog(@"[MediaComposer] ASButtonNode setTitle rewrite selector=setTitle:withFont:withColor:forState: original=%@ replacement=%@", title ?: @"(nil)", replacement ?: @"(nil)");
    }
    %orig(replacement, font, color, state);
}

- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color withShadowColor:(UIColor *)shadowColor withShadowOffset:(CGSize)shadowOffset forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASButtonNode setTitle:withFont:withColor:withShadowColor:withShadowOffset:forState:", self, title);
    NSString *replacement = ApolloPhotoComposerPlainReplacement(title);
    if (!sApolloMediaComposerLoggedButtonTitleRewrite && [replacement isKindOfClass:[NSString class]] && ![replacement isEqualToString:title]) {
        sApolloMediaComposerLoggedButtonTitleRewrite = YES;
        ApolloLog(@"[MediaComposer] ASButtonNode setTitle rewrite selector=setTitle:withFont:withColor:withShadowColor:withShadowOffset:forState: original=%@ replacement=%@", title ?: @"(nil)", replacement ?: @"(nil)");
    }
    %orig(replacement, font, color, shadowColor, shadowOffset, state);
}

%end

%hook NSItemProvider

- (BOOL)hasItemConformingToTypeIdentifier:(NSString *)typeIdentifier {
    if (!ApolloMediaComposerShouldWidenPicker()) return %orig;
    if (ApolloMediaComposerProviderIsMarkedVideo((NSItemProvider *)self) && ApolloMediaComposerTypeIdentifierIsImageRequest(typeIdentifier)) {
        if (!sApolloMediaComposerLoggedProviderProbe) {
            sApolloMediaComposerLoggedProviderProbe = YES;
            ApolloLog(@"[MediaComposer] video provider answering image conformance for %@", typeIdentifier ?: @"(nil)");
        }
        return YES;
    }
    return %orig;
}

- (BOOL)canLoadObjectOfClass:(Class)aClass {
    if (!ApolloMediaComposerShouldWidenPicker()) return %orig;
    if (ApolloMediaComposerProviderIsMarkedVideo((NSItemProvider *)self) && aClass == [UIImage class]) {
        ApolloLog(@"[MediaComposer] video provider answering canLoadObjectOfClass:UIImage");
        return YES;
    }
    return %orig;
}

- (NSProgress *)loadObjectOfClass:(Class)aClass completionHandler:(void (^)(id<NSSecureCoding> object, NSError *error))completionHandler {
    if (!ApolloMediaComposerShouldWidenPicker()) return %orig;
    NSMutableDictionary *context = ApolloMediaComposerContextForProvider((NSItemProvider *)self);
    if (context && aClass == [UIImage class] && completionHandler) {
        NSString *typeIdentifier = context[@"typeIdentifier"];
        ApolloLog(@"[MediaComposer] video provider loadObjectOfClass:UIImage via %@", typeIdentifier ?: @"(missing)");
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        [self loadFileRepresentationForTypeIdentifier:typeIdentifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                progress.completedUnitCount = 1;
                completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Video provider did not return a file"}]);
                return;
            }
            NSURL *stableURL = ApolloMediaComposerCopyVideoFileToStableTempURL(url, typeIdentifier);
            UIImage *poster = ApolloMediaComposerPosterImageForVideoURL(stableURL ?: url);
            if (stableURL) {
                context[@"fileURL"] = stableURL;
                context[@"filename"] = stableURL.lastPathComponent ?: @"apollo-selected-video.mp4";
                context[@"mimeType"] = ApolloMediaComposerVideoMIMETypeForTypeIdentifier(typeIdentifier, stableURL);
            }
            ApolloMediaComposerAttachContextToPosterImage(poster, context);
            progress.completedUnitCount = 1;
            completionHandler((id<NSSecureCoding>)poster, poster ? nil : [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not generate selected-video poster"}]);
        }];
        return progress;
    }
    return %orig;
}

- (NSProgress *)loadDataRepresentationForTypeIdentifier:(NSString *)typeIdentifier completionHandler:(void (^)(NSData *data, NSError *error))completionHandler {
    if (!ApolloMediaComposerShouldWidenPicker()) return %orig;
    NSMutableDictionary *context = ApolloMediaComposerContextForProvider((NSItemProvider *)self);
    if (context && ApolloMediaComposerTypeIdentifierIsImageRequest(typeIdentifier) && completionHandler) {
        NSString *videoType = context[@"typeIdentifier"];
        ApolloLog(@"[MediaComposer] video provider loadDataRepresentation image request=%@ via %@", typeIdentifier ?: @"(nil)", videoType ?: @"(missing)");
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        [self loadFileRepresentationForTypeIdentifier:videoType completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                progress.completedUnitCount = 1;
                completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Video provider did not return a file"}]);
                return;
            }
            NSURL *stableURL = ApolloMediaComposerCopyVideoFileToStableTempURL(url, videoType);
            UIImage *poster = ApolloMediaComposerPosterImageForVideoURL(stableURL ?: url);
            NSData *posterData = poster ? UIImageJPEGRepresentation(poster, 0.92) : nil;
            if (stableURL) {
                context[@"fileURL"] = stableURL;
                context[@"filename"] = stableURL.lastPathComponent ?: @"apollo-selected-video.mp4";
                context[@"mimeType"] = ApolloMediaComposerVideoMIMETypeForTypeIdentifier(videoType, stableURL);
            }
            ApolloMediaComposerAttachContextToPosterImage(poster, context);
            ApolloMediaComposerAttachPosterPayload(posterData, context);
            progress.completedUnitCount = 1;
            completionHandler(posterData, posterData ? nil : [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Could not generate selected-video poster data"}]);
        }];
        return progress;
    }
    return %orig;
}

- (NSProgress *)loadFileRepresentationForTypeIdentifier:(NSString *)typeIdentifier completionHandler:(void (^)(NSURL *url, NSError *error))completionHandler {
    if (!ApolloMediaComposerShouldWidenPicker()) return %orig;
    NSMutableDictionary *context = ApolloMediaComposerContextForProvider((NSItemProvider *)self);
    if (context && ApolloMediaComposerTypeIdentifierIsImageRequest(typeIdentifier) && completionHandler) {
        NSString *videoType = context[@"typeIdentifier"];
        ApolloLog(@"[MediaComposer] video provider loadFileRepresentation image request=%@ via %@", typeIdentifier ?: @"(nil)", videoType ?: @"(missing)");
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        [self loadFileRepresentationForTypeIdentifier:videoType completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                progress.completedUnitCount = 1;
                completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Video provider did not return a file"}]);
                return;
            }
            NSURL *stableURL = ApolloMediaComposerCopyVideoFileToStableTempURL(url, videoType);
            UIImage *poster = ApolloMediaComposerPosterImageForVideoURL(stableURL ?: url);
            NSData *posterData = poster ? UIImageJPEGRepresentation(poster, 0.92) : nil;
            NSURL *posterURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[ @"apollo-selected-video-poster-" stringByAppendingString:NSUUID.UUID.UUIDString] stringByAppendingPathExtension:@"jpg"]]];
            NSError *writeError = nil;
            BOOL wrote = [posterData writeToURL:posterURL options:NSDataWritingAtomic error:&writeError];
            if (stableURL) {
                context[@"fileURL"] = stableURL;
                context[@"filename"] = stableURL.lastPathComponent ?: @"apollo-selected-video.mp4";
                context[@"mimeType"] = ApolloMediaComposerVideoMIMETypeForTypeIdentifier(videoType, stableURL);
            }
            ApolloMediaComposerAttachContextToPosterImage(poster, context);
            ApolloMediaComposerAttachPosterPayload(posterData, context);
            progress.completedUnitCount = 1;
            completionHandler(wrote ? posterURL : nil, wrote ? nil : (writeError ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Could not write selected-video poster file"}]));
        }];
        return progress;
    }
    return %orig;
}

%end

static PHPickerFilter *ApolloMediaComposerCombinedImagesVideosFilter(void) {
    Class filterClass = objc_getClass("PHPickerFilter");
    if (!filterClass || ![filterClass respondsToSelector:@selector(anyFilterMatchingSubfilters:)] ||
        ![filterClass respondsToSelector:@selector(imagesFilter)] ||
        ![filterClass respondsToSelector:@selector(videosFilter)]) return nil;
    return [filterClass anyFilterMatchingSubfilters:@[[filterClass imagesFilter], [filterClass videosFilter]]];
}

static void ApolloMediaComposerApplyCombinedFilterToConfiguration(PHPickerConfiguration *configuration, NSString *reason) {
    if (!configuration || !ApolloMediaComposerShouldWidenPicker()) return;
    PHPickerFilter *combined = ApolloMediaComposerCombinedImagesVideosFilter();
    if (!combined) return;
    @try {
        [configuration setFilter:combined];
    } @catch (__unused NSException *e) {}
    if (!sApolloMediaComposerLoggedPickerConfigInitOverride) {
        sApolloMediaComposerLoggedPickerConfigInitOverride = YES;
        ApolloLog(@"[MediaComposer] primed PHPickerConfiguration filter to images+videos reason=%@ filter=%@", reason ?: @"(unknown)", configuration.filter);
    }
}

static void ApolloMediaComposerLogPhotoAuthStateOnce(void) {
    if (sApolloMediaComposerLoggedPhotoAuthState) return;
    sApolloMediaComposerLoggedPhotoAuthState = YES;
    Class libClass = objc_getClass("PHPhotoLibrary");
    if (!libClass || ![libClass respondsToSelector:@selector(authorizationStatusForAccessLevel:)]) {
        ApolloLog(@"[MediaComposer] PHPhotoLibrary auth-status accessor unavailable");
        return;
    }
    NSInteger status = [libClass authorizationStatusForAccessLevel:2 /* PHAccessLevelReadWrite */];
    NSString *desc = nil;
    switch (status) {
        case 0: desc = @"NotDetermined"; break;
        case 1: desc = @"Restricted"; break;
        case 2: desc = @"Denied"; break;
        case 3: desc = @"Authorized (Full)"; break;
        case 4: desc = @"Limited"; break;
        default: desc = [NSString stringWithFormat:@"Unknown(%ld)", (long)status]; break;
    }
    ApolloLog(@"[MediaComposer] PHPhotoLibrary access level=%@ — videos require Full Access OR adding videos via 'Manage Selected Photos' in Limited mode", desc);
}

%hook PHPickerConfiguration

- (instancetype)init {
    PHPickerConfiguration *configuration = %orig;
    ApolloMediaComposerApplyCombinedFilterToConfiguration(configuration, @"init");
    return configuration;
}

- (instancetype)initWithPhotoLibrary:(PHPhotoLibrary *)photoLibrary {
    PHPickerConfiguration *configuration = %orig(photoLibrary);
    ApolloMediaComposerApplyCombinedFilterToConfiguration(configuration, @"initWithPhotoLibrary:");
    return configuration;
}

- (void)setFilter:(PHPickerFilter *)filter {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    PHPickerFilter *combined = ApolloMediaComposerCombinedImagesVideosFilter();
    if (!combined) { %orig; return; }
    if (!sApolloMediaComposerLoggedPickerFilterRewrite) {
        sApolloMediaComposerLoggedPickerFilterRewrite = YES;
        ApolloLog(@"[MediaComposer] widening PHPickerConfiguration filter to images+videos via setFilter:");
    }
    %orig(combined);
}

%end

%hook PHPickerViewController

- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration {
    if (ApolloMediaComposerShouldWidenPicker() && configuration) {
        ApolloMediaComposerApplyCombinedFilterToConfiguration(configuration, @"PHPickerViewController initWithConfiguration:");
        PHPickerFilter *combined = ApolloMediaComposerCombinedImagesVideosFilter();
        if (combined) {
            if (!sApolloMediaComposerLoggedPickerInitOverride) {
                sApolloMediaComposerLoggedPickerInitOverride = YES;
                ApolloLog(@"[MediaComposer] forced PHPicker filter to images+videos at initWithConfiguration: (filter=%@)", configuration.filter);
            }
        }
        ApolloMediaComposerLogPhotoAuthStateOnce();
    }
    return %orig;
}

- (void)setDelegate:(id)delegate {
    ApolloMediaComposerWrapPickerDelegateIfNeeded(delegate);
    %orig;
}

%end

%hook PHFetchOptions

- (void)setPredicate:(NSPredicate *)predicate {
    %orig(ApolloMediaComposerShouldWidenPicker() ? ApolloMediaComposerPredicateAllowingImagesAndVideos(predicate) : predicate);
}

%end

%hook PHAsset

+ (id)fetchAssetsWithMediaType:(NSInteger)mediaType options:(PHFetchOptions *)options {
    if (ApolloMediaComposerShouldWidenPicker() && mediaType == 1) {
        if (!sApolloMediaComposerLoggedPhotoFetchRewrite) {
            sApolloMediaComposerLoggedPhotoFetchRewrite = YES;
            ApolloLog(@"[MediaComposer] widening PHAsset image fetch to all media for custom picker");
        }
        return [self fetchAssetsWithOptions:ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(options)];
    }
    return %orig;
}

+ (id)fetchAssetsWithOptions:(PHFetchOptions *)options {
    return %orig(ApolloMediaComposerShouldWidenPicker() ? ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(options) : options);
}

+ (id)fetchAssetsInAssetCollection:(PHAssetCollection *)assetCollection options:(PHFetchOptions *)options {
    return %orig(assetCollection, ApolloMediaComposerShouldWidenPicker() ? ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(options) : options);
}

%end

%ctor {
    dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", RTLD_LAZY);
    rebind_symbols((struct rebinding[2]) {
        {"UIImageJPEGRepresentation", (void *)hooked_UIImageJPEGRepresentation, (void **)&orig_UIImageJPEGRepresentation},
        {"UIImagePNGRepresentation", (void *)hooked_UIImagePNGRepresentation, (void **)&orig_UIImagePNGRepresentation},
    }, 2);
    %init;
}
