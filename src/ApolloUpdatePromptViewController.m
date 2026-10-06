#import "ApolloUpdatePromptViewController.h"
#import "ApolloAppIcon.h"
#import "ApolloCommon.h"
#import "ApolloUpdateChecker.h"
#import "ApolloThemeRuntime.h"
#import <QuartzCore/QuartzCore.h>

// Page transition: the prompt fades out while moving left, the chooser fades in
// while sliding in from the right. Deliberately slow.
static const NSTimeInterval kPageSlideDuration = 0.6;
static const NSTimeInterval kPageFadeInDelay = 0.12;
static const CGFloat kPageSlideFraction = 0.28;   // of the sheet width

// SF Symbols are OS-versioned and the device floor is iOS 14, so each row lists
// fallbacks; the last entry is always available.
static UIImage *ApolloUpdateSymbol(NSArray<NSString *> *names) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26
                                                                                         weight:UIImageSymbolWeightRegular];
    for (NSString *name in names) {
        UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
        if (image) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

// A fixed design size that still follows the Dynamic Type setting.
static UIFont *ApolloUpdateScaledFont(UIFont *font) {
    return [[UIFontMetrics defaultMetrics] scaledFontForFont:font];
}

// The four sideloader icons ship in the resource bundle (Resources/update-icon-*.png,
// 150px for a 50pt tile), so the chooser needs no network. nil falls back to a tile.
static UIImage *ApolloUpdateSourceIcon(NSString *name) {
    NSString *path = ApolloBundledResourcePath(name, @"png");
    UIImage *raw = path ? [UIImage imageWithContentsOfFile:path] : nil;
    return raw.CGImage ? [UIImage imageWithCGImage:raw.CGImage scale:3 orientation:UIImageOrientationUp] : nil;
}

#pragma mark - Chooser row

// A tappable filled card: colored icon tile, title, subtitle, chevron.
@interface ApolloUpdateChoiceRow : UIControl
- (instancetype)initWithIcon:(nullable UIImage *)icon
                     symbols:(NSArray<NSString *> *)symbols
                   tileColor:(UIColor *)tileColor
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle;
@end

@implementation ApolloUpdateChoiceRow

- (instancetype)initWithIcon:(UIImage *)icon
                     symbols:(NSArray<NSString *> *)symbols
                   tileColor:(UIColor *)tileColor
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.backgroundColor = [UIColor secondarySystemFillColor];
    self.layer.cornerRadius = 18;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, subtitle];

    // The real app icon when we have it, otherwise a colored tile with a glyph.
    UIView *badge;
    if (icon) {
        UIImageView *imageView = [[UIImageView alloc] initWithImage:icon];
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        badge = imageView;
    } else {
        badge = [[UIView alloc] init];
        badge.backgroundColor = tileColor;
        UIImageView *glyph = [[UIImageView alloc] initWithImage:ApolloUpdateSymbol(symbols)];
        glyph.tintColor = [UIColor whiteColor];
        glyph.contentMode = UIViewContentModeCenter;
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        [badge addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[
            [glyph.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        ]];
    }
    badge.layer.cornerRadius = 50 * 0.2237;   // app-icon corner radius
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.clipsToBounds = YES;
    badge.userInteractionEnabled = NO;
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:50],
        [badge.heightAnchor constraintEqualToConstant:50],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel.numberOfLines = 0;

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 0;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:14
                                                                                                 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevronConfig]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, text, chevron]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14;
    row.userInteractionEnabled = NO;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:13],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13],
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
    ]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 animations:^{ self.alpha = highlighted ? 0.6 : 1.0; }];
}

@end

#pragma mark - Link

// "See what's new >" — body-sized so it reads as part of the copy, with a chevron
// so it reads as tappable.
@interface ApolloUpdateLinkControl : UIControl
- (instancetype)initWithTitle:(NSString *)title;
@end

@implementation ApolloUpdateLinkControl

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitLink;
    self.accessibilityLabel = title;

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                   weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13
                                                                                         weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:config]];
    chevron.tintColor = [UIColor labelColor];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, chevron]];
    stack.spacing = 5;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1.0;
}

@end

#pragma mark - Sheet

@implementation ApolloUpdatePromptViewController {
    ApolloUpdateInfo *_info;
    NSString *_installedVersion;
    BOOL _offerSkip;
    UIColor *_accent;

    UIView *_promptPage;
    UIView *_chooserPage;
    UIStackView *_promptHeader;
    UIStackView *_promptActions;
    UIStackView *_chooserHeader;
    UIStackView *_chooserRows;
    UIButton *_updateButton;
    UILabel *_versionsLabel;

    // Haptics: a warning as the sheet lands, a soft impact for taps that go somewhere, a
    // selection tick for the ones that dismiss.
    UINotificationFeedbackGenerator *_notificationFeedback;
    UIImpactFeedbackGenerator *_softImpact;
    UISelectionFeedbackGenerator *_selectionFeedback;

    // Pinned bottom bar (Update / Later / Skip) shared by the summary and the notes.
    UIView *_actionsBar;
    UIView *_actionsHairline;
    UIScrollView *_summaryScroll;

    // Release notes: the summary crossfades to this while the sheet goes to its large detent.
    UIView *_notesContainer;
    UILabel *_notesTitle;
    UITextView *_notesText;
    UIActivityIndicatorView *_notesSpinner;
    UIStackView *_notesError;
    UILabel *_notesErrorLabel;
    NSArray<ApolloUpdateReleaseNotes *> *_notes;   // nil until a fetch succeeds
    BOOL _notesLoading;
    BOOL _showingNotes;

    BOOL _hasAnimatedIn;
    BOOL _showingChooser;
    BOOL _transitioning;
}

- (instancetype)initWithInfo:(ApolloUpdateInfo *)info
            installedVersion:(NSString *)installedVersion
                   offerSkip:(BOOL)offerSkip {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _info = info;
        _installedVersion = [installedVersion copy];
        _offerSkip = offerSkip;
    }
    return self;
}

// A half-height sheet that the release notes and the chooser expand to full height, set up
// like the account switcher's: form sheet, medium + large detents, grabber, and scrolling
// that expands the sheet at the edge. Before iOS 15 there are no detents, so it is the old
// full-height page sheet.
- (void)presentOverViewController:(UIViewController *)presenter {
    if (@available(iOS 15.0, *)) {
        self.modalPresentationStyle = UIModalPresentationFormSheet;
        UISheetPresentationController *sheet = self.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
        // Not a declared conformance: the protocol is iOS 15+ and the floor is 14.
        sheet.delegate = (id)self;
    } else {
        self.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    [presenter presentViewController:self animated:YES completion:nil];
}

#pragma mark Building

- (UILabel *)apollo_labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

- (UIFont *)apollo_largeTitleFont {
    return [UIFont boldSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle].pointSize];
}

// Full-width accent-filled button, identical to What's New's Continue button.
- (UIButton *)apollo_primaryButtonWithTitle:(NSString *)title action:(SEL)action identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = _accent;
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.clipsToBounds = YES;
    button.titleLabel.font = ApolloUpdateScaledFont([UIFont boldSystemFontOfSize:17]);
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityIdentifier = identifier;
    // At least 50, growing with the text size rather than clipping it.
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    return button;
}

// Quiet text button (Later / Skip / Cancel / Release notes): label-colored, not
// accent, so it stays legible on every theme (stock accents can be near-white).
- (UIButton *)apollo_textButtonWithTitle:(NSString *)title
                                    font:(UIFont *)font
                                   color:(UIColor *)color
                                  height:(CGFloat)height
                                  action:(SEL)action
                              identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = ApolloUpdateScaledFont(font);
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    // Later / Skip share a half-width row, so a large text size shrinks to fit instead of cutting off.
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:color forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityIdentifier = identifier;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:height].active = YES;
    return button;
}

- (UIScrollView *)apollo_scrollViewInPage:(UIView *)page bottomAnchor:(NSLayoutYAxisAnchor *)bottomAnchor constant:(CGFloat)bottomConstant content:(UIView *__autoreleasing *)outContent {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:page.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:page.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:page.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottomAnchor constant:bottomConstant],
    ]];
    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        // Short content fills the frame so it can be centered.
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    *outContent = content;
    return scroll;
}

- (UIView *)apollo_pagePinnedToSheet {
    UIView *page = [[UIView alloc] init];
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [page.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [page.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    return page;
}

- (UIStackView *)apollo_actionsStackWithButtons:(NSArray<UIView *> *)buttons {
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = 4;
    return actions;
}

// Pinned to the bottom of the sheet (the chooser page).
- (UIStackView *)apollo_actionsStackInPage:(UIView *)page buttons:(NSArray<UIView *> *)buttons {
    UIStackView *actions = [self apollo_actionsStackWithButtons:buttons];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:actions];
    [NSLayoutConstraint activateConstraints:@[
        [actions.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:20],
        [actions.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:-20],
        [actions.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    return actions;
}

- (void)apollo_buildPromptPage {
    BOOL canUpdate = (_info.handoff != ApolloUpdateHandoffNone);

    _promptPage = [self apollo_pagePinnedToSheet];

    // With no sideloader to hand off to (a dev build), the primary action just
    // opens the release page.
    _updateButton = [self apollo_primaryButtonWithTitle:canUpdate ? @"Update" : @"Release notes"
                                                 action:canUpdate ? @selector(apollo_updateTapped) : @selector(apollo_githubNotesTapped)
                                             identifier:@"update.primary"];
    // Later and Skip share one row under Update so the pinned bar stays short enough for the
    // half-height detent.
    UIButton *later = [self apollo_textButtonWithTitle:@"Later"
                                                  font:[UIFont systemFontOfSize:16]
                                                 color:[UIColor secondaryLabelColor]
                                                height:40
                                                action:@selector(apollo_dismissTapped)
                                            identifier:@"update.later"];
    UIView *secondary = later;
    if (_offerSkip) {
        UIButton *skip = [self apollo_textButtonWithTitle:@"Skip this version"
                                                     font:[UIFont systemFontOfSize:15]
                                                    color:[UIColor tertiaryLabelColor]
                                                   height:40
                                                   action:@selector(apollo_skipTapped)
                                               identifier:@"update.skip"];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[later, skip]];
        row.distribution = UIStackViewDistributionFillEqually;
        secondary = row;
    }
    _promptActions = [self apollo_actionsStackWithButtons:@[_updateButton, secondary]];
    _promptActions.spacing = 2;
    _promptActions.translatesAutoresizingMaskIntoConstraints = NO;

    // No fill of its own: the notes end where the bar begins, and on iOS 26 the half-height
    // sheet is glass that a painted bar would show up against. The hairline fades in over
    // the notes.
    _actionsBar = [[UIView alloc] init];
    _actionsBar.translatesAutoresizingMaskIntoConstraints = NO;
    [_promptPage addSubview:_actionsBar];
    _actionsHairline = [[UIView alloc] init];
    _actionsHairline.translatesAutoresizingMaskIntoConstraints = NO;
    _actionsHairline.backgroundColor = [UIColor separatorColor];
    _actionsHairline.alpha = 0.0;
    [_actionsBar addSubview:_actionsHairline];
    [_actionsBar addSubview:_promptActions];
    [NSLayoutConstraint activateConstraints:@[
        [_actionsBar.leadingAnchor constraintEqualToAnchor:_promptPage.leadingAnchor],
        [_actionsBar.trailingAnchor constraintEqualToAnchor:_promptPage.trailingAnchor],
        [_actionsBar.bottomAnchor constraintEqualToAnchor:_promptPage.bottomAnchor],
        [_actionsHairline.topAnchor constraintEqualToAnchor:_actionsBar.topAnchor],
        [_actionsHairline.leadingAnchor constraintEqualToAnchor:_actionsBar.leadingAnchor],
        [_actionsHairline.trailingAnchor constraintEqualToAnchor:_actionsBar.trailingAnchor],
        [_actionsHairline.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [_promptActions.topAnchor constraintEqualToAnchor:_actionsBar.topAnchor constant:12],
        [_promptActions.leadingAnchor constraintEqualToAnchor:_actionsBar.leadingAnchor constant:20],
        [_promptActions.trailingAnchor constraintEqualToAnchor:_actionsBar.trailingAnchor constant:-20],
        [_promptActions.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
    ]];

    UIView *content = nil;
    _summaryScroll = [self apollo_scrollViewInPage:_promptPage bottomAnchor:_actionsBar.topAnchor constant:0 content:&content];

    // Same icon size and corner radius as the What's New sheet.
    const CGFloat iconSize = 64;
    UIImageView *iconView = [[UIImageView alloc] initWithImage:ApolloCurrentAppIcon()];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 16;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.hidden = (iconView.image == nil);
    iconView.accessibilityIdentifier = @"update.icon";
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:iconSize],
        [iconView.heightAnchor constraintEqualToConstant:iconSize],
    ]];

    UILabel *pillLabel = [[UILabel alloc] init];
    pillLabel.attributedText = [[NSAttributedString alloc] initWithString:@"NEW RELEASE" attributes:@{
        NSKernAttributeName: @0.8,
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor labelColor],
    }];
    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor = [_accent colorWithAlphaComponent:0.18];
    pill.layer.cornerRadius = 11;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:pillLabel];
    [NSLayoutConstraint activateConstraints:@[
        [pillLabel.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4],
        [pillLabel.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4],
        [pillLabel.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:10],
        [pillLabel.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-10],
    ]];

    UILabel *title = [self apollo_labelWithText:@"Update available" font:[self apollo_largeTitleFont] color:[UIColor labelColor]];
    UILabel *subtitle = [self apollo_labelWithText:@"See what's new and get the latest version of Apollo Reborn."
                                              font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                             color:[UIColor secondaryLabelColor]];
    _versionsLabel = [self apollo_labelWithText:@"" font:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]
                                          color:[UIColor tertiaryLabelColor]];
    UILabel *versions = _versionsLabel;   // text is set by -apollo_updateAccentColors

    NSMutableArray<UIView *> *header = [NSMutableArray arrayWithObjects:iconView, pill, title, subtitle, versions, nil];
    if (canUpdate && (_info.notesSourceURL || _info.releaseURL)) {
        ApolloUpdateLinkControl *notes = [[ApolloUpdateLinkControl alloc] initWithTitle:@"Release Notes"];
        notes.accessibilityIdentifier = @"update.notes";
        [notes addTarget:self action:@selector(apollo_showNotes) forControlEvents:UIControlEventTouchUpInside];
        [header addObject:notes];
    }
    _promptHeader = [[UIStackView alloc] initWithArrangedSubviews:header];
    _promptHeader.axis = UILayoutConstraintAxisVertical;
    _promptHeader.alignment = UIStackViewAlignmentCenter;
    _promptHeader.spacing = 10;
    [_promptHeader setCustomSpacing:14 afterView:iconView];
    [_promptHeader setCustomSpacing:10 afterView:pill];
    [_promptHeader setCustomSpacing:6 afterView:title];
    [_promptHeader setCustomSpacing:8 afterView:subtitle];
    _promptHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_promptHeader];
    NSLayoutConstraint *centerY = [_promptHeader.centerYAnchor constraintEqualToAnchor:content.centerYAnchor constant:-4];
    centerY.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        centerY,
        [_promptHeader.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:28],
        [_promptHeader.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-12],
        [_promptHeader.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [_promptHeader.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
    ]];
}

#pragma mark Release notes

// Hidden until "Release Notes" is tapped. Fills the same space as the summary, above the
// pinned action bar, with a back chevron and a scrollable text view.
- (void)apollo_buildNotesView {
    _notesContainer = [[UIView alloc] init];
    _notesContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _notesContainer.alpha = 0.0;
    _notesContainer.hidden = YES;
    [_promptPage insertSubview:_notesContainer belowSubview:_actionsBar];
    [NSLayoutConstraint activateConstraints:@[
        [_notesContainer.topAnchor constraintEqualToAnchor:_promptPage.topAnchor],
        [_notesContainer.leadingAnchor constraintEqualToAnchor:_promptPage.leadingAnchor],
        [_notesContainer.trailingAnchor constraintEqualToAnchor:_promptPage.trailingAnchor],
        [_notesContainer.bottomAnchor constraintEqualToAnchor:_actionsBar.topAnchor],
    ]];

    UIImageSymbolConfiguration *chevron = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [backButton setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:chevron] forState:UIControlStateNormal];
    backButton.tintColor = [UIColor labelColor];
    backButton.accessibilityLabel = @"Back";
    backButton.accessibilityIdentifier = @"update.notes.back";
    [backButton addTarget:self action:@selector(apollo_hideNotesTapped) forControlEvents:UIControlEventTouchUpInside];
    backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_notesContainer addSubview:backButton];

    _notesTitle = [self apollo_labelWithText:[NSString stringWithFormat:@"What's New in %@", _info.version]
                                        font:[UIFont boldSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3].pointSize]
                                       color:[UIColor labelColor]];
    _notesTitle.numberOfLines = 1;
    _notesTitle.adjustsFontSizeToFitWidth = YES;
    _notesTitle.minimumScaleFactor = 0.8;
    _notesTitle.accessibilityTraits = UIAccessibilityTraitHeader;
    _notesTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [_notesContainer addSubview:_notesTitle];

    _notesText = [[UITextView alloc] init];
    _notesText.editable = NO;
    _notesText.backgroundColor = [UIColor clearColor];
    _notesText.textContainerInset = UIEdgeInsetsMake(8, 24, 24, 24);
    _notesText.textContainer.lineFragmentPadding = 0;
    _notesText.alwaysBounceVertical = YES;
    _notesText.hidden = YES;
    _notesText.accessibilityIdentifier = @"update.notes.text";
    _notesText.translatesAutoresizingMaskIntoConstraints = NO;
    [_notesContainer addSubview:_notesText];

    _notesSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _notesSpinner.hidesWhenStopped = YES;
    _notesSpinner.accessibilityIdentifier = @"update.notes.spinner";
    _notesSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_notesContainer addSubview:_notesSpinner];

    _notesErrorLabel = [self apollo_labelWithText:@"" font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] color:[UIColor secondaryLabelColor]];
    NSMutableArray<UIView *> *errorViews = [NSMutableArray arrayWithObject:_notesErrorLabel];
    if (_info.releaseURL) {
        [errorViews addObject:[self apollo_textButtonWithTitle:@"Open on GitHub"
                                                          font:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                                         color:[UIColor labelColor]
                                                        height:44
                                                        action:@selector(apollo_githubNotesTapped)
                                                    identifier:@"update.notes.github"]];
    }
    _notesError = [[UIStackView alloc] initWithArrangedSubviews:errorViews];
    _notesError.axis = UILayoutConstraintAxisVertical;
    _notesError.alignment = UIStackViewAlignmentCenter;
    _notesError.spacing = 6;
    _notesError.hidden = YES;
    _notesError.accessibilityIdentifier = @"update.notes.error";
    _notesError.translatesAutoresizingMaskIntoConstraints = NO;
    [_notesContainer addSubview:_notesError];

    [NSLayoutConstraint activateConstraints:@[
        // Below the grabber.
        [backButton.topAnchor constraintEqualToAnchor:_notesContainer.topAnchor constant:22],
        [backButton.leadingAnchor constraintEqualToAnchor:_notesContainer.leadingAnchor constant:12],
        [backButton.widthAnchor constraintEqualToConstant:44],
        [backButton.heightAnchor constraintEqualToConstant:44],
        [_notesTitle.centerYAnchor constraintEqualToAnchor:backButton.centerYAnchor],
        [_notesTitle.centerXAnchor constraintEqualToAnchor:_notesContainer.centerXAnchor],
        [_notesTitle.leadingAnchor constraintGreaterThanOrEqualToAnchor:backButton.trailingAnchor constant:4],
        [_notesTitle.trailingAnchor constraintLessThanOrEqualToAnchor:_notesContainer.trailingAnchor constant:-60],
        [_notesText.topAnchor constraintEqualToAnchor:backButton.bottomAnchor constant:4],
        [_notesText.leadingAnchor constraintEqualToAnchor:_notesContainer.leadingAnchor],
        [_notesText.trailingAnchor constraintEqualToAnchor:_notesContainer.trailingAnchor],
        [_notesText.bottomAnchor constraintEqualToAnchor:_notesContainer.bottomAnchor],
        [_notesSpinner.centerXAnchor constraintEqualToAnchor:_notesContainer.centerXAnchor],
        [_notesSpinner.centerYAnchor constraintEqualToAnchor:_notesContainer.centerYAnchor constant:24],
        [_notesError.centerXAnchor constraintEqualToAnchor:_notesContainer.centerXAnchor],
        [_notesError.centerYAnchor constraintEqualToAnchor:_notesContainer.centerYAnchor constant:24],
        [_notesError.leadingAnchor constraintGreaterThanOrEqualToAnchor:_notesContainer.leadingAnchor constant:32],
        [_notesError.trailingAnchor constraintLessThanOrEqualToAnchor:_notesContainer.trailingAnchor constant:-32],
    ]];
}

// One block of attributed text for every release in range. A single release skips its own
// version header (the bar already says it); several get a header and date each.
- (NSAttributedString *)apollo_attributedNotes:(NSArray<ApolloUpdateReleaseNotes *> *)releases {
    UIFont *body = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UIFont *small = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIFont *heading = [UIFont systemFontOfSize:body.pointSize weight:UIFontWeightBold];
    UIFont *versionFont = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2].pointSize weight:UIFontWeightBold];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    dateFormatter.timeStyle = NSDateFormatterNoStyle;
    BOOL multiple = releases.count > 1;

    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    void (^append)(NSString *, UIFont *, UIColor *, NSParagraphStyle *) = ^(NSString *text, UIFont *font, UIColor *color, NSParagraphStyle *style) {
        NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, color, NSForegroundColorAttributeName, nil];
        if (style) attrs[NSParagraphStyleAttributeName] = style;
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    };
    NSParagraphStyle *(^style)(CGFloat before, CGFloat after, CGFloat indent) = ^NSParagraphStyle *(CGFloat before, CGFloat after, CGFloat indent) {
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        paragraph.paragraphSpacingBefore = out.length ? before : 0;
        paragraph.paragraphSpacing = after;
        paragraph.lineSpacing = 2;
        if (indent > 0) {
            paragraph.headIndent = indent;
            paragraph.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentNatural location:indent options:@{}]];
            paragraph.defaultTabInterval = indent;
        }
        return paragraph;
    };

    for (ApolloUpdateReleaseNotes *release in releases) {
        if (multiple) {
            append([NSString stringWithFormat:@"Version %@\n", release.version], versionFont, [UIColor labelColor], style(28, 0, 0));
            if (release.date) append([dateFormatter stringFromDate:release.date], small, [UIColor secondaryLabelColor], nil), append(@"\n", small, [UIColor secondaryLabelColor], style(0, 4, 0));
        }
        for (ApolloUpdateNoteBlock *block in release.blocks) {
            switch (block.kind) {
                case ApolloUpdateNoteKindHeading:
                    append([block.text stringByAppendingString:@"\n"], heading, [UIColor labelColor], style(18, 6, 0));
                    break;
                case ApolloUpdateNoteKindParagraph:
                    append([block.text stringByAppendingString:@"\n"], body, [UIColor labelColor], style(0, 8, 0));
                    break;
                case ApolloUpdateNoteKindBullet: {
                    NSParagraphStyle *bullet = style(0, 8, 18);
                    append(@"\u2022\t", body, [UIColor secondaryLabelColor], bullet);
                    append(block.text, body, [UIColor labelColor], bullet);
                    if (block.credit.length) append([@" " stringByAppendingString:block.credit], small, [UIColor tertiaryLabelColor], bullet);
                    append(@"\n", body, [UIColor labelColor], bullet);
                    break;
                }
            }
        }
    }
    return out;
}

- (void)apollo_loadNotesIfNeeded {
    if (_notes || _notesLoading) { [self apollo_renderNotesState]; return; }
    _notesLoading = YES;
    [self apollo_renderNotesState];
    __weak typeof(self) weakSelf = self;
    ApolloUpdateFetchReleaseNotes(_info, ^(NSArray<ApolloUpdateReleaseNotes *> *notes) {
        ApolloUpdatePromptViewController *strongSelf = (ApolloUpdatePromptViewController *)weakSelf;
        if (!strongSelf) return;
        strongSelf->_notesLoading = NO;
        strongSelf->_notes = notes;   // nil on failure, which retries the next time it's opened
        [strongSelf apollo_renderNotesState];
    });
}

- (void)apollo_renderNotesState {
    if (_notesLoading) {
        _notesText.hidden = YES;
        _notesError.hidden = YES;
        [_notesSpinner startAnimating];
        return;
    }
    [_notesSpinner stopAnimating];
    if (_notes.count > 0) {
        // Built once: reopening the notes keeps the text (and where the reader was in it).
        if (_notesText.attributedText.length == 0) {
            _notesText.attributedText = [self apollo_attributedNotes:_notes];
            _notesText.contentOffset = CGPointMake(0, -_notesText.adjustedContentInset.top);
        }
        _notesText.hidden = NO;
        _notesError.hidden = YES;
        return;
    }
    _notesText.hidden = YES;
    _notesErrorLabel.text = _notes ? @"No release notes were published for this update."
                                   : @"Couldn't load the release notes.";
    _notesError.hidden = NO;
}

- (void)apollo_buildChooserPage {
    _chooserPage = [self apollo_pagePinnedToSheet];

    UIStackView *chooserActions = [self apollo_actionsStackInPage:_chooserPage buttons:@[
        [self apollo_textButtonWithTitle:@"Cancel"
                                    font:[UIFont systemFontOfSize:17]
                                   color:[UIColor secondaryLabelColor]
                                  height:44
                                  action:@selector(apollo_dismissTapped)
                              identifier:@"update.cancel"],
    ]];

    UIView *content = nil;
    [self apollo_scrollViewInPage:_chooserPage bottomAnchor:chooserActions.topAnchor constant:-12 content:&content];

    // Without the exact variant the rows only open the sideloader (see ApolloUpdateHandoffOpenApp),
    // so say where the update is actually found.
    BOOL exact = (_info.handoff == ApolloUpdateHandoffExact);
    UILabel *title = [self apollo_labelWithText:@"Update Apollo" font:[self apollo_largeTitleFont] color:[UIColor labelColor]];
    UILabel *subtitle = [self apollo_labelWithText:exact ? @"Choose how you'd like to update."
                                                         : @"Open your sideloader, then update Apollo Reborn there."
                                              font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                             color:[UIColor secondaryLabelColor]];
    _chooserHeader = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    _chooserHeader.axis = UILayoutConstraintAxisVertical;
    _chooserHeader.alignment = UIStackViewAlignmentCenter;
    _chooserHeader.spacing = 8;
    _chooserHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_chooserHeader];

    _chooserRows = [[UIStackView alloc] init];
    _chooserRows.axis = UILayoutConstraintAxisVertical;
    _chooserRows.spacing = 10;
    _chooserRows.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_chooserRows];

    [self apollo_addSideloaderRow:ApolloUpdateSideloaderAltStore name:@"AltStore" icon:@"update-icon-altstore"
                          symbols:@[@"diamond.fill", @"square.stack.3d.up.fill"]
                             tile:[UIColor colorWithRed:0.13 green:0.65 blue:0.60 alpha:1] identifier:@"update.altstore"];
    [self apollo_addSideloaderRow:ApolloUpdateSideloaderSideStore name:@"SideStore" icon:@"update-icon-sidestore"
                          symbols:@[@"diamond.fill", @"square.stack.3d.up.fill"]
                             tile:[UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1] identifier:@"update.sidestore"];
    [self apollo_addSideloaderRow:ApolloUpdateSideloaderFeather name:@"Feather" icon:@"update-icon-feather"
                          symbols:@[@"bird.fill", @"leaf.fill"]
                             tile:[UIColor colorWithRed:0.30 green:0.55 blue:0.98 alpha:1] identifier:@"update.feather"];
    [self apollo_addSideloaderRow:ApolloUpdateSideloaderFlareStore name:@"FlareStore" icon:@"update-icon-flarestore"
                          symbols:@[@"flame.fill"]
                             tile:[UIColor colorWithRed:0.98 green:0.45 blue:0.20 alpha:1] identifier:@"update.flarestore"];

    // "Do it yourself": this build's own IPA when its variant is known, otherwise the release
    // page, where the user picks theirs.
    BOOL download = exact && _info.downloadURL;
    if (download || _info.releaseURL) {
        // Hairline between "open in an app" and "do it yourself".
        UIView *rule = [[UIView alloc] init];
        rule.backgroundColor = [UIColor separatorColor];
        [rule.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
        [_chooserRows setCustomSpacing:16 afterView:_chooserRows.arrangedSubviews.lastObject];
        [_chooserRows addArrangedSubview:rule];
        [_chooserRows setCustomSpacing:16 afterView:rule];
        if (download) {
            [self apollo_addRowWithIcon:nil symbols:@[@"arrow.down.to.line", @"arrow.down.circle"] tile:[UIColor systemGrayColor]
                                  title:@"Download IPA" subtitle:@"Save for manual installation"
                             identifier:@"update.download" action:@selector(apollo_downloadTapped)];
        } else {
            [self apollo_addRowWithIcon:nil symbols:@[@"safari", @"arrow.up.right.square"] tile:[UIColor systemGrayColor]
                                  title:@"Release Page" subtitle:@"Choose your build's IPA on GitHub"
                             identifier:@"update.releasepage" action:@selector(apollo_releasePageTapped)];
        }
    }

    [NSLayoutConstraint activateConstraints:@[
        [_chooserHeader.topAnchor constraintEqualToAnchor:content.topAnchor constant:36],
        [_chooserHeader.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [_chooserHeader.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [_chooserRows.topAnchor constraintEqualToAnchor:_chooserHeader.bottomAnchor constant:32],
        [_chooserRows.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [_chooserRows.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        // <=, not ==: an equal pin would stretch the rows to fill a tall sheet.
        [_chooserRows.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
    ]];

    // Back to wherever Update was tapped (the summary, or the release notes), same chevron as
    // the notes page. On the page itself rather than in the scroll content, so it stays put.
    UIImageSymbolConfiguration *chevron = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    [back setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:chevron] forState:UIControlStateNormal];
    back.tintColor = [UIColor labelColor];
    back.accessibilityLabel = @"Back";
    back.accessibilityIdentifier = @"update.chooser.back";
    [back addTarget:self action:@selector(apollo_chooserBackTapped) forControlEvents:UIControlEventTouchUpInside];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [_chooserPage addSubview:back];
    [NSLayoutConstraint activateConstraints:@[
        // Centered on the title's first line.
        [back.topAnchor constraintEqualToAnchor:_chooserPage.topAnchor constant:34],
        [back.leadingAnchor constraintEqualToAnchor:_chooserPage.leadingAnchor constant:12],
        [back.widthAnchor constraintEqualToConstant:44],
        [back.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (ApolloUpdateChoiceRow *)apollo_addRowWithIcon:(NSString *)iconName
                                         symbols:(NSArray<NSString *> *)symbols
                                            tile:(UIColor *)tile
                                           title:(NSString *)title
                                        subtitle:(NSString *)subtitle
                                      identifier:(NSString *)identifier
                                          action:(SEL)action {
    ApolloUpdateChoiceRow *row = [[ApolloUpdateChoiceRow alloc] initWithIcon:iconName ? ApolloUpdateSourceIcon(iconName) : nil
                                                                     symbols:symbols
                                                                   tileColor:tile
                                                                       title:title
                                                                    subtitle:subtitle];
    row.accessibilityIdentifier = identifier;
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_chooserRows addArrangedSubview:row];
    return row;
}

// One "Continue in <app>" row; what it opens is decided at tap time by ApolloUpdateSideloaderHandoffURL.
- (void)apollo_addSideloaderRow:(ApolloUpdateSideloader)sideloader
                           name:(NSString *)name
                           icon:(NSString *)iconName
                        symbols:(NSArray<NSString *> *)symbols
                           tile:(UIColor *)tile
                     identifier:(NSString *)identifier {
    ApolloUpdateChoiceRow *row = [self apollo_addRowWithIcon:iconName symbols:symbols tile:tile
                                                       title:name
                                                    subtitle:[@"Continue in " stringByAppendingString:name]
                                                  identifier:identifier
                                                      action:@selector(apollo_sideloaderRowTapped:)];
    row.tag = sideloader;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _accent = ApolloThemeAccentColor() ?: self.view.tintColor ?: [UIColor systemBlueColor];

    _notificationFeedback = [[UINotificationFeedbackGenerator alloc] init];
    _softImpact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    _selectionFeedback = [[UISelectionFeedbackGenerator alloc] init];

    [self apollo_buildPromptPage];
    [self apollo_buildNotesView];

    // Entrance states (see -apollo_animateEntrance).
    _promptHeader.alpha = 0.0;
    _promptHeader.transform = CGAffineTransformMakeScale(0.82, 0.82);
    _promptActions.alpha = 0.0;
    _promptActions.transform = CGAffineTransformMakeTranslation(0, 10);
    [self apollo_updateAccentColors];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Wake the Taptic Engine while the sheet rises so the warning lands without lag.
    [_notificationFeedback prepare];
    [_softImpact prepare];
    [_selectionFeedback prepare];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self apollo_updateAccentColors];   // in the hierarchy now, so real traits
    if (_hasAnimatedIn) return;
    _hasAnimatedIn = YES;
    [_notificationFeedback notificationOccurred:UINotificationFeedbackTypeWarning];
    [self apollo_animateEntrance];
    // Fetch the notes now, while the summary is being read, so Release Notes opens with them
    // ready. Only when the sheet is actually shown (not on every daily check); a failed
    // prefetch is simply retried when Release Notes is tapped.
    if (_info.handoff != ApolloUpdateHandoffNone && _info.notesSourceURL) [self apollo_loadNotesIfNeeded];
}

// Same beat as What's New: the header pops in scaled and faded, then the actions
// fade in beneath it.
- (void)apollo_animateEntrance {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        _promptHeader.alpha = 1.0;
        _promptHeader.transform = CGAffineTransformIdentity;
        _promptActions.alpha = 1.0;
        _promptActions.transform = CGAffineTransformIdentity;
        return;
    }
    [UIView animateWithDuration:0.5 delay:0.05 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_promptHeader.alpha = 1.0;
        self->_promptHeader.transform = CGAffineTransformIdentity;
    } completion:nil];
    [UIView animateWithDuration:0.4 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_promptActions.alpha = 1.0;
        self->_promptActions.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// Everything that depends on the resolved accent. Static, so re-run on appearance changes
// (stock monochromatic/chumbus accents are near-white): black-vs-white title on the accent
// fill, and the new version in the accent unless that would vanish on a white sheet.
- (void)apollo_updateAccentColors {
    UIColor *accent = _accent ?: [UIColor systemBlueColor];
    BOOL lightAccent = ApolloColorIsLight([accent resolvedColorWithTraitCollection:self.traitCollection]);
    [_updateButton setTitleColor:lightAccent ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];

    UIFont *small = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    BOOL darkSheet = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIColor *newColor = (lightAccent && !darkSheet) ? [UIColor labelColor] : accent;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@ \u2192 ", _installedVersion]
            attributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: [UIColor tertiaryLabelColor]}];
    [text appendAttributedString:[[NSAttributedString alloc]
        initWithString:_info.version
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:small.pointSize weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: newColor}]];
    _versionsLabel.attributedText = text;
    _versionsLabel.accessibilityLabel = [NSString stringWithFormat:@"Version %@ to %@", _installedVersion, _info.version];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        [self apollo_updateAccentColors];
    }
}

#pragma mark Page transition

- (void)apollo_showChooser {
    if (_showingChooser || _transitioning) return;
    _showingChooser = YES;
    _transitioning = YES;
    _promptPage.userInteractionEnabled = NO;
    // Five rows and a header need the full height.
    [self apollo_setSheetLarge:YES];
    if (!_chooserPage) [self apollo_buildChooserPage];   // only built if the user gets this far

    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CGFloat shift = reduceMotion ? 0.0 : CGRectGetWidth(self.view.bounds) * kPageSlideFraction;

    _chooserPage.hidden = NO;
    _chooserPage.alpha = 0.0;
    _chooserPage.transform = CGAffineTransformMakeTranslation(shift, 0);

    // The prompt fades out drifting left...
    [UIView animateWithDuration:kPageSlideDuration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_promptPage.alpha = 0.0;
        self->_promptPage.transform = CGAffineTransformMakeTranslation(-shift, 0);
    } completion:nil];

    // ...while the chooser fades in sliding from the right.
    [UIView animateWithDuration:kPageSlideDuration delay:kPageFadeInDelay options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_chooserPage.alpha = 1.0;
        self->_chooserPage.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self->_promptPage.hidden = YES;
        self->_transitioning = NO;
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self->_chooserHeader);
    }];
}

// The reverse of -apollo_showChooser: the chooser fades out drifting right while the prompt
// slides back in from the left, exactly as it was left (summary, or the open release notes).
// The sheet returns to half height unless the notes are open.
- (void)apollo_hideChooser {
    if (!_showingChooser || _transitioning) return;
    _showingChooser = NO;
    _transitioning = YES;
    _chooserPage.userInteractionEnabled = NO;
    if (!_showingNotes) [self apollo_setSheetLarge:NO];

    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CGFloat shift = reduceMotion ? 0.0 : CGRectGetWidth(self.view.bounds) * kPageSlideFraction;

    _promptPage.hidden = NO;
    _promptPage.alpha = 0.0;
    _promptPage.transform = CGAffineTransformMakeTranslation(-shift, 0);

    [UIView animateWithDuration:kPageSlideDuration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_chooserPage.alpha = 0.0;
        self->_chooserPage.transform = CGAffineTransformMakeTranslation(shift, 0);
    } completion:nil];

    [UIView animateWithDuration:kPageSlideDuration delay:kPageFadeInDelay options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_promptPage.alpha = 1.0;
        self->_promptPage.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self->_chooserPage.hidden = YES;
        self->_chooserPage.transform = CGAffineTransformIdentity;
        self->_chooserPage.userInteractionEnabled = YES;
        self->_promptPage.userInteractionEnabled = YES;
        self->_transitioning = NO;
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self->_showingNotes ? (id)self->_notesTitle : (id)self->_promptHeader);
    }];
}

#pragma mark Actions

- (void)apollo_softTap {
    [_softImpact impactOccurred];
    [_softImpact prepare];
}

- (void)apollo_selectionTick {
    [_selectionFeedback selectionChanged];
    [_selectionFeedback prepare];
}

- (void)apollo_chooserBackTapped {
    ApolloLog(@"[update] sheet: back from the chooser");
    [self apollo_hideChooser];
}

- (void)apollo_updateTapped {
    ApolloLog(@"[update] sheet: update tapped");
    if (!_showingChooser && !_transitioning) [self apollo_softTap];
    [self apollo_showChooser];
}

// Later and the chooser's Cancel.
- (void)apollo_dismissTapped {
    [self apollo_selectionTick];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)apollo_skipTapped {
    [self apollo_selectionTick];
    if (self.onSkip) self.onSkip();
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Fallback when the notes can't be shown in the sheet (no source, failed fetch, dev builds).
- (void)apollo_githubNotesTapped {
    [self apollo_softTap];
    if (_info.releaseURL) ApolloPresentWebURLFromViewController(self, _info.releaseURL);
}

- (void)apollo_setSheetLarge:(BOOL)large {
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = self.sheetPresentationController;
        if (!sheet) return;
        UISheetPresentationControllerDetentIdentifier target = large ? UISheetPresentationControllerDetentIdentifierLarge
                                                                      : UISheetPresentationControllerDetentIdentifierMedium;
        if ([sheet.selectedDetentIdentifier isEqual:target]) return;
        [sheet animateChanges:^{ sheet.selectedDetentIdentifier = target; }];
    }
}

// Release Notes: the sheet goes to full height while the summary crossfades to the notes.
// The Update / Later / Skip bar stays put underneath.
- (void)apollo_showNotes {
    if (_showingNotes || _showingChooser || _transitioning) return;
    _showingNotes = YES;
    [self apollo_softTap];
    ApolloLog(@"[update] sheet: release notes opened");
    [self apollo_setSheetLarge:YES];
    _notesContainer.hidden = NO;
    _summaryScroll.userInteractionEnabled = NO;
    [self apollo_loadNotesIfNeeded];
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.3;
    [UIView animateWithDuration:duration delay:0.05 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_summaryScroll.alpha = 0.0;
        self->_notesContainer.alpha = 1.0;
        self->_actionsHairline.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (self->_showingNotes) self->_summaryScroll.hidden = YES;
    }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _notesTitle);
}

// `collapse` NO when the user already dragged the sheet back down to the half detent.
- (void)apollo_hideNotesAndCollapse:(BOOL)collapse {
    if (!_showingNotes) return;
    _showingNotes = NO;
    if (collapse) [self apollo_setSheetLarge:NO];
    _summaryScroll.hidden = NO;
    _summaryScroll.userInteractionEnabled = YES;
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.3;
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_summaryScroll.alpha = 1.0;
        self->_notesContainer.alpha = 0.0;
        self->_actionsHairline.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (!self->_showingNotes) self->_notesContainer.hidden = YES;
    }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _promptHeader);
}

- (void)apollo_hideNotesTapped {
    [self apollo_hideNotesAndCollapse:YES];
}

// Dragging the sheet back to the half detent returns to the summary.
- (void)sheetPresentationControllerDidChangeSelectedDetentIdentifier:(UISheetPresentationController *)sheet API_AVAILABLE(ios(15.0)) {
    if (_showingNotes && !_showingChooser && ![sheet.selectedDetentIdentifier isEqual:UISheetPresentationControllerDetentIdentifierLarge]) {
        [self apollo_hideNotesAndCollapse:NO];
    }
}

- (void)apollo_sideloaderRowTapped:(UIControl *)row {
    [self apollo_softTap];
    ApolloUpdateSideloader sideloader = (ApolloUpdateSideloader)row.tag;
    NSURL *url = ApolloUpdateSideloaderHandoffURL(sideloader, _info);
    NSString *name = sideloader == ApolloUpdateSideloaderAltStore ? @"AltStore"
        : sideloader == ApolloUpdateSideloaderSideStore ? @"SideStore"
        : sideloader == ApolloUpdateSideloaderFeather ? @"Feather" : @"FlareStore";
    [self apollo_openURL:url appName:name];
}

- (void)apollo_downloadTapped {
    [self apollo_softTap];
    [self apollo_openURL:_info.downloadURL appName:nil];
}

- (void)apollo_releasePageTapped {
    [self apollo_softTap];
    [self apollo_openURL:_info.releaseURL appName:nil];
}

// `appName` non-nil => a sideloader hand-off, so a failed open means it isn't installed.
- (void)apollo_openURL:(NSURL *)url appName:(NSString *)appName {
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        ApolloLog(@"[update] open %@ -> %@", url.scheme, success ? @"ok" : @"failed");
        UIViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            // Handed off; the user finishes the update in the other app.
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        if (!appName) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"Couldn't Open %@", appName]
                             message:@"Make sure it's installed, or choose another option."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
}

@end
