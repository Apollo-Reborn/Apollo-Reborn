#import "settings/ApolloSettingsTableViewController.h"

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import <objc/runtime.h>

static char kApolloAccentActionCellKey;
static char kApolloPrimaryTextCellKey;

UIColor *ApolloSettingsPrimaryTextColor(void) {
    // Native settings and subreddit rows share Apollo's primary text palette:
    // notably Pure Black uses D0D1D6, not UIKit's bright white labelColor.
    return ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
}

static UITraitCollection *ApolloSettingsTextTraits(UITraitCollection *traits) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if ([defaults objectForKey:@"UseSystemTextSize"] &&
        ![defaults boolForKey:@"UseSystemTextSize"] &&
        [defaults objectForKey:@"ApolloCustomTextSize"]) {
        // Apollo persists one-based ApplicationTextSize raw values: 3 is
        // Medium (16pt Body), 4 is Large (17pt Body). Verified against
        // native Appearance rows while moving the slider; Swift's case
        // order alone does not establish its RawRepresentable values.
        NSArray *categories = @[
            UIContentSizeCategoryExtraSmall, UIContentSizeCategorySmall,
            UIContentSizeCategoryMedium, UIContentSizeCategoryLarge,
            UIContentSizeCategoryExtraLarge, UIContentSizeCategoryExtraExtraLarge,
            UIContentSizeCategoryExtraExtraExtraLarge,
            UIContentSizeCategoryAccessibilityMedium, UIContentSizeCategoryAccessibilityLarge,
            UIContentSizeCategoryAccessibilityExtraLarge,
            UIContentSizeCategoryAccessibilityExtraExtraLarge,
            UIContentSizeCategoryAccessibilityExtraExtraExtraLarge
        ];
        NSInteger raw = [defaults integerForKey:@"ApolloCustomTextSize"];
        if (raw >= 1 && raw <= (NSInteger)categories.count) category = categories[raw - 1];
    }
    return [UITraitCollection traitCollectionWithTraitsFromCollections:@[
        traits ?: UITraitCollection.currentTraitCollection,
        [UITraitCollection traitCollectionWithPreferredContentSizeCategory:category]
    ]];
}

UIFont *ApolloSettingsFont(UIFontTextStyle style, UITraitCollection *traits) {
    return [UIFont preferredFontForTextStyle:style
              compatibleWithTraitCollection:ApolloSettingsTextTraits(traits)];
}

static UIFont *ApolloSettingsSectionHeaderFont(UITraitCollection *traits) {
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
        compatibleWithTraitCollection:ApolloSettingsTextTraits(traits)];
}

static NSString *ApolloSettingsTitleCaseHeader(NSString *text) {
    return text.capitalizedString;
}

static char kApolloSettingsTitleUIKitColorKey;

// The label of a header or footer UIKit built from the section's title string.
static UILabel *ApolloSettingsPlainTitleLabel(UIView *view) {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return nil;
    UITableViewHeaderFooterView *titleView = (UITableViewHeaderFooterView *)view;
    return titleView.contentConfiguration ? nil : titleView.textLabel;
}

// Keeps the colour UIKit gave a title before the settings styling first
// touched it, so -apollo_restyleShownSectionTitles can start from the same
// place a newly displayed title does.
static void ApolloSettingsRememberTitleColor(UIView *view) {
    UILabel *label = ApolloSettingsPlainTitleLabel(view);
    if (label.textColor && !objc_getAssociatedObject(label, &kApolloSettingsTitleUIKitColorKey)) {
        objc_setAssociatedObject(label, &kApolloSettingsTitleUIKitColorKey, label.textColor,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The fonts the settings styling gives section headers and footers (see
// -tableView:willDisplayHeaderView:forSection: and the footer one). A theme
// font or text size change shows up here.
static NSString *ApolloSettingsSectionTitleFontKey(UITraitCollection *traits) {
    UIFont *header = nil;
    if (@available(iOS 26.0, *)) {
        header = ApolloSettingsSectionHeaderFont(traits);
    } else {
        header = ApolloSettingsFont(UIFontTextStyleCaption1, traits);
    }
    UIFont *footer = ApolloSettingsFont(UIFontTextStyleFootnote, traits);
    return [NSString stringWithFormat:@"%@ %.2f|%@ %.2f", header.fontName, header.pointSize,
                                      footer.fontName, footer.pointSize];
}

void ApolloSettingsApplySectionHeaderTypography(UIView *view) {
    // Older iOS versions retain their original casing, fonts, and theme setup.
    if (@available(iOS 26.0, *)) {} else { return; }
    ApolloSettingsRememberTitleColor(view);
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        // UIKit owns standard form headers. Configure their source of truth,
        // rather than only modifying labels that UIKit can recreate on update.
        if ([header.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
            UIListContentConfiguration *configuration = [(UIListContentConfiguration *)header.contentConfiguration copy];
            configuration.text = ApolloSettingsTitleCaseHeader(configuration.text);
            configuration.textProperties.font = ApolloSettingsSectionHeaderFont(view.traitCollection);
            configuration.textProperties.adjustsFontForContentSizeCategory = NO;
            configuration.textProperties.color = ApolloThemeSettingsSecondaryTextColor()
                ?: UIColor.secondaryLabelColor;
            header.contentConfiguration = configuration;
            return;
        }
        // Legacy title-based headers create their label lazily; force its
        // creation before walking subviews in willDisplayHeaderView.
        ApolloSettingsApplySectionHeaderTypography(header.textLabel);
    }
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        label.text = ApolloSettingsTitleCaseHeader(label.text);
        label.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
        label.font = ApolloSettingsSectionHeaderFont(view.traitCollection);
        label.adjustsFontForContentSizeCategory = NO;
    }
    for (UIView *child in view.subviews) ApolloSettingsApplySectionHeaderTypography(child);
}

static void ApolloSettingsApplyTextTypography(UIView *view) {
    // Only semantic text participates: fixed artwork/preview typography stays
    // with its owner. Keep the descriptor's family and weight, changing size
    // from the semantic style afresh so reuse never compounds the scale.
    if ([view isKindOfClass:UILabel.class] || [view isKindOfClass:UITextField.class] ||
        [view isKindOfClass:UITextView.class]) {
        id textView = view;
        // Match native primary text without recoloring accent, destructive,
        // disabled, or deliberately secondary labels.
        if ((![view isKindOfClass:UILabel.class] || [(UILabel *)view isEnabled]) &&
            [[textView textColor] isEqual:UIColor.labelColor]) {
            [textView setTextColor:ApolloSettingsPrimaryTextColor()];
        } else if ([[textView textColor] isEqual:UIColor.secondaryLabelColor]) {
            [textView setTextColor:ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor];
        }
        UIFont *font = [textView font];
        NSString *style = [font.fontDescriptor objectForKey:UIFontDescriptorTextStyleAttribute];
        if (style) {
            [textView setAdjustsFontForContentSizeCategory:NO];
            [textView setFont:[font fontWithSize:ApolloSettingsFont(style, view.traitCollection).pointSize]];
        }
    }
    for (UIView *child in view.subviews) ApolloSettingsApplyTextTypography(child);
}

// A plain header/footer's title label, then everything else in the view. The
// label is styled directly because UIKit attaches it to the view lazily: a view
// built for an update animation (a reloadSections: such as the form's
// -rebuildSectionContainingRowID:, or any batch update that rebuilds existing
// footers, the form's footer-height pass included) reaches willDisplay with its
// label still detached, so the subview walk alone skips it. That footer then
// kept UIKit's own size and colour while its siblings had the settings ones.
static void ApolloSettingsApplySectionTitleTypography(UIView *view, UIFontTextStyle style) {
    ApolloSettingsRememberTitleColor(view);
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
        label.font = ApolloSettingsFont(style, view.traitCollection);
        if (![label isDescendantOfView:view]) ApolloSettingsApplyTextTypography(label);
    }
    ApolloSettingsApplyTextTypography(view);
}

void ApolloSettingsApplyCellTypography(UITableViewCell *cell) {
    // UIKit's default cell labels are fixed 17pt, unlike Eureka's Body rows.
    // Subtitle cells retain their smaller secondary text hierarchy.
    UIFont *titleFont = cell.textLabel.font;
    if (![titleFont.fontDescriptor objectForKey:UIFontDescriptorTextStyleAttribute] &&
        fabs(titleFont.pointSize - 17.0) < 0.01) {
        UIFontDescriptor *descriptor = [titleFont.fontDescriptor fontDescriptorByAddingAttributes:@{
            UIFontDescriptorTextStyleAttribute: UIFontTextStyleBody
        }];
        cell.textLabel.font = [UIFont fontWithDescriptor:descriptor
            size:ApolloSettingsFont(UIFontTextStyleBody, cell.traitCollection).pointSize];
    }
    if (![cell.detailTextLabel.font.fontDescriptor objectForKey:UIFontDescriptorTextStyleAttribute]) {
        cell.detailTextLabel.font = ApolloSettingsFont(
            cell.detailTextLabel.font.pointSize < 17.0 ? UIFontTextStyleFootnote : UIFontTextStyleBody,
            cell.traitCollection);
    }
    ApolloSettingsApplyTextTypography(cell.contentView);
}

@interface ApolloSettingsTableViewController ()
@property (nonatomic, copy) NSString *apollo_lastTextSizeCategory;
// The section title fonts the table last took its heights with, and whether a
// pass to take new ones is queued (see -apollo_restyleShownSectionTitles).
@property (nonatomic, copy) NSString *apollo_sectionTitleFontKey;
@property (nonatomic) BOOL apollo_titleHeightPassPending;
@end

@implementation ApolloSettingsTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self apollo_applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
    [self apollo_restyleShownSectionTitles];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyTheme];
}

- (UITableView *)apollo_sourceThemeTableView {
    return ApolloInheritedSettingsThemeSourceTableView(self);
}

- (UIColor *)apollo_themeCellBackgroundColor {
    UITableView *source = [self apollo_sourceThemeTableView];
    if (!ApolloThemeSourceTableIsStale(source)) {
        for (UITableViewCell *cell in source.visibleCells) {
            UIColor *color = cell.backgroundColor ?: cell.contentView.backgroundColor;
            if (color) return color;
        }
    }
    return ApolloThemeCardBackgroundColor() ?: [UIColor secondarySystemGroupedBackgroundColor];
}

- (UIColor *)apollo_themeAccentColor {
    return ApolloThemeAccentColor() ?: self.view.tintColor ?: [UIColor systemBlueColor];
}

- (void)apollo_applyPrimaryTextColorToCell:(UITableViewCell *)cell {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kApolloPrimaryTextCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)apollo_applyAccentActionTextColorToCell:(UITableViewCell *)cell {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kApolloAccentActionCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if (!cell) return;

    ApolloSettingsApplyCellTypography(cell);

    UIColor *cellColor = [self apollo_themeCellBackgroundColor];
    cell.backgroundColor = cellColor;

    UIColor *accentColor = [self apollo_themeAccentColor];
    cell.tintColor = accentColor;
    if (cell.accessoryView) cell.accessoryView.tintColor = accentColor;

    for (UIView *subview in cell.contentView.subviews) {
        subview.tintColor = accentColor;
    }

    if ([objc_getAssociatedObject(cell, &kApolloAccentActionCellKey) boolValue]) {
        cell.textLabel.textColor = accentColor;
    } else if (cell.textLabel.enabled &&
               [objc_getAssociatedObject(cell, &kApolloPrimaryTextCellKey) boolValue]) {
        UIColor *primary = ApolloSettingsPrimaryTextColor();
        if (primary) cell.textLabel.textColor = primary;
    }
}

- (void)apollo_applyTheme {
    NSString *category = ApolloSettingsTextTraits(self.traitCollection).preferredContentSizeCategory;
    BOOL textSizeChanged = self.apollo_lastTextSizeCategory &&
        ![self.apollo_lastTextSizeCategory isEqualToString:category];
    self.apollo_lastTextSizeCategory = category;
    // Reload only after a size change, before table measurement. Ordinary
    // appearances must not discard in-progress text-field edits.
    if (textSizeChanged) [self.tableView reloadData];
    ApolloApplyInheritedSettingsTableTheme(self);

    UIColor *accentColor = [self apollo_themeAccentColor];
    self.view.tintColor = accentColor;
    self.tableView.tintColor = accentColor;
    self.navigationController.navigationBar.tintColor = accentColor;

    for (UITableViewCell *cell in self.tableView.visibleCells) {
        [self apollo_applyThemeToCell:cell];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (@available(iOS 26.0, *)) {
        ApolloSettingsApplySectionHeaderTypography(view);
    } else {
        ApolloSettingsApplySectionTitleTypography(view, UIFontTextStyleCaption1);
    }
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    ApolloSettingsApplySectionTitleTypography(view, UIFontTextStyleFootnote);
}

- (void)tableView:(UITableView *)__unused tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)__unused indexPath {
    [self apollo_applyThemeToCell:cell];
}

// Section headers and footers are styled once, as they're displayed (the
// willDisplay callbacks above), so the ones that were showing while the theme
// changed under a pushed screen (Theme Manager is one of the hub's Shortcuts)
// came back in the old theme's colour and font: a stock theme's colours have
// its values baked in, and a custom theme's keep resolving to its tokens after
// the runtime is switched off. Run the display styling again on the ones the
// table is showing, through the screen's own callbacks so a subclass's styling
// comes along. Cells get the same from -apollo_applyTheme.
- (void)apollo_restyleShownSectionTitles {
    UITableView *tableView = self.tableView;
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        for (NSUInteger footer = 0; footer < 2; footer++) {
            UITableViewHeaderFooterView *view = footer ? [tableView footerViewForSection:section]
                                                       : [tableView headerViewForSection:section];
            if (!view) continue;
            UILabel *label = ApolloSettingsPlainTitleLabel(view);
            UIFont *font = label.font;
            // The styling recolours a title only while it has the colour UIKit
            // gave it, so a title left in the old theme's colour would keep it.
            UIColor *uikitColor = objc_getAssociatedObject(label, &kApolloSettingsTitleUIKitColorKey);
            if (uikitColor) label.textColor = uikitColor;
            if (footer) {
                [self tableView:tableView willDisplayFooterView:view forSection:section];
            } else {
                [self tableView:tableView willDisplayHeaderView:view forSection:section];
            }
            if (label && ![label.font isEqual:font]) {
                // Measured later (the form's footer check reads -sizeThatFits:),
                // and a label still framed for the old font measures wrong.
                [view setNeedsLayout];
                [view layoutIfNeeded];
            }
        }
    }

    // The titles' heights follow their fonts, on screen or not, and the table
    // only takes new ones from an updates pass. The key is stored once a pass
    // has taken them, so a pass that didn't run (a cancelled swipe-back left
    // the screen covered) is asked for again next time. A colour-only theme
    // change keeps the key.
    NSString *fontKey = ApolloSettingsSectionTitleFontKey(self.traitCollection);
    if (!self.apollo_sectionTitleFontKey) {
        self.apollo_sectionTitleFontKey = fontKey;
    } else if (![fontKey isEqualToString:self.apollo_sectionTitleFontKey]) {
        [self apollo_scheduleSectionTitleHeightPass];
    }
}

// Once any transition is over (a pass during one gets its settle captured),
// on the next turn, so the transition's own completion work, the form's footer
// check included, has run.
- (void)apollo_scheduleSectionTitleHeightPass {
    if (self.apollo_titleHeightPassPending) return;
    self.apollo_titleHeightPassPending = YES;
    __weak typeof(self) weakSelf = self;
    void (^pass)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.apollo_titleHeightPassPending = NO;
        if (!strongSelf.tableView.window) return;
        // A transition that began since: wait for that one too. One that can't
        // take a completion anymore is ending, so go ahead (as the form's
        // footer check does).
        id<UIViewControllerTransitionCoordinator> current = strongSelf.transitionCoordinator;
        if (current && [current animateAlongsideTransition:nil
                                                completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            [weakSelf apollo_scheduleSectionTitleHeightPass];
        }]) {
            return;
        }
        NSString *fontKey = ApolloSettingsSectionTitleFontKey(strongSelf.traitCollection);
        if ([fontKey isEqualToString:strongSelf.apollo_sectionTitleFontKey]) return;
        strongSelf.apollo_sectionTitleFontKey = fontKey;
        ApolloLog(@"[SettingsForm] section title fonts changed with the theme — re-measuring");
        [strongSelf apollo_updateSectionTitleHeights];
    };
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator && [coordinator animateAlongsideTransition:nil
                                                   completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        dispatch_async(dispatch_get_main_queue(), pass);
    }]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), pass);
}

// After an updates pass UIKit puts the first row on screen back where it was,
// except when the top edge of the screen is inside a section footer: it then
// puts the list back against another row and the list jumps (the form's
// -performUpdateKeepingVisibleRowsInPlace: has the details). This pass adds
// and removes no rows, so note where the first row on screen sits and put that
// index path back there. At the top of the list UIKit keeps the list at the
// top, which is right: putting the row back there would push the header above
// it under the bars.
- (void)apollo_updateSectionTitleHeights {
    UITableView *tableView = self.tableView;
    CGFloat offsetY = tableView.contentOffset.y;
    CGFloat visibleTop = offsetY + tableView.adjustedContentInset.top;
    NSIndexPath *anchor = nil;
    CGFloat anchorOffset = 0.0;
    NSArray<NSIndexPath *> *visible = visibleTop > 0.5
        ? [tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)] : nil;
    for (NSIndexPath *indexPath in visible) {
        CGRect rect = [tableView rectForRowAtIndexPath:indexPath];
        if (CGRectGetMaxY(rect) <= visibleTop) continue;   // under the bars
        anchor = indexPath;
        anchorOffset = CGRectGetMinY(rect) - offsetY;
        break;
    }
    [UIView performWithoutAnimation:^{
        [self apollo_takeSectionTitleHeights];
        [tableView layoutIfNeeded];   // the update, and UIKit's restore, happen here
        CGFloat restored = tableView.contentOffset.y;
        // Rows that come on screen as the list is put back are measured as
        // they're laid out and can move the anchor again, so correct until it holds.
        NSInteger passes = 0;
        for (; anchor && passes < 4; passes++) {
            UIEdgeInsets insets = tableView.adjustedContentInset;
            CGFloat minY = -insets.top;
            CGFloat maxY = MAX(minY, tableView.contentSize.height + insets.bottom - CGRectGetHeight(tableView.bounds));
            CGFloat target = CGRectGetMinY([tableView rectForRowAtIndexPath:anchor]) - anchorOffset;
            target = MIN(MAX(target, minY), maxY);
            if (fabs(target - tableView.contentOffset.y) < 0.5) break;
            tableView.contentOffset = CGPointMake(tableView.contentOffset.x, target);
            [tableView layoutIfNeeded];
        }
        ApolloLog(@"[SettingsForm] section title heights taken: offset was %.1f, UIKit restored %.1f, now %.1f (%@)",
                  offsetY, restored, tableView.contentOffset.y,
                  anchor ? [NSString stringWithFormat:@"row %ld/%ld kept in place in %ld pass(es)",
                                                      (long)anchor.section, (long)anchor.row, (long)passes]
                         : @"top of the list");
    }];
}

- (void)apollo_takeSectionTitleHeights {
    [self.tableView beginUpdates];
    [self.tableView endUpdates];
}

@end


// UITextView subclass that allows users to tap links within footer text, but not select text
@implementation ApolloFooterLinkTextView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UITextPosition *position = [self closestPositionToPoint:point];
    if (!position) return NO;

    UITextRange *range = [self.tokenizer rangeEnclosingPosition:position withGranularity:UITextGranularityCharacter inDirection:UITextLayoutDirectionLeft];
    if (!range) return NO;

    NSInteger startIndex = [self offsetFromPosition:self.beginningOfDocument toPosition:range.start];
    return [self.attributedText attribute:NSLinkAttributeName atIndex:startIndex effectiveRange:nil] != nil;
}

@end
