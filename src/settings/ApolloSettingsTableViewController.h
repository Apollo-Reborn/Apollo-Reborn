#import <UIKit/UIKit.h>

// Apollo's in-app slider overrides the system category only inside settings.
#ifdef __cplusplus
extern "C" {
#endif
UIColor *ApolloSettingsPrimaryTextColor(void);
UIFont *ApolloSettingsFont(UIFontTextStyle style, UITraitCollection *traits);
void ApolloSettingsApplyCellTypography(UITableViewCell *cell);
void ApolloSettingsApplySectionHeaderTypography(UIView *view);
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
// The updates pass that lets the table take section title heights again after
// a theme font change restyled them (see -viewWillAppear:). The base runs it
// with the first row on screen kept in place; the form also measures its
// footers again in it.
- (void)apollo_takeSectionTitleHeights;
@end

@interface ApolloFooterLinkTextView : UITextView
@end
