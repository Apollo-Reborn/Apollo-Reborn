#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

// MARK: - Liquid Glass App Icon Picker
//
// Injects a "Liquid Glass" section into Apollo's native App Icon picker
// (Settings -> App Icon, backed by _TtC6Apollo29SettingsAppIconViewController).
// The injected section lives at table-view index 1, right after Apollo's
// "current / primary icon" section. Rows in every section >= 1 in Apollo's
// original layout get shifted down by 1; all hooked data-source and delegate
// methods passthrough to %orig with a remapped section index.
//
// Each row renders a 1x4 preview strip (Default / Dark / Clear / Clear Dark)
// for one of four bundled Liquid Glass icons. Tapping a row calls
// -[UIApplication setAlternateIconName:completionHandler:] with the icon ID
// (or nil if the user picked the icon that matches the primary `jryng`
// CFBundleIcon, so iOS stays in its "default icon" state when possible).
//
// The hook self-disables on un-patched IPAs by checking CFBundleAlternateIcons
// for the `jryng` entry the LG patch installs.

static NSString *const kLGSectionTitle = @"Liquid Glass";
static NSString *const kLGCellReuseID = @"ApolloLGIconRow";
static NSString *const kLGChangedIconNotification = @"com.christianselig.ChangedAppIcon";
static const NSInteger kLGSectionIndex = 0;
static const CGFloat kLGThumbnailSide = 52.0;
static const CGFloat kLGThumbnailCorner = 11.5;
static const CGFloat kLGTileSpacing = 12.0;
static const CGFloat kLGRowHeight = 124.0;

#pragma mark - Bundled preview data

#include "LiquidGlassIconPreviews.gen.h"

// The generated header exposes kLGPrimaryIconIDCString as a plain C string.
// Wrap it in an NSString once for use in ObjC dictionary lookups.
static NSString *LGPrimaryIconID(void) {
    static NSString *cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = @(kLGPrimaryIconIDCString);
    });
    return cached;
}

static UIImage *LGPreviewImage(NSString *iconID, NSString *variant) {
    if (!iconID || !variant) return nil;

    // Cache decoded UIImages forever (16 entries, small) so we only ever pay
    // the base64-decode + PNG-decode cost on the first display.
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.name = @"ca.jeffrey.apollo.lg-icon-previews";
    });
    NSString *cacheKey = [NSString stringWithFormat:@"%@/%@", iconID, variant];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    const char *cIcon = iconID.UTF8String;
    const char *cVariant = variant.UTF8String;
    for (size_t i = 0; i < kLGPreviewEntryCount; i++) {
        const LGPreviewEntry *entry = &kLGPreviewEntries[i];
        if (strcmp(entry->iconID, cIcon) != 0 || strcmp(entry->variant, cVariant) != 0) continue;

        NSString *b64 = [[NSString alloc] initWithBytesNoCopy:(void *)entry->base64
                                                       length:strlen(entry->base64)
                                                     encoding:NSASCIIStringEncoding
                                                 freeWhenDone:NO];
        if (!b64) {
            ApolloLog(@"[LGIconPicker] failed to wrap base64 cstring for %@/%@", iconID, variant);
            return nil;
        }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64
                                                            options:0];
        if (!data) {
            ApolloLog(@"[LGIconPicker] base64 decode failed for %@/%@", iconID, variant);
            return nil;
        }
        UIImage *img = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
        if (img) [cache setObject:img forKey:cacheKey];
        return img;
    }
    return nil;
}

#pragma mark - Icon model

typedef struct {
    __unsafe_unretained NSString *iconID;
    __unsafe_unretained NSString *displayName;
} LGIconRow;

static const LGIconRow *LGIconRows(NSInteger *outCount) {
    // The icon list lives in liquid-glass/icons.json. The header generated
    // by liquid-glass/scripts/generate_previews_header.py exposes it as
    // `kLGIconRowEntries` (C-string fields). Wrap each entry in an NSString
    // once at first call. We keep a static strong NSArray around so the
    // NSStrings outlive every call without us having to manage refcounts
    // through the calloc'd C array (whose __unsafe_unretained members ARC
    // cannot track).
    static LGIconRow *rows = NULL;
    static NSInteger count = 0;
    static NSArray<NSString *> *strongStorage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        count = (NSInteger)kLGIconRowEntryCount;
        rows = (LGIconRow *)calloc((size_t)count, sizeof(LGIconRow));
        NSMutableArray<NSString *> *storage = [NSMutableArray arrayWithCapacity:(NSUInteger)(count * 2)];
        for (NSInteger i = 0; i < count; i++) {
            NSString *iconID      = [@(kLGIconRowEntries[i].iconID) copy];
            NSString *displayName = [@(kLGIconRowEntries[i].displayName) copy];
            [storage addObject:iconID];
            [storage addObject:displayName];
            rows[i].iconID      = iconID;
            rows[i].displayName = displayName;
        }
        strongStorage = [storage copy];
        (void)strongStorage;  // intentionally kept alive via static reference
    });
    if (outCount) *outCount = count;
    return rows;
}

static NSInteger LGIconRowCount(void) {
    NSInteger c = 0;
    LGIconRows(&c);
    return c;
}

static const LGIconRow *LGIconRowAt(NSInteger index) {
    NSInteger count = 0;
    const LGIconRow *rows = LGIconRows(&count);
    if (index < 0 || index >= count) return NULL;
    return &rows[index];
}

static NSString *LGCurrentAlternateIconName(void) __attribute__((unused));
static NSString *LGCurrentAlternateIconName(void) {
    return UIApplication.sharedApplication.alternateIconName;
}

#pragma mark - Eligibility

static BOOL LGAlternateIconsAvailable(void) {
    // patch.sh registers every icon ID from liquid-glass/icons.json into
    // CFBundleAlternateIcons (including the primary, as a no-op switch
    // target so we never need to call setAlternateIconName:nil). We're
    // patched iff the primary appears as an alternate.
    //
    // Don't gate on `[UIApplication.sharedApplication supportsAlternateIcons]`
    // here: this helper is called from hooks AND %ctor, but %ctor runs before
    // UIApplication exists (sharedApplication == nil) so supportsAlternateIcons
    // would return NO at startup. Re-evaluating Info.plist on every call is
    // cheap (dict lookup) and avoids any caching that would freeze a bad
    // startup answer in place.
    NSDictionary *icons = NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"];
    if (![icons isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *alts = icons[@"CFBundleAlternateIcons"];
    if (![alts isKindOfClass:[NSDictionary class]]) return NO;
    return alts[LGPrimaryIconID()] != nil;
}

#pragma mark - Section remap helpers

static BOOL LGSectionIsOurs(NSInteger section) {
    return section == kLGSectionIndex;
}

static NSInteger LGRemapSectionToOriginal(NSInteger section) {
    // Hooks pass UIKit-visible section indices that include our injected
    // section. Apollo's original logic needs the section index it would have
    // used before injection.
    if (section < kLGSectionIndex) return section;
    return section - 1; // section > kLGSectionIndex
}

static NSIndexPath *LGRemapIndexPathToOriginal(NSIndexPath *indexPath) {
    if (!indexPath) return indexPath;
    NSInteger remapped = LGRemapSectionToOriginal(indexPath.section);
    if (remapped == indexPath.section) return indexPath;
    return [NSIndexPath indexPathForRow:indexPath.row inSection:remapped];
}

#pragma mark - TLS remap scope
//
// While we are inside the Apollo data-source/delegate callouts with a remapped
// (Apollo-perspective) indexPath, Apollo can call back into the table view
// using that same remapped indexPath — e.g. -dequeueReusableCellWithIdentifier:forIndexPath:.
// UIKit's row-data lookup uses our injected layout, so a remapped section that
// happens to land on our 4-row LG section will assert out of bounds when
// Apollo's original section had more rows.
//
// To bridge the two views, we set thread-local "remap-in-flight" state before
// delegating to %orig with a remapped indexPath. UITableView's
// dequeueReusableCellWithIdentifier:forIndexPath: / cellForRowAtIndexPath: hooks
// rewrite the inbound indexPath from Apollo-perspective back to UIKit-perspective
// when the TLS state is active, then call %orig with the UIKit-visible indexPath
// so UIKit's row-data lookup matches its own table layout.

static __thread BOOL sLGRemapActive = NO;
static __thread NSInteger sLGRemapApolloSection = -1;
static __thread NSInteger sLGRemapUIKitSection = -1;
static __thread __unsafe_unretained UITableView *sLGRemapActiveTable = nil;

typedef struct {
    BOOL prevActive;
    NSInteger prevApolloSection;
    NSInteger prevUIKitSection;
    __unsafe_unretained UITableView *prevTable;
} LGRemapScope;

static inline void LGRemapScopeEnter(LGRemapScope *scope,
                                     UITableView *tableView,
                                     NSInteger apolloSection,
                                     NSInteger uikitSection) {
    scope->prevActive = sLGRemapActive;
    scope->prevApolloSection = sLGRemapApolloSection;
    scope->prevUIKitSection = sLGRemapUIKitSection;
    scope->prevTable = sLGRemapActiveTable;
    sLGRemapActive = YES;
    sLGRemapApolloSection = apolloSection;
    sLGRemapUIKitSection = uikitSection;
    sLGRemapActiveTable = tableView;
}

static inline void LGRemapScopeExit(LGRemapScope *scope) {
    sLGRemapActive = scope->prevActive;
    sLGRemapApolloSection = scope->prevApolloSection;
    sLGRemapUIKitSection = scope->prevUIKitSection;
    sLGRemapActiveTable = scope->prevTable;
}

#define LG_REMAP_SCOPE(tv, apolloSection, uikitSection) \
    __attribute__((cleanup(LGRemapScopeExit))) LGRemapScope _lgScope; \
    LGRemapScopeEnter(&_lgScope, (tv), (apolloSection), (uikitSection))

static inline NSIndexPath *LGRewriteIndexPathForActiveScope(UITableView *tableView, NSIndexPath *indexPath) {
    if (!sLGRemapActive) return indexPath;
    if (sLGRemapActiveTable && tableView != sLGRemapActiveTable) return indexPath;
    if (!indexPath || indexPath.section != sLGRemapApolloSection) return indexPath;
    return [NSIndexPath indexPathForRow:indexPath.row inSection:sLGRemapUIKitSection];
}

#pragma mark - Preview tile view

@interface LGIconPreviewTile : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *captionLabel;
- (instancetype)initWithCaption:(NSString *)caption;
- (void)setImage:(UIImage *)image;
@end

@implementation LGIconPreviewTile

- (instancetype)initWithCaption:(NSString *)caption {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
    self.imageView.clipsToBounds = YES;
    self.imageView.layer.cornerRadius = kLGThumbnailCorner;
    self.imageView.layer.cornerCurve = kCACornerCurveContinuous;
    self.imageView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.imageView.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
    self.imageView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self addSubview:self.imageView];

    self.captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.captionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.captionLabel.textColor = [UIColor secondaryLabelColor];
    self.captionLabel.textAlignment = NSTextAlignmentCenter;
    self.captionLabel.text = caption;
    self.captionLabel.numberOfLines = 1;
    self.captionLabel.adjustsFontSizeToFitWidth = YES;
    self.captionLabel.minimumScaleFactor = 0.75;
    self.captionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:self.captionLabel];

    [NSLayoutConstraint activateConstraints:@[
        // Image is fixed-size and centered horizontally; the tile itself is
        // free to grow wider (via UIStackViewDistributionFillEqually) so the
        // caption has room beyond the icon footprint.
        [self.imageView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.imageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.imageView.widthAnchor constraintEqualToConstant:kLGThumbnailSide],
        [self.imageView.heightAnchor constraintEqualToConstant:kLGThumbnailSide],
        [self.imageView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor],
        [self.imageView.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],

        [self.captionLabel.topAnchor constraintEqualToAnchor:self.imageView.bottomAnchor constant:6.0],
        [self.captionLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.captionLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.captionLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    return self;
}

- (void)setImage:(UIImage *)image {
    self.imageView.image = image;
}

@end

#pragma mark - Custom cell

@interface LGIconPickerCell : UITableViewCell
@property (nonatomic, copy) NSString *iconID;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSArray<LGIconPreviewTile *> *previewTiles;
@property (nonatomic, strong) UIStackView *previewStack;
@end

@implementation LGIconPickerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    // iOS 14+: prevent UIKit from re-asserting its default UIListContentConfiguration
    // over our custom layout (which on iOS 26 clips our subviews and creates
    // confusing top-edge artefacts).
    if (@available(iOS 14.0, *)) {
        self.automaticallyUpdatesContentConfiguration = NO;
        self.contentConfiguration = nil;
    }

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 1;
    [self.contentView addSubview:self.titleLabel];

    NSArray<NSString *> *captions = @[@"Default", @"Dark", @"Clear", @"Clear Dark"];
    NSMutableArray<LGIconPreviewTile *> *tiles = [NSMutableArray arrayWithCapacity:captions.count];
    for (NSString *caption in captions) {
        LGIconPreviewTile *tile = [[LGIconPreviewTile alloc] initWithCaption:caption];
        [tiles addObject:tile];
    }
    self.previewTiles = [tiles copy];

    self.previewStack = [[UIStackView alloc] initWithArrangedSubviews:tiles];
    self.previewStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewStack.axis = UILayoutConstraintAxisHorizontal;
    self.previewStack.alignment = UIStackViewAlignmentTop;
    self.previewStack.distribution = UIStackViewDistributionFillEqually;
    self.previewStack.spacing = kLGTileSpacing;
    [self.contentView addSubview:self.previewStack];

    // Pin to contentView edges directly. layoutMarginsGuide in iOS 26 grouped
    // cells sometimes overlaps the rounded section background and clips the top
    // of subviews.
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],

        [self.previewStack.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8.0],
        [self.previewStack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [self.previewStack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
        [self.previewStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10.0],
    ]];

    return self;
}

- (void)configureWithRow:(const LGIconRow *)row {
    if (!row) return;
    self.iconID = row->iconID;
    self.titleLabel.text = row->displayName;
    // Liquid Glass icons don't reliably reflect the currently-selected
    // alternate icon (Apple's icon-stack assets don't round-trip cleanly
    // through alternateIconName), so we omit the checkmark in this section
    // rather than show stale state.
    self.accessoryType = UITableViewCellAccessoryNone;

    NSArray<NSString *> *variants = @[@"default", @"dark", @"clear-light", @"clear-dark"];
    for (NSInteger i = 0; i < (NSInteger)self.previewTiles.count && i < (NSInteger)variants.count; i++) {
        UIImage *img = LGPreviewImage(row->iconID, variants[i]);
        [self.previewTiles[i] setImage:img];
    }
}

@end

#pragma mark - Selection plumbing

static void LGApplyAlternateIcon(UITableView *tableView, NSString *iconID) {
    if (!iconID) return;

    if (![UIApplication.sharedApplication supportsAlternateIcons]) {
        ApolloLog(@"[LGIconPicker] supportsAlternateIcons=NO at tap; aborting swap for icon=%@", iconID);
        return;
    }

    ApolloLog(@"[LGIconPicker] requesting alternate icon=%@", iconID);
    __weak UITableView *weakTable = tableView;
    [UIApplication.sharedApplication setAlternateIconName:iconID completionHandler:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ApolloLog(@"[LGIconPicker] setAlternateIconName failed: %@", error);
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Couldn't Change Icon"
                                     message:error.localizedDescription ?: @"Unknown error."
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *presenter = weakTable.window.rootViewController;
                while (presenter.presentedViewController) presenter = presenter.presentedViewController;
                [presenter presentViewController:alert animated:YES completion:nil];
                return;
            }
            // Apollo observes this notification and reloads its table view.
            [[NSNotificationCenter defaultCenter] postNotificationName:kLGChangedIconNotification object:nil];
            [weakTable reloadData];
        });
    }];
}

#pragma mark - Hooks

%hook _TtC6Apollo29SettingsAppIconViewController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSInteger original = %orig;
    if (!LGAlternateIconsAvailable()) return original;
    return original + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return LGIconRowCount();
        NSInteger remapped = LGRemapSectionToOriginal(section);
        return %orig(tableView, remapped);
    }
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable() && LGSectionIsOurs(indexPath.section)) {
        LGIconPickerCell *cell = (LGIconPickerCell *)[tableView dequeueReusableCellWithIdentifier:kLGCellReuseID];
        if (!cell || ![cell isKindOfClass:[LGIconPickerCell class]]) {
            cell = [[LGIconPickerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGCellReuseID];
        }
        const LGIconRow *row = LGIconRowAt(indexPath.row);
        [cell configureWithRow:row];
        return cell;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *remapped = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, remapped.section, indexPath.section);
        return %orig(tableView, remapped);
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(indexPath.section)) {
            // Skip Apollo's themed styling pass for our custom cell.
            return;
        }
        NSIndexPath *remapped = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, remapped.section, indexPath.section);
        %orig(tableView, cell, remapped);
        return;
    }
    %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return kLGSectionTitle;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return nil;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(indexPath.section)) return kLGRowHeight;
        NSIndexPath *remapped = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, remapped.section, indexPath.section);
        return %orig(tableView, remapped);
    }
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return UITableViewAutomaticDimension;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable() && LGSectionIsOurs(indexPath.section)) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        const LGIconRow *row = LGIconRowAt(indexPath.row);
        if (row) LGApplyAlternateIcon(tableView, row->iconID);
        return;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *remapped = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, remapped.section, indexPath.section);
        %orig(tableView, remapped);
        return;
    }
    %orig;
}

%end

#pragma mark - UITableView bridge hooks
//
// Apollo's data-source/delegate methods call back into the table view using
// the Apollo-perspective indexPath we hand them. We rewrite those indexPaths
// back to the UIKit-visible indexPath (where our injected section is shifted
// to its real position) so UIKit's row-data lookups see the layout we
// actually published.

%hook UITableView

- (__kindof UITableViewCell *)dequeueReusableCellWithIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *rewritten = LGRewriteIndexPathForActiveScope(self, indexPath);
    return %orig(identifier, rewritten);
}

- (UITableViewCell *)cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *rewritten = LGRewriteIndexPathForActiveScope(self, indexPath);
    return %orig(rewritten);
}

- (CGRect)rectForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *rewritten = LGRewriteIndexPathForActiveScope(self, indexPath);
    return %orig(rewritten);
}

- (void)deselectRowAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated {
    NSIndexPath *rewritten = LGRewriteIndexPathForActiveScope(self, indexPath);
    %orig(rewritten, animated);
}

%end

%ctor {
    if (LGAlternateIconsAvailable()) {
        ApolloLog(@"[LGIconPicker] ctor: injecting Liquid Glass section, %ld preview entries", (long)kLGPreviewEntryCount);
    } else {
        ApolloLog(@"[LGIconPicker] ctor: LG asset catalog not detected, hooks will passthrough");
    }
}
