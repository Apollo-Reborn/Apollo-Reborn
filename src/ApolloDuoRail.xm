#import "ApolloDuoRail.h"
#import "ApolloCommon.h"

// Keep the rail attached to Apollo's tab controller across scene activate,
// rotation, and size-class changes. Compact hides it and restores the tab bar.
// UITableView: native A–Z index sits on bounds.maxX and would land in the
// Duo status gutter beside the time/Wi-Fi pill — pin it onto the list.
// Comments: cover Compact nudges the jump FAB off Duo's system gear from
// every CommentsViewController-named class, not only the primary one.

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

%group ApolloDuoRailTabs

%hook _TtC6Apollo22ApolloTabBarController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoRailSync();
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoRailSync();
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    ApolloDuoRailSync();
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoRailSync();
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoRailSync();
    }];
}

%end

%end

%hook UITableView

- (void)layoutSubviews {
    %orig;
    if (ApolloDuoRailIsActive()) {
        ApolloDuoRailPinSectionIndex((UITableView *)self);
    }
}

%end

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (ApolloDuoCoverChromeIsActive()) {
        ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
    }
    if (ApolloDuoRailIsActive()) {
        const char *name = class_getName(self.class);
        if (name && strstr(name, "ApolloNavigationController")) {
            ApolloDuoRailFillOpenContent();
        }
    }
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (ApolloDuoCoverChromeIsActive()) {
        ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (ApolloDuoCoverChromeIsActive()) {
        ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
    }
    if (ApolloDuoRailIsActive()) {
        ApolloDuoRailFillOpenContent();
    }
}

%end

%ctor {
    %init;
    Class tabs = objc_getClass("_TtC6Apollo22ApolloTabBarController");
    if (!tabs) {
        ApolloLog(@"[DuoRail] ApolloTabBarController missing; rail inactive");
        return;
    }
    %init(ApolloDuoRailTabs);
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoRailSync();
    }];
    ApolloLog(@"[DuoRail] hook installed (inner rail under status; cover FABs; fill letterbox)");
}
