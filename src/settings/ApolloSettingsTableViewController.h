#import <UIKit/UIKit.h>

// Apollo's in-app slider overrides the system category only inside settings.
#ifdef __cplusplus
extern "C" {
#endif
UIColor *ApolloSettingsPrimaryTextColor(void);
UIFont *ApolloSettingsFont(UIFontTextStyle style, UITraitCollection *traits);
void ApolloSettingsApplyCellTypography(UITableViewCell *cell);
#ifdef __cplusplus
}
#endif

@interface ApolloSettingsTableViewController : UITableViewController
- (UITableView *)apollo_sourceThemeTableView;
- (UIColor *)apollo_themeCellBackgroundColor;
- (UIColor *)apollo_themeAccentColor;
- (void)apollo_applyPrimaryTextColorToCell:(UITableViewCell *)cell;
- (void)apollo_applyAccentActionTextColorToCell:(UITableViewCell *)cell;
- (void)apollo_applyThemeToCell:(UITableViewCell *)cell;
- (void)apollo_applyTheme;
@end

@interface ApolloFooterLinkTextView : UITextView
@end

@interface ApolloSettingsLinkFooterView : UITableViewHeaderFooterView
@property (nonatomic, strong, readonly) ApolloFooterLinkTextView *linkTextView;
@end
