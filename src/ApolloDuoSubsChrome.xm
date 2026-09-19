#import "ApolloDuoSubsChrome.h"
#import "ApolloCommon.h"

// RedditList-only hooks. Do not attach chrome writes to UIView or
// UITableView layoutSubviews — those paths already hung the Duo sim
// when they wrote layout inputs. viewDidLayout is idempotent.

%group ApolloDuoSubsChromeList

%hook _TtC6Apollo24RedditListViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoSubsChromeApply((UIViewController *)self);
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoSubsChromeApply((UIViewController *)self);
    }];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

%end

%end

%ctor {
    Class list = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!list) {
        ApolloLog(@"[DuoSubsChrome] RedditListViewController missing; chrome inactive");
        return;
    }
    %init(ApolloDuoSubsChromeList);
    ApolloLog(@"[DuoSubsChrome] hook installed (Duo title/Edit/+ only)");
}
