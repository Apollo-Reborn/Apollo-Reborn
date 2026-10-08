#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Shared native glass owner on iOS 26 and 27.
FOUNDATION_EXPORT UIView * _Nullable ApolloExpandedTabBarPlatter(UITabBar *tabBar);
FOUNDATION_EXPORT CGRect ApolloCompactNativePlatterBounds(UIView *platter, CGRect proposedBounds);
FOUNDATION_EXPORT CGPoint ApolloCompactNativePlatterCenter(UIView *platter, CGPoint proposedCenter);
FOUNDATION_EXPORT CGRect ApolloCompactNativeItemBounds(UIView *view, CGRect proposedBounds);
FOUNDATION_EXPORT CGPoint ApolloCompactNativeItemCenter(UIView *view, CGPoint proposedCenter);
FOUNDATION_EXPORT CGRect ApolloCompactNativeItemFrame(UIView *view, CGRect proposedFrame);
FOUNDATION_EXPORT CGFloat ApolloCompactNativeItemAlpha(UIView *view, CGFloat proposedAlpha);
FOUNDATION_EXPORT void ApolloInstallMinimizeItemGeometryHooks(Class buttonClass, Class lensClass, Class maskClass);

// Name-only compact tab bar. Its owner supplies the frame, transition, and
// expanded touch target; UIControlEventTouchUpInside requests expansion.
@interface ApolloCompactTabBarView : UIControl

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) CGFloat titleAlpha;
@property (nonatomic, assign) CGFloat expansionProgress; // 0 = compact, 1 = expanded
@property (nonatomic, readonly) CGRect expandedFrame;

- (CGSize)compactSize;
- (BOOL)prepareNativeTabBar:(UITabBar *)tabBar;
- (BOOL)ownsNativeTabBar:(UITabBar *)tabBar;
- (void)applyNativeFrame:(CGRect)frame expansionProgress:(CGFloat)progress;
- (void)restoreNativeTabBar;

@end

NS_ASSUME_NONNULL_END
