#import "ApolloPaneGallery.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloGalleryViewController.h"
#import "../ApolloThemeRuntime.h"
#import "../ApolloCommon.h"
#import <objc/runtime.h>

static char kPaneGalleryHost;

@interface ApolloPaneGalleryHost : UIViewController
@property(nonatomic, strong) UINavigationController *galleryNavigation;
@property(nonatomic, weak) UIViewController *sourceController;
@property(nonatomic, weak) UIViewController *readerController;
@property(nonatomic, weak) ApolloPaneSplitViewController *pane;
- (void)closeGallery;
@end

@implementation ApolloPaneGalleryHost
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    self.view.accessibilityIdentifier = @"ApolloPaneFullWidthGallery";
    self.view.accessibilityViewIsModal = YES;
    [self addChildViewController:self.galleryNavigation];
    UIView *content = self.galleryNavigation.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.galleryNavigation didMoveToParentViewController:self];
    UIScreenEdgePanGestureRecognizer *back = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeBack:)];
    back.edges = UIRectEdgeLeft;
    [self.view addGestureRecognizer:back];
}

- (void)edgeBack:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded &&
        [gesture translationInView:self.view].x > 80) [self closeGallery];
}

- (void)closeGallery {
    if (!self.parentViewController) return;
    ApolloPaneSplitViewController *pane = self.pane;
    [self beginAppearanceTransition:NO animated:NO];
    [self willMoveToParentViewController:nil];
    [self.view removeFromSuperview];
    [self removeFromParentViewController];
    [self endAppearanceTransition];
    if (self.sourceController.navigationController.topViewController == self.sourceController) {
        [self.sourceController beginAppearanceTransition:YES animated:NO];
        [self.sourceController endAppearanceTransition];
    }
    if (self.readerController.navigationController.topViewController == self.readerController) {
        [self.readerController beginAppearanceTransition:YES animated:NO];
        [self.readerController endAppearanceTransition];
    }
    objc_setAssociatedObject(pane, &kPaneGalleryHost, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pane apollo_resolvedDisplayStateMayHaveChanged];
    ApolloLog(@"[PaneGallery] returned to preserved list/reader stacks");
}
@end

BOOL ApolloPanePresentGallery(UIViewController *controller, UINavigationController *source) {
    if (!ApolloPaneLayoutActive() || ![controller isKindOfClass:ApolloGalleryViewController.class]) return NO;
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(source);
    if (!pane || !pane.viewIfLoaded.window) return NO;
    ApolloPaneDismissGalleryForController(pane);

    ApolloPaneGalleryHost *host = [ApolloPaneGalleryHost new];
    host.pane = pane;
    host.sourceController = source.topViewController;
    UIViewController *reader = [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary].topViewController;
    if (reader != host.sourceController && reader.viewIfLoaded.window) host.readerController = reader;
    host.galleryNavigation = [[UINavigationController alloc] initWithRootViewController:controller];
    host.galleryNavigation.navigationBar.tintColor = ApolloThemeAccentColor();
    controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain
        target:host action:@selector(closeGallery)];
    controller.navigationItem.leftBarButtonItem.accessibilityLabel = @"Back to posts";
    controller.navigationItem.leftBarButtonItem.accessibilityIdentifier = @"ApolloPaneGalleryBack";
    objc_setAssociatedObject(pane, &kPaneGalleryHost, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host.sourceController beginAppearanceTransition:NO animated:NO];
    [host.sourceController endAppearanceTransition];
    // The reader remains in its original stack, but is covered just like a
    // navigation destination. Deliver disappearance so hidden media stops.
    [host.readerController beginAppearanceTransition:NO animated:NO];
    [host.readerController endAppearanceTransition];
    [pane addChildViewController:host];
    host.view.translatesAutoresizingMaskIntoConstraints = NO;
    [pane.view addSubview:host.view];
    // The native tab container owns sidebar/tab occlusion, including rotation
    // and its visibility animation. No column-width or tab-mode overrides.
    UILayoutGuide *guide = pane.view.safeAreaLayoutGuide;
    if (@available(iOS 26.0, *)) guide = pane.tabBarController.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [host.view.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [host.view.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [host.view.topAnchor constraintEqualToAnchor:guide.topAnchor],
        // Extend the opaque gallery through the home-indicator area. UIKit
        // still supplies its safe inset to the grid; the old feed must not
        // peek out below the content guide's safe bottom.
        [host.view.bottomAnchor constraintEqualToAnchor:pane.view.bottomAnchor]
    ]];
    [host didMoveToParentViewController:pane];
    [pane apollo_resolvedDisplayStateMayHaveChanged];
    ApolloLog(@"[PaneGallery] installed full-width gallery within native content guide");
    return YES;
}

void ApolloPaneDismissGalleryForController(UIViewController *controller) {
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(controller);
    ApolloPaneGalleryHost *host = objc_getAssociatedObject(pane, &kPaneGalleryHost);
    [host closeGallery];
}

BOOL ApolloPaneGalleryIsPresented(UIViewController *controller) {
    return objc_getAssociatedObject(ApolloPaneSplitControllerFor(controller), &kPaneGalleryHost) != nil;
}
