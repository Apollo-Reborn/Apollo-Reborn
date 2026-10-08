#import "ApolloProfilePicturesPreview.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloSettingsTableViewController.h"

@interface ApolloProfilePicturesPreview ()
@property (nonatomic, strong) NSArray<UIImage *> *avatars;
@property (nonatomic, strong) CADisplayLink *animation;
@property (nonatomic) CGFloat avatarProgress;
@property (nonatomic) CGFloat animationStartProgress;
@property (nonatomic) CGFloat targetProgress;
@property (nonatomic) CFTimeInterval animationStart;
@end

@implementation ApolloProfilePicturesPreview

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    // Reddit's generic avatars, bundled so the preview loads immediately
    // without looking up real users. Orange/teal sources are avatar_default_1.png
    // and avatar_default_5.png at https://www.redditstatic.com/avatars/defaults/v2/.
    NSMutableArray *avatars = [NSMutableArray array];
    for (NSString *name in @[@"ProfilePreviewDefaultOrange", @"ProfilePreviewDefaultTeal"]) {
        NSString *path = ApolloBundledResourcePath(name, @"png");
        [avatars addObject:(path ? [UIImage imageWithContentsOfFile:path] : nil) ?: [UIImage new]];
    }
    self.avatars = avatars;
    self.avatarProgress = self.targetProgress = sShowUserAvatars ? 1 : 0;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Preview: a comment by Winter121921 and a reply by TheBean31415.";
    for (NSString *notification in @[@"ApolloUserAvatarsToggleChangedNotification"]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:notification object:nil];
    }
    self.contentMode = UIViewContentModeRedraw;
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)refresh {
    self.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    CGFloat target = sShowUserAvatars ? 1 : 0;
    if (target != self.targetProgress) {
        [self.animation invalidate];
        self.animation = nil;
        self.targetProgress = target;
        if (self.window && !UIAccessibilityIsReduceMotionEnabled()) {
            self.animationStartProgress = self.avatarProgress;
            self.animationStart = CACurrentMediaTime();
            self.animation = [CADisplayLink displayLinkWithTarget:self selector:@selector(animateAvatars:)];
            [self.animation addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        } else {
            self.avatarProgress = target;
        }
    }
    [self setNeedsDisplay];
}

- (void)animateAvatars:(CADisplayLink *)link {
    CGFloat t = MIN(1, (CACurrentMediaTime() - self.animationStart) / 0.28);
    CGFloat eased = t * t * (3 - 2 * t);
    self.avatarProgress = self.animationStartProgress + (self.targetProgress - self.animationStartProgress) * eased;
    [self setNeedsDisplay];
    if (t >= 1) {
        [link invalidate];
        self.animation = nil;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self refresh];
}

- (void)drawText:(NSString *)text rect:(CGRect)rect font:(UIFont *)font color:(UIColor *)color {
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
}

- (void)drawRect:(CGRect)rect {
    UIColor *primary = ApolloThemeSubredditListTextColor() ?: UIColor.labelColor;
    UIColor *secondary = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    // Keep the comment header within the preview on narrow phones.
    CGFloat scale = MIN(1, CGRectGetWidth(self.bounds) / 390.0);
    CGContextScaleCTM(UIGraphicsGetCurrentContext(), scale, scale);
    CGFloat width = CGRectGetWidth(self.bounds) / scale;
    // Apollo renders comment bodies as semantic Subheadline text. Resolve that
    // style through the settings typography helper so this sample follows both
    // Use System Text Size and Apollo's in-app text-size slider exactly.
    UIFont *bodyFont = ApolloSettingsFont(UIFontTextStyleSubheadline, self.traitCollection);
    CGFloat chromeSize = bodyFont.pointSize * (14.0 / 15.0);
    UIFont *nameFont = [UIFont systemFontOfSize:chromeSize weight:UIFontWeightMedium];
    UIFont *metadataFont = [UIFont systemFontOfSize:chromeSize weight:UIFontWeightRegular];
    NSArray *names = @[@"Winter121921", @"TheBean31415"];
    NSArray *bodies = @[@"Found a new hiking trail this weekend.", @"Nice! I tried a new coffee shop."];
    for (NSUInteger index = 0; index < 2; index++) {
        CGFloat left = index == 0 ? 14 : 28;
        CGFloat top = index == 0 ? 14 : 110;
        CGFloat textX = left;
        if (self.avatarProgress > 0) {
            UIImage *image = self.avatars[index];
            CGRect avatar = CGRectMake(left, top + 14 * (1 - self.avatarProgress), 28 * self.avatarProgress, 28 * self.avatarProgress);
            CGContextRef context = UIGraphicsGetCurrentContext();
            CGContextSaveGState(context);
            CGContextSetAlpha(context, self.avatarProgress);
            // Mirror upstream avatar geometry without importing unrelated runtime changes.
            UIBezierPath *clip = sProfileAvatarStyle == 2
                ? [UIBezierPath bezierPathWithRoundedRect:avatar cornerRadius:avatar.size.width * 0.24]
                : [UIBezierPath bezierPathWithOvalInRect:avatar];
            [clip addClip];
            // Keep the bundled avatar's aspect ratio within the selected shape.
            CGFloat diameter = 28 * self.avatarProgress;
            CGFloat scale = diameter / MAX(MAX(image.size.width, image.size.height), 1);
            CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
            [image drawInRect:CGRectMake(left + (diameter - size.width) / 2, top + (28 - size.height) / 2, size.width, size.height) blendMode:kCGBlendModeNormal alpha:self.avatarProgress];
            CGContextRestoreGState(context);
            textX += 33 * self.avatarProgress;
        }
        CGFloat nameWidth = [names[index] sizeWithAttributes:@{NSFontAttributeName:nameFont}].width;
        [self drawText:names[index]
                  rect:CGRectMake(textX, top + 5, nameWidth + 1, nameFont.lineHeight + 2)
                  font:nameFont
                 color:primary];
        UIColor *voteColor = secondary;
        UIImage *arrow = [[UIImage imageNamed:@"inline-upvote" inBundle:NSBundle.mainBundle compatibleWithTraitCollection:self.traitCollection] imageWithTintColor:voteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGFloat voteX = textX + nameWidth + 9;
        NSString *score = index == 0 ? @"1.9k" : @"1.5k";
        CGFloat scoreWidth = [score sizeWithAttributes:@{NSFontAttributeName:metadataFont}].width;
        // Preserve the native artwork's aspect ratio and center it on the
        // metadata cap height, like an inline text attachment.
        CGFloat arrowHeight = metadataFont.capHeight + 3;
        CGFloat arrowWidth = arrowHeight * arrow.size.width / MAX(arrow.size.height, 1);
        CGFloat capCenter = top + 5 + metadataFont.ascender - metadataFont.capHeight / 2;
        [arrow drawInRect:CGRectMake(voteX, capCenter - arrowHeight / 2, arrowWidth, arrowHeight)];
        CGFloat scoreX = voteX + arrowWidth + 3;
        [self drawText:score
                  rect:CGRectMake(scoreX, top + 5, scoreWidth + 1, metadataFont.lineHeight + 2)
                  font:metadataFont
                 color:voteColor];
        UIImage *more = [[UIImage imageNamed:@"inline-more-options" inBundle:NSBundle.mainBundle compatibleWithTraitCollection:self.traitCollection] imageWithTintColor:secondary renderingMode:UIImageRenderingModeAlwaysOriginal];
        [more drawInRect:CGRectMake(width - 64, top + 12, 18, 4)];
        [self drawText:@"3d"
                  rect:CGRectMake(width - 34, top + 5, 25, metadataFont.lineHeight + 2)
                  font:metadataFont
                 color:secondary];
        [self drawText:bodies[index]
                  rect:CGRectMake(left, top + 37, width - left - 14, 64)
                  font:bodyFont
                 color:primary];
    }
    [(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) setFill];
    UIRectFill(CGRectMake(14, 98, width - 28, 0.5));
    [UIColor.systemRedColor setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(14, 110, 2, 86) cornerRadius:1] fill];
}
@end
