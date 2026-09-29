#import <UIKit/UIKit.h>

// Apollo's in-app slider overrides the system category only inside settings.
#ifdef __cplusplus
extern "C" {
#endif
UIColor *ApolloSettingsPrimaryTextColor(void);
UIFont *ApolloSettingsFont(UIFontTextStyle style, UITraitCollection *traits);
void ApolloSettingsApplyCellTypography(UITableViewCell *cell);
void ApolloSettingsApplySectionHeaderTypography(UIView *view);
// What -tableView:willDisplayFooterView:forSection: applies to every footer. A
// screen that sizes its own footer view applies it to the view it measures, so
// the height it answers is the height of the text as it is displayed.
void ApolloSettingsApplyFooterTypography(UIView *view);
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
