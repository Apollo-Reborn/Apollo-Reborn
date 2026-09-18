// ApolloMediaHinge.xm
//
// Architecture reset: MediaViewer is stock full-screen again. Trailing-half
// frame pins left ghosts after dismiss and fought the old FeedSplit tile.
// reservedRegions stays unused (SIGSEGV on Duo even with window+scene).
// Close-button chrome still uses safe-area + layout-margin extras only.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloDeviceReservedRegions.h"

static id ApolloMediaHingeIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static void ApolloMediaHingeAvoidPageChrome(UIViewController *page) {
    if (!page.isViewLoaded) return;
    UIView *close = ApolloMediaHingeIvar(page, "closeButton");
    if ([close isKindOfClass:[UIView class]]) {
        ApolloDeviceAvoidReservedRegionsForView(close);
    }
}

%hook _TtC6Apollo23MediaPageViewController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMediaHingeAvoidPageChrome((UIViewController *)self);
}

%end

%ctor {
    Class page = objc_getClass("_TtC6Apollo23MediaPageViewController");
    if (!page) {
        ApolloLog(@"[MediaHinge] MediaPageViewController missing; viewer chrome skip");
        return;
    }
    %init;
    ApolloLog(@"[MediaHinge] stock fullscreen viewer (no Duo trailing pin)");
}
