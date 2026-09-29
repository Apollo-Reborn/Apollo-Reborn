#import "settings/ApolloBackupActionsCell.h"

#import "ApolloThemeRuntime.h"

@interface ApolloBackupActionsCell ()
@property (nonatomic, strong) UILabel *filenameLabel;
@property (nonatomic, strong) UIStackView *actionStack;
@property (nonatomic, strong) UIButton *restoreButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, copy) NSURL *backupURL;
@property (nonatomic, copy) ApolloBackupActionHandler restoreAction;
@property (nonatomic, copy) ApolloBackupActionHandler exportAction;
@property (nonatomic, copy) ApolloBackupActionHandler deleteAction;
@end

@implementation ApolloBackupActionsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) [self setUpContent];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self setUpContent];
    return self;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(8.0, 4.0, 8.0, 4.0);
    button.backgroundColor = UIColor.tertiarySystemFillColor;
    button.layer.cornerRadius = 9.0;
    button.clipsToBounds = YES;
    button.enabled = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];
    return button;
}

- (void)setUpContent {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.isAccessibilityElement = NO;

    self.filenameLabel = [UILabel new];
    self.filenameLabel.numberOfLines = 0;
    self.filenameLabel.lineBreakMode = NSLineBreakByCharWrapping;
    self.filenameLabel.adjustsFontForContentSizeCategory = YES;
    [self.filenameLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
        forAxis:UILayoutConstraintAxisVertical];

    self.restoreButton = [self buttonWithTitle:@"Restore" action:@selector(restoreTapped)];
    self.exportButton = [self buttonWithTitle:@"Export" action:@selector(exportTapped)];
    self.deleteButton = [self buttonWithTitle:@"Delete" action:@selector(deleteTapped)];
    self.exportButton.accessibilityLabel = @"Export to Files";

    self.actionStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.restoreButton, self.exportButton, self.deleteButton,
    ]];
    self.actionStack.alignment = UIStackViewAlignmentFill;
    self.actionStack.distribution = UIStackViewDistributionFillEqually;

    UIStackView *contentStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.filenameLabel, self.actionStack,
    ]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.alignment = UIStackViewAlignmentFill;
    contentStack.spacing = 8.0;
    [self.contentView addSubview:contentStack];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [contentStack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [contentStack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [contentStack.topAnchor constraintEqualToAnchor:margins.topAnchor constant:4.0],
        [contentStack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-4.0],
    ]];
    self.accessibilityElements = @[
        self.filenameLabel, self.restoreButton, self.exportButton, self.deleteButton,
    ];
    [self updateTypography];
    [self updateTheme];
}

- (void)configureWithBackupURL:(NSURL *)backupURL
                restoreAction:(ApolloBackupActionHandler)restoreAction
                 exportAction:(ApolloBackupActionHandler)exportAction
                 deleteAction:(ApolloBackupActionHandler)deleteAction {
    self.backupURL = backupURL;
    self.restoreAction = restoreAction;
    self.exportAction = exportAction;
    self.deleteAction = deleteAction;
    self.filenameLabel.text = backupURL.lastPathComponent;
    self.restoreButton.enabled = restoreAction != nil;
    self.exportButton.enabled = exportAction != nil;
    self.deleteButton.enabled = deleteAction != nil;
    [self updateTypography];
    [self updateTheme];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.backupURL = nil;
    self.restoreAction = nil;
    self.exportAction = nil;
    self.deleteAction = nil;
    self.filenameLabel.text = nil;
    self.restoreButton.enabled = NO;
    self.exportButton.enabled = NO;
    self.deleteButton.enabled = NO;
}

- (void)updateTypography {
    self.filenameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote
        compatibleWithTraitCollection:self.traitCollection];
    UIFont *buttonFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
        compatibleWithTraitCollection:self.traitCollection];
    self.restoreButton.titleLabel.font = buttonFont;
    self.exportButton.titleLabel.font = buttonFont;
    self.deleteButton.titleLabel.font = buttonFont;

    // Accessibility sizes need full-width actions to keep labels and targets
    // readable. Reconfigure on trait changes, never from a layout callback.
    BOOL accessibilitySize = UIContentSizeCategoryIsAccessibilityCategory(
        self.traitCollection.preferredContentSizeCategory);
    self.actionStack.axis = accessibilitySize ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.actionStack.spacing = accessibilitySize ? 4.0 : 8.0;
}

- (void)updateTheme {
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
    self.filenameLabel.textColor = UIColor.secondaryLabelColor;
    // Explicit title colors survive the settings base's inherited tint walk;
    // the destructive action must remain red when the theme accent changes.
    [self.restoreButton setTitleColor:accent forState:UIControlStateNormal];
    [self.exportButton setTitleColor:accent forState:UIControlStateNormal];
    [self.deleteButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [self.restoreButton setTitleColor:UIColor.tertiaryLabelColor forState:UIControlStateDisabled];
    [self.exportButton setTitleColor:UIColor.tertiaryLabelColor forState:UIControlStateDisabled];
    [self.deleteButton setTitleColor:UIColor.tertiaryLabelColor forState:UIControlStateDisabled];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self updateTheme];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateTypography];
    [self updateTheme];
}

- (void)restoreTapped {
    if (self.backupURL && self.restoreAction) self.restoreAction(self.backupURL);
}

- (void)exportTapped {
    if (self.backupURL && self.exportAction) self.exportAction(self.backupURL);
}

- (void)deleteTapped {
    if (self.backupURL && self.deleteAction) self.deleteAction(self.backupURL);
}

@end
