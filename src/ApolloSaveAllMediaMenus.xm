// Save the complete post collection from Apollo's native media UI. The
// ActionMenu registry owns both legacy-sheet rows and Liquid Glass menus;
// this module supplies context and actions without touching table geometry.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSaveAllMedia.h"
#import "ApolloSaveAllMediaItems.h"
#import "ApolloToast.h"

extern "C" CFArrayRef ApolloSaveAllMediaCopyURLs(const void *storage);

static NSString *const kApolloSaveAllTitle = @"Save All Media";
static NSString *const kApolloSaveAllIdentifier = @"app.apolloreborn.save-all-media";
static char kApolloSaveAllMenuContextKey;
static char kApolloSaveAllShareContextKey;
static __weak UIViewController *sApolloSaveAllVisiblePage;
static const CFTimeInterval kApolloSaveAllInlineShareGrace = 5.0;

@interface ApolloSaveAllMenuContext : NSObject
@property (nonatomic, copy) NSArray<ApolloSaveAllMediaItem *> *items;
@property (nonatomic, strong) id link;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) dispatch_block_t afterDismissal;
@property (nonatomic) BOOL menuEnded;
@property (nonatomic) BOOL shareCompleted;
@end
@implementation ApolloSaveAllMenuContext
@end

static ApolloSaveAllMenuContext *sApolloSaveAllInlineShareContext;
static CFTimeInterval sApolloSaveAllInlineShareAt;

// Only use this on the verified, strong Objective-C reference ivars below.
// Swift weak references (notably parentMediaPageViewController) are boxes.
static id ApolloSaveAllObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIViewController *ApolloSaveAllPageForController(UIViewController *controller) {
    Class pageClass = objc_getClass("_TtC6Apollo23MediaPageViewController");
    for (UIViewController *vc = controller; vc; vc = vc.parentViewController) {
        if (pageClass && [vc isKindOfClass:pageClass]) return vc;
    }
    return nil;
}

static NSArray<NSURL *> *ApolloSaveAllPageURLs(UIViewController *page) {
    Ivar ivar = class_getInstanceVariable(object_getClass(page), "foundURLs");
    if (!ivar) return nil;
    // Header dump: Optional<Array<Foundation.URL>> occupies one pointer.
    // Reject an unexpected slot instead of interpreting arbitrary Swift data.
    ptrdiff_t offset = ivar_getOffset(ivar);
    Ivar next = class_getInstanceVariable(object_getClass(page), "contentTypeHints");
    if (offset < 0 || !next || ivar_getOffset(next) - offset != sizeof(void *)) return nil;
    const void *storage = (const uint8_t *)(__bridge const void *)page + offset;
    return CFBridgingRelease(ApolloSaveAllMediaCopyURLs(storage));
}

static ApolloSaveAllMenuContext *ApolloSaveAllContextForPage(UIViewController *page) {
    if (!page) return nil;
    ApolloSaveAllMenuContext *context = [ApolloSaveAllMenuContext new];
    context.presenter = page;
    context.link = ApolloSaveAllObjectIvar(page, "link");
    NSError *error = nil;
    // Prefer original post metadata (including animated/video originals).
    NSArray *items = ApolloSaveAllMediaItemsFromLink(context.link, &error);
    if (items.count < 2 && !error) {
        items = ApolloSaveAllMediaItemsFromGallery(ApolloSaveAllObjectIvar(page, "foundRedditGallery"), &error);
    }
    if (items.count < 2 && !error) {
        NSArray *urls = ApolloSaveAllPageURLs(page);
        if (urls.count > 1) items = ApolloSaveAllMediaItemsFromURLs(urls, &error);
    }
    context.items = items;
    context.error = error;
    // A provider album may need one asynchronous lookup when selected. Never
    // offer a redundant bulk action for an ordinary single-image/video post.
    if (items.count > 1 || error || ApolloSaveAllMediaLinkHasCollection(context.link)) return context;
    return nil;
}

static void ApolloSaveAllArmInlineShare(id node, UIGestureRecognizer *recognizer) {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    // A new hold supersedes the previous cell, including a single-media post
    // or a hold that only reveals its spoiler. The native image share manager
    // can encode its temporary JPEG asynchronously before building the sheet.
    sApolloSaveAllInlineShareContext = nil;
    id mediaNode = ApolloSaveAllObjectIvar(node, "richMediaNode") ?: node;
    id link = ApolloSaveAllObjectIvar(mediaNode, "link");
    if (!link) return;
    SEL closestSelector = NSSelectorFromString(@"closestViewController");
    id owner = [node respondsToSelector:closestSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(node, closestSelector) : nil;
    if (![owner isKindOfClass:UIViewController.class] || !((UIViewController *)owner).viewIfLoaded.window) return;

    NSError *error = nil;
    NSArray *items = ApolloSaveAllMediaItemsFromLink(link, &error);
    if (items.count < 2 && !error && !ApolloSaveAllMediaLinkHasCollection(link)) return;
    ApolloSaveAllMenuContext *context = [ApolloSaveAllMenuContext new];
    context.items = items;
    context.link = link;
    context.error = error;
    context.presenter = owner;
    sApolloSaveAllInlineShareContext = context;
    sApolloSaveAllInlineShareAt = CACurrentMediaTime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSaveAllInlineShareGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sApolloSaveAllInlineShareContext == context) sApolloSaveAllInlineShareContext = nil;
    });
}

static void ApolloSaveAllBegin(ApolloSaveAllMenuContext *context) {
    UIViewController *presenter = context.presenter;
    if (!presenter || !presenter.viewIfLoaded.window) {
        ApolloLog(@"[SaveAllMedia] source viewer unavailable after dismissal");
        ApolloShowToastWithStyle(@"Couldn't Start Saving", @"Open the post and try again.", ApolloToastStyleError, nil);
        return;
    }
    if (context.error) {
        ApolloShowToastWithStyle(@"Unable to Save All Media", context.error.localizedDescription,
                                ApolloToastStyleError, nil);
        return;
    }
    if (context.items.count > 1) {
        ApolloSaveAllMedia(context.items, presenter);
        return;
    }
    ApolloShowToastWithStyle(@"Loading media…", nil, ApolloToastStyleInfo, nil);
    ApolloSaveAllMediaResolveLink(context.link, ^(NSArray<ApolloSaveAllMediaItem *> *items, NSError *error) {
        if (error || items.count == 0) {
            ApolloShowToastWithStyle(@"Unable to Save All Media", error.localizedDescription,
                                    ApolloToastStyleError, nil);
        } else if (presenter.viewIfLoaded.window) {
            ApolloSaveAllMedia(items, presenter);
        }
    });
}

// UIActivityViewController's completion is the selection contract. Its view
// disappearance is not: UIKit can remove the sheet before performActivity (or
// through a private child controller), so waiting for a later disappearance
// can leave a selected Save All action permanently queued.
static void ApolloSaveAllCompleteShare(UIActivityViewController *sheet, ApolloSaveAllMenuContext *context) {
    if (context.shareCompleted) return;
    context.shareCompleted = YES;
    ApolloLog(@"[SaveAllMedia] share activity completed; waiting for dismissal");
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_block_t begin = ^{ ApolloSaveAllBegin(context); };
        // The native completion handler has already run. Wait on its real
        // transition if it dismissed the sheet, otherwise dismiss the sheet
        // explicitly. A completed transition needs no additional callback.
        id<UIViewControllerTransitionCoordinator> transition = sheet.transitionCoordinator;
        if (sheet.isBeingDismissed && transition &&
            [transition animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> coordinator) {
                dispatch_async(dispatch_get_main_queue(), begin);
            }]) return;
        if (sheet.presentingViewController) {
            [sheet dismissViewControllerAnimated:YES completion:begin];
        } else {
            begin();
        }
    });
}

// Insert beside the existing save command, including when native actions are
// grouped in inline submenus. Preserve the other actions and their handlers.
static BOOL ApolloSaveAllInsertBesideSave(NSMutableArray<UIMenuElement *> *children, UIAction *action) {
    for (NSUInteger index = 0; index < children.count; index++) {
        UIMenuElement *element = children[index];
        if ([element isKindOfClass:UIAction.class]) {
            if ([((UIAction *)element).identifier isEqual:kApolloSaveAllIdentifier]) return YES;
            if ([element.title isEqualToString:@"Save Image"] ||
                [element.title isEqualToString:@"Save Video"] ||
                [element.title isEqualToString:@"Save GIF"]) {
                [children insertObject:action atIndex:index + 1];
                return YES;
            }
        } else if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *menu = (UIMenu *)element;
            NSMutableArray *nested = [menu.children mutableCopy];
            if (ApolloSaveAllInsertBesideSave(nested, action)) {
                children[index] = [menu menuByReplacingChildren:nested];
                return YES;
            }
        }
    }
    return NO;
}

static UIAction *ApolloSaveAllAction(dispatch_block_t perform) {
    return [UIAction actionWithTitle:kApolloSaveAllTitle
                              image:ApolloActionMenuSymbolIcon(@"square.and.arrow.down.on.square")
                         identifier:kApolloSaveAllIdentifier
                            handler:^(__unused UIAction *action) { perform(); }];
}

static ApolloSaveAllMenuContext *sApolloSaveAllArmedContext;
static CFTimeInterval sApolloSaveAllArmedAt;
static ApolloSaveAllMenuContext *sApolloSaveAllConfigContext;

// Full-screen image menus share Apollo's native handlers. Capture the native
// controllers at menu creation so a later page change cannot change the image
// being copied or saved. Videos/GIFs keep their existing download menus.
static NSUInteger sApolloFullScreenNativeMenuBuild;
static char kApolloFullScreenImageMenuKey;

// UIKit's _UIClickPresentationInteraction uses this generator's preview event
// when a context-menu hold is recognized. It is a distinct pattern, not a
// UIImpactFeedbackStyle. Verified in UIKit 26.5 disassembly and 27.1 runtime:
// the platform metrics and this generator use the same previewedPattern.
@protocol ApolloMediaMenuFeedback <NSObject>
- (instancetype)initWithView:(UIView *)view;
- (void)userInteractionStarted;
- (void)previewedAtLocation:(CGPoint)location;
- (void)userInteractionEnded;
- (void)userInteractionCancelled;
@end

static char kApolloFullScreenHoldFeedbackKey;
static void ApolloFullScreenMediaHoldFeedback(UIGestureRecognizer *recognizer) {
    id<ApolloMediaMenuFeedback> feedback = objc_getAssociatedObject(recognizer, &kApolloFullScreenHoldFeedbackKey);
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (feedback || !recognizer.view.window) return;
        Class generator = NSClassFromString(@"_UIClickPresentationFeedbackGenerator");
        if ([generator instancesRespondToSelector:@selector(initWithView:)] &&
            [generator instancesRespondToSelector:@selector(userInteractionStarted)] &&
            [generator instancesRespondToSelector:@selector(previewedAtLocation:)] &&
            [generator instancesRespondToSelector:@selector(userInteractionEnded)] &&
            [generator instancesRespondToSelector:@selector(userInteractionCancelled)]) {
            feedback = [(id<ApolloMediaMenuFeedback>)[generator alloc] initWithView:recognizer.view];
        }
        if (feedback) {
            // Keep the generator active for the hold, as UIKit does. Releasing
            // it immediately can cut short asynchronously delivered feedback.
            objc_setAssociatedObject(recognizer, &kApolloFullScreenHoldFeedbackKey, feedback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [feedback userInteractionStarted];
            [feedback previewedAtLocation:[recognizer locationInView:recognizer.view]];
        } else {
            // Older/future UIKit versions may not expose the native generator.
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy] impactOccurred];
        }
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        if (recognizer.state == UIGestureRecognizerStateEnded) [feedback userInteractionEnded];
        else [feedback userInteractionCancelled];
        objc_setAssociatedObject(recognizer, &kApolloFullScreenHoldFeedbackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The actions-only video/GIF menu has no preview platter to drag. Give its
// own background a pan recognizer; never attach it to the viewer or window,
// where the same swipe could also dismiss the underlying full-screen media.
static char kApolloMediaMenuDismissalKey;
static id ApolloMediaMenuObject(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

@interface ApolloMediaMenuDismissal : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIContextMenuInteraction *interaction;
@property (nonatomic, weak) UIView *background;
@property (nonatomic, weak) UIView *menuView;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic) BOOL ended;
- (void)install;
- (void)invalidate;
@end
@implementation ApolloMediaMenuDismissal
- (void)install {
    if (self.ended || self.pan) return;
    id presentations = ApolloMediaMenuObject(self.interaction, @"presentationsByIdentifier");
    if (![presentations isKindOfClass:NSDictionary.class] || [presentations count] != 1) return;
    id controller = ApolloMediaMenuObject([presentations allValues].firstObject, @"uiController");
    UIView *menu = ApolloMediaMenuObject(controller, @"menuView");
    if (![menu isKindOfClass:UIView.class]) return;
    Class containerClass = NSClassFromString(@"_UIContextMenuContainerView");
    UIView *background = menu.superview;
    while (background && ![background isKindOfClass:containerClass]) background = background.superview;
    if (!background.window) return;
    self.background = background;
    self.menuView = menu;
    self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];
    self.pan.maximumNumberOfTouches = 1;
    self.pan.delegate = self;
    [background addGestureRecognizer:self.pan];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    // Keep menu-row selection, submenu navigation and scrolling native.
    return !self.ended && self.interaction && touch.view && self.menuView &&
        [touch.view isDescendantOfView:self.background] && ![touch.view isDescendantOfView:self.menuView];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // UIKit's platter pan can recognize even when it cannot dismiss an
    // actions-only menu. Let this background-only dismissal complete too.
    return !self.ended && other.view && [other.view isDescendantOfView:self.background];
}
- (void)swiped:(UIPanGestureRecognizer *)recognizer {
    if (!self.ended && recognizer.state == UIGestureRecognizerStateBegan) {
        [self.interaction dismissMenu];
    }
}
- (void)invalidate {
    self.ended = YES;
    [self.pan.view removeGestureRecognizer:self.pan];
    self.pan = nil;
}
- (void)dealloc {
    [_pan.view removeGestureRecognizer:_pan];
}
@end

@interface ApolloFullScreenImageMenu : NSObject
@property (nonatomic, weak) UIViewController *page;
@property (nonatomic, weak) UIViewController *viewer;
@property (nonatomic, weak) UIView *source;
@property (nonatomic, strong) id imageActions;
@property (nonatomic, strong) id shareActions;
@property (nonatomic, strong) ApolloSaveAllMenuContext *album;
@property (nonatomic) BOOL ended;
@property (nonatomic, copy) dispatch_block_t pending;
@end
@implementation ApolloFullScreenImageMenu
@end

static UIViewController *ApolloFullScreenCurrentViewer(UIViewController *page) {
    if (![page isKindOfClass:UIPageViewController.class]) return nil;
    UIViewController *viewer = ((UIPageViewController *)page).viewControllers.firstObject;
    return [viewer isKindOfClass:NSClassFromString(@"Apollo.MediaViewerController")] ? viewer : nil;
}

static ApolloFullScreenImageMenu *ApolloFullScreenImageContext(UIViewController *page, UIView *source) {
    UIViewController *viewer = ApolloFullScreenCurrentViewer(page);
    id imageView = ApolloSaveAllObjectIvar(viewer, "imageView");
    if (!viewer || ApolloSaveAllObjectIvar(viewer, "player") ||
        ![imageView isKindOfClass:UIImageView.class] || !((UIImageView *)imageView).image) return nil;
    SEL animated = NSSelectorFromString(@"animatedImage");
    if ([imageView respondsToSelector:animated] && ((id (*)(id, SEL))objc_msgSend)(imageView, animated)) return nil;
    ApolloFullScreenImageMenu *context = [ApolloFullScreenImageMenu new];
    context.page = page;
    context.viewer = viewer;
    context.source = source ?: page.view;
    context.album = ApolloSaveAllContextForPage(page);
    sApolloFullScreenNativeMenuBuild++;
    @try {
        context.imageActions = ApolloNativeActionMenuCaptureController(context.source, ^{
            ((void (*)(id, SEL, id))objc_msgSend)(page, @selector(moreButtonTapped:), context.source);
        });
        if (context.album) {
            context.shareActions = ApolloNativeActionMenuCaptureController(context.source, ^{
                ((void (*)(id, SEL, id))objc_msgSend)(page, @selector(shareButtonTappedWithSender:), context.source);
            });
        }
    } @finally { sApolloFullScreenNativeMenuBuild--; }
    if (!ApolloNativeActionMenuHasAction(context.imageActions, 26) ||
        !ApolloNativeActionMenuHasAction(context.imageActions, 100)) return nil;
    return context;
}

static UIAction *ApolloFullScreenImageAction(NSString *title, NSString *symbol,
                                             ApolloFullScreenImageMenu *context, dispatch_block_t perform) {
    return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil
        handler:^(__unused UIAction *action) {
            // Programmatic menus use the shared presenter's completion; held
            // menus use the viewer delegate's completion. Neither may present
            // another menu/share sheet while UIKit is still dismissing this one.
            dispatch_block_t retained = ^{
                if (context.page.viewIfLoaded.window) perform();
            };
            if (ApolloNativeActionMenuPerformAfterDismissal(context, retained)) return;
            if (context.ended) dispatch_async(dispatch_get_main_queue(), retained);
            else context.pending = perform;
        }];
}

static void ApolloFullScreenShareImage(ApolloFullScreenImageMenu *context) {
    if (ApolloNativeActionMenuHasAction(context.shareActions, 27)) {
        ApolloNativeActionMenuInvokeAction(context.shareActions, 27);
    } else if (context.page.viewIfLoaded.window && ApolloFullScreenCurrentViewer(context.page) == context.viewer) {
        // A single image's native share button prepares the system share sheet.
        // Both long-press Share and the chooser's Share Image use this path.
        sApolloFullScreenNativeMenuBuild++;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(context.page, @selector(shareButtonTappedWithSender:), context.source); }
        @finally { sApolloFullScreenNativeMenuBuild--; }
    }
}

static UIMenu *ApolloFullScreenImageMenuBuild(ApolloFullScreenImageMenu *context, BOOL sharing) {
    __weak ApolloFullScreenImageMenu *weakContext = context;
    NSMutableArray *actions = [NSMutableArray array];
    if (sharing) {
        [actions addObject:ApolloFullScreenImageAction(@"Share Image", @"square.and.arrow.up", context, ^{
            ApolloFullScreenShareImage(weakContext);
        })];
    } else {
        [actions addObject:ApolloFullScreenImageAction(@"Copy Image", @"doc.on.doc", context, ^{
            ApolloNativeActionMenuInvokeAction(weakContext.imageActions, 100);
        })];
    }
    [actions addObject:ApolloFullScreenImageAction(@"Save Image", @"square.and.arrow.down", context, ^{
        ApolloNativeActionMenuInvokeAction(weakContext.imageActions, 26);
    })];
    if (context.album) {
        [actions addObject:ApolloFullScreenImageAction(kApolloSaveAllTitle, @"square.and.arrow.down.on.square", context, ^{
            ApolloSaveAllBegin(weakContext.album);
        })];
    }
    if (sharing) {
        if (ApolloNativeActionMenuHasAction(context.shareActions, 19)) {
            [actions addObject:ApolloFullScreenImageAction(@"Share Album Link", @"link", context, ^{
                ApolloNativeActionMenuInvokeAction(weakContext.shareActions, 19);
            })];
        }
    } else {
        [actions addObject:ApolloFullScreenImageAction(@"Share", @"square.and.arrow.up", context, ^{
            ApolloFullScreenShareImage(weakContext);
        })];
    }
    return [UIMenu menuWithTitle:@"" children:actions];
}

static void ApolloFullScreenShowShareMenu(ApolloFullScreenImageMenu *context) {
    if (!context.page.viewIfLoaded.window) return;
    context.ended = NO;
    UIView *source = ApolloSaveAllObjectIvar(context.page, "shareButton") ?: context.source;
    __weak ApolloFullScreenImageMenu *weakContext = context;
    ApolloNativeActionMenuPresentCaptured(ApolloFullScreenImageMenuBuild(context, YES), source, context, ^{
        weakContext.ended = YES;
    });
}

static UIMenu *ApolloFullScreenWithoutSharing(UIMenu *menu) {
    NSMutableArray *children = [NSMutableArray array];
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *nested = ApolloFullScreenWithoutSharing((UIMenu *)element);
            if (nested.children.count) [children addObject:nested];
        } else if (![element.title isEqualToString:@"Share"] && ![element.title isEqualToString:@"Share Album Link"]) {
            [children addObject:element];
        }
    }
    return [menu menuByReplacingChildren:children];
}

%hook _TtC6Apollo23MediaPageViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sApolloSaveAllVisiblePage = (UIViewController *)self;
}
- (void)moreButtonTapped:(id)sender {
    if (sApolloFullScreenNativeMenuBuild) {
        %orig;
        return;
    }
    sApolloSaveAllArmedContext = ApolloSaveAllContextForPage((UIViewController *)self);
    sApolloSaveAllArmedAt = CACurrentMediaTime();
    UIView *source = [sender isKindOfClass:UIView.class] ? sender : ((UIViewController *)self).view;
    id controller = ApolloNativeActionMenuCaptureController(source, ^{
        %orig;
    });
    if (controller) {
        UIMenu *menu = ApolloFullScreenWithoutSharing(ApolloNativeActionMenuBuildCaptured(controller));
        if (ApolloNativeActionMenuPresentCaptured(menu, source, controller, nil)) return;
    }
    %orig;
}
- (void)shareButtonTappedWithSender:(id)sender {
    if (sApolloFullScreenNativeMenuBuild) {
        %orig;
        return;
    }
    UIView *source = [sender isKindOfClass:UIView.class] ? sender : ((UIViewController *)self).view;
    ApolloFullScreenImageMenu *context = ApolloFullScreenImageContext((UIViewController *)self, source);
    if (!context) {
        %orig;
        return;
    }
    ApolloFullScreenShowShareMenu(context);
}
%end

// Feed media and the comments header both enter the native image-share flow.
// Capture the post at gesture time; reading a recycled cell after JPEG
// preparation could otherwise save a different post's collection.
%hook _TtC6Apollo13RichMediaNode
- (void)longPressedWithGestureRecognizer:(UIGestureRecognizer *)recognizer {
    ApolloSaveAllArmInlineShare(self, recognizer);
    %orig;
}
%end

%hook _TtC6Apollo23RichMediaHeaderCellNode
- (void)longPressedWithGestureRecognizer:(UIGestureRecognizer *)recognizer {
    ApolloSaveAllArmInlineShare(self, recognizer);
    %orig;
}
%end

%hook _TtC6Apollo21MediaViewerController
- (void)scrollViewLongPressed:(UIGestureRecognizer *)recognizer {
    // Only the legacy gesture needs explicit feedback. Real context-menu
    // interactions already play UIKit's native pattern themselves.
    ApolloFullScreenMediaHoldFeedback(recognizer);
    UIViewController *page = ApolloSaveAllPageForController((UIViewController *)self);
    ApolloFullScreenImageMenu *context = ApolloFullScreenImageContext(page, recognizer.view);
    if (!context) {
        %orig;
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        __weak ApolloFullScreenImageMenu *weakContext = context;
        ApolloNativeActionMenuPresentCaptured(ApolloFullScreenImageMenuBuild(context, NO), recognizer.view, context, ^{
            weakContext.ended = YES;
        });
    }
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    ApolloFullScreenImageMenu *image = ApolloFullScreenImageContext(
        ApolloSaveAllPageForController((UIViewController *)self), interaction.view);
    if (image) {
        UIContextMenuConfiguration *config = [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
            actionProvider:^UIMenu *(__unused NSArray *suggested) { return ApolloFullScreenImageMenuBuild(image, NO); }];
        objc_setAssociatedObject(config, &kApolloFullScreenImageMenuKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return config;
    }
    ApolloSaveAllMenuContext *previous = sApolloSaveAllConfigContext;
    sApolloSaveAllConfigContext = ApolloSaveAllContextForPage(ApolloSaveAllPageForController((UIViewController *)self));
    UIContextMenuConfiguration *configuration = %orig;
    sApolloSaveAllConfigContext = previous;
    return configuration;
}

// Install after UIKit creates the overlay, and cancel installation if the
// menu closes before its presentation animation finishes.
%new
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    ApolloMediaMenuDismissal *dismissal = [ApolloMediaMenuDismissal new];
    dismissal.interaction = interaction;
    objc_setAssociatedObject(configuration, &kApolloMediaMenuDismissalKey, dismissal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [dismissal install];
    if (animator) [animator addCompletion:^{ [dismissal install]; }];
}

// Apollo has no implementation of this optional delegate method. Read the
// deferred action IN the animator completion: UIKit may call willEnd before
// the selected UIAction's handler has run.
%new
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    ApolloMediaMenuDismissal *dismissal = objc_getAssociatedObject(configuration, &kApolloMediaMenuDismissalKey);
    [dismissal invalidate];
    objc_setAssociatedObject(configuration, &kApolloMediaMenuDismissalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloFullScreenImageMenu *image = objc_getAssociatedObject(configuration, &kApolloFullScreenImageMenuKey);
    if (image) {
        dispatch_block_t finish = ^{
            image.ended = YES;
            dispatch_block_t pending = image.pending;
            image.pending = nil;
            if (pending) pending();
        };
        if (animator) [animator addCompletion:finish];
        else dispatch_async(dispatch_get_main_queue(), finish);
        return;
    }
    ApolloSaveAllMenuContext *context = objc_getAssociatedObject(configuration, &kApolloSaveAllMenuContextKey);
    if (!context) return;
    dispatch_block_t finish = ^{
        context.menuEnded = YES;
        dispatch_block_t action = context.afterDismissal;
        context.afterDismissal = nil;
        if (action) action();
    };
    if (animator) [animator addCompletion:finish];
    else dispatch_async(dispatch_get_main_queue(), finish);
}
%end

%hook UIContextMenuConfiguration
+ (instancetype)configurationWithIdentifier:(id)identifier previewProvider:(id)previewProvider actionProvider:(UIMenu *(^)(NSArray<UIMenuElement *> *))actionProvider {
    ApolloSaveAllMenuContext *context = sApolloSaveAllConfigContext;
    if (!context || !actionProvider) return %orig;
    UIMenu *(^originalProvider)(NSArray<UIMenuElement *> *) = [actionProvider copy];
    UIMenu *(^provider)(NSArray<UIMenuElement *> *) = ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIMenu *menu = originalProvider(suggested);
        if (!menu) return menu;
        NSMutableArray *children = [menu.children mutableCopy];
        UIAction *action = ApolloSaveAllAction(^{
            if (context.menuEnded) ApolloSaveAllBegin(context);
            else {
                // Weak capture breaks context -> block -> context ownership.
                __weak ApolloSaveAllMenuContext *weakContext = context;
                context.afterDismissal = ^{ ApolloSaveAllBegin(weakContext); };
            }
        });
        if (!ApolloSaveAllInsertBesideSave(children, action)) [children addObject:action];
        return [menu menuByReplacingChildren:children];
    };
    id configuration = %orig(identifier, previewProvider, provider);
    objc_setAssociatedObject(configuration, &kApolloSaveAllMenuContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}
%end

// Apollo also opens the system share sheet when an image is held. Add an
// application activity, keeping the selected item's normal sharing intact.
@interface ApolloSaveAllActivity : UIActivity
@property (nonatomic, strong) ApolloSaveAllMenuContext *context;
@end
@implementation ApolloSaveAllActivity
+ (UIActivityCategory)activityCategory { return UIActivityCategoryAction; }
- (UIActivityType)activityType { return kApolloSaveAllIdentifier; }
- (NSString *)activityTitle { return kApolloSaveAllTitle; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"square.and.arrow.down.on.square"]; }
- (BOOL)canPerformWithActivityItems:(NSArray *)items { return self.context != nil; }
- (void)prepareWithActivityItems:(NSArray *)items {}
- (void)performActivity {
    ApolloLog(@"[SaveAllMedia] share activity selected");
    [self activityDidFinish:YES];
}
@end

%hook UIActivityViewController
- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    UIViewController *page = sApolloSaveAllVisiblePage;
    BOOL isMediaShare = NO;
    Class saveClass = objc_getClass("_TtC6Apollo17SaveMediaActivity");
    for (id activity in applicationActivities) {
        if ([activity isKindOfClass:ApolloSaveAllActivity.class]) return %orig;
        if (saveClass && [activity isKindOfClass:saveClass]) isMediaShare = YES;
    }
    ApolloSaveAllMenuContext *context = nil;
    if (isMediaShare) {
        ApolloSaveAllMenuContext *inlineContext = sApolloSaveAllInlineShareContext;
        sApolloSaveAllInlineShareContext = nil;
        if (inlineContext && CACurrentMediaTime() - sApolloSaveAllInlineShareAt <= kApolloSaveAllInlineShareGrace &&
            inlineContext.presenter.viewIfLoaded.window) {
            context = inlineContext;
        } else if (page.viewIfLoaded.window) {
            context = ApolloSaveAllContextForPage(page);
        }
    }
    if (!context) return %orig;
    ApolloSaveAllActivity *activity = [ApolloSaveAllActivity new];
    activity.context = context;
    NSMutableArray *activities = [applicationActivities mutableCopy] ?: [NSMutableArray array];
    [activities addObject:activity];
    id controller = %orig(activityItems, activities);
    objc_setAssociatedObject(controller, &kApolloSaveAllShareContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Ensure a callback exists even if Apollo doesn't install one. The setter
    // hook below also wraps any handler Apollo supplies after initialization.
    UIActivityViewController *sheet = controller;
    UIActivityViewControllerCompletionWithItemsHandler completion = sheet.completionWithItemsHandler;
    sheet.completionWithItemsHandler = completion ?: ^(__unused UIActivityType type, __unused BOOL completed,
                                                       __unused NSArray *items, __unused NSError *error) {};
    return controller;
}
- (void)setCompletionWithItemsHandler:(UIActivityViewControllerCompletionWithItemsHandler)completion {
    ApolloSaveAllMenuContext *context = objc_getAssociatedObject(self, &kApolloSaveAllShareContextKey);
    // UIKit clears this property as part of completion. Passing nil through
    // avoids reinstalling a handler while the system is tearing the sheet down.
    if (!context || !completion) {
        %orig;
        return;
    }
    UIActivityViewControllerCompletionWithItemsHandler nativeCompletion = [completion copy];
    __weak UIActivityViewController *weakSheet = (UIActivityViewController *)self;
    UIActivityViewControllerCompletionWithItemsHandler wrapped = ^(UIActivityType type, BOOL completed,
                                                                   NSArray *items, NSError *error) {
        nativeCompletion(type, completed, items, error);
        if (completed && !error && [type isEqualToString:kApolloSaveAllIdentifier]) {
            ApolloSaveAllCompleteShare(weakSheet, context);
        }
    };
    %orig(wrapped);
}
%end

%ctor {
    %init;
    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"SaveAllMedia";
    spec.legacyDismissesSheet = YES;
    spec.matches = ^BOOL(id actionController, __unused NSString *title) {
        ApolloSaveAllMenuContext *context = sApolloSaveAllArmedContext;
        sApolloSaveAllArmedContext = nil;
        if (!context || CACurrentMediaTime() - sApolloSaveAllArmedAt > 1.5) return NO;
        objc_setAssociatedObject(actionController, &kApolloSaveAllMenuContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    };
    spec.title = ^NSString *(__unused id controller, __unused UITableViewCell *donor) { return kApolloSaveAllTitle; };
    spec.image = ^UIImage *(__unused id controller, __unused UITableViewCell *donor) {
        return ApolloActionMenuSymbolIcon(@"square.and.arrow.down.on.square");
    };
    spec.perform = ^(id controller) {
        ApolloSaveAllMenuContext *context = objc_getAssociatedObject(controller, &kApolloSaveAllMenuContextKey);
        dispatch_block_t save = ^{ ApolloSaveAllBegin(context); };
        if (!ApolloNativeActionMenuPerformAfterDismissal(controller, save)) save();
    };
    void (^perform)(id) = spec.perform;
    spec.buildElement = ^(id controller, NSMutableArray<UIMenuElement *> *children) {
        UIAction *action = ApolloSaveAllAction(^{ perform(controller); });
        if (!ApolloSaveAllInsertBesideSave(children, action)) [children addObject:action];
    };
    ApolloActionMenuRegister(spec);
    ApolloLog(@"[SaveAllMedia] native media menu hooks installed");
}
