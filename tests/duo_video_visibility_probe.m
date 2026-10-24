#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface NSObject (ApolloVisibilityProbe)
- (UIView *)view;
- (BOOL)isVisibleInProperRect;
@end

void ApolloRunVideoVisibilityProbe(void) {
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    if (![window.rootViewController isKindOfClass:UITabBarController.class]) return;
    UITabBarController *tab = (UITabBarController *)window.rootViewController;
    if (![tab.selectedViewController isKindOfClass:UINavigationController.class]) return;
    UINavigationController *nav = (UINavigationController *)tab.selectedViewController;
    CGRect navInWindow = [nav.navigationBar convertRect:nav.navigationBar.bounds toView:window];
    CGRect originalTabBounds = tab.tabBar.bounds;
    CGRect originalTabFrame = tab.tabBar.frame;
    CGRect content = CGRectMake(0, CGRectGetMaxY(navInWindow), window.bounds.size.width,
                                window.bounds.size.height - CGRectGetMaxY(navInWindow));
    id node = [NSClassFromString(@"ASVideoNode") new];
    UIView *video = [node view];
    UIView *container = [[UIView alloc] init];
    [window addSubview:container];
    [container addSubview:video];
    NSMutableArray *rows = [NSMutableArray array];
    for (CGFloat y = -150; y <= 450; y += 25) {
        container.frame = CGRectMake(30, y, 240, 200);
        // Keep the child's origin at zero, isolating the tab-bar bug from Apollo's
        // separate frame-versus-bounds conversion quirk.
        video.frame = CGRectMake(0, 0, 240, 200);
        CGRect rect = [video convertRect:video.bounds toView:window];
        CGRect visible = CGRectIntersection(rect, content);
        double fraction = CGRectIsNull(visible) ? 0 : visible.size.height / rect.size.height;
        BOOL native = [node isVisibleInProperRect];
        tab.tabBar.bounds = CGRectMake(originalTabBounds.origin.x, originalTabBounds.origin.y,
                                       originalTabBounds.size.width, 49);
        BOOL legacyHeightControl = [node isVisibleInProperRect];
        tab.tabBar.bounds = originalTabBounds;
        tab.tabBar.frame = originalTabFrame;
        [rows addObject:@{@"top":@(y), @"midY":@(CGRectGetMidY(rect)),
                          @"visibleFraction":@(fraction), @"nativeAllowsAutoplay":@(native),
                          @"controlWith49ptTabBar":@(legacyHeightControl)}];
    }
    [video removeFromSuperview];
    [container removeFromSuperview];
    NSDictionary *result = @{@"window":NSStringFromCGRect(window.bounds),
        @"navBarFrame":NSStringFromCGRect(nav.navigationBar.frame),
        @"navBarInWindow":NSStringFromCGRect(navInWindow),
        @"tabBarFrame":NSStringFromCGRect(originalTabFrame),
        @"tabBarBounds":NSStringFromCGRect(originalTabBounds),
        @"nativeRegionTop":@(CGRectGetMaxY(nav.navigationBar.frame)),
        @"nativeRegionBottom":@(window.bounds.size.height-originalTabBounds.size.height),
        @"rows":rows};
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/autoplay-visible-probe.json"];
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:path atomically:YES];
}

__attribute__((constructor)) static void StartApolloVisibilityProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloRunVideoVisibilityProbe(); });
}
