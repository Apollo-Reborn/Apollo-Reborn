#import "ApolloHiddenContentViewController.h"
#import "ApolloHiddenContentMedia.h"
#import "ApolloCommon.h"
#import "ApolloSaveAllMedia.h"
#import "ApolloSaveAllMediaItems.h"
#import <objc/runtime.h>
#import <Vision/Vision.h>
#import "ApolloThemeRuntime.h"
#import "ApolloUserProfileCache.h"
#import "UserDefaultConstants.h"

// Some image hosts return a successful image response containing their removal
// notice. Recognize only the known tombstone wording, never the post's status:
// deleted posts can still have perfectly valid images. OCR runs off the UI thread.
static void ApolloHiddenImageIsTombstone(UIImage *image, void (^completion)(BOOL)) {
    if (!image) { completion(YES); return; }
    static char resultKey;
    NSNumber *cached = objc_getAssociatedObject(image, &resultKey);
    if (cached) { completion(cached.boolValue); return; }
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.apolloreborn.hidden-image-check", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        BOOL tombstone = NO;
        // The host tombstone is monochrome on black. Skip OCR for ordinary
        // photographs; sample a tiny bitmap to keep scrolling inexpensive.
        uint8_t pixels[32 * 32 * 4] = {0};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, 32, 32, 8, 32 * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        NSUInteger dark = 0, monochrome = 0;
        if (context && image.CGImage) {
            CGContextDrawImage(context, CGRectMake(0, 0, 32, 32), image.CGImage);
            for (NSUInteger i = 0; i < 32 * 32; i++) {
                int r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2];
                if (MAX(r, MAX(g, b)) < 60) dark++;
                if (MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 15) monochrome++;
            }
        }
        if (context) CGContextRelease(context);
        if (image.CGImage && dark > 512 && monochrome > 970) {
            VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.recognitionLanguages = @[@"en-US"];
            request.usesLanguageCorrection = NO;
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
            if ([handler performRequests:@[request] error:nil]) {
                NSMutableArray *lines = [NSMutableArray array];
                for (VNRecognizedTextObservation *observation in request.results) {
                    NSString *line = [observation topCandidates:1].firstObject.string;
                    if (line) [lines addObject:line.lowercaseString];
                }
                NSString *text = [lines componentsJoinedByString:@" "];
                tombstone = [text containsString:@"looking for"] &&
                    [text containsString:@"image"] && [text containsString:@"probably deleted"];
            }
        }
        objc_setAssociatedObject(image, &resultKey, @(tombstone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(tombstone); });
    });
}

// Apollo's media loader uses this determinate clockwise ring.
@interface DACircularProgressView : UIView
@property (nonatomic, strong) UIColor *trackTintColor;
@property (nonatomic, strong) UIColor *progressTintColor;
@property (nonatomic) CGFloat thicknessRatio;
@property (nonatomic) NSInteger indeterminate;
@property (nonatomic) NSInteger clockwiseProgress;
@property (nonatomic) CGFloat progress;
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
@end

#pragma mark - Pill badge

static NSString *ApolloHiddenScoreMagnitude(NSInteger score) {
    // Avoid labs(NSIntegerMin), which overflows signed integers.
    double magnitude = fabs((double)score);
    if (magnitude < 1000) return [NSString stringWithFormat:@"%.0f", magnitude];
    double divisor = magnitude >= 1000000 ? 1000000.0 : 1000.0;
    NSString *number = [NSString stringWithFormat:@"%.1f", magnitude / divisor];
    if ([number hasSuffix:@".0"]) number = [number substringToIndex:number.length - 2];
    return [number stringByAppendingString:divisor == 1000000.0 ? @"M" : @"K"];
}

static UIColor *ApolloHiddenContentPillBackgroundColor(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return [UIColor colorWithRed:1.0 green:0.66 blue:0.64 alpha:1.0];  // salmon, matches deleted-comments chip
        case ApolloHiddenContentReasonRemoved: return [UIColor colorWithRed:1.0 green:0.71 blue:0.42 alpha:1.0];  // orange, between hidden and deleted
        case ApolloHiddenContentReasonHidden: default: return [UIColor colorWithRed:1.0 green:0.84 blue:0.55 alpha:1.0]; // amber
    }
}

static NSString *ApolloHiddenContentPillLabelText(ApolloHiddenContentReason reason) {
    switch (reason) {
        case ApolloHiddenContentReasonDeleted: return @"DELETED";
        case ApolloHiddenContentReasonRemoved: return @"REMOVED";
        case ApolloHiddenContentReasonHidden: default: return @"HIDDEN";
    }
}

// Measured from Apollo's profile CommentCellNode: author/metadata 14pt,
// body 15pt, context title 14pt medium, and gray (tertiary) metadata.
static UIFont *ApolloHiddenOverviewFont(BOOL medium) {
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:14 weight:medium ? UIFontWeightMedium : UIFontWeightRegular]];
}
static CGFloat ApolloHiddenOverviewAvatarSize(void) {
    UIFont *font = ApolloHiddenOverviewFont(YES);
    return MIN(28, MIN(floor(font.lineHeight * 1.7), MAX(24, floor(font.capHeight * 2.75))));
}
static UIColor *ApolloHiddenOverviewMetadataColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        UIColor *custom = ApolloThemeRuntimeColor(ApolloThemeTokenTertiaryLabel);
        if (custom) return [custom resolvedColorWithTraitCollection:traits];
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        return dark ? [UIColor colorWithRed:97/255.0 green:98/255.0 blue:106/255.0 alpha:1]
                    : [UIColor colorWithWhite:133/255.0 alpha:1];
    }];
}

#pragma mark - Overview entry

// Profile overview entries use a compact identity line, the complete archived
// body, and a separate parent-post preview. Do not truncate recovered text to
// the two lines of a settings-style cell.
@interface ApolloHiddenContextLabel : UILabel
@property (nonatomic) UIEdgeInsets textInsets;
@end
@implementation ApolloHiddenContextLabel
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) self.textInsets = UIEdgeInsetsMake(10, 13, 10, 13);
    return self;
}
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)lines {
    CGRect text = [super textRectForBounds:UIEdgeInsetsInsetRect(bounds, self.textInsets) limitedToNumberOfLines:lines];
    return UIEdgeInsetsInsetRect(text, UIEdgeInsetsMake(-self.textInsets.top, -self.textInsets.left, -self.textInsets.bottom, -self.textInsets.right));
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, self.textInsets)];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.08 animations:^{ self.alpha = 0.62; }];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = 1.0; }];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = 1.0; }];
}
@end

@interface ApolloHiddenContentCell : UITableViewCell <UIContextMenuInteractionDelegate, UIScrollViewDelegate>
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UILabel *voteKindLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) UILabel *contextLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UILabel *reasonAttributionLabel;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UIView *mediaContainerView;
@property (nonatomic, strong) UIScrollView *mediaScrollView;
@property (nonatomic, strong) UIStackView *mediaPagesStack;
@property (nonatomic, copy) NSArray<UIImageView *> *mediaImageViews;
@property (nonatomic, copy) NSArray<NSURL *> *mediaURLs;
@property (nonatomic, strong) NSMutableIndexSet *loadedMediaIndexes;
@property (nonatomic, strong) UILabel *mediaLabel;
@property (nonatomic, strong) NSMutableIndexSet *unavailableMediaIndexes;
@property (nonatomic) CGFloat mediaAspectRatio;
@property (nonatomic) BOOL compactMedia;
@property (nonatomic) NSUInteger mediaGeneration;

@property (nonatomic, strong) UIStackView *headerStack;
@property (nonatomic, strong) UIView *headerMiddleSpacer;
@property (nonatomic, strong) UIView *statusLeadingSpacer;
@property (nonatomic, copy) dispatch_block_t mediaTapped;
@property (nonatomic, copy) dispatch_block_t mediaSaveImageRequested;
@property (nonatomic, copy) dispatch_block_t mediaSaveAllRequested;
@property (nonatomic) NSUInteger mediaCount;
@property (nonatomic) NSUInteger currentMediaIndex;
@property (nonatomic, strong) NSLayoutConstraint *previewHeight;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UIView *overviewSeparatorView;
@property (nonatomic, copy) NSString *representedName;
@end

@implementation ApolloHiddenContentCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.authorLabel = [UILabel new];
        self.authorLabel.font = ApolloHiddenOverviewFont(YES);
        self.authorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.authorLabel.numberOfLines = 1;
        [self.authorLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        self.voteKindLabel = [UILabel new];
        self.voteKindLabel.font = ApolloHiddenOverviewFont(NO);
        self.voteKindLabel.textColor = UIColor.secondaryLabelColor;
        [self.voteKindLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        self.dateLabel = [UILabel new];
        self.dateLabel.font = ApolloHiddenOverviewFont(NO);
        [self.dateLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        self.avatarView = [UIImageView new];
        self.avatarView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarView.clipsToBounds = YES;
        self.avatarView.layer.cornerRadius = ApolloHiddenOverviewAvatarSize() / 2;
        ApolloHiddenContextLabel *flair = [ApolloHiddenContextLabel new];
        flair.textInsets = UIEdgeInsetsMake(1, 5, 1, 5);
        flair.layer.cornerRadius = 4;
        flair.clipsToBounds = YES;
        self.reasonLabel = flair;
        // Match Apollo's compact flair typography.
        self.reasonLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular]];
        [self.reasonLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        self.reasonAttributionLabel = [UILabel new];
        self.reasonAttributionLabel.font = ApolloHiddenOverviewFont(NO);
        self.reasonAttributionLabel.textColor = UIColor.secondaryLabelColor;
        [self.reasonAttributionLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        self.headerMiddleSpacer = [UIView new];
        self.statusLeadingSpacer = [UIView new];
        self.statusLeadingSpacer.hidden = YES;
        [self.authorLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.voteKindLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.reasonAttributionLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.reasonLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.dateLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *identity = [[UIStackView alloc] initWithArrangedSubviews:@[self.avatarView, self.authorLabel, self.voteKindLabel]];
        identity.axis = UILayoutConstraintAxisHorizontal;
        identity.alignment = UIStackViewAlignmentCenter;
        identity.spacing = 6;
        [identity setCustomSpacing:10 afterView:self.authorLabel];
        UIStackView *status = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusLeadingSpacer, self.reasonAttributionLabel, self.reasonLabel, self.dateLabel]];
        status.axis = UILayoutConstraintAxisHorizontal;
        status.alignment = UIStackViewAlignmentCenter;
        status.spacing = 6;
        self.headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[identity, self.headerMiddleSpacer, status]];
        self.headerStack.axis = UILayoutConstraintAxisHorizontal;
        self.headerStack.alignment = UIStackViewAlignmentCenter;
        self.headerStack.spacing = 6;
        NSLayoutConstraint *avatarWidth = [self.avatarView.widthAnchor constraintEqualToConstant:ApolloHiddenOverviewAvatarSize()];
        avatarWidth.priority = UILayoutPriorityRequired;
        avatarWidth.active = YES;
        [self.avatarView.heightAnchor constraintEqualToConstant:ApolloHiddenOverviewAvatarSize()].active = YES;
        self.bodyLabel = [UILabel new];
        self.bodyLabel.numberOfLines = 0;
        self.bodyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        self.contextLabel = [ApolloHiddenContextLabel new];
        self.contextLabel.numberOfLines = 0;
        self.contextLabel.font = ApolloHiddenOverviewFont(YES);
        self.contextLabel.layer.cornerRadius = 4;
        self.contextLabel.clipsToBounds = YES;
        self.contextLabel.userInteractionEnabled = YES;
        self.mediaContainerView = [UIView new];
        self.mediaContainerView.clipsToBounds = YES;
        [self.mediaContainerView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_openMedia)]];
        [self.mediaContainerView addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
        self.mediaScrollView = [UIScrollView new];
        self.mediaScrollView.delegate = self;
        self.mediaScrollView.pagingEnabled = YES;
        self.mediaScrollView.showsHorizontalScrollIndicator = NO;
        self.mediaScrollView.directionalLockEnabled = YES;
        self.mediaScrollView.alwaysBounceHorizontal = YES;
        self.mediaScrollView.translatesAutoresizingMaskIntoConstraints = NO;
        self.mediaPagesStack = [UIStackView new];
        self.mediaPagesStack.axis = UILayoutConstraintAxisHorizontal;
        self.mediaPagesStack.spacing = 0;
        self.mediaPagesStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.mediaContainerView addSubview:self.mediaScrollView];
        [self.mediaScrollView addSubview:self.mediaPagesStack];
        self.mediaLabel = [ApolloHiddenContextLabel new];
        ((ApolloHiddenContextLabel *)self.mediaLabel).textInsets = UIEdgeInsetsMake(5, 13, 5, 13);
        self.mediaLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        self.mediaLabel.textColor = UIColor.whiteColor;
        self.mediaLabel.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.7];
        self.mediaLabel.layer.cornerRadius = 12;
        self.mediaLabel.clipsToBounds = YES;
        self.mediaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.mediaContainerView addSubview:self.mediaLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.mediaScrollView.leadingAnchor constraintEqualToAnchor:self.mediaContainerView.leadingAnchor],
            [self.mediaScrollView.trailingAnchor constraintEqualToAnchor:self.mediaContainerView.trailingAnchor],
            [self.mediaScrollView.topAnchor constraintEqualToAnchor:self.mediaContainerView.topAnchor],
            [self.mediaScrollView.bottomAnchor constraintEqualToAnchor:self.mediaContainerView.bottomAnchor],
            [self.mediaPagesStack.leadingAnchor constraintEqualToAnchor:self.mediaScrollView.contentLayoutGuide.leadingAnchor],
            [self.mediaPagesStack.trailingAnchor constraintEqualToAnchor:self.mediaScrollView.contentLayoutGuide.trailingAnchor],
            [self.mediaPagesStack.topAnchor constraintEqualToAnchor:self.mediaScrollView.contentLayoutGuide.topAnchor],
            [self.mediaPagesStack.bottomAnchor constraintEqualToAnchor:self.mediaScrollView.contentLayoutGuide.bottomAnchor],
            [self.mediaPagesStack.heightAnchor constraintEqualToAnchor:self.mediaScrollView.frameLayoutGuide.heightAnchor],
            [self.mediaLabel.topAnchor constraintEqualToAnchor:self.mediaContainerView.topAnchor constant:10],
            [self.mediaLabel.trailingAnchor constraintEqualToAnchor:self.mediaContainerView.trailingAnchor constant:-10],
        ]];
        self.previewHeight = [self.mediaContainerView.heightAnchor constraintEqualToConstant:180];
        self.previewHeight.priority = UILayoutPriorityRequired - 1;
        self.previewHeight.active = YES;
        self.contentStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.headerStack, self.bodyLabel, self.mediaContainerView, self.contextLabel]];
        self.contentStack.axis = UILayoutConstraintAxisVertical;
        self.contentStack.spacing = 8;
        self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
        // Apollo's profile Overview separates entries with a short section
        // gutter rather than UITableView's one-pixel rule.
        self.overviewSeparatorView = [UIView new];
        self.overviewSeparatorView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.contentStack];
        [self.contentView addSubview:self.overviewSeparatorView];
        [NSLayoutConstraint activateConstraints:@[
            [self.contentStack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:15],
            [self.contentStack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-15],
            [self.contentStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [self.contentStack.bottomAnchor constraintEqualToAnchor:self.overviewSeparatorView.topAnchor constant:-10],
            [self.overviewSeparatorView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [self.overviewSeparatorView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [self.overviewSeparatorView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [self.overviewSeparatorView.heightAnchor constraintEqualToConstant:8.0],
        ]];
        for (UILabel *label in @[self.authorLabel, self.voteKindLabel, self.bodyLabel, self.contextLabel, self.reasonAttributionLabel, self.reasonLabel, self.dateLabel]) {
            label.adjustsFontForContentSizeCategory = YES;
        }
        [self apollo_updateHeaderLayout];
    }
    return self;
}
- (void)apollo_applyOverviewTheme {
    self.backgroundColor = ApolloThemeSubredditListBackgroundColor() ?: UIColor.systemBackgroundColor;
    self.contentView.backgroundColor = self.backgroundColor;
    UIColor *contextColor = ApolloThemeSubredditListHeaderBackgroundColor() ?: UIColor.secondarySystemBackgroundColor;
    self.overviewSeparatorView.backgroundColor = contextColor;
    self.contextLabel.backgroundColor = contextColor;
    self.bodyLabel.textColor = ApolloThemeSubredditListTextColor() ?: UIColor.labelColor;
    self.authorLabel.textColor = self.bodyLabel.textColor;
    UIColor *metadataColor = ApolloHiddenOverviewMetadataColor();
    self.dateLabel.textColor = metadataColor;
    self.voteKindLabel.textColor = metadataColor;
    self.reasonAttributionLabel.textColor = metadataColor;
    UIColor *noticeColor = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    for (UIImageView *page in self.mediaImageViews) {
        for (UIStackView *notice in page.subviews) {
            if (![notice isKindOfClass:UIStackView.class]) continue;
            for (UIView *part in notice.arrangedSubviews) {
                part.tintColor = noticeColor;
                if ([part isKindOfClass:UILabel.class]) ((UILabel *)part).textColor = noticeColor;
            }
        }
    }
    if (self.voteKindLabel.attributedText.length) {
        NSMutableAttributedString *text = [self.voteKindLabel.attributedText mutableCopy];
        [text addAttribute:NSForegroundColorAttributeName value:metadataColor range:NSMakeRange(0, text.length)];
        self.voteKindLabel.attributedText = text;
    }
}
- (void)apollo_updateHeaderLayout {
    BOOL accessibility = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.headerStack.axis = accessibility ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.headerStack.alignment = accessibility ? UIStackViewAlignmentFill : UIStackViewAlignmentCenter;
    self.headerStack.spacing = accessibility ? 4 : 6;
    self.headerMiddleSpacer.hidden = accessibility;
    self.statusLeadingSpacer.hidden = !accessibility;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyOverviewTheme];
    if (![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self apollo_updateHeaderLayout];
    }
}
- (void)apollo_openMedia {
    if (![self.unavailableMediaIndexes containsIndex:self.currentMediaIndex] && self.mediaTapped) self.mediaTapped();
}
- (void)apollo_updateMediaHeight {
    BOOL compact = [self.unavailableMediaIndexes containsIndex:self.currentMediaIndex];
    if (compact == self.compactMedia) return;
    self.compactMedia = compact;
    self.previewHeight.active = NO;
    self.previewHeight = compact
        ? [self.mediaContainerView.heightAnchor constraintEqualToConstant:100]
        : [self.mediaContainerView.heightAnchor constraintEqualToAnchor:self.mediaContainerView.widthAnchor multiplier:1.0 / self.mediaAspectRatio];
    self.previewHeight.priority = UILayoutPriorityRequired - 1;
    self.previewHeight.active = YES;
    // Recalculate the self-sizing row when an asynchronous image resolves.
    UIView *parent = self.superview;
    while (parent && ![parent isKindOfClass:UITableView.class]) parent = parent.superview;
    if (parent) [(UITableView *)parent performBatchUpdates:nil completion:nil];
}
- (void)apollo_showUnavailableAtIndex:(NSUInteger)index {
    [self.unavailableMediaIndexes addIndex:index];
    UIImageView *page = self.mediaImageViews[index];
    page.image = nil;
    page.accessibilityTraits = UIAccessibilityTraitStaticText;
    page.accessibilityLabel = @"Image unavailable. The original image is no longer available.";
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"photo.badge.exclamationmark"]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *title = [UILabel new];
    title.text = @"Image unavailable";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    UILabel *detail = [UILabel new];
    detail.text = @"The original image is no longer available.";
    detail.font = [UIFont systemFontOfSize:13];
    detail.numberOfLines = 0;
    detail.textAlignment = NSTextAlignmentCenter;
    UIColor *color = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    icon.tintColor = color;
    title.textColor = color;
    detail.textColor = color;
    UIStackView *notice = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, detail]];
    notice.axis = UILayoutConstraintAxisVertical;
    notice.alignment = UIStackViewAlignmentCenter;
    notice.spacing = 3;
    [notice setCustomSpacing:6 afterView:icon];
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:notice];
    [NSLayoutConstraint activateConstraints:@[
        [icon.heightAnchor constraintEqualToConstant:24],
        [icon.widthAnchor constraintEqualToConstant:24],
        [notice.centerYAnchor constraintEqualToAnchor:page.centerYAnchor],
        [notice.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:8],
        [notice.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:-8],
    ]];
    [self apollo_updateMediaHeight];
}
- (void)apollo_updateCurrentMediaIndex {
    CGFloat width = CGRectGetWidth(self.mediaScrollView.bounds);
    if (width <= 0 || self.mediaURLs.count == 0) return;
    NSUInteger index = MIN(self.mediaURLs.count - 1, (NSUInteger)MAX(0, lround(self.mediaScrollView.contentOffset.x / width)));
    self.currentMediaIndex = index;
    if (self.mediaURLs.count > 1) {
        self.mediaLabel.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)index + 1, (unsigned long)self.mediaURLs.count];
        self.mediaLabel.hidden = NO;
    }
    [self apollo_updateMediaHeight];
    [self apollo_loadMediaAroundIndex:index];
}
- (void)apollo_loadMediaAroundIndex:(NSUInteger)centerIndex {
    if (self.mediaURLs.count == 0) return;
    NSUInteger first = centerIndex > 0 ? centerIndex - 1 : 0;
    NSUInteger last = MIN(self.mediaURLs.count - 1, centerIndex + 1);
    NSString *representedName = self.representedName;
    NSUInteger generation = self.mediaGeneration;
    for (NSUInteger index = first; index <= last; index++) {
        if ([self.loadedMediaIndexes containsIndex:index]) continue;
        [self.loadedMediaIndexes addIndex:index];
        NSURL *url = self.mediaURLs[index];
        __weak typeof(self) weakSelf = self;
        [ApolloUserProfileCache.sharedCache requestImageForURL:url completion:^(UIImage *image) {
            typeof(self) owner = weakSelf;
            if (!owner || owner.mediaGeneration != generation || ![owner.representedName isEqualToString:representedName] || index >= owner.mediaURLs.count || ![owner.mediaURLs[index] isEqual:url]) return;
            ApolloHiddenImageIsTombstone(image, ^(BOOL unavailable) {
                typeof(self) cell = weakSelf;
                if (!cell || cell.mediaGeneration != generation || ![cell.representedName isEqualToString:representedName] || index >= cell.mediaURLs.count || ![cell.mediaURLs[index] isEqual:url]) return;
                if (unavailable) {
                    [cell apollo_showUnavailableAtIndex:index];
                } else {
                    [UIView transitionWithView:cell.mediaImageViews[index] duration:0.18
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                        animations:^{ cell.mediaImageViews[index].image = image; } completion:nil];
                }
                if (cell.mediaURLs.count == 1) cell.mediaLabel.hidden = YES;
            });
        }];
    }
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self apollo_updateCurrentMediaIndex];
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    if (!self.mediaSaveImageRequested || [self.unavailableMediaIndexes containsIndex:self.currentMediaIndex]) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *saveImage = [UIAction actionWithTitle:@"Save Image"
                                             image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
            if (weakSelf.mediaSaveImageRequested) weakSelf.mediaSaveImageRequested();
        }];
        if (weakSelf.mediaCount <= 1 || !weakSelf.mediaSaveAllRequested) {
            return [UIMenu menuWithTitle:@"" children:@[saveImage]];
        }
        UIAction *saveAll = [UIAction actionWithTitle:@"Save All Media"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.down.on.square"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *action) {
            if (weakSelf.mediaSaveAllRequested) weakSelf.mediaSaveAllRequested();
        }];
        return [UIMenu menuWithTitle:@"" children:@[saveImage, saveAll]];
    }];
}
- (void)configureWithItem:(ApolloHiddenContentItem *)item username:(NSString *)username {
    self.mediaGeneration++;
    self.representedName = item.fullName;
    [self apollo_applyOverviewTheme];
    NSString *author = item.author.length && ![item.author isEqualToString:@"[deleted]"] ? item.author : username;
    NSString *kindLabel = item.kind == ApolloHiddenContentKindComment ? @"Comment" : @"Post";
    NSInteger score = item.score.integerValue;
    NSString *voteText = score < 0
        ? [NSString stringWithFormat:@"↓ %@", ApolloHiddenScoreMagnitude(score)]
        : [NSString stringWithFormat:@"↑ %@", ApolloHiddenScoreMagnitude(score)];
    self.authorLabel.text = author;
    self.authorLabel.accessibilityLabel = author;
    NSString *voteKindText = item.score
        ? [NSString stringWithFormat:@"%@ · %@", voteText, kindLabel]
        : kindLabel;
    NSMutableAttributedString *attributedVoteKind = [[NSMutableAttributedString alloc] initWithString:voteKindText attributes:@{
        NSFontAttributeName: self.voteKindLabel.font,
        NSForegroundColorAttributeName: self.dateLabel.textColor ?: UIColor.secondaryLabelColor,
    }];
    NSRange kindRange = [voteKindText rangeOfString:kindLabel options:NSBackwardsSearch];
    if (kindRange.location != NSNotFound) {
        UIFont *kindFont = ApolloHiddenOverviewFont(NO);
        [attributedVoteKind addAttribute:NSFontAttributeName value:kindFont range:kindRange];
    }
    self.voteKindLabel.attributedText = attributedVoteKind;
    NSString *reasonAttribution = item.removalDetail.length
        ? item.removalDetail
        : (item.reason == ApolloHiddenContentReasonDeleted ? @"Author" : nil);
    self.reasonAttributionLabel.text = reasonAttribution.length
        ? [NSString stringWithFormat:@"%@ ·", reasonAttribution]
        : nil;
    self.reasonAttributionLabel.hidden = reasonAttribution.length == 0;
    self.reasonLabel.text = ApolloHiddenContentPillLabelText(item.reason);
    self.reasonLabel.backgroundColor = ApolloHiddenContentPillBackgroundColor(item.reason);
    self.reasonLabel.textColor = UIColor.blackColor;
    NSTimeInterval age = MAX(0, -item.createdDate.timeIntervalSinceNow);
    NSInteger amount = (NSInteger)age;
    NSString *unit = @"s";
    if (age >= 365 * 86400) { amount = (NSInteger)(age / (365 * 86400)); unit = @"y"; }
    else if (age >= 86400) { amount = (NSInteger)(age / 86400); unit = @"d"; }
    else if (age >= 3600) { amount = (NSInteger)(age / 3600); unit = @"h"; }
    else if (age >= 60) { amount = (NSInteger)(age / 60); unit = @"m"; }
    self.dateLabel.text = item.createdDate ? [NSString stringWithFormat:@"%ld%@", (long)amount, unit] : @"";
    BOOL isImagePost = item.kind == ApolloHiddenContentKindPost && (item.mediaURLs.count > 0 || item.previewURL != nil);
    if (isImagePost) {
        // Apollo presents an image post as media plus its post-preview card;
        // don't make the post title look like a comment body above the image.
        self.bodyLabel.text = item.body;
        self.bodyLabel.hidden = item.body.length == 0;
    } else {
        self.bodyLabel.text = item.kind == ApolloHiddenContentKindPost && item.title.length
            ? [NSString stringWithFormat:@"%@%@", item.title, item.body.length ? [@"\n\n" stringByAppendingString:item.body] : @""]
            : (item.body.length ? item.body : @"No text in the archive");
        self.bodyLabel.hidden = NO;
    }
    NSString *contextTitle = item.kind == ApolloHiddenContentKindComment
        ? item.parentPostTitle
        : (isImagePost ? item.title : nil);
    // Keep the parent title and subreddit as separate paragraphs, like the
    // native overview preview, with a small gap and quieter subreddit text.
    NSString *subreddit = item.subreddit ?: @"";
    if ([subreddit hasPrefix:@"r/"]) subreddit = [subreddit substringFromIndex:2];
    NSString *context = [NSString stringWithFormat:@"%@%@%@", contextTitle ?: @"",
        contextTitle.length && subreddit.length ? @"\n" : @"", subreddit];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.paragraphSpacing = 8;
    NSMutableAttributedString *preview = [[NSMutableAttributedString alloc] initWithString:context attributes:@{
        NSFontAttributeName: self.contextLabel.font,
        NSForegroundColorAttributeName: ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor,
    }];
    if (contextTitle.length && subreddit.length) {
        [preview addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, contextTitle.length + 1)];
    }
    if (subreddit.length) {
        [preview addAttributes:@{NSForegroundColorAttributeName: ApolloHiddenOverviewMetadataColor(),
                                 NSFontAttributeName: ApolloHiddenOverviewFont(NO)}
                        range:NSMakeRange(context.length - subreddit.length, subreddit.length)];
    }
    self.contextLabel.attributedText = preview;
    self.contextLabel.hidden = context.length == 0;
    self.contextLabel.alpha = 1.0;
    // Read the shared preference whenever a row is configured, including
    // when returning from settings. Compact Full avatars keep a circular crop.
    NSInteger avatarStyle = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyProfileAvatarStyle];
    self.avatarView.layer.cornerRadius = avatarStyle == 2 ? ApolloHiddenOverviewAvatarSize() * 0.24 : ApolloHiddenOverviewAvatarSize() / 2;
    self.avatarView.hidden = ![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowUserAvatars];
    self.avatarView.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    self.avatarView.tintColor = ApolloThemeAccentColor() ?: self.tintColor;
    for (UIView *page in self.mediaPagesStack.arrangedSubviews) {
        [self.mediaPagesStack removeArrangedSubview:page];
        [page removeFromSuperview];
    }
    NSArray<NSURL *> *mediaURLs = item.mediaURLs.count ? item.mediaURLs : (item.previewURL ? @[item.previewURL] : @[]);
    self.mediaURLs = mediaURLs;
    self.mediaCount = mediaURLs.count;
    self.currentMediaIndex = 0;
    self.loadedMediaIndexes = [NSMutableIndexSet indexSet];
    self.unavailableMediaIndexes = [NSMutableIndexSet indexSet];
    self.compactMedia = NO;
    NSMutableArray<UIImageView *> *imageViews = [NSMutableArray arrayWithCapacity:mediaURLs.count];
    for (NSUInteger index = 0; index < mediaURLs.count; index++) {
        UIImageView *imageView = [UIImageView new];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.clipsToBounds = YES;
        imageView.isAccessibilityElement = YES;
        imageView.accessibilityTraits = UIAccessibilityTraitButton;
        imageView.accessibilityLabel = mediaURLs.count > 1
            ? [NSString stringWithFormat:@"Image %lu of %lu", (unsigned long)index + 1, (unsigned long)mediaURLs.count]
            : @"Open image";
        [self.mediaPagesStack addArrangedSubview:imageView];
        [imageView.widthAnchor constraintEqualToAnchor:self.mediaScrollView.frameLayoutGuide.widthAnchor].active = YES;
        [imageViews addObject:imageView];
    }
    self.mediaImageViews = imageViews;
    [self.mediaScrollView setContentOffset:CGPointZero animated:NO];
    // Derive media height from the final laid-out feed width, not a reused
    // cell's creation-time bounds. A fixed height computed during configure
    // could leave side gutters until navigation forced another layout pass.
    // Do not cap portrait height: fit the full image to the feed width.
    CGFloat ratio = item.previewAspectRatio;
    if (!isfinite(ratio) || ratio < 0.1 || ratio > 10.0) ratio = 1.0;
    self.mediaAspectRatio = ratio;
    self.previewHeight.active = NO;
    self.previewHeight = [self.mediaContainerView.heightAnchor
        constraintEqualToAnchor:self.mediaContainerView.widthAnchor multiplier:1.0 / ratio];
    self.previewHeight.priority = UILayoutPriorityRequired - 1;
    self.previewHeight.active = YES;
    self.mediaLabel.text = mediaURLs.count > 1 ? [NSString stringWithFormat:@"1/%lu", (unsigned long)mediaURLs.count] : @"Loading image…";
    self.mediaLabel.hidden = NO;
    self.mediaContainerView.hidden = mediaURLs.count == 0;
    self.mediaScrollView.scrollEnabled = mediaURLs.count > 1;
    NSString *name = item.fullName;
    __weak typeof(self) weakSelf = self;
    ApolloUserProfileCache *cache = ApolloUserProfileCache.sharedCache;
    if (!self.avatarView.hidden) [cache requestInfoForUsername:author completion:^(ApolloUserProfileInfo *info) {
        NSURL *url = info.iconURL;
        if (!url) return;
        [cache requestImageForURL:url completion:^(UIImage *image) {
            if ([weakSelf.representedName isEqualToString:name] && image) weakSelf.avatarView.image = image;
        }];
    }];
    [self apollo_loadMediaAroundIndex:0];
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedName = nil;
    self.mediaTapped = nil;
    self.mediaSaveImageRequested = nil;
    self.mediaSaveAllRequested = nil;
    self.mediaURLs = @[];
    self.mediaImageViews = @[];
}
@end

#pragma mark - Deleted/removed-item detail

// A deleted or removed item's live reddit.com page just shows Reddit's own
// tombstone ("[removed]"/"[deleted by user]"), not anything useful, so this
// shows the already-fetched archived title/body directly instead.
@interface ApolloHiddenContentDetailViewController : UIViewController
@property (nonatomic, strong) ApolloHiddenContentItem *item;
@property (nonatomic, strong) UIControl *subredditControl;
@end

@implementation ApolloHiddenContentDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL isPost = self.item.kind == ApolloHiddenContentKindPost;
    self.title = self.item.reason == ApolloHiddenContentReasonRemoved
        ? (isPost ? @"Removed Post" : @"Removed Comment")
        : (isPost ? @"Deleted Post" : @"Deleted Comment");
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                 target:self action:@selector(apollo_share)];
    UIBarButtonItem *arcticShiftItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"safari"]
                                                                          style:UIBarButtonItemStylePlain
                                                                         target:self action:@selector(apollo_openInArcticShift)];
    arcticShiftItem.accessibilityLabel = @"Open in Arctic Shift";
    self.navigationItem.rightBarButtonItems = @[shareItem, arcticShiftItem];

    UITextView *textView = [UITextView new];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.font = [UIFont systemFontOfSize:16.0];
    textView.backgroundColor = self.view.backgroundColor;
    textView.textColor = UIColor.labelColor;
    textView.textContainerInset = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    textView.text = [self apollo_archivedText];
    [self.view addSubview:textView];

    NSString *subreddit = self.item.subreddit ?: @"";
    if ([subreddit hasPrefix:@"r/"]) subreddit = [subreddit substringFromIndex:2];
    if (subreddit.length > 0) {
        self.subredditControl = [UIControl new];
        self.subredditControl.translatesAutoresizingMaskIntoConstraints = NO;
        self.subredditControl.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemBackgroundColor;
        self.subredditControl.layer.cornerRadius = 8;
        self.subredditControl.isAccessibilityElement = YES;
        self.subredditControl.accessibilityTraits = UIAccessibilityTraitButton;
        self.subredditControl.accessibilityLabel = [NSString stringWithFormat:@"Open %@ subreddit", subreddit];
        [self.subredditControl addTarget:self action:@selector(apollo_openSubreddit) forControlEvents:UIControlEventTouchUpInside];
        UILabel *subredditLabel = [UILabel new];
        subredditLabel.translatesAutoresizingMaskIntoConstraints = NO;
        subredditLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        subredditLabel.textColor = UIColor.labelColor;
        subredditLabel.text = subreddit;
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.tintColor = UIColor.tertiaryLabelColor;
        [self.subredditControl addSubview:subredditLabel];
        [self.subredditControl addSubview:chevron];
        [self.view addSubview:self.subredditControl];
        [NSLayoutConstraint activateConstraints:@[
            [self.subredditControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
            [self.subredditControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
            [self.subredditControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
            [self.subredditControl.heightAnchor constraintEqualToConstant:48],
            [subredditLabel.leadingAnchor constraintEqualToAnchor:self.subredditControl.leadingAnchor constant:14],
            [subredditLabel.centerYAnchor constraintEqualToAnchor:self.subredditControl.centerYAnchor],
            [chevron.trailingAnchor constraintEqualToAnchor:self.subredditControl.trailingAnchor constant:-14],
            [chevron.centerYAnchor constraintEqualToAnchor:self.subredditControl.centerYAnchor],
            [textView.topAnchor constraintEqualToAnchor:self.subredditControl.bottomAnchor constant:8],
        ]];
    } else {
        [textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor].active = YES;
    }
    [NSLayoutConstraint activateConstraints:@[
        [textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (NSString *)apollo_archivedText {
    NSMutableString *text = [NSMutableString string];
    if (self.item.title.length > 0) [text appendFormat:@"%@\n\n", self.item.title];
    if (self.item.removalDetail.length > 0) {
        NSString *verb = self.item.reason == ApolloHiddenContentReasonDeleted ? @"Deleted by" : @"Removed by";
        [text appendFormat:@"%@: %@\n\n", verb, self.item.removalDetail];
    }
    [text appendString:self.item.body.length > 0 ? self.item.body : @"(no body text in the archive)"];
    return text;
}

- (void)apollo_openSubreddit {
    NSString *subreddit = self.item.subreddit ?: @"";
    if ([subreddit hasPrefix:@"r/"]) subreddit = [subreddit substringFromIndex:2];
    if (subreddit.length == 0) return;
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = @"www.reddit.com";
    components.path = [@"/r/" stringByAppendingString:subreddit];
    NSURL *url = components.URL;
    if (!url) return;
    if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)apollo_share {
    NSString *subreddit = self.item.subreddit ?: @"";
    if ([subreddit hasPrefix:@"r/"]) subreddit = [subreddit substringFromIndex:2];
    NSString *sharePrefix = subreddit.length ? [NSString stringWithFormat:@"r/%@\n\n", subreddit] : @"";
    NSString *shareText = [sharePrefix stringByAppendingString:[self apollo_archivedText]];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[shareText]
                                                                             applicationActivities:nil];
    // iPad presents this as a popover, which crashes without an anchor.
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:activity animated:YES completion:nil];
}

// Arctic Shift has no per-item permalink route -- it's a single-page search UI
// that auto-runs a search from ?fun=ids&ids=<fullname> in the URL, which is
// what "ID Lookup" does manually (confirmed against the site's bundled JS).
- (void)apollo_openInArcticShift {
    if (self.item.fullName.length == 0) return;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/search"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"fun" value:@"ids"],
        [NSURLQueryItem queryItemWithName:@"ids" value:self.item.fullName],
    ];
    if (components.URL) [[UIApplication sharedApplication] openURL:components.URL options:@{} completionHandler:nil];
}

@end

#pragma mark - View controller

static void ApolloHiddenContentSaveMedia(NSArray<NSURL *> *urls, UIViewController *presenter) {
    NSError *error = nil;
    NSArray<ApolloSaveAllMediaItem *> *media = ApolloSaveAllMediaItemsFromURLs(urls, &error);
    if (media.count) {
        ApolloSaveAllMedia(media, presenter);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unable to Save Media"
                                                                   message:error.localizedDescription ?: @"This archived media is unavailable."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@interface ApolloHiddenContentViewController ()
@property (nonatomic, copy) NSString *username;
@property (nonatomic) BOOL loading;
@property (nonatomic, copy) NSArray<ApolloHiddenContentItem *> *items;

@property (nonatomic, strong) UIView *statusContainerView;
@property (nonatomic, strong) DACircularProgressView *progressRing;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@end

@implementation ApolloHiddenContentViewController

+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter {
    if (username.length == 0 || !presenter) return;
    ApolloHiddenContentViewController *list = [[ApolloHiddenContentViewController alloc] initWithStyle:UITableViewStylePlain];
    list.username = username;
    if (presenter.navigationController) {
        [presenter.navigationController pushViewController:list animated:YES];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hidden & Deleted";
    [self.tableView registerClass:[ApolloHiddenContentCell class] forCellReuseIdentifier:@"Cell"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.alwaysBounceVertical = YES;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    self.tableView.separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;

    UIRefreshControl *refreshControl = [UIRefreshControl new];
    [refreshControl addTarget:self action:@selector(apollo_refreshTriggered) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    // tableView.backgroundView rather than a plain subview of self.view: it's a
    // fixed, non-scrolling layer UIKit keeps sized to the table view's bounds.
    self.statusContainerView = [[UIView alloc] initWithFrame:self.tableView.bounds];
    self.statusContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundView = self.statusContainerView;

    self.progressRing = [[NSClassFromString(@"DACircularProgressView") alloc] init];
    // Keep archive loading neutral and readable against the active system
    // appearance: black in light mode, white in dark mode.
    self.progressRing.trackTintColor = [UIColor.labelColor colorWithAlphaComponent:0.16];
    self.progressRing.progressTintColor = UIColor.labelColor;
    self.progressRing.thicknessRatio = 0.08;
    self.progressRing.clockwiseProgress = 1;
    self.progressRing.indeterminate = 0;
    self.progressRing.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressRing.isAccessibilityElement = YES;
    self.progressRing.accessibilityLabel = @"Archive loading progress";
    self.progressLabel = [UILabel new];
    self.progressLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.progressLabel.textColor = UIColor.secondaryLabelColor;
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.numberOfLines = 0;
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusContainerView addSubview:self.progressRing];
    [self.statusContainerView addSubview:self.progressLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.progressRing.centerXAnchor constraintEqualToAnchor:self.statusContainerView.centerXAnchor],
        [self.progressRing.centerYAnchor constraintEqualToAnchor:self.statusContainerView.centerYAnchor constant:-12],
        [self.progressRing.widthAnchor constraintEqualToConstant:56],
        [self.progressRing.heightAnchor constraintEqualToConstant:56],
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.progressRing.bottomAnchor constant:12],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.statusContainerView.leadingAnchor constant:20],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.statusContainerView.trailingAnchor constant:-20],
    ]];

    [self apollo_fetchForceRefresh:NO];
}

- (void)apollo_refreshTriggered {
    [self apollo_fetchForceRefresh:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Reconfigure cached rows when returning after changing avatar preferences.
    [self.tableView reloadData];
}

- (void)apollo_fetchForceRefresh:(BOOL)forceRefresh {
    if (self.loading) return;
    self.loading = YES;
    self.progressRing.progress = 0;
    self.progressRing.hidden = self.items.count > 0;
    self.progressLabel.hidden = self.items.count > 0;
    [self.emptyStateLabel removeFromSuperview];
    __weak __typeof(self) weakSelf = self;
    // Fetch sequentially: the shared archive service rate-limits concurrent
    // posts/comments requests. Commit one complete snapshot, preserving the
    // previous results if either request fails.
    ApolloHiddenContentFetchWithProgress(self.username, ApolloHiddenContentKindPost, forceRefresh, ^(double fraction, NSString *stage) {
        [weakSelf apollo_updateProgress:fraction * 0.5 stage:[@"Posts: " stringByAppendingString:stage]];
    }, ^(NSArray *posts, NSString *postError) {
        __typeof(self) owner = weakSelf;
        if (!owner) return;
        if (postError) {
            [owner apollo_finishWithItems:nil error:postError];
            return;
        }
        ApolloHiddenContentFetchWithProgress(owner.username, ApolloHiddenContentKindComment, forceRefresh, ^(double fraction, NSString *stage) {
            [weakSelf apollo_updateProgress:0.5 + fraction * 0.5 stage:[@"Comments: " stringByAppendingString:stage]];
        }, ^(NSArray *comments, NSString *commentError) {
            NSMutableArray *combined = [NSMutableArray arrayWithArray:posts ?: @[]];
            [combined addObjectsFromArray:comments ?: @[]];
            [combined sortUsingComparator:^NSComparisonResult(ApolloHiddenContentItem *a, ApolloHiddenContentItem *b) {
                NSComparisonResult result = [(b.createdDate ?: NSDate.distantPast) compare:(a.createdDate ?: NSDate.distantPast)];
                return result == NSOrderedSame ? [a.fullName compare:b.fullName] : result;
            }];
            [weakSelf apollo_finishWithItems:combined error:commentError];
        });
    });
}

- (void)apollo_updateProgress:(double)fraction stage:(NSString *)stage {
    // Updates arrive only when network work completes; never advance a timer
    // toward an invented completion percentage while a request is stalled.
    double progress = MAX(self.progressRing.progress, MIN(1, fraction));
    [self.progressRing setProgress:progress animated:YES];
    self.progressRing.accessibilityValue = [NSString stringWithFormat:@"%.0f%%", progress * 100];
    self.progressLabel.text = stage;
}

- (void)apollo_finishWithItems:(NSArray *)items error:(NSString *)error {
    self.loading = NO;
    [self.progressRing setProgress:error ? self.progressRing.progress : 1 animated:NO];
    self.progressRing.hidden = YES;
    self.progressLabel.hidden = YES;
    [self.tableView.refreshControl endRefreshing];
    if (error) {
        [self apollo_showError:error];
        return;
    }
    self.items = items ?: @[];
    [self.tableView reloadData];
    if (self.items.count == 0) [self apollo_showEmptyState];
}

// Preserve loaded results on refresh failure; an empty list offers retry.
- (void)apollo_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Fetch Hidden Content"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    if (self.items.count == 0) {
        [self apollo_showStatusText:@"Couldn't load results. Pull down to try again."];
    }
}

- (void)apollo_showStatusText:(NSString *)text {
    if (!self.emptyStateLabel) {
        self.emptyStateLabel = [[UILabel alloc] init];
        self.emptyStateLabel.numberOfLines = 0;
        self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
        self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
        self.emptyStateLabel.font = [UIFont systemFontOfSize:15.0];
        // Full-height inset frame + flexible width/height (UILabel centers its
        // text vertically), so the text re-flows on rotation instead of keeping
        // its creation-time width.
        self.emptyStateLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    self.emptyStateLabel.text = text;
    self.emptyStateLabel.frame = CGRectInset(self.statusContainerView.bounds, 32.0, 0);
    [self.statusContainerView addSubview:self.emptyStateLabel];
}

- (void)apollo_showEmptyState {
    [self apollo_showStatusText:@"No hidden or deleted posts or comments found in the archive for this account."];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloHiddenContentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    ApolloHiddenContentItem *item = self.items[indexPath.row];
    [cell configureWithItem:item username:self.username];
    __weak typeof(self) weakSelf = self;
    __weak ApolloHiddenContentCell *weakCell = cell;
    cell.mediaTapped = ^{
        NSArray *urls = item.mediaURLs.count ? item.mediaURLs : (item.previewURL ? @[item.previewURL] : @[]);
        NSUInteger index = MIN(weakCell.currentMediaIndex, urls.count ? urls.count - 1 : 0);
        UIImageView *source = index < weakCell.mediaImageViews.count ? weakCell.mediaImageViews[index] : nil;
        if (!ApolloHiddenContentPresentMedia(urls, index, source, weakSelf)) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Media unavailable" message:@"This archived image cannot be opened in this Apollo build." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        }
    };
    cell.mediaSaveImageRequested = ^{
        NSArray<NSURL *> *urls = item.mediaURLs.count ? item.mediaURLs : (item.previewURL ? @[item.previewURL] : @[]);
        NSUInteger index = MIN(weakCell.currentMediaIndex, urls.count ? urls.count - 1 : 0);
        ApolloHiddenContentSaveMedia(urls.count ? @[urls[index]] : @[], weakSelf);
    };
    cell.mediaSaveAllRequested = ^{
        NSArray<NSURL *> *urls = item.mediaURLs.count ? item.mediaURLs : (item.previewURL ? @[item.previewURL] : @[]);
        ApolloHiddenContentSaveMedia(urls, weakSelf);
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ApolloHiddenContentItem *item = self.items[indexPath.row];

    // Deleted and Removed items have no useful live reddit.com page (it's just
    // Reddit's own tombstone) -- show the archived copy instead. Only a
    // genuinely Hidden item (still fully intact, just excluded from the
    // account's own listing) is worth opening live.
    if (item.reason != ApolloHiddenContentReasonHidden) {
        ApolloHiddenContentDetailViewController *detail = [ApolloHiddenContentDetailViewController new];
        detail.item = item;
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }

    // Open intact items through Apollo's native URL router.
    if (item.permalink.length == 0) return;
    // NSURLComponents.path percent-encodes on assignment; +URLWithString: does
    // not, and silently returns nil for a permalink with unencoded non-ASCII
    // characters (e.g. an accented slug).
    NSURLComponents *urlComponents = [NSURLComponents new];
    urlComponents.scheme = @"https";
    urlComponents.host = @"www.reddit.com";
    urlComponents.path = item.permalink;
    NSURL *url = urlComponents.URL;
    if (!url) return;

    // This list stays on the navigation stack, retaining its results and
    // scroll position when the user comes back from the live destination.
    if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }

}

@end
