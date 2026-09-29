#pragma once

#import <UIKit/UIKit.h>

// Device builds still support the iOS 26 SDK and iOS 14 deployment floor.
// Declare the public 27.1 toolbar API when that SDK cannot see it; UIKit
// supplies the implementation. Every use must remain availability-guarded.
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 270100
typedef NS_ENUM(NSInteger, UIBarButtonItemAxisBehavior) {
    UIBarButtonItemAxisBehaviorAutomatic = 0,
    UIBarButtonItemAxisBehaviorHorizontalOnly = 1,
    UIBarButtonItemAxisBehaviorVerticalPreferred = 2,
} API_AVAILABLE(ios(27.1));

@interface UIBarButtonItem (ApolloDuoUIKitCompatibility)
@property (nonatomic, assign) UIBarButtonItemAxisBehavior axisBehavior API_AVAILABLE(ios(27.1));
@end
#endif
