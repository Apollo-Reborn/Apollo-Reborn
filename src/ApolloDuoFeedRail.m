#import "ApolloDuoFeedRail.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloNativeSubredditIcons.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUserProfileCache.h"
#import "UserDefaultConstants.h"
#import "ApolloCommon.h"

// The panel sits 12pt in from the display's top, bottom and leading edges,
// like the subreddit drawer that opens beside it.
static const CGFloat kRailInset = 12;
// The buttons' width in either style: room for a subreddit name under its icon.
static const CGFloat kRailColumnWidth = 92;
// The buttons' distance from the display edge and from the divider before
// the feed; the rounded panel's too.
static const CGFloat kRailSideInset = 4;
static const CGFloat kRailButtonHeight = 62;
static const CGFloat kRailFavoriteHeight = 60;
static const CGFloat kRailGlyphSize = 24;
static const CGFloat kRailAvatarSize = 32;
// The highlight sits this far inside the panel's sides, and 2pt inside its
// button's top and bottom.
static const CGFloat kRailSelectionInset = 4;
// A rounded rectangle rather than the lens's capsule, whose curve would cut
// into the names along its bottom; at this radius the longest name fits.
static const CGFloat kRailSelectionRadius = 16;
// Room under the last favorite, so its highlight clears the panel's rounded
// bottom when the list is scrolled to the end.
static const CGFloat kRailFavoritesBottomInset = 10;
static const NSInteger kRailSubredditsTag = -1;
static const NSInteger kRailFavoriteTag = -2;

// The highlight is the shade UIKit's lens gives the tab rail's selected tab,
// darker than the glass (sampled from the rail on iOS 26 and 27), with the
// item itself in the accent.
static UIColor *ApolloDuoFeedRailSelectionColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
            return [UIColor colorWithWhite:0 alpha:dark ? 0.69 : 0.09];
        }];
    });
    return color;
}

static char kApolloDuoFeedRailFavoritesContext;

// "u/name" favorites are followed users.
static NSString *ApolloDuoFeedRailUsername(NSString *favorite) {
    return [favorite.lowercaseString hasPrefix:@"u/"] && favorite.length > 2 ? [favorite substringFromIndex:2] : nil;
}

// A glyph scaled into a square template image, so Apollo's bundled art and SF
// Symbols share one size.
static UIImage *ApolloDuoFeedRailGlyph(UIImage *source) {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGFloat scale = kRailGlyphSize / MAX(source.size.width, source.size.height);
    CGSize size = CGSizeMake(source.size.width * scale, source.size.height * scale);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kRailGlyphSize, kRailGlyphSize)];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [[source imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
            drawInRect:CGRectMake((kRailGlyphSize - size.width) / 2, (kRailGlyphSize - size.height) / 2, size.width, size.height)];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// One entry: a glyph (feeds, Subreddits) or a subreddit's icon (favorites)
// over its name, on a rounded highlight while it is what the feed shows.
@interface ApolloDuoFeedRailButton : UIControl
@property(nonatomic, strong) UIView *selection;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *initial;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, copy) NSString *subreddit;
@property(nonatomic, strong) ApolloGalleryImageRequest *iconRequest;
// The subreddit info lookup has been asked for (once, when first in view).
@property(nonatomic) BOOL infoRequested;
// An icon is loading or shown.
@property(nonatomic) BOOL hasIcon;
@property(nonatomic) BOOL avatar;
// A feed shortcut drawn as a tile, circle or Classic icon, at the avatars' size.
@property(nonatomic) BOOL styled;
@property(nonatomic) BOOL chosen;
// The highlight's top corner radius: the panel's own curve, less the inset,
// for the button at the top of the panel; kRailSelectionRadius elsewhere.
@property(nonatomic) CGFloat selectionTopRadius;
// Shapes the top button's highlight under the panel's rounded top.
@property(nonatomic, strong) CAShapeLayer *domeMask;
@end

@implementation ApolloDuoFeedRailButton
- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.selectionTopRadius = kRailSelectionRadius;
    self.selection = [UIView new];
    self.selection.userInteractionEnabled = NO;
    self.selection.backgroundColor = ApolloDuoFeedRailSelectionColor();
    self.selection.layer.cornerRadius = kRailSelectionRadius;
    self.selection.layer.cornerCurve = kCACornerCurveContinuous;
    self.selection.hidden = YES;
    [self addSubview:self.selection];
    self.icon = [UIImageView new];
    self.icon.userInteractionEnabled = NO;
    [self addSubview:self.icon];
    self.label = [UILabel new];
    self.label.text = title;
    self.label.textAlignment = NSTextAlignmentCenter;
    // A long name shrinks a little, then truncates, so it stays inside the
    // highlight.
    self.label.adjustsFontSizeToFitWidth = YES;
    self.label.minimumScaleFactor = 0.8;
    self.label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:self.label];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = title;
    return self;
}
- (instancetype)initWithGlyph:(UIImage *)glyph title:(NSString *)title {
    if (!(self = [self initWithTitle:title])) return nil;
    self.icon.image = ApolloDuoFeedRailGlyph(glyph);
    self.icon.contentMode = UIViewContentModeCenter;
    self.label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    return self;
}
// A feed shortcut as the subreddit list draws it in the chosen icon style
// (Settings > Feed Shortcuts). Monochrome takes the rail's colors; the other
// styles keep their own. Bare glyphs (Tinted, Monochrome) are centered on the
// glyph box and overhang it as the list's do; tiles, circles and Classic sit
// at the avatars' size.
- (instancetype)initWithShortcutIcon:(UIImage *)icon style:(ApolloSubredditFeedIconStyle)style title:(NSString *)title {
    if (!(self = [self initWithTitle:title])) return nil;
    BOOL monochrome = style == ApolloSubredditFeedIconStyleMonochrome;
    BOOL bare = monochrome || style == ApolloSubredditFeedIconStyleTinted;
    self.styled = !bare;
    self.icon.image = [icon imageWithRenderingMode:monochrome ? UIImageRenderingModeAlwaysTemplate
                                                              : UIImageRenderingModeAlwaysOriginal];
    self.icon.contentMode = bare ? UIViewContentModeCenter : UIViewContentModeScaleAspectFit;
    self.label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    return self;
}
- (instancetype)initWithSubreddit:(NSString *)subreddit iconURL:(NSURL *)iconURL {
    if (!(self = [self initWithTitle:subreddit])) return nil;
    self.avatar = YES;
    self.subreddit = subreddit;
    NSString *username = ApolloDuoFeedRailUsername(subreddit);
    self.accessibilityLabel = username ? subreddit : [@"r/" stringByAppendingString:subreddit];
    self.label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.icon.contentMode = UIViewContentModeScaleAspectFill;
    self.icon.clipsToBounds = YES;
    self.icon.layer.cornerRadius = kRailAvatarSize / 2;
    // Until the icon loads (or for a subreddit without one), its first letter.
    self.initial = [UILabel new];
    NSString *name = username ?: subreddit;
    self.initial.text = name.length ? [name substringToIndex:1].uppercaseString : @"r";
    self.initial.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    self.initial.textAlignment = NSTextAlignmentCenter;
    self.initial.clipsToBounds = YES;
    self.initial.layer.cornerRadius = kRailAvatarSize / 2;
    [self insertSubview:self.initial belowSubview:self.icon];
    [self loadIconFromURL:iconURL];
    return self;
}
- (void)loadIconFromURL:(NSURL *)url {
    if (!url || self.hasIcon) return;
    self.hasIcon = YES;
    [self.iconRequest cancel];
    __weak ApolloDuoFeedRailButton *weakSelf = self;
    self.iconRequest = [ApolloGalleryImageLoader.sharedLoader loadThumbnailAtURL:url completion:^(UIImage *image) {
        ApolloDuoFeedRailButton *button = weakSelf;
        if (!button) return;
        if (!image) {
            // A stale or broken URL: the info lookup may still find a working one.
            button.hasIcon = NO;
            return;
        }
        button.icon.image = image;
        button.initial.hidden = YES;
    }];
}
- (void)dealloc {
    [_iconRequest cancel];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGRect selection = CGRectInset(bounds, kRailSelectionInset, 2);
    self.selection.frame = selection;
    [self shapeSelection];
    // Icon and name sit in the middle of the highlight, the name well above
    // its rounded bottom corners and inset from its sides.
    BOOL large = self.avatar || self.styled;
    CGFloat iconSize = large ? kRailAvatarSize : kRailGlyphSize;
    CGFloat iconTop = CGRectGetMinY(selection) + (large ? 5 : 8);
    self.icon.frame = CGRectMake((bounds.size.width - iconSize) / 2, iconTop, iconSize, iconSize);
    self.initial.frame = self.icon.frame;
    CGFloat labelInset = self.avatar ? 6 : 5;
    self.label.frame = CGRectMake(CGRectGetMinX(selection) + labelInset, CGRectGetMaxY(self.icon.frame) + (large ? 3 : 5),
                                  CGRectGetWidth(selection) - labelInset * 2, self.avatar ? 12 : 13);
}
// Under the panel's rounded top, the highlight's top follows it in circular
// arcs, as the panel's corners are, so the gap there matches the sides'.
// UIKit's corner radii are continuous curves, which hug the corner and pinch
// that gap.
- (void)shapeSelection {
    CGSize size = self.selection.bounds.size;
    CGFloat top = MIN(self.selectionTopRadius, size.width / 2);
    CGFloat bottom = MIN(kRailSelectionRadius, MIN(size.width / 2, size.height - top));
    BOOL dome = top > kRailSelectionRadius && bottom > 0;
    CGFloat radius = dome ? 0 : kRailSelectionRadius;
    if (@available(iOS 26.0, *)) {
        self.selection.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:
            [UICornerRadius fixedRadius:radius]];
    } else {
        self.selection.layer.cornerRadius = radius;
    }
    if (!dome) {
        self.selection.layer.mask = nil;
        return;
    }
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(0, top)];
    [path addArcWithCenter:CGPointMake(top, top) radius:top startAngle:M_PI endAngle:M_PI * 1.5 clockwise:YES];
    [path addArcWithCenter:CGPointMake(size.width - top, top) radius:top startAngle:M_PI * 1.5 endAngle:0 clockwise:YES];
    [path addArcWithCenter:CGPointMake(size.width - bottom, size.height - bottom) radius:bottom
                startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [path addArcWithCenter:CGPointMake(bottom, size.height - bottom) radius:bottom
                startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
    [path closePath];
    if (!self.domeMask) self.domeMask = [CAShapeLayer layer];
    self.domeMask.frame = self.selection.bounds;
    self.domeMask.path = path.CGPath;
    self.selection.layer.mask = self.domeMask;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1;
}
- (void)applyAccent:(UIColor *)accent neutral:(UIColor *)neutral {
    self.selection.hidden = !self.chosen;
    self.icon.tintColor = self.chosen ? accent : neutral;
    self.label.textColor = self.chosen ? accent : neutral;
    self.initial.textColor = accent;
    self.initial.backgroundColor = [accent colorWithAlphaComponent:0.18];
    self.accessibilityTraits = UIAccessibilityTraitButton | (self.chosen ? UIAccessibilityTraitSelected : 0);
}
@end

@interface ApolloDuoFeedRail () <UIScrollViewDelegate>
@property(nonatomic, strong) UIVisualEffectView *panel;
@property(nonatomic, strong) NSArray<ApolloDuoFeedRailButton *> *feedButtons;
@property(nonatomic, strong) NSArray<ApolloDuoFeedRailButton *> *favoriteButtons;
@property(nonatomic, strong) ApolloDuoFeedRailButton *subredditsButton;
@property(nonatomic, strong) UIScrollView *favorites;
@property(nonatomic, strong) UIView *separator;
// The hairline on the column's trailing edge, where the feed begins.
@property(nonatomic, strong) UIView *divider;
@property(nonatomic, copy) NSArray<NSNumber *> *shortcuts;
@property(nonatomic) NSInteger shortcutStyle;
@property(nonatomic, copy) NSArray<NSString *> *favoriteNames;
@end

@implementation ApolloDuoFeedRail

+ (CGFloat)reservedWidth { return kRailSideInset * 2 + kRailColumnWidth; }
+ (CGFloat)panelMaxXFilled:(BOOL)filled {
    return filled ? ApolloDuoFeedRail.reservedWidth : kRailSideInset + kRailColumnWidth;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _selectedFeed = -1;
    self.panel = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.panel.clipsToBounds = YES;
    [self applyPanelStyle];
    [self addSubview:self.panel];
    self.favorites = [UIScrollView new];
    self.favorites.delegate = self;
    self.favorites.showsVerticalScrollIndicator = NO;
    self.favorites.alwaysBounceVertical = NO;
    self.favorites.contentInset = UIEdgeInsetsMake(0, 0, kRailFavoritesBottomInset, 0);
    [self.panel.contentView addSubview:self.favorites];
    self.separator = [UIView new];
    self.separator.userInteractionEnabled = NO;
    [self.panel.contentView addSubview:self.separator];
    self.divider = [UIView new];
    self.divider.userInteractionEnabled = NO;
    [self addSubview:self.divider];
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    self.subredditsButton = [[ApolloDuoFeedRailButton alloc]
        initWithGlyph:[UIImage systemImageNamed:@"list.bullet" withConfiguration:symbol] title:@"Subreddits"];
    self.subredditsButton.tag = kRailSubredditsTag;
    [self.subredditsButton addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.panel.contentView addSubview:self.subredditsButton];
    self.accessibilityLabel = @"Feeds";
    for (NSString *name in @[ApolloFavoriteSubredditsUpdatedNotification, ApolloFeedShortcutsChangedNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadShortcuts) name:name object:nil];
    }
    // Apollo saves a star from the subreddit list (or a confirmed unfavorite)
    // without posting anything, so the column watches the saved list itself.
    [NSUserDefaults.standardUserDefaults addObserver:self forKeyPath:UDKeyApolloFavoriteSubreddits options:0
                                             context:&kApolloDuoFeedRailFavoritesContext];
    [self reloadShortcuts];
    return self;
}

- (void)dealloc {
    [NSUserDefaults.standardUserDefaults removeObserver:self forKeyPath:UDKeyApolloFavoriteSubreddits
                                                context:&kApolloDuoFeedRailFavoritesContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kApolloDuoFeedRailFavoritesContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    // After the write that changed it; a burst of writes (the alphabetizing
    // pass writes again) rebuilds once, the rest find nothing new.
    __weak ApolloDuoFeedRail *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadShortcuts]; });
}

- (void)reloadShortcuts {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadShortcuts]; });
        return;
    }
    // The feed shortcuts Settings > Feed Shortcuts shows, in its icon style.
    NSMutableArray<NSNumber *> *shortcuts = [NSMutableArray array];
    for (NSNumber *index in ApolloFeedShortcutVisibleIndexes()) {
        if (index.integerValue <= 2 || self.showsModerator) [shortcuts addObject:index];
    }
    NSInteger style = sSubredditFeedIconStyle;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id name in [NSUserDefaults.standardUserDefaults arrayForKey:UDKeyApolloFavoriteSubreddits] ?: @[]) {
        if ([name isKindOfClass:NSString.class] && [name length]) [names addObject:name];
    }
    BOOL shortcutsChanged = !self.feedButtons || ![shortcuts isEqualToArray:self.shortcuts ?: @[]]
        || style != self.shortcutStyle;
    BOOL favoritesChanged = !self.favoriteButtons || ![names isEqualToArray:self.favoriteNames ?: @[]];
    if (!shortcutsChanged && !favoritesChanged) return;
    if (shortcutsChanged) {
        self.shortcuts = shortcuts;
        self.shortcutStyle = style;
        for (UIView *view in self.feedButtons) [view removeFromSuperview];
        NSMutableArray<ApolloDuoFeedRailButton *> *buttons = [NSMutableArray array];
        for (NSNumber *index in shortcuts) {
            NSString *title = ApolloFeedShortcutShortTitle(index.integerValue);
            // Monochrome's shape is Tinted's, drawn here in the rail's colors.
            ApolloSubredditFeedIconStyle drawn = style == ApolloSubredditFeedIconStyleMonochrome
                ? ApolloSubredditFeedIconStyleTinted : (ApolloSubredditFeedIconStyle)style;
            UIImage *icon = ApolloFeedShortcutIconImage(index.integerValue, drawn, ApolloSubredditFeedLayoutRows, shortcuts.count);
            ApolloDuoFeedRailButton *button = icon
                ? [[ApolloDuoFeedRailButton alloc] initWithShortcutIcon:icon style:(ApolloSubredditFeedIconStyle)style title:title]
                : [[ApolloDuoFeedRailButton alloc] initWithGlyph:ApolloFeedShortcutTemplateGlyph(index.integerValue) title:title];
            button.tag = index.integerValue;
            [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.panel.contentView addSubview:button];
            [buttons addObject:button];
        }
        self.feedButtons = buttons;
    }
    if (favoritesChanged) {
        if (self.favoriteNames) ApolloLog(@"[DuoFeedRail] favorites changed: %lu", (unsigned long)names.count);
        self.favoriteNames = names;
        for (UIView *view in self.favoriteButtons) [view removeFromSuperview];
        // The subreddit list's own icon cache first, then Apollo's icon
        // tracker. Either way the image itself usually comes out of a cache.
        NSDictionary<NSString *, NSURL *> *icons = names.count
            ? ApolloNativeSubredditIconURLs([NSUserDefaults.standardUserDefaults dataForKey:@"SubredditIconData"]) : @{};
        ApolloSubredditInfoCache *cache = ApolloSubredditInfoCache.sharedCache;
        NSMutableArray<ApolloDuoFeedRailButton *> *buttons = [NSMutableArray array];
        for (NSString *name in names) {
            // A followed user's avatar comes from the profile cache Apollo's
            // comment and feed avatars use.
            NSString *username = ApolloDuoFeedRailUsername(name);
            NSURL *iconURL = username ? [ApolloUserProfileCache.sharedCache cachedInfoForUsername:username].iconURL
                : ([cache cachedInfoForSubreddit:name].iconURL ?: icons[name.lowercaseString]);
            ApolloDuoFeedRailButton *button = [[ApolloDuoFeedRailButton alloc] initWithSubreddit:name iconURL:iconURL];
            button.tag = kRailFavoriteTag;
            [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.favorites addSubview:button];
            [buttons addObject:button];
        }
        self.favoriteButtons = buttons;
    }
    [self refreshColors];
    [self setNeedsLayout];
}

- (void)setFilled:(BOOL)filled {
    if (_filled == filled) return;
    _filled = filled;
    [self applyPanelStyle];
    [self refreshColors];
    [self setNeedsLayout];
}

// Rounded is glass, its corners following the display's concentrically as
// the drawer's do. Filled is solid, on the subreddit list's own background
// like the drawer's Standard style, and square at the divider; its left
// corners follow the display, which rounds them there anyway, so the top
// highlight can follow it too.
- (void)applyPanelStyle {
    UIVisualEffect *effect = nil;
    if (!self.filled) {
        if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
    self.panel.effect = effect;
    if (@available(iOS 26.0, *)) {
        self.panel.cornerConfiguration = self.filled
            ? [UICornerConfiguration configurationWithUniformLeftRadius:[UICornerRadius containerConcentricRadius]
                                                      uniformRightRadius:[UICornerRadius fixedRadius:0]]
            : [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius containerConcentricRadiusWithMinimum:24]];
    } else {
        self.panel.layer.cornerRadius = self.filled ? 0 : 24;
        self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = MAX(0, self.bounds.size.height - kRailInset * 2);
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat hairline = 1 / scale;
    // Filled, the panel runs to the display edges and the divider; the
    // buttons keep the rounded panel's place.
    CGFloat contentX = 0, contentY = 0, columnWidth = kRailColumnWidth;
    if (self.filled) {
        self.panel.frame = CGRectMake(0, 0, MAX(0, self.bounds.size.width - hairline), self.bounds.size.height);
        contentX = kRailSideInset;
        contentY = kRailInset;
    } else {
        self.panel.frame = CGRectMake(kRailSideInset, kRailInset, kRailColumnWidth, height);
    }
    self.divider.frame = CGRectMake(self.bounds.size.width - hairline, 0, hairline, self.bounds.size.height);
    // The top button's highlight follows the panel's rounded top-left from
    // inside it, no closer to it than the highlight sits from its edges.
    CGFloat cornerRadius = self.filled ? 0 : columnWidth / 2;
    if (@available(iOS 26.0, *)) cornerRadius = [self.panel effectiveRadiusForCorner:UIRectCornerTopLeft];
    CGFloat cornerInset = MAX(contentX, contentY) + kRailSelectionInset;
    CGFloat topRadius = MAX(kRailSelectionRadius,
                            MIN(columnWidth / 2 - kRailSelectionInset, cornerRadius - cornerInset));
    // Home, Popular and All, then Subreddits, which opens the drawer.
    NSMutableArray<ApolloDuoFeedRailButton *> *buttons = [self.feedButtons mutableCopy] ?: [NSMutableArray array];
    [buttons addObject:self.subredditsButton];
    CGFloat y = kRailSelectionInset - 2;
    for (ApolloDuoFeedRailButton *button in buttons) {
        CGFloat radius = button == buttons.firstObject ? topRadius : kRailSelectionRadius;
        if (fabs(button.selectionTopRadius - radius) > 0.5) {
            button.selectionTopRadius = radius;
            [button setNeedsLayout];
        }
        button.frame = CGRectMake(contentX, contentY + y, columnWidth, kRailButtonHeight);
        y += kRailButtonHeight;
    }
    self.separator.frame = CGRectMake(contentX + 16, contentY + y + 6, columnWidth - 32, hairline * 2);
    y += 12;
    // The favorites fill the rest of the panel and scroll when they don't fit.
    self.favorites.frame = CGRectMake(contentX, contentY + y, columnWidth, MAX(0, height - y));
    CGFloat favoriteY = 0;
    for (ApolloDuoFeedRailButton *button in self.favoriteButtons) {
        button.frame = CGRectMake(0, favoriteY, columnWidth, kRailFavoriteHeight);
        favoriteY += kRailFavoriteHeight;
    }
    self.favorites.contentSize = CGSizeMake(columnWidth, favoriteY);
    self.favorites.alwaysBounceVertical = favoriteY + kRailFavoritesBottomInset > self.favorites.bounds.size.height;
    self.separator.hidden = self.favoriteButtons.count == 0;
    [self requestVisibleIcons];
}

// A favorite with no icon on hand asks once it is in view, as the subreddit
// list does for its rows: the subreddit info cache, or for a followed user
// the profile cache. Both coalesce and keep what they learn, so this costs at
// most one lookup per favorite.
- (void)requestVisibleIcons {
    if (!self.window || self.hidden || self.alpha < 0.01) return;
    CGRect visible = self.favorites.bounds;
    for (ApolloDuoFeedRailButton *button in self.favoriteButtons) {
        if (button.hasIcon || button.infoRequested || !CGRectIntersectsRect(button.frame, visible)) continue;
        button.infoRequested = YES;
        __weak ApolloDuoFeedRailButton *weakButton = button;
        NSString *username = ApolloDuoFeedRailUsername(button.subreddit);
        if (username) {
            // Completes on the main queue, from the cache first when it can.
            [ApolloUserProfileCache.sharedCache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
                if (info.iconURL) [weakButton loadIconFromURL:info.iconURL];
            }];
            continue;
        }
        [ApolloSubredditInfoCache.sharedCache requestInfoForSubreddit:button.subreddit completion:^(ApolloSubredditInfo *info) {
            if (!info.iconURL) return;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakButton loadIconFromURL:info.iconURL]; });
        }];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self requestVisibleIcons];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self setNeedsLayout];
}

// The panel alone takes touches; the gap beside it passes them on.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)setSelectedFeed:(NSInteger)selectedFeed {
    if (_selectedFeed == selectedFeed) return;
    _selectedFeed = selectedFeed;
    [self refreshColors];
}

- (void)setSelectedSubreddit:(NSString *)selectedSubreddit {
    if (_selectedSubreddit == selectedSubreddit || [_selectedSubreddit isEqualToString:selectedSubreddit]) return;
    _selectedSubreddit = [selectedSubreddit copy];
    [self refreshColors];
}

- (void)setSubredditsSelected:(BOOL)subredditsSelected {
    if (_subredditsSelected == subredditsSelected) return;
    _subredditsSelected = subredditsSelected;
    [self refreshColors];
}

- (void)refreshColors {
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
    UIColor *neutral = ApolloNavigationChromeColor() ?: UIColor.labelColor;
    // A system color that shows on the glass panel, which washes out the
    // separator colors (the theme's and UIKit's both nearly vanish there).
    self.separator.backgroundColor = UIColor.tertiaryLabelColor;
    self.divider.backgroundColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    // The column has its own plain backdrop, so the feed's rows end at the
    // divider instead of running behind the panel.
    self.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    self.panel.backgroundColor = self.filled
        ? (ApolloThemeSubredditListBackgroundColor() ?: UIColor.secondarySystemBackgroundColor) : nil;
    for (ApolloDuoFeedRailButton *button in self.feedButtons) {
        button.chosen = button.tag == self.selectedFeed;
        [button applyAccent:accent neutral:neutral];
    }
    for (ApolloDuoFeedRailButton *button in self.favoriteButtons) {
        button.chosen = self.selectedSubreddit && [button.subreddit caseInsensitiveCompare:self.selectedSubreddit] == NSOrderedSame;
        [button applyAccent:accent neutral:neutral];
    }
    self.subredditsButton.chosen = self.subredditsSelected;
    [self.subredditsButton applyAccent:accent neutral:neutral];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self refreshColors];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self refreshColors];
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    if (alpha > 0.01) [self requestVisibleIcons];
}

- (void)tapped:(ApolloDuoFeedRailButton *)button {
    if (button.tag == kRailSubredditsTag) {
        if (self.toggleSubreddits) self.toggleSubreddits();
    } else if (button.tag == kRailFavoriteTag) {
        if (self.selectSubreddit && button.subreddit.length) self.selectSubreddit(button.subreddit);
    } else if (self.selectFeed) {
        self.selectFeed(button.tag);
    }
}

@end
