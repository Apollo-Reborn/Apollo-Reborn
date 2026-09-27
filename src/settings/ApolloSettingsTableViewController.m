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
@end

@implementation ApolloSettingsTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self apollo_applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
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
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *sectionView = (UITableViewHeaderFooterView *)view;
        sectionView.textLabel.font = ApolloSettingsFont(UIFontTextStyleCaption1, view.traitCollection);
    }
    ApolloSettingsApplyTextTypography(view);
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *sectionView = (UITableViewHeaderFooterView *)view;
        sectionView.textLabel.font = ApolloSettingsFont(UIFontTextStyleFootnote, view.traitCollection);
    }
    ApolloSettingsApplyTextTypography(view);
}

- (void)tableView:(UITableView *)__unused tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)__unused indexPath {
    [self apollo_applyThemeToCell:cell];
}

@end

@implementation ApolloSettingsLinkFooterView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    // Let the table supply its final grouped/safe-area width before measuring
    // the text. A bare UITextView footer initially receives the full table
    // width, then rewraps when UIKit installs the grouped section insets.
    _linkTextView = [[ApolloFooterLinkTextView alloc] init];
    _linkTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _linkTextView.editable = NO;
    _linkTextView.scrollEnabled = NO;
    _linkTextView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _linkTextView.backgroundColor = UIColor.clearColor;
    _linkTextView.textContainerInset = UIEdgeInsetsMake(8, 16, 8, 16);
    [self.contentView addSubview:_linkTextView];
    [NSLayoutConstraint activateConstraints:@[
        [_linkTextView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_linkTextView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_linkTextView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_linkTextView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
    return self;
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
