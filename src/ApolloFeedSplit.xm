// ApolloFeedSplit.xm
//
// Architecture reset (open Duo v1): Mail-style dual-VC hosting and
// continuous Apply / midX frame clamps are **disabled**. They caused
// overscroll ghosts, skippy comments scroll, and portrait breakage.
//
// Compact / cover / ordinary iPhone: this file installs no nav hooks,
// so stock push/pop and layout stay untouched.
// Open Duo: ApolloDuoRail is the chrome. Navigation is stock
// UINavigationController (popToRoot for Subs). Do not reintroduce
// viewDidLayout re-pinning, SetPrimaryAlongside, or stack surgery.
//
// UISplitViewController / UIArrangementViewController were considered
// and rejected for v1 — wrapping a tab's ApolloNavigationController
// breaks settings, floating tabs, swipe-up comments, and URL routing
// that treat tab.selectedViewController as that nav.

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloDuoRail.h"
#import "ApolloFeedSplitLayout.h"

extern "C" BOOL ApolloFeedSplitEnabled(void) {
    return NO;
}

extern "C" BOOL ApolloFeedSplitForceTiledActive(void) {
    return NO;
}

extern "C" void ApolloFeedSplitForceTiledForSeconds(NSTimeInterval seconds) {
    (void)seconds;
}

extern "C" void ApolloFeedSplitReapplyVisible(void) {
}

extern "C" void ApolloFeedSplitReapplySoon(void) {
}

// Subs rail: stock directory. RedditList is the Posts-tab root.
extern "C" void ApolloFeedSplitShowSubredditPicker(UINavigationController *nav) {
    ApolloDuoRailSetPickingSubreddits(YES);
    if (!nav) {
        ApolloLog(@"[FeedSplit] directory skipped (no posts nav; tiling disabled)");
        return;
    }
    if (nav.viewControllers.count > 1) {
        [nav popToRootViewControllerAnimated:NO];
    }
    ApolloLog(@"[FeedSplit] stock directory (popToRoot; tiling disabled)");
}

%ctor {
    ApolloLog(@"[FeedSplit] tiling disabled — rail + stock nav (no column pin)");
}
