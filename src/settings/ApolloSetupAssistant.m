#import "settings/ApolloSetupAssistant.h"
#import "settings/ApolloSetupPreset.h"
#import "settings/ApolloSettingsForm.h"
#import "settings/ApolloBackupDocument.h"
#import "settings/ApolloAutomaticBackupViewController.h"
#import "settings/CustomAPIViewController.h"
#import "ApolloAccountCredentials.h"
#import "ApolloAppIcon.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUpdateManifest.h"
#import "ApolloUsageHeartbeat.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "UserDefaultConstants.h"
#import "../Version.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdlib.h>

static NSString *const kSetupGroup = @"group.com.christianselig.apollo";
static __weak UINavigationController *sSetupNavigation;
static BOOL sSetupPresentationPending;

// +load precedes all Logos constructors, including the sideload-unlock writes.
// Only the lifecycle stamp is written here; no user settings are applied.
@interface ApolloSetupBootstrap : NSObject
@end
@implementation ApolloSetupBootstrap
+ (void)load {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!bundleID.length) return;
        NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kSetupGroup];
        ApolloSetupState state = ApolloSetupInitialState(
            [defaults persistentDomainForName:bundleID] ?: @{},
            [group persistentDomainForName:kSetupGroup] ?: @{});
        [defaults setInteger:state forKey:UDKeySetupAssistantState];
    }
}
@end

BOOL ApolloSetupAssistantBlocksLaunchPrompts(void) {
    return [NSUserDefaults.standardUserDefaults integerForKey:UDKeySetupAssistantState] == ApolloSetupStatePending ||
        sSetupNavigation != nil || sSetupPresentationPending;
}

@interface ApolloSetupDraft : NSObject
@property (nonatomic, copy) NSString *presetIdentifier;
@property (nonatomic) ApolloSetupAppearance appearance;
@property (nonatomic) BOOL glass;
@property (nonatomic) BOOL installCount;
@property (nonatomic) BOOL crashCapture;
@property (nonatomic) BOOL firstRun;
@end
@implementation ApolloSetupDraft
@end

// Onboarding is a visual pager, rather than a settings table. Auxiliary
// credential, feature-detail and privacy screens still use the shared form layer.
static UIColor *ApolloSetupBackground(void) {
    return [UIColor colorWithRed:0.035 green:0.035 blue:0.045 alpha:1];
}

static UILabel *ApolloSetupLabel(NSString *text, CGFloat size, UIFontWeight weight, BOOL secondary) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [[UIFontMetrics metricsForTextStyle:size >= 28 ? UIFontTextStyleTitle1 : UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = secondary ? [UIColor colorWithWhite:0.65 alpha:1] : UIColor.whiteColor;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

static UIStackView *ApolloSetupStack(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = spacing;
    return stack;
}

static void ApolloSetupPaintText(NSString *text, CGRect rect, CGFloat size, UIFontWeight weight, UIColor *color) {
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName:color}];
}

static void ApolloSetupPaintSymbol(NSString *symbol, CGRect rect, UIColor *color) {
    UIImage *image = [[UIImage systemImageNamed:symbol] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    [image drawInRect:rect];
}

// A deliberately illustrative miniature, never a second live Apollo controller.
// Its media/avatars/link cards and chrome reflect the staged choices without
// mutating startup-latched hooks. Drawing keeps the hero entirely decorative;
// all actionable choices and explanations are real, accessible UIKit controls.
@interface ApolloSetupArtwork : UIView
@property (nonatomic) NSInteger step;
@property (nonatomic, strong) ApolloSetupDraft *draft;
@property (nonatomic, strong) UIColor *accent;
@property (nonatomic) UIUserInterfaceStyle systemStyle;
@end

@implementation ApolloSetupArtwork
- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIColor *accent = [self.accent resolvedColorWithTraitCollection:self.traitCollection];
    CGFloat scale = MIN(rect.size.width / 340.0, rect.size.height / 260.0);
    CGContextTranslateCTM(context, rect.size.width / 2, rect.size.height / 2);
    CGContextScaleCTM(context, scale, scale);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(id)[accent colorWithAlphaComponent:0.24].CGColor,
        (id)[accent colorWithAlphaComponent:0].CGColor];
    CGGradientRef glow = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawRadialGradient(context, glow, CGPointZero, 8, CGPointZero, 128, 0);
    CGGradientRelease(glow);
    CGColorSpaceRelease(space);

    if (self.step == 0 || self.step == 3) {
        for (NSUInteger i = 0; i < 3; i++) {
            CGFloat radius = 77 + i * 20;
            [[UIColor colorWithWhite:1 alpha:0.035] setStroke];
            UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-radius, -radius, radius * 2, radius * 2)];
            ring.lineWidth = 1;
            [ring stroke];
        }
        CGContextSaveGState(context);
        CGContextSetShadowWithColor(context, CGSizeMake(0, 16), 26, [accent colorWithAlphaComponent:0.3].CGColor);
        CGRect iconRect = CGRectMake(-62, -62, 124, 124);
        [[UIColor colorWithWhite:0.12 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:iconRect cornerRadius:29] fill];
        CGContextRestoreGState(context);
        CGContextSaveGState(context);
        [[UIBezierPath bezierPathWithRoundedRect:iconRect cornerRadius:29] addClip];
        [ApolloCurrentAppIcon() drawInRect:iconRect];
        CGContextRestoreGState(context);
        ApolloSetupPaintSymbol(self.step == 0 ? @"sparkle" : @"checkmark.circle.fill",
            CGRectMake(72, -78, self.step == 0 ? 23 : 40, self.step == 0 ? 28 : 40), accent);
        ApolloSetupPaintSymbol(@"sparkle", CGRectMake(-113, 42, 15, 19), [accent colorWithAlphaComponent:0.6]);
        return;
    }

    BOOL appearance = self.step == 2;
    ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:self.draft.presetIdentifier];
    NSDictionary *values = preset.values ?: NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    BOOL enhanced = [values[UDKeyFeedGalleryCarousel] boolValue];
    BOOL avatars = [values[UDKeyShowUserAvatars] boolValue];
    BOOL light = appearance && (self.draft.appearance == ApolloSetupAppearanceLight ||
        (self.draft.appearance == ApolloSetupAppearanceSystem && self.systemStyle == UIUserInterfaceStyleLight));
    if (appearance && self.draft.appearance == ApolloSetupAppearanceUnchanged) {
        light = self.systemStyle == UIUserInterfaceStyleLight;
    }
    BOOL glass = appearance && (ApolloLiquidGlassCanToggle() ? self.draft.glass : IsLiquidGlass());
    UIColor *surface = light ? [UIColor colorWithWhite:0.96 alpha:1] : [UIColor colorWithWhite:0.095 alpha:1];
    UIColor *ink = light ? [UIColor colorWithWhite:0.12 alpha:1] : UIColor.whiteColor;
    UIColor *muted = light ? [UIColor colorWithWhite:0.4 alpha:1] : [UIColor colorWithWhite:0.55 alpha:1];
    CGRect phone = CGRectMake(-91, -124, 182, 248);
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, 16), 24, UIColor.blackColor.CGColor);
    [[UIColor colorWithWhite:0.22 alpha:1] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(phone, -3, -3) cornerRadius:29] fill];
    CGContextRestoreGState(context);
    [surface setFill];
    [[UIBezierPath bezierPathWithRoundedRect:phone cornerRadius:27] fill];
    [[UIColor colorWithWhite:0 alpha:1] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-25, -115, 50, 12) cornerRadius:6] fill];

    if (glass) {
        [[accent colorWithAlphaComponent:light ? 0.08 : 0.16] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-81, -92, 162, 27) cornerRadius:13.5] fill];
    }
    ApolloSetupPaintText(@"Posts", CGRectMake(-72, -86, 95, 20), 15, UIFontWeightBold, ink);
    ApolloSetupPaintSymbol(@"ellipsis", CGRectMake(57, -84, 13, 8), accent);
    ApolloSetupPaintText(@"r/Outdoors", CGRectMake(-72, -53, 130, 16), 9, UIFontWeightSemibold, accent);
    ApolloSetupPaintText(@"A little room to explore.", CGRectMake(-72, -36, 148, 18), 11, UIFontWeightSemibold, ink);

    // A small vector landscape gives the sample a coherent focal point without
    // downloading media or needing a user's account during first launch.
    CGRect landscape = CGRectMake(-73, -12, 146, 75);
    CGContextSaveGState(context);
    [[UIBezierPath bezierPathWithRoundedRect:landscape cornerRadius:8] addClip];
    [[UIColor colorWithRed:0.32 green:0.4 blue:0.49 alpha:1] setFill];
    UIRectFill(landscape);
    [[UIColor colorWithRed:0.94 green:0.76 blue:0.52 alpha:1] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(28, 0, 22, 22)] fill];
    UIBezierPath *mountain = [UIBezierPath bezierPath];
    [mountain moveToPoint:CGPointMake(-73, 63)];
    [mountain addLineToPoint:CGPointMake(-73, 39)];
    [mountain addLineToPoint:CGPointMake(-24, 2)];
    [mountain addLineToPoint:CGPointMake(19, 43)];
    [mountain addLineToPoint:CGPointMake(48, 25)];
    [mountain addLineToPoint:CGPointMake(73, 43)];
    [mountain addLineToPoint:CGPointMake(73, 63)];
    [mountain closePath];
    [[UIColor colorWithRed:0.19 green:0.27 blue:0.29 alpha:1] setFill];
    [mountain fill];
    UIBezierPath *ridge = [UIBezierPath bezierPath];
    [ridge moveToPoint:CGPointMake(-73, 63)];
    [ridge addLineToPoint:CGPointMake(-73, 54)];
    [ridge addCurveToPoint:CGPointMake(73, 42) controlPoint1:CGPointMake(-4, 15) controlPoint2:CGPointMake(5, 82)];
    [ridge addLineToPoint:CGPointMake(73, 63)];
    [ridge closePath];
    [[UIColor colorWithRed:0.1 green:0.18 blue:0.2 alpha:1] setFill];
    [ridge fill];
    CGContextRestoreGState(context);
    if (enhanced) {
        for (NSUInteger i = 0; i < 3; i++) {
            [(i == 0 ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.4]) setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-9 + (CGFloat)i * 7, 53, 3, 3)] fill];
        }
    }
    ApolloSetupPaintText(@"↑ 128    ♡ 24", CGRectMake(-72, 69, 130, 15), 9, UIFontWeightMedium, muted);
    if (!appearance) {
        CGFloat x = -72;
        if (avatars) {
            [accent setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-72, 89, 15, 15)] fill];
            ApolloSetupPaintSymbol(@"person.fill", CGRectMake(-69, 92, 9, 10), UIColor.whiteColor);
            x += 20;
        }
        ApolloSetupPaintText(enhanced ? @"↗  A favourite trail" : @"example.com/trail", CGRectMake(x, 91, 143, 16), 9, UIFontWeightMedium, enhanced ? accent : muted);
    } else {
        CGRect tabs = CGRectMake(-76, 90, 152, 26);
        [[(glass ? accent : muted) colorWithAlphaComponent:glass ? 0.12 : 0.07] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:tabs cornerRadius:glass ? 13 : 3] fill];
        NSArray *symbols = @[@"house.fill", @"envelope", @"gearshape"];
        for (NSUInteger i = 0; i < symbols.count; i++) {
            ApolloSetupPaintSymbol(symbols[i], CGRectMake(-56 + (CGFloat)i * 48, 97, 13, 13), i == 0 ? accent : muted);
        }
    }
}
@end

@class ApolloSetupPage;
@interface ApolloSetupAssistantViewController () <UIDocumentPickerDelegate, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) ApolloSetupDraft *draft;
@property (nonatomic) NSInteger step;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL changingPage;
@property (nonatomic, strong) UIPageViewController *pager;
@property (nonatomic, strong) UIPageControl *dots;
@property (nonatomic, strong) UIButton *continueButton;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *skipButton;
- (void)refreshPage;
- (void)openSignIn;
- (void)restoreBackup;
- (void)showPresetDetails;
- (void)showPrivacy;
- (void)showBackups;
- (NSString *)accountSummary;
@end

@interface ApolloSetupPage : UIViewController
@property (nonatomic) NSInteger index;
@property (nonatomic, weak) ApolloSetupAssistantViewController *host;
- (void)reloadContent;
@end

// Details use the form layer, keeping optional information out of the pager.
@interface ApolloSetupDetails : ApolloSettingsFormViewController
@property (nonatomic, strong) ApolloSetupDraft *draft;
@property (nonatomic) BOOL privacy;
@end
@implementation ApolloSetupDetails
- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    if (self.privacy) {
        self.title = @"Privacy & Diagnostics";
        return @[[ApolloSettingsSection sectionWithTitle:nil
            footer:@"Install counting sends an anonymous monthly identifier and basic app/build information. Local crash reports stay on this device; nothing is shared unless you review and submit it. Crash recording changes take effect next launch."
            rows:@[
                [ApolloSettingsRow switchRowWithID:@"setup.installCount" title:@"Anonymous Install Count"
                    isOn:^BOOL { return weakSelf.draft.installCount; }
                    onToggle:^(UISwitch *sender) { weakSelf.draft.installCount = sender.isOn; }],
                [ApolloSettingsRow switchRowWithID:@"setup.crashes" title:@"Local Crash Reports"
                    isOn:^BOOL { return weakSelf.draft.crashCapture; }
                    onToggle:^(UISwitch *sender) { weakSelf.draft.crashCapture = sender.isOn; }],
            ]]];
    }
    self.title = @"Included Features";
    ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:self.draft.presetIdentifier];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *highlight in preset.highlights ?: @[@"Your current feature preferences"]) {
        [rows addObject:[ApolloSettingsRow valueRowWithID:highlight title:highlight detail:nil onSelect:nil]];
    }
    return @[[ApolloSettingsSection sectionWithTitle:preset.title ?: @"Keep My Settings"
        footer:@"Compatibility fixes stay active in every preset. AI, translation, deleted-comment recovery, experimental services, sound, filters, gestures and privacy keep their current settings."
        rows:rows]];
}
@end

@implementation ApolloSetupPage
- (void)loadView {
    self.view = [UIView new];
    [self reloadContent];
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsMake(12, 12, 12, 12);
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button setTitleColor:self.host.view.tintColor forState:UIControlStateNormal];
    [button addTarget:self.host action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)choice:(NSString *)title selected:(BOOL)selected action:(void (^)(void))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:selected ? UIColor.whiteColor : [UIColor colorWithWhite:0.65 alpha:1] forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(14, 5, 14, 5);
    button.backgroundColor = selected ? [self.host.view.tintColor colorWithAlphaComponent:0.2] : [UIColor colorWithWhite:1 alpha:0.055];
    button.layer.cornerRadius = 16;
    button.layer.borderWidth = selected ? 1.5 : 0;
    button.layer.borderColor = [self.host.view.tintColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    button.accessibilityTraits |= selected ? UIAccessibilityTraitSelected : 0;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *sender) { action(); }] forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIStackView *)choices:(NSArray<UIView *> *)buttons {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    // Accessibility sizes get a vertical layout rather than compressed labels.
    if (UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)) row.axis = UILayoutConstraintAxisVertical;
    return row;
}

- (void)reloadContent {
    for (UIView *view in self.view.subviews) [view removeFromSuperview];
    ApolloSetupAssistantViewController *host = self.host;
    if (!host) return;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    NSArray *titles = @[@"Welcome to\nApollo Reborn", @"Choose your Apollo", @"Make it yours", @"You’re all set"];
    NSArray *subtitles = @[@"A familiar favourite. A fresh start.\nLet’s make Apollo feel like you.",
        @"Start with the experience that feels right.\nEvery setting is yours to change later.",
        @"Classic charm or a little more glass.\nChoose the look you love.",
        @"Your choices are ready.\nThere’s always more to discover in Settings."];
    ApolloSetupArtwork *artwork = [ApolloSetupArtwork new];
    artwork.backgroundColor = UIColor.clearColor;
    artwork.step = self.index;
    artwork.draft = host.draft;
    artwork.accent = host.view.tintColor;
    artwork.systemStyle = host.draft.appearance == ApolloSetupAppearanceUnchanged
        ? host.view.window.traitCollection.userInterfaceStyle
        : host.view.window.windowScene.traitCollection.userInterfaceStyle;
    [artwork.heightAnchor constraintEqualToConstant:self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact ? 140 : 230].active = YES;
    UILabel *title = ApolloSetupLabel(titles[self.index], 32, UIFontWeightBold, NO);
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    UILabel *subtitle = ApolloSetupLabel(subtitles[self.index], 16, UIFontWeightRegular, YES);
    UIStackView *stack = ApolloSetupStack(@[artwork, title, subtitle], 12);
    [stack setCustomSpacing:6 afterView:artwork];
    [stack setCustomSpacing:22 afterView:subtitle];
    __weak typeof(host) weakHost = host;
    if (self.index == 0) {
        UIButton *signIn = [self button:@"Set Up Reddit" action:@selector(openSignIn)];
        signIn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
        signIn.layer.cornerRadius = 14;
        [signIn setImage:[UIImage systemImageNamed:@"person.crop.circle.badge.plus"] forState:UIControlStateNormal];
        signIn.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
        [stack addArrangedSubview:signIn];
        [stack addArrangedSubview:ApolloSetupLabel([host accountSummary], 13, UIFontWeightRegular, YES)];
        [stack addArrangedSubview:[self button:@"Restore an Apollo Backup" action:@selector(restoreBackup)]];
    } else if (self.index == 1) {
        NSMutableArray *choices = [NSMutableArray array];
        for (ApolloSetupPreset *preset in ApolloSetupPreset.allPresets) {
            [choices addObject:[self choice:preset.title selected:[host.draft.presetIdentifier isEqualToString:preset.identifier] action:^{
                weakHost.draft.presetIdentifier = preset.identifier;
                [weakHost refreshPage];
            }]];
        }
        [stack addArrangedSubview:[self choices:choices]];
        ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:host.draft.presetIdentifier];
        NSString *descriptionText = [preset.identifier isEqualToString:@"balanced"]
            ? [@"Recommended. " stringByAppendingString:preset.subtitle] : preset.subtitle;
        UILabel *description = ApolloSetupLabel(descriptionText ?: @"Your current preferences, just as you like them.", 14, UIFontWeightRegular, YES);
        [stack addArrangedSubview:description];
        if (!host.draft.firstRun) {
            [stack addArrangedSubview:[self choice:@"Keep My Settings" selected:!host.draft.presetIdentifier action:^{
                weakHost.draft.presetIdentifier = nil;
                [weakHost refreshPage];
            }]];
        }
        [stack addArrangedSubview:[self button:@"What’s included?" action:@selector(showPresetDetails)]];
    } else if (self.index == 2) {
        if (ApolloLiquidGlassCanToggle()) {
            [stack addArrangedSubview:[self choices:@[
                [self choice:@"Classic" selected:!host.draft.glass action:^{ weakHost.draft.glass = NO; [weakHost refreshPage]; }],
                [self choice:@"Liquid Glass" selected:host.draft.glass action:^{ weakHost.draft.glass = YES; [weakHost refreshPage]; }],
            ]]];
        }
        NSMutableArray *choices = [NSMutableArray array];
        NSArray *modes = @[@"Current", @"System", @"Light", @"Dark"];
        for (NSInteger i = host.draft.firstRun ? 1 : 0; i < (NSInteger)modes.count; i++) {
            ApolloSetupAppearance mode = i - 1;
            [choices addObject:[self choice:modes[i] selected:host.draft.appearance == mode action:^{
                weakHost.draft.appearance = mode;
                [weakHost refreshPage];
            }]];
        }
        [stack addArrangedSubview:[self choices:choices]];
        [stack addArrangedSubview:ApolloSetupLabel(ApolloLiquidGlassCanToggle()
            ? @"Interface changes apply when you reopen Apollo."
            : @"This build uses its installed interface style.", 13, UIFontWeightRegular, YES)];
    } else {
        ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:host.draft.presetIdentifier];
        NSArray *modes = @[@"Current appearance", @"System appearance", @"Light appearance", @"Dark appearance"];
        NSString *summary = [NSString stringWithFormat:@"%@  ·  %@%@", preset.title ?: @"Keep My Settings",
            modes[host.draft.appearance + 1], ApolloLiquidGlassCanToggle() ? host.draft.glass ? @"\nLiquid Glass" : @"\nClassic interface" : @""];
        [stack addArrangedSubview:ApolloSetupLabel(summary, 15, UIFontWeightMedium, NO)];
        [stack addArrangedSubview:[self button:@"Privacy & Diagnostics" action:@selector(showPrivacy)]];
        [stack addArrangedSubview:[self button:@"Set Up Automatic Backups" action:@selector(showBackups)]];
    }
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll insertSubview:content atIndex:0];
    // A centered column on roomy screens, a naturally scrolling page on short
    // screens and at larger text sizes. Footer controls never scroll away.
    NSLayoutConstraint *center = [stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor];
    center.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [stack.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-48],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-12], center,
    ]];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory] ||
        previous.verticalSizeClass != self.traitCollection.verticalSizeClass) [self reloadContent];
}
@end

@implementation ApolloSetupAssistantViewController
- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _draft = [ApolloSetupDraft new];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _draft.firstRun = [defaults integerForKey:UDKeySetupAssistantState] == ApolloSetupStatePending;
        _draft.presetIdentifier = _draft.firstRun ? @"balanced" : nil;
        _draft.appearance = _draft.firstRun ? ApolloSetupAppearanceSystem : ApolloSetupAppearanceUnchanged;
        _draft.glass = [defaults boolForKey:UDKeyLiquidGlassEnabled];
        _draft.installCount = !ApolloUsageHeartbeatIsDisabled();
        _draft.crashCapture = [defaults boolForKey:UDKeyCrashCaptureEnabled];
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (UIButton *)headerButton:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    button.layer.cornerRadius = 22;
    [button.widthAnchor constraintEqualToConstant:44].active = YES;
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Setup Assistant";
    // An immersive surface like Apple's feature setup sheets. The appearance
    // choice changes the miniature only; it never recolors the running app.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = ApolloSetupBackground();
    self.view.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
    self.backButton = [self headerButton:@"chevron.left" action:@selector(previousPage)];
    self.backButton.accessibilityLabel = @"Previous step";
    self.skipButton = [self headerButton:@"xmark" action:@selector(skipSetup)];
    self.skipButton.accessibilityLabel = self.draft.firstRun ? @"Skip setup" : @"Cancel setup";
    UILabel *eyebrow = ApolloSetupLabel(@"APOLLO REBORN", 11, UIFontWeightSemibold, YES);
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.backButton, eyebrow, self.skipButton]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    self.pager = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
        navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal options:nil];
    self.pager.dataSource = self;
    self.pager.delegate = self;
    [self addChildViewController:self.pager];
    self.pager.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pager.view];
    [self.pager didMoveToParentViewController:self];
    [self.pager setViewControllers:@[[self pageAtIndex:0]] direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];

    self.dots = [UIPageControl new];
    self.dots.numberOfPages = 4;
    self.dots.currentPageIndicatorTintColor = UIColor.whiteColor;
    self.dots.pageIndicatorTintColor = [UIColor colorWithWhite:1 alpha:0.23];
    self.dots.accessibilityLabel = @"Setup steps";
    [self.dots addTarget:self action:@selector(dotChanged) forControlEvents:UIControlEventValueChanged];
    self.continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.continueButton.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];
    self.continueButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.continueButton.titleLabel.numberOfLines = 0;
    self.continueButton.contentEdgeInsets = UIEdgeInsetsMake(16, 24, 16, 24);
    self.continueButton.backgroundColor = self.view.tintColor;
    self.continueButton.layer.cornerRadius = 26;
    UIColor *resolved = [self.view.tintColor resolvedColorWithTraitCollection:self.traitCollection];
    [self.continueButton setTitleColor:ApolloColorIsLight(resolved) ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
    [self.continueButton.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [self.continueButton addTarget:self action:@selector(continueSetup) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *footer = ApolloSetupStack(@[self.dots, self.continueButton], 12);
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [header.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [self.pager.view.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [self.pager.view.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.pager.view.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.pager.view.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-4],
        [footer.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
    ]];
    [self updateControls];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    sSetupNavigation = self.navigationController;
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self.navigationController setToolbarHidden:YES animated:NO];
    self.navigationController.presentationController.delegate = self;
    [self refreshPage];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshPage];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!self.navigationController.isBeingDismissed) [self.navigationController setNavigationBarHidden:NO animated:animated];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || !self.navigationController) sSetupNavigation = nil;
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    sSetupNavigation = nil;
}

- (ApolloSetupPage *)pageAtIndex:(NSInteger)index {
    ApolloSetupPage *page = [ApolloSetupPage new];
    page.index = index;
    page.host = self;
    return page;
}
- (UIViewController *)pageViewController:(UIPageViewController *)pager viewControllerBeforeViewController:(UIViewController *)controller {
    NSInteger index = ((ApolloSetupPage *)controller).index;
    return index > 0 ? [self pageAtIndex:index - 1] : nil;
}
- (UIViewController *)pageViewController:(UIPageViewController *)pager viewControllerAfterViewController:(UIViewController *)controller {
    NSInteger index = ((ApolloSetupPage *)controller).index;
    return index < 3 ? [self pageAtIndex:index + 1] : nil;
}
- (void)pageViewController:(UIPageViewController *)pager willTransitionToViewControllers:(NSArray<UIViewController *> *)pending {
    // UIPageViewController may retain a neighbouring page from before a draft
    // edit. Refresh it on entry so selections and the final summary stay current.
    for (ApolloSetupPage *page in pending) [page reloadContent];
    self.changingPage = YES;
    [self updateControls];
}
- (void)pageViewController:(UIPageViewController *)pager didFinishAnimating:(BOOL)finished previousViewControllers:(NSArray<UIViewController *> *)previous transitionCompleted:(BOOL)completed {
    self.changingPage = NO;
    self.step = ((ApolloSetupPage *)pager.viewControllers.firstObject).index;
    [self updateControls];
    if (completed) [self announcePage];
}
- (void)updateControls {
    self.dots.currentPage = self.step;
    self.backButton.alpha = self.step > 0 ? 1 : 0;
    self.backButton.enabled = self.step > 0 && !self.changingPage;
    self.continueButton.enabled = !self.changingPage;
    self.dots.enabled = !self.changingPage;
    [self.continueButton setTitle:self.step == 3 ? @"Finish Setup" : @"Continue" forState:UIControlStateNormal];
}
- (void)announcePage {
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.pager.viewControllers.firstObject.view);
}
- (void)goToPage:(NSInteger)index {
    if (self.changingPage || index == self.step || index < 0 || index > 3) return;
    UIPageViewControllerNavigationDirection direction = index > self.step ? UIPageViewControllerNavigationDirectionForward : UIPageViewControllerNavigationDirectionReverse;
    self.changingPage = YES;
    [self updateControls];
    __weak typeof(self) weakSelf = self;
    [self.pager setViewControllers:@[[self pageAtIndex:index]] direction:direction
        animated:!UIAccessibilityIsReduceMotionEnabled() completion:^(__unused BOOL finished) {
            weakSelf.step = index;
            weakSelf.changingPage = NO;
            [weakSelf updateControls];
            [weakSelf announcePage];
        }];
}
- (void)previousPage { [self goToPage:self.step - 1]; }
- (void)dotChanged { [self goToPage:self.dots.currentPage]; }
- (void)continueSetup {
    if (self.changingPage) return;
    if (self.step < 3) [self goToPage:self.step + 1];
    else [self finishSetup];
}
- (void)refreshPage {
    for (ApolloSetupPage *page in self.pager.viewControllers) [page reloadContent];
}
- (NSString *)accountSummary {
    NSString *username = ApolloActiveAccountUsername();
    if (username.length) return [@"Signed in as u/" stringByAppendingString:username];
    if (ApolloWebSessionUsernames().count) return @"Sign-in saved. Reopen Apollo to activate it.";
    if ([NSUserDefaults.standardUserDefaults stringForKey:UDKeyRedditClientId].length) return @"API key saved. Ready to sign in.";
    return @"You can connect your account later.";
}
- (void)openSignIn {
    __weak typeof(self) weakSelf = self;
    ApolloWebSessionPresentSignInChooser(self, ^{
        [weakSelf.navigationController pushViewController:[[ApolloSetupAPIKeyViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
    });
}
- (void)showPresetDetails {
    ApolloSetupDetails *details = [[ApolloSetupDetails alloc] initWithStyle:UITableViewStyleInsetGrouped];
    details.draft = self.draft;
    [self.navigationController pushViewController:details animated:YES];
}
- (void)showPrivacy {
    ApolloSetupDetails *details = [[ApolloSetupDetails alloc] initWithStyle:UITableViewStyleInsetGrouped];
    details.draft = self.draft;
    details.privacy = YES;
    [self.navigationController pushViewController:details animated:YES];
}
- (void)showBackups {
    [self.navigationController pushViewController:[[ApolloAutomaticBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
}
- (void)closeSetup {
    sSetupNavigation = nil;
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}
- (void)skipSetup {
    if (self.draft.firstRun) {
        [NSUserDefaults.standardUserDefaults setInteger:ApolloSetupStateSkipped forKey:UDKeySetupAssistantState];
        [self markCurrentReleaseSeen];
    }
    // Only staged preset/appearance/privacy changes are discarded. A completed
    // sign-in or backup operation is a separate explicit user action.
    ApolloLog(@"[SetupAssistant] Dismissed without applying a preset");
    [self closeSetup];
}

- (void)markCurrentReleaseSeen {
    if (!self.draft.firstRun) return;
    [NSUserDefaults.standardUserDefaults setObject:ApolloUpdateNormalizedVersion(@(TWEAK_VERSION))
                                           forKey:UDKeyLastSeenWhatsNewVersion];
}

- (void)finishSetup {
    if (self.finished) return;
    self.finished = YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kSetupGroup];
    ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:self.draft.presetIdentifier];
    BOOL restart = ApolloSetupWriteValues(defaults, preset.values ?: @{});
    restart |= ApolloSetupWriteValues(defaults, ApolloSetupMainAppearanceValues(self.draft.appearance));
    restart |= ApolloSetupWriteValues(group, ApolloSetupGroupAppearanceValues(self.draft.appearance));
    if (ApolloLiquidGlassCanToggle()) {
        restart |= self.draft.glass != sLiquidGlassEnabled;
        [defaults setBool:self.draft.glass forKey:UDKeyLiquidGlassEnabled];
    }
    restart |= self.draft.crashCapture != [defaults boolForKey:UDKeyCrashCaptureEnabled];
    [defaults setBool:self.draft.crashCapture forKey:UDKeyCrashCaptureEnabled];
    ApolloSetUsageHeartbeatDisabled(!self.draft.installCount);
    if (preset) [defaults setObject:preset.identifier forKey:UDKeySetupPreset];
    [defaults setInteger:ApolloSetupStateCompleted forKey:UDKeySetupAssistantState];
    [self markCurrentReleaseSeen];
    restart |= [defaults boolForKey:UDKeyWebJSONPendingRestart];
    [group synchronize];
    [defaults synchronize];
    ApolloLog(@"[SetupAssistant] Finished (preset=%@, restart=%d)", preset.identifier ?: @"keep", restart);
    if (!restart) {
        [self closeSetup];
        return;
    }
    // Do not try to resynchronise dozens of globals or rebuild Apollo's native
    // controllers. A single clean launch picks up every setting and UIKit design.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Your Setup Is Saved"
        message:@"Quit and reopen Apollo to apply your choices. You won’t need to run setup again."
        preferredStyle:UIAlertControllerStyleAlert];
    alert.modalInPresentation = YES;
    [alert addAction:[UIAlertAction actionWithTitle:@"Quit & Reopen" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [defaults synchronize]; [group synchronize]; exit(0); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup {
    UTType *backup = [UTType typeWithFilenameExtension:@"apollobackup"];
    NSArray *types = backup ? @[backup, UTTypeZIP] : @[UTTypeZIP];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    // asCopy:YES imports into our sandbox. Confirm only after the picker has
    // finished dismissing; keep the existing validated restore/restart flow.
    __weak typeof(self) weakSelf = self;
    [controller dismissViewControllerAnimated:YES completion:^{
        ApolloBackupPresentRestoreConfirmation(weakSelf, url, nil);
    }];
}

@end

void ApolloSetupAssistantPresentFrom(UIViewController *presenter) {
    if (!presenter || sSetupNavigation || presenter.presentedViewController) return;
    ApolloSetupAssistantViewController *assistant = [ApolloSetupAssistantViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:assistant];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.view.backgroundColor = ApolloSetupBackground();
    nav.view.tintColor = ApolloThemeAccentColor() ?: presenter.view.tintColor ?: UIColor.systemBlueColor;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.modalInPresentation = assistant.draft.firstRun;
    nav.preferredContentSize = CGSizeMake(540, 820);
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
        nav.sheetPresentationController.preferredCornerRadius = 30;
    }
    sSetupNavigation = nav;
    [presenter presentViewController:nav animated:YES completion:nil];
}

static void ApolloSetupAttemptPresentation(NSUInteger attempt) {
    if ([NSUserDefaults.standardUserDefaults integerForKey:UDKeySetupAssistantState] != ApolloSetupStatePending || sSetupNavigation) {
        sSetupPresentationPending = NO;
        return;
    }
    UIViewController *presenter = ApolloMainTabBarController();
    if (!presenter.view.window || presenter.presentedViewController || presenter.isBeingPresented || presenter.transitionCoordinator) {
        if (attempt < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSetupAttemptPresentation(attempt + 1);
            });
        } else {
            sSetupPresentationPending = NO;
        }
        return;
    }
    sSetupPresentationPending = NO;
    ApolloSetupAssistantPresentFrom(presenter);
    ApolloLog(@"[SetupAssistant] Presented first-run setup");
}

static void ApolloSetupPresentIfNeeded(void) {
    if ([NSUserDefaults.standardUserDefaults integerForKey:UDKeySetupAssistantState] != ApolloSetupStatePending ||
        sSetupNavigation || sSetupPresentationPending) return;
    sSetupPresentationPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloSetupAttemptPresentation(0); });
}

void ApolloSetupAssistantStart(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { ApolloSetupPresentIfNeeded(); }];
    ApolloSetupPresentIfNeeded();
}
