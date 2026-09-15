#import "settings/ApolloActionMenuSettingsViewController.h"

#import "ApolloActionMenuLayout.h"
#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsPinnedPreview.h"

#import <objc/runtime.h>

// The live preview is hosted by the shared pinned-preview machinery
// (ApolloSettingsPinnedPreview.h): the "Preview" section holds one transparent
// spacer row and the card itself is a direct subview of the table that sits on
// that row at rest and locks under the nav bar — with a copy of the section
// title — once the row would scroll away, so the item list is rearranged with
// the menu in view. Tap the card to pin/unpin it (remembered per screen).
//
// The preview is a miniature of the selected ••• menu as the saved layout
// leaves it: the visible items in order, drawn the way this device draws the
// menu (a Liquid Glass UIMenu, or Apollo's accent-tinted sheet before it),
// capped at a handful of rows with a "+N more" line. Every row carries a KEY
// (its item) and a SIGNATURE (its look): on a refresh a row that survived
// slides from its old place to its new one, a hidden row scale-fades out, a
// re-shown one scale-fades in, and the spacer row (hence the card) springs to
// the new height alongside.

#pragma mark - Preview model

static NSString *const kApolloAMAllMenus = @"all";

static NSString *const kApolloAMPreviewKeyCaption = @"caption";
static NSString *const kApolloAMPreviewKeyPanel = @"panel";
static NSString *const kApolloAMPreviewKeyMore = @"more";
static NSString *const kApolloAMPreviewRowKeyPrefix = @"row.";

static const CGFloat kApolloAMPreviewTopPadding = 10.0;      // centres the caption on the pin glyph
static const CGFloat kApolloAMPreviewBottomPadding = 12.0;
static const CGFloat kApolloAMPreviewSidePadding = 14.0;
static const CGFloat kApolloAMPreviewCaptionHeight = 14.0;
static const CGFloat kApolloAMPreviewCaptionSpacing = 10.0;
static const CGFloat kApolloAMPreviewPanelPadding = 5.0;
static const CGFloat kApolloAMPreviewRowHeight = 30.0;
static const CGFloat kApolloAMPreviewPanelMaxWidth = 250.0;
static const CGFloat kApolloAMPreviewMoreHeight = 18.0;
static const NSUInteger kApolloAMPreviewMaxRows = 8;

@interface ApolloAMPreviewState : NSObject
@property (nonatomic, copy) ApolloActionMenuContext context;
@property (nonatomic, copy) NSArray<ApolloActionMenuItem *> *visibleItems;   // saved order, hidden removed
@property (nonatomic) BOOL glass;
@property (nonatomic) CGFloat previewHeight;
@end

@implementation ApolloAMPreviewState
@end

static ApolloAMPreviewState *ApolloAMCurrentPreviewState(ApolloActionMenuContext context) {
    ApolloAMPreviewState *state = [ApolloAMPreviewState new];
    state.context = context;
    state.visibleItems = ApolloActionMenuPreviewItems(context);
    state.glass = IsLiquidGlass();
    return state;
}

// The feed's locked Submit Post row is drawn as the quick new-post buttons
// (Photo/Link/Text/Poll) on Liquid Glass while the Polls feature is on —
// ApolloSubmitPostTypesMenu swaps the plain row for them — and the mock
// follows suit, so the preview matches what that menu actually shows.
static BOOL ApolloAMItemDrawsAsPalette(ApolloActionMenuItem *item, BOOL glass) {
    return glass && item.locked && [item.kinds containsObject:@51] && ApolloPollsFeatureEnabled();
}

#pragma mark - Preview view

@interface ApolloAMPreviewView : UIView
@property (nonatomic, strong) ApolloAMPreviewState *previewState;
@property (nonatomic, strong) UIColor *accentColor;
// The rendered blocks and their signatures, keyed — what the content view's
// refresh diffs against the previous rendering.
@property (nonatomic, copy) NSDictionary<NSString *, UIView *> *itemViewsByKey;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *itemSignaturesByKey;
- (void)apollo_configurePreview;
- (CGFloat)apollo_heightForWidth:(CGFloat)width;
@end

@implementation ApolloAMPreviewView {
    UILabel *_captionLabel;
    UIView *_panelView;
    NSArray<UIView *> *_rowViews;
    UILabel *_moreLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    return self;
}

- (UIColor *)apollo_accent {
    return self.accentColor ?: ApolloThemeAccentColor() ?: self.tintColor;
}

- (NSUInteger)apollo_shownRowCount {
    return MIN(self.previewState.visibleItems.count, kApolloAMPreviewMaxRows);
}

- (NSUInteger)apollo_moreCount {
    NSUInteger visible = self.previewState.visibleItems.count;
    return visible > kApolloAMPreviewMaxRows ? visible - kApolloAMPreviewMaxRows : 0;
}

- (CGFloat)apollo_panelHeight {
    return 2.0 * kApolloAMPreviewPanelPadding + (CGFloat)[self apollo_shownRowCount] * kApolloAMPreviewRowHeight;
}

- (CGFloat)apollo_heightForWidth:(__unused CGFloat)width {
    CGFloat height = kApolloAMPreviewTopPadding + kApolloAMPreviewCaptionHeight + kApolloAMPreviewCaptionSpacing
        + [self apollo_panelHeight] + kApolloAMPreviewBottomPadding;
    if ([self apollo_moreCount] > 0) height += kApolloAMPreviewMoreHeight;
    return ceil(height);
}

// One menu row: icon + title, drawn like this device's menu draws it — label
// ink on the glass UIMenu, the accent on Apollo's classic sheet — with a
// hairline under every row but the last.
- (UIView *)apollo_rowViewForItem:(ApolloActionMenuItem *)item last:(BOOL)last {
    BOOL glass = self.previewState.glass;
    if (ApolloAMItemDrawsAsPalette(item, glass)) return [self apollo_paletteRowViewLast:last];
    UIView *row = [UIView new];
    row.backgroundColor = UIColor.clearColor;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[item icon]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = glass ? UIColor.labelColor : [self apollo_accent];
    icon.tag = 1;
    [row addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = item.title;
    title.font = [UIFont systemFontOfSize:13.0];
    title.textColor = glass ? UIColor.labelColor : [self apollo_accent];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.tag = 2;
    [row addSubview:title];

    if (!last) {
        UIView *separator = [UIView new];
        separator.backgroundColor = [(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) colorWithAlphaComponent:0.6];
        separator.tag = 3;
        [row addSubview:separator];
    }
    return row;
}

// The quick new-post buttons: the four glyphs the glass menu's small-element
// section shows (the bundled custom symbols, with the same stock fallbacks),
// spread evenly across the row, under the full-width hairline that section has.
- (UIView *)apollo_paletteRowViewLast:(BOOL)last {
    UIView *row = [UIView new];
    row.backgroundColor = UIColor.clearColor;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightRegular];
    NSArray<NSArray<NSString *> *> *glyphs = @[ @[ @"custom.photo.badge.plus", @"photo" ],
                                               @[ @"custom.link.badge.plus", @"link" ],
                                               @[ @"custom.text.page.badge.plus", @"text.alignleft" ],
                                               @[ @"custom.chart.bar.horizontal.page.fill.badge.plus", @"chart.bar" ] ];
    for (NSArray<NSString *> *glyph in glyphs) {
        UIImage *image = ApolloPollComposeSymbol(glyph[0]) ?: [UIImage systemImageNamed:glyph[1]];
        image = [[image imageByApplyingSymbolConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImageView *icon = [[UIImageView alloc] initWithImage:image];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tintColor = UIColor.labelColor;
        icon.tag = 4;
        [row addSubview:icon];
    }
    if (!last) {
        UIView *separator = [UIView new];
        separator.backgroundColor = [(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) colorWithAlphaComponent:0.6];
        separator.tag = 3;
        [row addSubview:separator];
    }
    return row;
}

- (void)apollo_configurePreview {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    ApolloAMPreviewState *state = self.previewState;
    if (!state) return;

    NSMutableDictionary<NSString *, UIView *> *viewsByKey = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *signaturesByKey = [NSMutableDictionary dictionary];
    UIColor *accent = [self apollo_accent];
    NSString *accentKey = [NSString stringWithFormat:@"%p", accent];

    UILabel *caption = [UILabel new];
    caption.text = [[NSString stringWithFormat:@"%@ menu", ApolloActionMenuContextTitle(state.context)] uppercaseString];
    caption.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    caption.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    [self addSubview:caption];
    _captionLabel = caption;
    viewsByKey[kApolloAMPreviewKeyCaption] = caption;
    signaturesByKey[kApolloAMPreviewKeyCaption] = [@"caption|" stringByAppendingString:caption.text];

    // The menu surface, drawn under the rows (the rows are siblings, not
    // children, so each animates on its own).
    UIView *panel = [UIView new];
    panel.backgroundColor = state.glass
        ? [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.55]
        : [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.7];
    panel.layer.cornerRadius = state.glass ? 18.0 : 12.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    panel.layer.borderColor = [[(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) colorWithAlphaComponent:0.5] resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [self addSubview:panel];
    _panelView = panel;
    viewsByKey[kApolloAMPreviewKeyPanel] = panel;
    signaturesByKey[kApolloAMPreviewKeyPanel] = [NSString stringWithFormat:@"panel|%d|%lu", state.glass,
                                                 (unsigned long)[self apollo_shownRowCount]];

    NSUInteger shown = [self apollo_shownRowCount];
    NSMutableArray<UIView *> *rows = [NSMutableArray arrayWithCapacity:shown];
    for (NSUInteger i = 0; i < shown; i++) {
        ApolloActionMenuItem *item = state.visibleItems[i];
        BOOL last = (i + 1 == shown);
        UIView *row = [self apollo_rowViewForItem:item last:last];
        [self addSubview:row];
        [rows addObject:row];
        NSString *key = [kApolloAMPreviewRowKeyPrefix stringByAppendingString:item.itemID];
        viewsByKey[key] = row;
        signaturesByKey[key] = [NSString stringWithFormat:@"%@|%@|%d|%d|%@",
                                ApolloAMItemDrawsAsPalette(item, state.glass) ? @"palette" : @"row",
                                item.title, state.glass, last, accentKey];
    }
    _rowViews = rows;

    NSUInteger more = [self apollo_moreCount];
    if (more > 0) {
        UILabel *moreLabel = [UILabel new];
        moreLabel.text = [NSString stringWithFormat:@"+%lu more", (unsigned long)more];
        moreLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        moreLabel.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
        moreLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:moreLabel];
        _moreLabel = moreLabel;
        viewsByKey[kApolloAMPreviewKeyMore] = moreLabel;
        signaturesByKey[kApolloAMPreviewKeyMore] = [@"more|" stringByAppendingString:moreLabel.text];
    } else {
        _moreLabel = nil;
    }

    self.itemViewsByKey = viewsByKey;
    self.itemSignaturesByKey = signaturesByKey;
    [self setNeedsLayout];
}

// Frame-based: this is a plain settings mock, not a Texture hook, and the
// keyed diff needs every block's frame the moment the rendering is laid out.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    if (width <= 0.0) return;

    CGFloat y = kApolloAMPreviewTopPadding;
    _captionLabel.frame = CGRectMake(kApolloAMPreviewSidePadding, y,
                                     MAX(0.0, width - 2.0 * kApolloAMPreviewSidePadding - 48.0), kApolloAMPreviewCaptionHeight);
    y += kApolloAMPreviewCaptionHeight + kApolloAMPreviewCaptionSpacing;

    CGFloat panelWidth = MIN(kApolloAMPreviewPanelMaxWidth, width - 2.0 * kApolloAMPreviewSidePadding);
    CGFloat panelX = round((width - panelWidth) / 2.0);
    CGFloat panelHeight = [self apollo_panelHeight];
    _panelView.frame = CGRectMake(panelX, y, panelWidth, panelHeight);

    CGFloat rowY = y + kApolloAMPreviewPanelPadding;
    for (UIView *row in _rowViews) {
        row.frame = CGRectMake(panelX, rowY, panelWidth, kApolloAMPreviewRowHeight);
        UIView *icon = [row viewWithTag:1];
        UIView *title = [row viewWithTag:2];
        UIView *separator = [row viewWithTag:3];
        CGFloat iconSide = 18.0;
        CGFloat iconY = round((kApolloAMPreviewRowHeight - iconSide) / 2.0);
        icon.frame = CGRectMake(14.0, iconY, iconSide, iconSide);
        CGFloat titleX = 14.0 + iconSide + 10.0;
        title.frame = CGRectMake(titleX, 0.0, MAX(0.0, panelWidth - titleX - 12.0), kApolloAMPreviewRowHeight);
        // A new-post buttons row (no icon/title, tag-4 glyphs instead): spread
        // the glyphs evenly and run its hairline the full width, as the menu does.
        NSMutableArray<UIView *> *glyphs = [NSMutableArray array];
        for (UIView *subview in row.subviews) {
            if (subview.tag == 4) [glyphs addObject:subview];
        }
        CGFloat slot = glyphs.count > 0 ? panelWidth / (CGFloat)glyphs.count : 0.0;
        for (NSUInteger g = 0; g < glyphs.count; g++) {
            glyphs[g].frame = CGRectMake(round(slot * (CGFloat)g + (slot - iconSide) / 2.0), iconY, iconSide, iconSide);
        }
        CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
        CGFloat separatorX = glyphs.count > 0 ? 0.0 : titleX;
        separator.frame = CGRectMake(separatorX, kApolloAMPreviewRowHeight - hairline, MAX(0.0, panelWidth - separatorX), hairline);
        rowY += kApolloAMPreviewRowHeight;
    }
    y += panelHeight;
    if (_moreLabel) {
        _moreLabel.frame = CGRectMake(panelX, y, panelWidth, kApolloAMPreviewMoreHeight);
    }
}

@end

#pragma mark - Preview content view (fills the pinned card)

// The host's contentView: owns the current rendering, replaces it with an
// animated keyed diff when the layout changes, and knows how tall the card
// must be for a given state (what the spacer row's height block asks).
@interface ApolloAMPreviewContentView : UIView
@property (nonatomic, strong) ApolloAMPreviewView *currentPreviewView;
@property (nonatomic, strong) UIColor *accentColor;
@property (nonatomic, strong) UIViewPropertyAnimator *previewAnimator;
@property (nonatomic) NSUInteger previewTransitionGeneration;
@property (nonatomic) BOOL previewRefreshPending;
@property (nonatomic, copy) ApolloActionMenuContext pendingContext;
+ (CGFloat)heightForState:(ApolloAMPreviewState *)state;
- (void)apollo_refreshForContext:(ApolloActionMenuContext)context width:(CGFloat)width animated:(BOOL)animated;
- (void)apollo_finishPreviewTransition;
@end

@implementation ApolloAMPreviewContentView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;
    return self;
}

+ (CGFloat)heightForState:(ApolloAMPreviewState *)state {
    ApolloAMPreviewView *probe = [[ApolloAMPreviewView alloc] initWithFrame:CGRectZero];
    probe.previewState = state;
    return [probe apollo_heightForWidth:0.0];
}

- (ApolloAMPreviewView *)apollo_previewViewForState:(ApolloAMPreviewState *)state width:(CGFloat)width {
    ApolloAMPreviewView *preview = [[ApolloAMPreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.accentColor = self.accentColor;
    preview.previewState = state;
    [preview apollo_configurePreview];
    state.previewHeight = [preview apollo_heightForWidth:width];
    return preview;
}

- (void)apollo_addPreviewView:(ApolloAMPreviewView *)preview height:(CGFloat)height {
    [self addSubview:preview];
    [NSLayoutConstraint activateConstraints:@[
        [preview.topAnchor constraintEqualToAnchor:self.topAnchor],
        [preview.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [preview.heightAnchor constraintEqualToConstant:height]
    ]];
}

- (void)apollo_finishPreviewTransition {
    UIViewPropertyAnimator *animator = self.previewAnimator;
    if (!animator) return;
    [animator stopAnimation:NO];
    [animator finishAnimationAtPosition:UIViewAnimatingPositionEnd];
}

- (void)apollo_replacePreviewImmediately:(ApolloAMPreviewView *)preview state:(ApolloAMPreviewState *)state {
    [self apollo_finishPreviewTransition];
    for (UIView *subview in self.subviews) [subview removeFromSuperview];
    [self apollo_addPreviewView:preview height:state.previewHeight];
    preview.alpha = 1.0;
    self.currentPreviewView = preview;
    [UIView performWithoutAnimation:^{ [self layoutIfNeeded]; }];
}

// Re-render for the context's current layout. Animated: the new rendering is
// laid out over the old one and each block is matched by key — a row that
// survived slides from its old spot to its new one (a pixel-identical twin
// swaps in silently; a restyled one cross-fades on the way), a hidden row
// scale-fades out, a re-shown one scale-fades in. The screen springs the
// spacer row (and so the card) to the new height alongside. A refresh landing
// mid-animation is queued and replayed once the animation completes.
- (void)apollo_refreshForContext:(ApolloActionMenuContext)context width:(CGFloat)width animated:(BOOL)animated {
    if (animated && self.previewAnimator.state == UIViewAnimatingStateActive) {
        self.previewRefreshPending = YES;
        self.pendingContext = context;
        return;
    }
    [self apollo_finishPreviewTransition];

    ApolloAMPreviewState *state = ApolloAMCurrentPreviewState(context);
    ApolloAMPreviewView *incoming = [self apollo_previewViewForState:state width:width];
    ApolloAMPreviewView *outgoing = self.currentPreviewView;
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || !outgoing) {
        [self apollo_replacePreviewImmediately:incoming state:state];
        return;
    }

    [self layoutIfNeeded];
    [self apollo_addPreviewView:incoming height:state.previewHeight];
    [incoming layoutIfNeeded];
    self.currentPreviewView = incoming;

    NSDictionary<NSString *, UIView *> *oldItems = outgoing.itemViewsByKey;
    NSDictionary<NSString *, UIView *> *newItems = incoming.itemViewsByKey;
    NSMutableArray<UIView *> *departingItems = [NSMutableArray array]; // gone: scale-fade out in place
    NSMutableArray<UIView *> *restyledItems = [NSMutableArray array];  // old look of a survivor: fade out in place
    for (NSString *key in newItems) {
        UIView *newItem = newItems[key];
        UIView *oldItem = oldItems[key];
        if (!oldItem) {
            newItem.alpha = 0.0;
            newItem.transform = CGAffineTransformMakeScale(0.88, 0.88);
            continue;
        }
        CGRect oldFrame = [oldItem convertRect:oldItem.bounds toView:self];
        CGRect newFrame = [newItem convertRect:newItem.bounds toView:self];
        // Top-aligned slide: the panel grows/shrinks from its top edge, and a
        // row keeps its own height, so anchoring on the top keeps a moving
        // row's icon and title on one straight path.
        newItem.transform = CGAffineTransformMakeTranslation(CGRectGetMinX(oldFrame) - CGRectGetMinX(newFrame),
                                                              CGRectGetMinY(oldFrame) - CGRectGetMinY(newFrame));
        BOOL sameLook = [outgoing.itemSignaturesByKey[key] isEqualToString:incoming.itemSignaturesByKey[key]];
        if (sameLook) {
            oldItem.alpha = 0.0; // the twin takes over from the very first frame
        } else {
            newItem.alpha = 0.0;
            [restyledItems addObject:oldItem];
        }
    }
    for (NSString *key in oldItems) {
        if (!newItems[key]) [departingItems addObject:oldItems[key]];
    }

    NSUInteger generation = ++self.previewTransitionGeneration;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.88];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.34 timingParameters:timing];
    __weak __typeof(self) weakSelf = self;
    __weak UIViewPropertyAnimator *weakAnimator = animator;
    [animator addAnimations:^{
        for (UIView *item in newItems.allValues) {
            item.alpha = 1.0;
            item.transform = CGAffineTransformIdentity;
        }
        for (UIView *item in departingItems) {
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.88, 0.88);
        }
        for (UIView *item in restyledItems) item.alpha = 0.0;
    }];
    [animator addCompletion:^(__unused UIViewAnimatingPosition finalPosition) {
        [outgoing removeFromSuperview];
        incoming.alpha = 1.0;
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.previewTransitionGeneration == generation && strongSelf.previewAnimator == weakAnimator) {
            strongSelf.previewAnimator = nil;
        }
        if (strongSelf.previewRefreshPending) {
            strongSelf.previewRefreshPending = NO;
            ApolloActionMenuContext pending = strongSelf.pendingContext ?: context;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.previewTransitionGeneration != generation) return;
                [weakSelf apollo_refreshForContext:pending width:CGRectGetWidth(weakSelf.bounds) animated:YES];
            });
        }
    }];
    self.previewAnimator = animator;
    [animator startAnimation];
}

@end

#pragma mark - Item row cell

// One catalogue item: its menu icon, its title, a drag grip and the
// show/hide switch. The switch is the accessory (so it keeps its native
// placement and theming); the grip sits inside the content area just left of
// it. A hidden item dims its icon and title but stays in the list, so it can
// be dragged and switched back on any time.
@interface ApolloAMItemCell : UITableViewCell
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, strong, readonly) UISwitch *toggle;
@property (nonatomic, strong, readonly) UIImageView *grip;
@end

@implementation ApolloAMItemCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    _toggle = [[UISwitch alloc] init];
    self.accessoryView = _toggle;
    UIImageSymbolConfiguration *gripConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
    _grip = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.horizontal.3" withConfiguration:gripConfiguration]];
    _grip.tintColor = UIColor.tertiaryLabelColor;
    _grip.contentMode = UIViewContentModeCenter;
    [self.contentView addSubview:_grip];
    self.imageView.contentMode = UIViewContentModeCenter;
    self.textLabel.numberOfLines = 1;
    self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect content = self.contentView.bounds;
    CGFloat gripSide = 24.0;
    self.grip.frame = CGRectMake(CGRectGetMaxX(content) - gripSide - 4.0,
                                 round((CGRectGetHeight(content) - gripSide) / 2.0), gripSide, gripSide);
    // Apollo's option-* art is a mixed bag of shapes; a fixed 28pt box keeps
    // every title on the same column.
    CGRect imageFrame = self.imageView.frame;
    imageFrame.size = CGSizeMake(28.0, 28.0);
    imageFrame.origin.y = round((CGRectGetHeight(content) - 28.0) / 2.0);
    self.imageView.frame = imageFrame;
    CGRect textFrame = self.textLabel.frame;
    textFrame.origin.x = CGRectGetMaxX(imageFrame) + 12.0;
    textFrame.size.width = MAX(0.0, CGRectGetMinX(self.grip.frame) - 8.0 - CGRectGetMinX(textFrame));
    self.textLabel.frame = textFrame;
    CGRect detailFrame = self.detailTextLabel.frame;
    detailFrame.origin.x = textFrame.origin.x;
    detailFrame.size.width = textFrame.size.width;
    self.detailTextLabel.frame = detailFrame;
    // The theme pass tints every image view in the cell with the accent; the
    // grip is chrome, not content.
    self.grip.tintColor = UIColor.tertiaryLabelColor;
}

@end

#pragma mark - The screen

@interface ApolloActionMenuSettingsViewController () <UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, copy) ApolloActionMenuContext context;
@property (nonatomic, strong) ApolloPinnedPreviewHost *previewHost;
// Card width the spacer row was last measured for (0 = only the table's own
// section inset was available). Updated from the real cell frame by the pinned
// layout pass, which then asks for a one-row re-measure.
@property (nonatomic) CGFloat previewCardWidth;
@property (nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@end

static NSString *const kApolloAMRowMenu = @"menu";
static NSString *const kApolloAMRowReset = @"reset";
static NSString *const kApolloAMRowPreview = @"preview";
static NSString *const kApolloAMItemRowPrefix = @"item.";

@implementation ApolloActionMenuSettingsViewController

- (void)viewDidLoad {
    self.context = ApolloActionMenuContextPost;
    [super viewDidLoad];
    self.title = @"Action Menus";
    self.selectionFeedback = [[UISelectionFeedbackGenerator alloc] init];

    // Drag & drop powers the item rows' reordering (touch and hold a row, then
    // drag). Scoped hard to that section by the drag delegate + drop proposal;
    // every other row refuses to lift. This keeps the UISwitch accessories
    // fully functional (a persistent editing mode would hide them).
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;

    // The pinned preview: shared layout pass on the table (the subclass adds no
    // ivars, so isa-swizzling the existing table view is safe) + the host as a
    // direct subview of it, never a cell, so it survives every reload.
    if (![self.tableView isKindOfClass:[ApolloPinnedPreviewTableView class]]) {
        object_setClass(self.tableView, [ApolloPinnedPreviewTableView class]);
    }
    ApolloPinnedPreviewHost *host = [[ApolloPinnedPreviewHost alloc] initWithFrame:CGRectZero];
    host.contentView = [[ApolloAMPreviewContentView alloc] initWithFrame:CGRectZero];
    __weak __typeof(self) weakSelf = self;
    host.spacerIndexPath = ^NSIndexPath * {
        return [weakSelf indexPathForRowID:kApolloAMRowPreview];
    };
    host.cardWidthDidChange = ^(CGFloat width) {
        [weakSelf previewCardWidthDidChange:width];
    };
    host.pinned = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyActionMenuPreviewPinned];
    host.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeyActionMenuPreviewPinned];
        ApolloLog(@"[ActionMenuSettings] preview %@", pinned ? @"pinned" : @"unpinned");
        // Slide the block into (or out of) its pinned spot instead of snapping:
        // the table's layout pass computes the new frames inside the animation.
        UITableView *table = weakSelf.tableView;
        [table setNeedsLayout];
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ [table layoutIfNeeded]; }
                         completion:nil];
    };
    self.previewHost = host;
    ApolloPinnedPreviewAttachHost(self.tableView, host);
    [self applyThemeToPreviewHost];
    [self.previewContentView apollo_refreshForContext:self.context
                                                width:[self previewCardWidthForTable:self.tableView]
                                             animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.previewContentView.previewRefreshPending = NO;
    self.previewContentView.pendingContext = nil;
    [self.previewContentView apollo_finishPreviewTransition];
    ++self.previewContentView.previewTransitionGeneration;
    [super viewWillDisappear:animated];
}

- (ApolloAMPreviewContentView *)previewContentView {
    return (ApolloAMPreviewContentView *)self.previewHost.contentView;
}

#pragma mark - Form

- (NSString *)itemRowIDForItemID:(NSString *)itemID {
    return [NSString stringWithFormat:@"%@%@.%@", kApolloAMItemRowPrefix, self.context, itemID];
}

- (NSString *)firstItemRowID {
    NSString *first = [self editableItems].firstObject.itemID;
    return first ? [self itemRowIDForItemID:first] : nil;
}

// All is a settings overview, never a runtime menu context. Each switch
// updates only the contexts whose catalogue contains the item. A mixed state
// remains visible in the subtitle; selecting a menu exposes its own override.
- (BOOL)editingAllMenus {
    return [self.context isEqualToString:kApolloAMAllMenus];
}

- (NSArray<ApolloActionMenuItem *> *)editableItems {
    NSMutableArray<ApolloActionMenuItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    NSArray *contexts = self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ];
    for (ApolloActionMenuContext context in contexts) {
        for (NSString *itemID in ApolloActionMenuResolvedOrder(context)) {
            ApolloActionMenuItem *item = ApolloActionMenuCatalogItem(context, itemID);
            // A locked row (the feed's Submit Post) is not the user's to move or hide.
            if (!item || item.locked || [ids containsObject:itemID]) continue;
            [ids addObject:itemID];
            [items addObject:item];
        }
    }
    if (self.editingAllMenus) {
        [items sortUsingComparator:^NSComparisonResult(ApolloActionMenuItem *a, ApolloActionMenuItem *b) {
            return [a.title localizedStandardCompare:b.title];
        }];
    }
    return items;
}

- (NSArray<NSString *> *)contextsForItem:(NSString *)itemID {
    if (!self.editingAllMenus) return @[ self.context ];
    NSMutableArray *contexts = [NSMutableArray array];
    for (NSString *context in ApolloActionMenuAllContexts()) {
        if (ApolloActionMenuCatalogItem(context, itemID)) [contexts addObject:context];
    }
    return contexts;
}

- (BOOL)itemIsHidden:(NSString *)itemID {
    for (NSString *context in [self contextsForItem:itemID]) {
        if (!ApolloActionMenuIsItemHidden(context, itemID)) return NO;
    }
    return YES;
}

// The selected menu's locked rows are absent from the list; the footer says
// where they are instead (nil when the menu has none).
- (NSString *)lockedItemsNote {
    if (self.editingAllMenus) return nil;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    for (ApolloActionMenuItem *item in ApolloActionMenuCatalog(self.context)) {
        if (!item.locked) continue;
        [notes addObject:ApolloAMItemDrawsAsPalette(item, IsLiquidGlass())
            ? [NSString stringWithFormat:@"The new-post buttons (%@) always stay at the top of this menu and can’t be hidden.", item.title]
            : [NSString stringWithFormat:@"%@ always stays at the top of this menu and can’t be hidden.", item.title]];
    }
    return notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;
    ApolloActionMenuContext context = self.context;

    // ---- Preview (the spacer row the pinned card sits on) ----

    // Escape hatch (custom row): a transparent placeholder — the pinned host
    // draws the card on top of (or, once scrolled, instead of) this slot. Its
    // height is the card's height for the selected menu's current layout.
    ApolloSettingsRow *preview =
        [ApolloSettingsRow customRowWithID:kApolloAMRowPreview
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            ApolloPinnedPreviewSpacerCell *cell =
                [[ApolloPinnedPreviewSpacerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloPinnedPreviewClearSpacerCell(cell);
            cell.isAccessibilityElement = NO;
            return cell;
        }
                                  onSelect:nil];
    preview.height = ^CGFloat {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return 0.0;
        return [ApolloAMPreviewContentView heightForState:ApolloAMCurrentPreviewState(strongSelf.context)];
    };

    // ---- Menu picker ----

    ApolloSettingsRow *menu =
        [ApolloSettingsRow valueRowWithID:kApolloAMRowMenu
                                    title:@"Menu"
                                   detail:^NSString * { return weakSelf.editingAllMenus ? @"All" : ApolloActionMenuContextTitle(weakSelf.context); }
                                 onSelect:^{ [weakSelf presentMenuPicker]; }];
    menu.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    // ---- Items (drag to reorder, switch to show/hide) ----

    NSMutableArray<ApolloSettingsRow *> *itemRows = [NSMutableArray array];
    for (ApolloActionMenuItem *item in [self editableItems]) {
        NSString *itemID = item.itemID;
        // Hidden state is read live on every configure (a switch flip reloads
        // just this row by identity), never captured at build time.
        ApolloSettingsRow *row =
            [ApolloSettingsRow customRowWithID:[self itemRowIDForItemID:itemID]
                                          cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *r) {
            return [weakSelf itemCellForItem:item
                                      hidden:[weakSelf itemIsHidden:item.itemID]
                                     inTable:tableView];
        }
                                      onSelect:nil];
        [itemRows addObject:row];
    }

    // ---- Reset (only while this menu differs from Apollo's default) ----

    ApolloSettingsRow *reset =
        [ApolloSettingsRow buttonRowWithID:kApolloAMRowReset
                                     title:self.editingAllMenus ? @"Reset All Menus" : @"Reset This Menu"
                                    action:^{ [weakSelf resetCurrentMenu]; }];
    reset.visible = ^BOOL { return weakSelf.editingAllMenus ? ApolloActionMenuCustomizedContextCount() > 0 : ApolloActionMenuContextIsCustomized(weakSelf.context); };

    NSString *itemsFooter;
    if (self.editingAllMenus) {
        itemsFooter = @"Switch an action on or off across the menus that support it. Shown in Some Menus means your per-menu choices differ. Select a menu to adjust its choices and order.";
    } else {
        itemsFooter = @"Only actions supported by this menu are listed. Some appear only for your own content or when a feature is enabled. Touch and hold to reorder. Switching visibility preserves Apollo’s order. The preview reflects the last time you opened this menu.";
        NSString *lockedNote = [self lockedItemsNote];
        if (lockedNote) itemsFooter = [itemsFooter stringByAppendingFormat:@" %@", lockedNote];
    }
    if (!self.editingAllMenus && !IsLiquidGlass()) {
        itemsFooter = [itemsFooter stringByAppendingString:@"\n\nOn this version of iOS, Apollo Reborn's own items always sit below Apollo's."];
    }

    NSMutableArray *sections = [NSMutableArray array];
    if (!self.editingAllMenus) [sections addObject:[ApolloSettingsSection sectionWithTitle:@"Preview" footer:nil rows:@[ preview ]]];
    [sections addObjectsFromArray:@[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:self.editingAllMenus ? @"Visibility across all context menus. Choose a specific menu to reorder its available actions." : ApolloActionMenuContextDescription(context)
                                           rows:@[ menu ]],
        [ApolloSettingsSection sectionWithTitle:@"Items" footer:itemsFooter rows:itemRows],
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[ reset ]],
    ]];
    return sections;
}

- (UITableViewCell *)itemCellForItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden inTable:(UITableView *)tableView {
    static NSString *const reuseID = @"Cell_ActionMenuItem";
    ApolloAMItemCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
        [cell.toggle addTarget:self action:@selector(itemSwitchToggled:) forControlEvents:UIControlEventValueChanged];
    }
    cell.itemID = item.itemID;
    cell.textLabel.text = item.title;
    cell.imageView.image = [item icon];
    cell.grip.hidden = self.editingAllMenus;
    cell.toggle.on = !hidden;
    [self styleItemCell:cell forItem:item hidden:hidden];
    return cell;
}

// The look that follows the hidden state: dimmed icon and title, the All
// overview's per-menu subtitle, accessibility. Kept apart from the cell's
// creation so a switch flip can restyle the cell IN PLACE — reloading the row
// there swapped the cell out under the switch mid-animation, cutting the
// knob's own transition short and briefly drawing two switches (the "odd
// toggle" in the 2026-09-14 device recording). Never sets the switch: it is
// either freshly configured by the caller or animating under the user's thumb.
- (void)styleItemCell:(ApolloAMItemCell *)cell forItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden {
    // A row Apollo only offers sometimes says so — unless this user's menu
    // offered it last time (a moderator's Moderator row, say).
    NSArray<NSString *> *seen = ApolloActionMenuLastPresentedItemIDs(self.context);
    BOOL offered = seen ? [seen containsObject:item.itemID] : item.usuallyShown;
    cell.detailTextLabel.text = offered ? nil : @"Shown when available";
    if (self.editingAllMenus) {
        NSArray *contexts = [self contextsForItem:item.itemID];
        NSUInteger hiddenCount = 0;
        for (NSString *context in contexts) {
            if (ApolloActionMenuIsItemHidden(context, item.itemID)) hiddenCount++;
        }
        cell.detailTextLabel.text = hiddenCount == 0 ? @"Shown in All Supported Menus" :
            (hiddenCount == contexts.count ? @"Hidden in All Supported Menus" : @"Shown in Some Menus");
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.toggle.accessibilityLabel = [NSString stringWithFormat:@"Show %@", item.title];
    // Reuse pool: set BOTH states explicitly. A hidden row's label is disabled
    // (the theme pass leaves disabled labels alone, so the dim survives it);
    // a shown row is re-enabled, reset to the plain label colour and marked
    // for the theme's primary text like every other settings row.
    UIColor *accent = [self apollo_themeAccentColor] ?: ApolloThemeAccentColor() ?: self.view.tintColor;
    cell.imageView.tintColor = hidden ? UIColor.tertiaryLabelColor : accent;
    cell.textLabel.enabled = !hidden;
    cell.textLabel.textColor = hidden ? UIColor.secondaryLabelColor : UIColor.labelColor;
    if (!hidden) [self apollo_applyPrimaryTextColorToCell:cell];
    cell.textLabel.alpha = 1.0;
    cell.accessibilityLabel = hidden ? [NSString stringWithFormat:@"%@, hidden", item.title] : item.title;
}

#pragma mark - Actions

- (void)presentMenuPicker {
    NSArray<ApolloActionMenuContext> *contexts = [@[ kApolloAMAllMenus ] arrayByAddingObjectsFromArray:ApolloActionMenuAllContexts()];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (ApolloActionMenuContext context in contexts) [titles addObject:[context isEqualToString:kApolloAMAllMenus] ? @"All" : ApolloActionMenuContextTitle(context)];
    NSInteger current = (NSInteger)[contexts indexOfObject:self.context];
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:kApolloAMRowMenu], @"Menu", titles, current,
                                ^(NSInteger pickedIndex) {
        if (pickedIndex < 0 || pickedIndex >= (NSInteger)contexts.count) return;
        [weakSelf switchToContext:contexts[(NSUInteger)pickedIndex]];
    });
}

// Swap the whole lower half of the screen to another menu: the picker row's
// footer, the item list and the reset row all follow, and the preview
// re-renders for that menu's layout (its rows cross over by key, so shared
// items like Share glide between the two renderings).
- (void)switchToContext:(ApolloActionMenuContext)context {
    if (!context || [context isEqualToString:self.context]) return;
    self.previewContentView.previewRefreshPending = NO;
    self.previewContentView.pendingContext = nil;
    [self.previewContentView apollo_finishPreviewTransition];
    ++self.previewContentView.previewTransitionGeneration;
    self.context = context;
    self.previewHost.hidden = self.editingAllMenus;
    ApolloLog(@"[ActionMenuSettings] editing %@", context);
    // The item list changes length between menus, so this must be a whole
    // reload (rebuildForm → reloadData): reloading one section against a
    // model whose OTHER sections have already changed trips UITableView's
    // batch-update consistency check. The pinned card survives reloadData
    // (it is a table subview, never a cell); only the preview animates.
    [self rebuildForm];
    [self animatePreviewStateChange];
}

- (void)itemSwitchToggled:(UISwitch *)sender {
    ApolloAMItemCell *cell = nil;
    for (UIView *view = sender.superview; view; view = view.superview) {
        if ([view isKindOfClass:[ApolloAMItemCell class]]) { cell = (ApolloAMItemCell *)view; break; }
    }
    NSString *itemID = cell.itemID;
    if (itemID.length == 0) return;
    BOOL hide = !sender.isOn;

    for (NSString *context in [self contextsForItem:itemID]) {
        ApolloActionMenuSetItemHidden(context, itemID, hide);
    }
    // Restyle the tapped cell in place (see styleItemCell:). No row reload
    // here: the switch is still animating under the user's thumb, and a
    // reload replaces the cell — and the switch — beneath it.
    ApolloActionMenuItem *item = nil;
    for (ApolloActionMenuItem *candidate in [self editableItems]) {
        if ([candidate.itemID isEqualToString:itemID]) { item = candidate; break; }
    }
    BOOL nowHidden = [self itemIsHidden:itemID];
    if (item) [self styleItemCell:cell forItem:item hidden:nowHidden];
    // Only if the model refused the change (it never does for a listed item)
    // does the switch need putting back; otherwise it keeps its own motion.
    if (cell.toggle.on == nowHidden) [cell.toggle setOn:!nowHidden animated:YES];
    [self visibilityDidChange]; // the reset row
    [self animatePreviewStateChange];
}

- (void)resetCurrentMenu {
    for (NSString *context in (self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ])) {
        ApolloActionMenuResetContext(context);
    }
    // Visibility first (this very row disappears), then the items section —
    // same ordering rule as the drag completion above.
    [self visibilityDidChange];
    NSString *firstItemRowID = [self firstItemRowID];
    if (firstItemRowID) {
        [self rebuildSectionContainingRowID:firstItemRowID withRowAnimation:UITableViewRowAnimationFade];
    }
    [self animatePreviewStateChange];
}

#pragma mark - Reordering (drag & drop)

// The item rows' section index, derived by identity (never hardcoded).
- (NSInteger)itemsSectionIndex {
    NSString *firstItemRowID = [self firstItemRowID];
    NSIndexPath *anyItemRow = firstItemRowID ? [self indexPathForRowID:firstItemRowID] : nil;
    return anyItemRow ? anyItemRow.section : NSNotFound;
}

- (BOOL)indexPathIsItemRow:(NSIndexPath *)indexPath {
    return !self.editingAllMenus && indexPath && indexPath.section == [self itemsSectionIndex];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self indexPathIsItemRow:indexPath];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    if (![self indexPathIsItemRow:fromIndexPath] || ![self indexPathIsItemRow:toIndexPath]) return;
    NSMutableArray<NSString *> *order = [[[self editableItems] valueForKey:@"itemID"] mutableCopy];
    if (fromIndexPath.row < 0 || fromIndexPath.row >= (NSInteger)order.count ||
        toIndexPath.row < 0 || toIndexPath.row >= (NSInteger)order.count) return;
    NSString *moved = order[(NSUInteger)fromIndexPath.row];
    [order removeObjectAtIndex:(NSUInteger)fromIndexPath.row];
    [order insertObject:moved atIndex:(NSUInteger)toIndexPath.row];
    ApolloActionMenuSetOrder(self.context, order);

    // Re-sync the form model with the moved rows (UIKit already animated the
    // move; rebuilding on the next runloop turn keeps the drop animation
    // intact), show the reset row, and slide the preview's rows into the new
    // order. The reset row comes FIRST: an untouched menu's first drag makes
    // it appear, and rebuildSectionContainingRowID re-snapshots every
    // section's visibility while reloading only the items section — with the
    // reset row not yet inserted, UIKit's batch-update check trips on that
    // section's count (1 in the snapshot vs 0 in the table). Diffing the
    // visibility in first inserts the row, so the rebuild's snapshot matches.
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf visibilityDidChange];
        NSString *firstItemRowID = [strongSelf firstItemRowID];
        if (firstItemRowID) {
            [strongSelf rebuildSectionContainingRowID:firstItemRowID withRowAnimation:UITableViewRowAnimationNone];
        }
        [strongSelf animatePreviewStateChange];
    });
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (![self indexPathIsItemRow:sourceIndexPath]) return sourceIndexPath;
    if ([self indexPathIsItemRow:proposedDestinationIndexPath]) return proposedDestinationIndexPath;
    NSInteger itemsSection = [self itemsSectionIndex];
    NSInteger lastRow = MAX([tableView numberOfRowsInSection:itemsSection] - 1, 0);
    NSInteger row = proposedDestinationIndexPath.section < itemsSection ? 0 : lastRow;
    return [NSIndexPath indexPathForRow:row inSection:itemsSection];
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    ApolloLog(@"[ActionMenuSettings] drag begin asked for %ld/%ld (item row: %d)",
              (long)indexPath.section, (long)indexPath.row, [self indexPathIsItemRow:indexPath]);
    if (![self indexPathIsItemRow:indexPath]) return @[];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[NSItemProvider new]];
    item.localObject = indexPath;
    return @[ item ];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (session.localDragSession && [self indexPathIsItemRow:destinationIndexPath]) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                               intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    // Local same-table reorders with a .move/insertAtDestination proposal are
    // committed by UIKit through tableView:moveRowAtIndexPath:toIndexPath:
    // before this is called; nothing else can be dropped here.
}

#pragma mark - Pinned preview plumbing

// Card chrome follows the same theme walk as the real cells (cell colour,
// section corner radius, table background for the stuck backdrop, accent for
// the pin glyph), and the mock is re-rendered for the theme's ink.
- (void)applyThemeToPreviewHost {
    ApolloPinnedPreviewHost *host = self.previewHost;
    if (!host) return;
    host.card.backgroundColor = [self apollo_themeCellBackgroundColor];
    host.card.layer.cornerRadius = ApolloPinnedPreviewSectionCornerRadius(self.tableView);
    UIColor *tableBackground = self.tableView.backgroundColor;
    UIColor *resolved = [tableBackground resolvedColorWithTraitCollection:self.tableView.traitCollection];
    if (!resolved || CGColorGetAlpha(resolved.CGColor) < 0.99) {
        tableBackground = [UIColor systemGroupedBackgroundColor];
    }
    host.backdropColor = tableBackground;
    UIColor *accent = [self apollo_themeAccentColor];
    host.accentColor = accent;
    self.previewContentView.accentColor = accent;
    [self.previewContentView apollo_refreshForContext:self.context
                                                width:[self previewCardWidthForTable:self.tableView]
                                             animated:NO];
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    [self applyThemeToPreviewHost];
}

// The spacer row must stay invisible whatever the theme pass does to cells.
- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if ([cell isKindOfClass:[ApolloPinnedPreviewSpacerCell class]]) {
        ApolloPinnedPreviewClearSpacerCell(cell);
        return;
    }
    [super apollo_applyThemeToCell:cell];
}

// Width the spacer row's height is derived from: the measured cell width once
// the layout pass has seen a real cell, else the table's reported section inset.
- (CGFloat)previewCardWidthForTable:(UITableView *)tableView {
    if (self.previewCardWidth > 0) return self.previewCardWidth;
    UIEdgeInsets inset = ApolloPinnedPreviewSectionContentInset(tableView);
    CGFloat width = CGRectGetWidth(tableView.bounds) - inset.left - inset.right;
    if (width <= 0.0) width = CGRectGetWidth(UIScreen.mainScreen.bounds) - inset.left - inset.right;
    return MAX(0.0, width);
}

- (void)previewCardWidthDidChange:(CGFloat)width {
    if (width <= 0 || fabs(width - self.previewCardWidth) <= 0.5) return;
    self.previewCardWidth = width;
    // The mock's height doesn't depend on the width (rows are fixed-height and
    // the panel is capped), so only the rendering needs the real width.
    [self.previewContentView apollo_refreshForContext:self.context width:width animated:NO];
}

// The layout changed: re-render the mock (keyed slide/fade) and spring the
// spacer row — and with it the card and every row beneath — to the new
// height in the same beat. Nothing reloads.
- (void)animatePreviewStateChange {
    if (self.editingAllMenus) return;
    CGFloat width = [self previewCardWidthForTable:self.tableView];
    [self.previewContentView apollo_refreshForContext:self.context width:width animated:YES];
    UITableView *table = self.tableView;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [table performBatchUpdates:nil completion:nil]; // re-reads the spacer's height block
        return;
    }
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [table performBatchUpdates:nil completion:nil]; // re-reads the spacer's height block
        [table layoutIfNeeded];                         // the host follows the new row rect
    }
                     completion:nil];
}

@end
