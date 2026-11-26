#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

// A Foundation-only delegate harness: execute the production hook methods,
// leaving UIKit layout/appearance verification to the simulator.
static BOOL duo;
static BOOL __attribute__((unused)) ApolloDeviceIsDuo(void) { return duo; }
static const CGFloat UITableViewAutomaticDimension = -1;
static const NSInteger NSLineBreakByWordWrapping = 0;
@interface UIView : NSObject @end
@implementation UIView @end
@interface UITableView : UIView @end
@implementation UITableView @end
@interface UILabel : UIView
@property NSInteger numberOfLines;
@property NSInteger lineBreakMode;
@property BOOL adjustsFontForContentSizeCategory;
@property BOOL nativeThemeApplied;
@end
@implementation UILabel @end
@interface UITableViewHeaderFooterView : UIView
@property UILabel *textLabel;
@end
@implementation UITableViewHeaderFooterView @end

@interface NativePortraitLockController : NSObject
@property NSArray *explanations;
@property UIView *customFooter;
@property NSUInteger nativeViewCalls;
@property NSUInteger nativeHeightCalls;
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section;
- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section;
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section;
- (void)tableView:(UITableView *)table willDisplayFooterView:(UIView *)view forSection:(NSInteger)section;
@end
@implementation NativePortraitLockController
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    (void)table;
    id text = self.explanations[section];
    return text == NSNull.null ? nil : text;
}
- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    (void)table; (void)section;
    self.nativeViewCalls++;
    return self.customFooter;
}
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    (void)table; (void)section;
    self.nativeHeightCalls++;
    return 37;
}
- (void)tableView:(UITableView *)table willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    (void)table; (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class])
        ((UITableViewHeaderFooterView *)view).textLabel.nativeThemeApplied = YES;
}
@end
@interface SettingsPortraitLockViewController : NativePortraitLockController @end
// INCLUDE_PRODUCTION_HELPER
@implementation SettingsPortraitLockViewController
// INCLUDE_PRODUCTION_HOOKS
@end

int main(void) {
    @autoreleasepool {
        NSString *smart = @"Locks Apollo to portrait (vertical) orientation except for Media Viewer.";
        NSString *buddy = @"If using the iOS Portrait Orientation Lock feature, Apollo will attempt to detect device rotations in Media Viewer and offer to let you rotate media.";
        NSString *note = @"On iPhone Duo, this setting applies only to the cover display. Rotation offers are unavailable on the inner display.";
        SettingsPortraitLockViewController *vc = [SettingsPortraitLockViewController new];
        // Unrelated and missing sections, reordered and repeated originals: never indices.
        vc.explanations = @[@"Future unrelated explanation", buddy, NSNull.null, smart, buddy];
        vc.customFooter = [UIView new];
        UITableView *table = [UITableView new];
        for (NSNumber *capability in @[@NO, @YES]) {
            duo = capability.boolValue;
            for (NSInteger i = 0; i < (NSInteger)vc.explanations.count; i++) {
                id raw = vc.explanations[i];
                NSString *original = raw == NSNull.null ? nil : raw;
                BOOL targeted = duo && ([original isEqual:smart] || [original isEqual:buddy]);
                NSString *expected = targeted ? [original stringByAppendingFormat:@"\n\n%@", note] : original;
                NSString *actual = [vc tableView:table titleForFooterInSection:i];
                assert(actual == expected || [actual isEqual:expected]);
                NSUInteger views = vc.nativeViewCalls, heights = vc.nativeHeightCalls;
                assert([vc tableView:table viewForFooterInSection:i] == (targeted ? nil : vc.customFooter));
                assert([vc tableView:table heightForFooterInSection:i] == (targeted ? UITableViewAutomaticDimension : 37));
                assert(vc.nativeViewCalls == views + !targeted);
                assert(vc.nativeHeightCalls == heights + !targeted);
                UITableViewHeaderFooterView *footer = [UITableViewHeaderFooterView new];
                footer.textLabel = [UILabel new];
                footer.textLabel.numberOfLines = 1;
                footer.textLabel.lineBreakMode = 99;
                [vc tableView:table willDisplayFooterView:footer forSection:i];
                assert(footer.textLabel.nativeThemeApplied);
                assert(footer.textLabel.numberOfLines == (targeted ? 0 : 1));
                assert(footer.textLabel.lineBreakMode == (targeted ? NSLineBreakByWordWrapping : 99));
                assert(footer.textLabel.adjustsFontForContentSizeCategory == targeted);
                [vc tableView:table willDisplayFooterView:[UIView new] forSection:i]; // fail soft
            }
        }
        // Already annotated titles are stable, and near matches remain untouched.
        duo = YES;
        NSString *annotated = [smart stringByAppendingFormat:@"\n\n%@", note];
        vc.explanations = @[annotated, [smart stringByAppendingString:@" Changed."], @""];
        assert([[vc tableView:table titleForFooterInSection:0] isEqual:annotated]);
        assert([vc tableView:table viewForFooterInSection:0] == nil);
        for (NSInteger i = 1; i < 3; i++) {
            assert([[vc tableView:table titleForFooterInSection:i] isEqual:vc.explanations[i]]);
            assert([vc tableView:table viewForFooterInSection:i] == vc.customFooter);
        }
        // Repeated height queries model fold/rotation: no retained native bounds/height.
        for (NSUInteger n = 0; n < 4; n++)
            assert([vc tableView:table heightForFooterInSection:0] == UITableViewAutomaticDimension);
        puts("portrait lock settings: PASS (production footer delegate + capability/matching policy)");
    }
    return 0;
}
