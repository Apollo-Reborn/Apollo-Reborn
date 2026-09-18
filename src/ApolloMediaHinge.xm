// ApolloMediaHinge.xm
//
// Keep Apollo's fullscreen MediaPage chrome (close button and anything that
// mirrors it) off an iOS 27.1 reserved region. Stock MediaViewer is a single
// full-bleed pager — wrapping it in UIArrangementViewController would break
// presentation, swipe-up comments, and PiP — so we query reservedRegions at
// runtime and no-op on older SDKs.

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
    ApolloLog(@"[MediaHinge] MediaPage chrome hinge avoidance installed");
}
