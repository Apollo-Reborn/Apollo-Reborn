#import "ApolloDuoRail.h"
#import "ApolloCommon.h"

// Keep the rail attached to Apollo's tab controller across scene activate,
// rotation, and size-class changes. Open-inner rail is leading and hides
// the tab bar. Closed portrait Duo and Compact restore the stock tab bar
// (no side rail). Cover Compact nudges the jump FAB off Duo's system gear.

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

@interface ASTableView : UITableView
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
        ApolloDuoRailApplyListInsets((UIScrollView *)self);
        ApolloDuoRailPinSectionIndex((UITableView *)self);
    }
}

%end

%group ApolloDuoRailTexture

// Texture feeds override layoutSubviews and ignore additionalSafeAreaInsets.
// Re-apply after %orig so vote chevrons / thumbnails stay right of the rail.
%hook ASTableView

- (void)layoutSubviews {
    %orig;
    if (ApolloDuoRailIsActive()) {
        ApolloDuoRailApplyListInsets((UIScrollView *)self);
    }
}

%end

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
    if (objc_getClass("ASTableView")) {
        %init(ApolloDuoRailTexture);
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoRailSync();
    }];
    ApolloLog(@"[DuoRail] hook installed (Open left 112pt rail; Closed/Phone stock tab bar)");
}
