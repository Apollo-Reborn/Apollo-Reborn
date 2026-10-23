// ApolloGalleryViewController.m — see ApolloGalleryViewController.h.

#import "ApolloGalleryViewController.h"
#import "ApolloGalleryPinchIntroduction.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryGridGeometry.h"
#import "ApolloGallerySource.h"
#import "ApolloAccountCredentials.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloGalleryImageViewer.h"
#import "ApolloGalleryMediaActions.h"
#import "ApolloCommon.h"
#import "ApolloTagFilters.h"
#import "ApolloThemeRuntime.h"
#import "TagFiltersViewController.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloClasses.h"

// Rows from the bottom at which the next batch starts loading.
static NSInteger const kApolloGalleryLoadAheadRows = 3;

static NSString *const kApolloGalleryCellID = @"ApolloGalleryTile";
static char kApolloGalleryContextMenuActions;
static char kApolloGalleryContextMenuSourceItem;
static char kApolloGalleryPreparedController;

// Grid autoplay ("Play Videos / GIFs in Gallery View"). Only tiles on screen
// play, and only this many at once: every playing tile is a decoder session.
// Twelve covers a portrait screen of GIF-shaped tiles (two columns, six rows
// of 16:9) so a GIF subreddit moves edge to edge; a four-column landscape grid
// can show sixteen, and there the tiles mostly on screen win, top to bottom,
// before the slivers at the edges (see -apollo_tilesInPlaybackOrder).
static NSInteger const kApolloGalleryMaxPlayingTiles = 12;
// Of those, at most this many may be real .gif files animated through
// FLAnimatedImage: unlike the hardware-decoded mp4/HLS tiles, every GIF frame
// is decoded on the CPU at the file's full resolution. Rare in practice —
// Reddit supplies an mp4 rendition for nearly every GIF it hosts, and those
// tiles play it instead (ApolloGalleryItem.gifMP4URL).
static NSInteger const kApolloGalleryMaxAnimatedGIFTiles = 3;
// Tiles are ~200pt wide, so an HLS stream is capped far below what the
// fullscreen viewer pulls; bandwidth and decode work scale with the grid.
static double const kApolloGalleryTilePeakBitRate = 1500000.0;

#pragma mark - Waterfall layout

@protocol ApolloGalleryWaterfallLayoutDelegate <UICollectionViewDelegate>
// height/width for the tile at `index`.
- (CGFloat)galleryLayout:(UICollectionViewLayout *)layout aspectRatioForItemAtIndex:(NSInteger)index;
@end

// Column-balanced waterfall: each tile keeps its picture's real proportions and
// goes into whichever column is currently shortest, which is what stops a grid
// of mixed portrait/landscape photos from looking like a broken table.
@interface ApolloGalleryWaterfallLayout : UICollectionViewLayout
@property (nonatomic) NSInteger columnCount;
@property (nonatomic) CGFloat spacing;
@property (nonatomic, strong) NSMutableArray<UICollectionViewLayoutAttributes *> *attributesCache;
@property (nonatomic) CGFloat contentHeight;
@property (nonatomic) CGFloat lastPreparedWidth;
@property (nonatomic) NSInteger destinationColumnCount;
@property (nonatomic) CGFloat transitionProgress;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<UICollectionViewLayoutAttributes *> *> *columnAttributes;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *columnContentHeights;
@property (nonatomic) NSInteger preparedItemCount;
@end

@implementation ApolloGalleryWaterfallLayout

- (instancetype)init {
    self = [super init];
    if (self) {
        _columnCount = kApolloGalleryMinColumns;
        _spacing = kApolloGalleryTileSpacing;
        _attributesCache = [NSMutableArray array];
        _columnAttributes = [NSMutableDictionary dictionary];
        _columnContentHeights = [NSMutableDictionary dictionary];
        _preparedItemCount = -1;
    }
    return self;
}

- (NSArray<UICollectionViewLayoutAttributes *> *)apollo_attributesForColumns:(NSInteger)columnCount
                                                                            width:(CGFloat)width
                                                                    contentHeight:(CGFloat *)contentHeight {
    NSArray<UICollectionViewLayoutAttributes *> *cached = self.columnAttributes[@(columnCount)];
    if (cached) {
        *contentHeight = self.columnContentHeights[@(columnCount)].doubleValue;
        return cached;
    }
    NSMutableArray<UICollectionViewLayoutAttributes *> *result = [NSMutableArray array];
    CGFloat heightOfContent = 0.0;
    // Clamped here too, not just at the call site: columnHeights below is a
    // fixed-size C array.
    NSInteger columns = MAX(1, MIN(columnCount, (NSInteger)kApolloGalleryMaxColumns));
    CGFloat totalSpacing = self.spacing * (columns - 1);
    CGFloat columnWidth = floor((width - totalSpacing) / columns);

    CGFloat columnHeights[kApolloGalleryMaxColumns];
    for (NSInteger i = 0; i < columns && i < kApolloGalleryMaxColumns; i++) columnHeights[i] = 0.0;

    id<ApolloGalleryWaterfallLayoutDelegate> delegate =
        (id<ApolloGalleryWaterfallLayoutDelegate>)self.collectionView.delegate;
    BOOL canAskDelegate = [delegate respondsToSelector:@selector(galleryLayout:aspectRatioForItemAtIndex:)];

    NSInteger count = [self.collectionView numberOfItemsInSection:0];
    for (NSInteger item = 0; item < count; item++) {
        // Shortest column wins; ties go to the leftmost so the first row fills
        // left-to-right in listing order.
        NSInteger targetColumn = 0;
        for (NSInteger column = 1; column < columns; column++) {
            if (columnHeights[column] < columnHeights[targetColumn] - 0.5) targetColumn = column;
        }

        CGFloat aspect = canAskDelegate ? [delegate galleryLayout:self aspectRatioForItemAtIndex:item]
                                        : kApolloGalleryDefaultAspect;
        aspect = MAX(kApolloGalleryMinAspect, MIN(kApolloGalleryMaxAspect, aspect));
        CGFloat height = round(columnWidth * aspect);

        CGFloat x = targetColumn * (columnWidth + self.spacing);
        CGFloat y = columnHeights[targetColumn];

        UICollectionViewLayoutAttributes *attributes =
            [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:item inSection:0]];
        attributes.frame = CGRectMake(x, y, columnWidth, height);
        [result addObject:attributes];

        columnHeights[targetColumn] = y + height + self.spacing;
        heightOfContent = MAX(heightOfContent, columnHeights[targetColumn]);
    }
    if (heightOfContent > 0.0) heightOfContent -= self.spacing;
    *contentHeight = heightOfContent;
    self.columnAttributes[@(columnCount)] = result;
    self.columnContentHeights[@(columnCount)] = @(heightOfContent);
    return result;
}

- (void)invalidateLayoutWithContext:(UICollectionViewLayoutInvalidationContext *)context {
    // reloadData and insert/delete updates can change aspect ratios even
    // when their final item count happens to match the previous listing.
    if (context.invalidateDataSourceCounts) {
        [self.columnAttributes removeAllObjects];
        [self.columnContentHeights removeAllObjects];
    }
    [super invalidateLayoutWithContext:context];
}

- (void)prepareLayout {
    [super prepareLayout];
    CGFloat width = self.collectionView.bounds.size.width;
    if (width <= 0.0) return;
    NSInteger count = [self.collectionView numberOfItemsInSection:0];
    if (fabs(width - self.lastPreparedWidth) > 0.5 || count != self.preparedItemCount) {
        [self.columnAttributes removeAllObjects];
        [self.columnContentHeights removeAllObjects];
    }
    self.lastPreparedWidth = width;
    self.preparedItemCount = count;
    CGFloat fromHeight = 0.0;
    NSArray<UICollectionViewLayoutAttributes *> *source =
        [self apollo_attributesForColumns:self.columnCount width:width contentHeight:&fromHeight];
    self.attributesCache = [source mutableCopy];
    self.contentHeight = fromHeight;
    CGFloat progress = MAX(0.0, MIN(1.0, self.transitionProgress));
    if (progress <= 0.0 || self.destinationColumnCount == self.columnCount) return;

    // A live pinch interpolates the actual waterfall frames, including the
    // rows that change columns. Keeping this inside our normal layout lets
    // pagination and image updates continue during a gesture; UIKit's
    // UICollectionViewTransitionLayout forbids data updates while active.
    CGFloat toHeight = 0.0;
    NSArray<UICollectionViewLayoutAttributes *> *destination =
        [self apollo_attributesForColumns:self.destinationColumnCount width:width contentHeight:&toHeight];
    for (NSUInteger i = 0; i < self.attributesCache.count; i++) {
        UICollectionViewLayoutAttributes *attributes = [source[i] copy];
        CGRect from = attributes.frame;
        CGRect to = destination[i].frame;
        attributes.frame = CGRectMake(from.origin.x + (to.origin.x - from.origin.x) * progress,
            from.origin.y + (to.origin.y - from.origin.y) * progress,
            from.size.width + (to.size.width - from.size.width) * progress,
            from.size.height + (to.size.height - from.size.height) * progress);
        self.attributesCache[i] = attributes;
    }
    self.contentHeight = fromHeight + (toHeight - fromHeight) * progress;
}

- (CGSize)collectionViewContentSize {
    return CGSizeMake(self.collectionView.bounds.size.width, MAX(self.contentHeight, 0.0));
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray<UICollectionViewLayoutAttributes *> *visible = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attributes in self.attributesCache) {
        if (CGRectIntersectsRect(attributes.frame, rect)) [visible addObject:attributes];
    }
    return visible;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.item < 0 || indexPath.item >= (NSInteger)self.attributesCache.count) return nil;
    return self.attributesCache[indexPath.item];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    return fabs(newBounds.size.width - self.lastPreparedWidth) > 0.5;
}

@end

#pragma mark - Tile

// Tiles display through FLAnimatedImageView (a UIImageView subclass out of
// Apollo's own bundled framework) so a real .gif can animate in the grid the
// same memory-safe way the viewer plays it — compressed data plus a small
// frame window, never every frame as a bitmap (issue #1000). Resolved once;
// nil means GIF tiles without an mp4 transcode simply stay stills.
// FLAnimatedImageView keeps animating whatever it was last handed until the
// animation is cleared explicitly (its -setImage: only clears it for a non-nil
// image), so every change of what a tile shows goes through here.
static void ApolloGalleryTileSetAnimation(UIImageView *imageView, id animatedImage) {
    if (![imageView respondsToSelector:@selector(setAnimatedImage:)]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(imageView, @selector(setAnimatedImage:), animatedImage);
}

// KVO context for the tile's AVPlayerItem status (see apollo_startPlayerWithURL:).
static void *kApolloGalleryTileItemStatusContext = &kApolloGalleryTileItemStatusContext;

@interface ApolloGalleryTileCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UILabel *blurLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong, nullable) ApolloGalleryImageRequest *request;
@property (nonatomic, copy, nullable) NSURL *thumbnailURL;
@property (nonatomic, strong, nullable) ApolloGalleryItem *item;
// Grid autoplay. The controller decides WHEN a tile plays (visibility, the
// cap, the setting, lifecycle); the cell owns the player or animation and
// tears it down on stop, reuse, and dealloc.
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property (nonatomic, strong, nullable) id playerEndObserver;
@property (nonatomic, strong, nullable) id playerFailObserver;
// The item whose `status` this cell observes (KVO must be removed from the
// exact object it was added to, so it is remembered rather than re-derived).
@property (nonatomic, strong, nullable) AVPlayerItem *observedPlayerItem;
@property (nonatomic, strong, nullable) ApolloGalleryImageRequest *animationRequest;
@property (nonatomic) BOOL animatingGIF;
// YES while the tile waits on the host lookup for a clip Reddit attached no
// stream to (see -apollo_startHostedVideoLookup).
@property (nonatomic, getter=isAwaitingHostedVideo) BOOL awaitingHostedVideo;
// YES for a GIF or video tile that has something to play (or a host it can
// ask for it) and isn't behind an NSFW/spoiler blur.
@property (nonatomic, readonly) BOOL canAutoplay;
// What the tile plays through AVPlayer: the post's own stream, else Reddit's
// mp4 rendition of its GIF. nil for a real .gif with no mp4 (see below).
@property (nonatomic, readonly, nullable) NSURL *tileStreamURL;
// YES when playing means the FLAnimatedImage path (a real .gif with no mp4).
@property (nonatomic, readonly) BOOL playsAnimatedGIF;
// Playing, or still fetching what it will play; both count against the cap.
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;
- (void)configureWithItem:(ApolloGalleryItem *)item;
- (void)startPlayback;
- (void)stopPlayback;
@end

@implementation ApolloGalleryTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.cornerRadius = 6.0;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.14];

        _imageView = [[(ApolloClassFLAnimatedImageView ?: UIImageView.class) alloc] initWithFrame:self.contentView.bounds];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [self.contentView addSubview:_imageView];

        // NSFW / spoiler cover. NSFW follows Apollo's active-account adult
        // content preference; spoilers always keep their reveal gate.
        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        _blurView.frame = self.contentView.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.hidden = YES;
        [self.contentView addSubview:_blurView];

        _blurLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _blurLabel.textColor = UIColor.whiteColor;
        _blurLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
        _blurLabel.textAlignment = NSTextAlignmentCenter;
        [_blurView.contentView addSubview:_blurLabel];

        // "4" for a multi-image post, "GIF" for an animation.
        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _badgeLabel.textColor = UIColor.whiteColor;
        _badgeLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _badgeLabel.layer.cornerRadius = 7.0;
        _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.hidden = YES;
        [self.contentView addSubview:_badgeLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self stopPlayback];
    [self.request cancel];
    self.request = nil;
    self.item = nil;
    self.thumbnailURL = nil;
    ApolloGalleryTileSetAnimation(self.imageView, nil);
    self.imageView.image = nil;
    self.imageView.alpha = 1.0;
    self.blurView.hidden = YES;
    self.badgeLabel.hidden = YES;
}

- (void)dealloc {
    [self stopPlayback];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.playerLayer) {
        // A sublayer, not a view: the frame write costs no Auto Layout pass,
        // and disabling actions stops rotation from tweening the video.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.playerLayer.frame = self.contentView.bounds;
        [CATransaction commit];
    }
    self.blurLabel.frame = self.contentView.bounds;
    CGSize badgeSize = [self.badgeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat badgeWidth = MAX(22.0, badgeSize.width + 10.0);
    self.badgeLabel.frame = CGRectMake(CGRectGetWidth(self.contentView.bounds) - badgeWidth - 6.0,
                                       CGRectGetHeight(self.contentView.bounds) - 20.0 - 6.0,
                                       badgeWidth, 20.0);
}

- (void)configureWithItem:(ApolloGalleryItem *)item {
    self.item = item;
    if (item.shouldBlurThumbnail) {
        self.blurView.hidden = NO;
        self.blurLabel.text = item.isSpoiler ? @"SPOILER" : @"NSFW";
        [self.contentView bringSubviewToFront:self.blurView];
    }
    // No badge for an image's position within a multi-image post — every image
    // gets its own tile, so it only clutters the grid, and the viewer already
    // spells it out ("7 of 20 in post") once you've opened one. Playables are a
    // different case: a poster frame gives no hint that the tile moves, and
    // nothing downstream says so either.
    if (item.kind == ApolloGalleryMediaKindVideo) {
        NSString *duration = item.durationText;
        self.badgeLabel.text = duration.length > 0 ? [@"▶ " stringByAppendingString:duration] : @"▶";
        self.badgeLabel.hidden = NO;
    } else if (item.kind == ApolloGalleryMediaKindGIF) {
        self.badgeLabel.text = @"GIF";
        self.badgeLabel.hidden = NO;
    }
    [self.contentView bringSubviewToFront:self.badgeLabel];
    [self setNeedsLayout];

    NSURL *url = item.thumbnailURL ?: item.imageURL;
    self.thumbnailURL = url;
    if (!url) return;

    // Thumbnail tier: one downsampled still frame. A tile must never pay for a
    // multi-frame GIF decode or a full-resolution bitmap it draws at ~185pt.
    UIImage *cached = [[ApolloGalleryImageLoader sharedLoader] cachedThumbnailForURL:url];
    if (cached) {
        self.imageView.image = cached;
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.imageView.alpha = 0.0;
    self.request = [[ApolloGalleryImageLoader sharedLoader] loadThumbnailAtURL:url
                                                                    completion:^(UIImage *image) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.thumbnailURL isEqual:url]) return;
        if (!image) {
            strongSelf.imageView.alpha = 1.0;
            return;
        }
        strongSelf.imageView.image = image;
        [UIView animateWithDuration:0.18 animations:^{ strongSelf.imageView.alpha = 1.0; }];
    }];
}

#pragma mark Tile autoplay

- (BOOL)canAutoplay {
    ApolloGalleryItem *item = self.item;
    // Nothing plays behind an NSFW/spoiler blur: the reader hasn't asked to
    // see it, and it would burn a decoder on pixels nobody can make out.
    if (!item || item.shouldBlurThumbnail) return NO;
    if (item.kind != ApolloGalleryMediaKindVideo && item.kind != ApolloGalleryMediaKindGIF) return NO;
    return self.tileStreamURL != nil || self.playsAnimatedGIF || item.canResolveHostedVideoForGrid;
}

- (NSURL *)tileStreamURL {
    ApolloGalleryItem *item = self.item;
    // A GIF's mp4 rendition is a grid-only stand-in: the viewer still opens
    // the real .gif, so it is deliberately not the item's videoURL.
    return item.videoURL ?: item.gifMP4URL;
}

- (BOOL)playsAnimatedGIF {
    ApolloGalleryItem *item = self.item;
    return item.kind == ApolloGalleryMediaKindGIF && self.tileStreamURL == nil && item.imageURL != nil &&
           [self.imageView respondsToSelector:@selector(setAnimatedImage:)];
}

- (BOOL)isPlaying {
    return self.player != nil || self.animatingGIF || self.animationRequest != nil || self.awaitingHostedVideo;
}

- (void)startPlayback {
    if (self.isPlaying || !self.canAutoplay) return;
    // Reddit's silent transcode is exactly right for a muted tile — even for a
    // hosted post (Redgifs, Streamable) whose audio-bearing original the
    // viewer resolves lazily. The grid only looks a host up when Reddit
    // attached no stream at all, which is the norm for sports-clip links.
    NSURL *stream = self.tileStreamURL;
    if (stream) {
        [self apollo_startPlayerWithURL:stream];
    } else if (self.playsAnimatedGIF) {
        [self apollo_startAnimationWithURL:self.item.imageURL];
    } else {
        [self apollo_startHostedVideoLookup];
    }
}

// A hosted clip with no Reddit stream (streamin, streamff, streamain, dubz, ...
// links usually get none) has nothing to play until its host is asked, so
// the tile asks: once per item, through the same coalesced lookup the viewer
// uses, and only for tiles the controller has let play (on screen, at rest,
// under the cap). The wait counts against the cap like a GIF download does.
- (void)apollo_startHostedVideoLookup {
    ApolloGalleryItem *item = self.item;
    self.awaitingHostedVideo = YES;
    __weak typeof(self) weakSelf = self;
    [item resolveHostedVideoForGridWithCompletion:^(BOOL resolvedOriginal) {
        typeof(self) strongSelf = weakSelf;
        // Stopped (scrolled off, viewer opened, app backgrounded) or reused
        // while the host answered. The item keeps the result, so this clip
        // plays straight away the next time its tile is on screen.
        if (!strongSelf || !strongSelf.awaitingHostedVideo || strongSelf.item != item) return;
        strongSelf.awaitingHostedVideo = NO;
        NSURL *stream = strongSelf.tileStreamURL;
        if (!stream) {
            ApolloLog(@"[Gallery] tile host lookup found nothing to play (original=%d); keeping the poster",
                      (int)resolvedOriginal);
            return;
        }
        [strongSelf apollo_startPlayerWithURL:stream];
    }];
}

- (void)stopPlayback {
    // A host lookup still in flight finishes for the item, not for this tile.
    self.awaitingHostedVideo = NO;
    [self.animationRequest cancel];
    self.animationRequest = nil;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (self.playerEndObserver) {
        [center removeObserver:self.playerEndObserver];
        self.playerEndObserver = nil;
    }
    if (self.playerFailObserver) {
        [center removeObserver:self.playerFailObserver];
        self.playerFailObserver = nil;
    }
    if (self.observedPlayerItem) {
        [self.observedPlayerItem removeObserver:self forKeyPath:@"status"
                                        context:kApolloGalleryTileItemStatusContext];
        self.observedPlayerItem = nil;
    }
    [self.player pause];
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    self.player = nil;
    if (self.animatingGIF) {
        self.animatingGIF = NO;
        // FLAnimatedImageView drops its still the moment it is handed an
        // animation, so put the poster back instead of leaving a blank tile.
        UIImage *thumbnail = self.thumbnailURL
            ? [[ApolloGalleryImageLoader sharedLoader] cachedThumbnailForURL:self.thumbnailURL] : nil;
        ApolloGalleryTileSetAnimation(self.imageView, nil);
        self.imageView.image = thumbnail;
    }
}

- (void)apollo_startPlayerWithURL:(NSURL *)url {
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:url];
    playerItem.preferredPeakBitRate = kApolloGalleryTilePeakBitRate;
    CGFloat scale = self.traitCollection.displayScale;
    CGSize size = self.contentView.bounds.size;
    if (size.width > 0.0 && size.height > 0.0) {
        playerItem.preferredMaximumResolution = CGSizeMake(size.width * scale, size.height * scale);
    }
    playerItem.preferredForwardBufferDuration = 2.0;

    AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
    // The grid never makes a sound; tapping through to the viewer is where
    // audio (and its own mute toggle) lives.
    player.muted = YES;
    player.allowsExternalPlayback = NO;
    if (@available(iOS 15.0, *)) {
        player.audiovisualBackgroundPlaybackPolicy = AVPlayerAudiovisualBackgroundPlaybackPolicyPauses;
    }

    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    // Loop: clips in a grid are glanced at, not watched to the end.
    self.playerEndObserver =
        [center addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                            object:playerItem
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
        AVPlayer *current = weakSelf.player;
        if (!current || current.currentItem != note.object) return;
        [current seekToTime:kCMTimeZero];
        [current play];
    }];
    // A stream that can't play leaves the poster frame in place, exactly as
    // if autoplay had never been attempted for this tile.
    self.playerFailObserver =
        [center addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                            object:playerItem
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.player.currentItem != note.object) return;
        ApolloLog(@"[Gallery] tile stream failed to play; keeping the poster");
        [strongSelf stopPlayback];
    }];
    // A stream that never loads (a dead rendition, or a device out of decoder
    // sessions) only ever reaches AVPlayerItemStatusFailed — no notification —
    // so watch the status too. Stopping frees the tile's slot under the cap
    // instead of leaving a poster counted as playing for the whole visit.
    [playerItem addObserver:self forKeyPath:@"status" options:0 context:kApolloGalleryTileItemStatusContext];
    self.observedPlayerItem = playerItem;

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.frame = self.contentView.bounds;
    // Over the poster, under the NSFW blur and the badge. The layer draws
    // nothing until its first frame, so the poster shows through meanwhile
    // and stays if the stream never starts.
    [self.contentView.layer insertSublayer:layer above:self.imageView.layer];
    self.player = player;
    self.playerLayer = layer;
    [player play];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != kApolloGalleryTileItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *playerItem = object;
    if (playerItem.status != AVPlayerItemStatusFailed) return;
    NSError *error = playerItem.error;
    // KVO may arrive off the main thread; the teardown touches layers.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        // Reused or stopped meanwhile: the failure belongs to an old item.
        if (!strongSelf || strongSelf.observedPlayerItem != playerItem) return;
        ApolloLogError(@"[Gallery] tile stream failed to load (%@ %ld); keeping the poster",
                  error.domain, (long)error.code);
        [strongSelf stopPlayback];
    });
}

- (void)apollo_startAnimationWithURL:(NSURL *)url {
    ApolloGalleryImageLoader *loader = [ApolloGalleryImageLoader sharedLoader];
    ApolloGalleryDecodedImage *cached = [loader cachedImageForURL:url];
    if (cached) {
        [self apollo_showAnimation:cached.animatedImage];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.animationRequest = [loader loadImageAtURL:url
                                          progress:nil
                                        completion:^(ApolloGalleryDecodedImage *decoded, NSData *data) {
        typeof(self) strongSelf = weakSelf;
        // Reused onto another item while the GIF downloaded (a stop cancels the
        // request, and a cancelled request never completes).
        if (!strongSelf || ![strongSelf.item.imageURL isEqual:url]) return;
        strongSelf.animationRequest = nil;
        [strongSelf apollo_showAnimation:decoded.animatedImage];
        (void)data;
    }];
    // The load can complete before the handle is stored; don't let a finished
    // request keep counting against the cap.
    if (self.animatingGIF) self.animationRequest = nil;
}

- (void)apollo_showAnimation:(id)animatedImage {
    // A still after all (APNG, WebP, a mislabeled file): the thumbnail stays.
    if (!animatedImage) return;
    ApolloGalleryTileSetAnimation(self.imageView, animatedImage);
    self.imageView.alpha = 1.0;
    self.animatingGIF = YES;
}

@end

#pragma mark - Grid view controller

@interface ApolloGalleryViewController () <UICollectionViewDataSource, UICollectionViewDelegate,
                                           UICollectionViewDataSourcePrefetching,
                                           UIGestureRecognizerDelegate,
                                           ApolloGalleryWaterfallLayoutDelegate,
                                           ApolloGalleryImageViewerDelegate>
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, copy) NSString *sourceDescription;
@property (nonatomic, strong) ApolloGalleryFeed *feed;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) ApolloGalleryWaterfallLayout *waterfallLayout;
@property (nonatomic, strong) UIActivityIndicatorView *initialSpinner;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, weak, nullable) ApolloGalleryImageViewer *activeViewer;
@property (nonatomic) BOOL galleryContextMenuActive;
@property (nonatomic, strong) NSMutableSet<UIContextMenuConfiguration *> *activeGalleryContextMenus;
@property (nonatomic) BOOL galleryReloadPendingAfterMenu;
@property (nonatomic) BOOL pinchEnabledBeforeContextMenu;
@property (nonatomic, weak) UINavigationBar *contextMenuNavigationBar;
@property (nonatomic) BOOL navigationBarEnabledBeforeContextMenu;
@property (nonatomic, weak) UIGestureRecognizer *contextMenuPopGesture;
@property (nonatomic) BOOL popGestureEnabledBeforeContextMenu;
@property (nonatomic, strong, nullable) UIBarButtonItem *filterBarButtonItem;
@property (nonatomic) NSInteger tileSizeIndex;
@property (nonatomic, strong) UIPinchGestureRecognizer *tilePinch;
@property (nonatomic, copy) NSArray<NSNumber *> *pinchSizeIndices;
@property (nonatomic, copy) NSArray<NSNumber *> *pinchTileWidths;
@property (nonatomic, strong) NSIndexPath *pinchAnchor;
@property (nonatomic, strong) ApolloGalleryItem *pinchAnchorItem;
@property (nonatomic) CGFloat pinchAnchorFraction;
@property (nonatomic) CGFloat pinchViewportY;
@property (nonatomic) CGFloat pinchStartPosition;
@property (nonatomic) CGFloat pinchStartTileWidth;
@property (nonatomic) NSInteger pinchStartTileSizeIndex;
@property (nonatomic) CGFloat pinchPosition;
@property (nonatomic) BOOL pinchingTiles;
@property (nonatomic, strong) CADisplayLink *tileSizeSettlement;
@property (nonatomic) CFTimeInterval tileSizeSettlementStart;
@property (nonatomic) CGFloat tileSizeSettlementFrom;
@property (nonatomic) CGFloat tileSizeSettlementTo;
// YES from -apollo_beginInitialLoad until that batch reports back. Only its
// completion stops the centre spinner and the refresh control and settles the
// empty state, so whatever drops the batch first (a filter change — the feed
// never calls a dropped batch back) must start another one.
@property (nonatomic) BOOL initialLoadPending;
// Coalesce viewport checks outside collection-view layout/update callbacks.
@property (nonatomic) BOOL viewportFillQueued;
@property (nonatomic, strong) NSArray<ApolloGalleryItem *> *coverageItems;
@property (nonatomic) CGFloat coverageWidth;
@property (nonatomic) NSInteger coverageColumns;
@property (nonatomic) CGFloat shortestColumnBottom;
// Menu-time preparation: a seeded feed and warmed thumbnails, handed to the
// push. It makes no listing request; a tap never waits for this work.
@property (nonatomic, copy) NSArray *preparationKey;
@property (nonatomic) CGSize preparationViewport;
@property (nonatomic) NSUInteger preparationWarmedCount;
@property (nonatomic, strong) NSMutableArray<ApolloGalleryImageRequest *> *preparationWarmRequests;
// Outstanding look-ahead loads keyed by index path, so UIKit's cancel callback
// can actually stop them (see collectionView:cancelPrefetchingForItemsAtIndexPaths:).
@property (nonatomic, strong) NSMutableDictionary<NSIndexPath *, ApolloGalleryImageRequest *> *prefetchRequests;
// Set by a memory warning for the rest of this visit: the grid keeps working,
// its tiles just stop moving (see didReceiveMemoryWarning).
@property (nonatomic) BOOL tilePlaybackSuspendedForMemory;
@property (nonatomic) NSInteger lastLoggedPlayingTileCount;
// A deferred -apollo_refreshTilePlayback is queued (see
// -apollo_setNeedsTilePlaybackRefresh).
@property (nonatomic) BOOL tilePlaybackRefreshQueued;
@end

@implementation ApolloGalleryViewController

- (instancetype)initWithHomeFeed {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = @"";
        _sourceDescription = @"Home";
        _feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = [subreddit copy] ?: @"";
        _sourceDescription = [@"r/" stringByAppendingString:_subreddit];
        _feed = [[ApolloGalleryFeed alloc] initWithSubreddit:_subreddit];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithMultiredditPath:(NSString *)multiredditPath {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = @"";
        NSString *name = [multiredditPath pathComponents].lastObject ?: @"multireddit";
        _sourceDescription = [@"m/" stringByAppendingString:name];
        _feed = [[ApolloGalleryFeed alloc] initWithMultiredditPath:multiredditPath];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithUsername:(NSString *)username {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = @"";
        _sourceDescription = [@"u/" stringByAppendingString:(username ?: @"")];
        _feed = [[ApolloGalleryFeed alloc] initWithUsername:username];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

// Bare username out of "u/name", "/u/name", "@name", or plain "name"; nil when
// nothing usable remains. Usernames never contain slashes or spaces.
static NSString *ApolloGalleryNormalizedUsername(NSString *value) {
    NSString *name = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([name hasPrefix:@"/"] || [name hasPrefix:@"@"]) name = [name substringFromIndex:1];
    if ([name.lowercaseString hasPrefix:@"u/"] || [name.lowercaseString hasPrefix:@"user/"]) {
        name = [name substringFromIndex:[name rangeOfString:@"/"].location + 1];
    }
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@" "]) return nil;
    return name;
}

static NSString *ApolloGalleryNormalizedMultiredditPath(NSString *value) {
    NSString *path = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path pathComponents]) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        [components addObject:component];
    }
    if (components.count != 4 ||
        ![components[0].lowercaseString isEqualToString:@"user"] ||
        ![components[2].lowercaseString isEqualToString:@"m"]) {
        return nil;
    }
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

// Seed the freshly built (not yet pushed) gallery with the sort the source
// feed was showing. Runs before viewDidLoad's first fetch, so no reload is
// wasted. Values the feed can't honor are dropped: an unknown raw keeps the
// default, and rising quietly stands down on feeds whose listing endpoint
// rejects it — inheriting a sort should never produce an error the user
// didn't cause.
static void ApolloGalleryApplyInheritedSort(ApolloGalleryViewController *gallery,
                                            NSNumber *sortValue, NSNumber *topWindowValue) {
    if (!gallery || !sortValue) return;
    NSInteger sortRaw = sortValue.integerValue;
    if (sortRaw < ApolloGallerySortHot || sortRaw > ApolloGallerySortControversial) return;
    ApolloGallerySort sort = (ApolloGallerySort)sortRaw;
    if (sort == ApolloGallerySortRising && !gallery.feed.supportsRisingSort) return;
    if (sort == ApolloGallerySortBest && !gallery.feed.supportsBestSort) return;

    ApolloGalleryTopWindow window = gallery.feed.topWindow;
    NSInteger windowRaw = topWindowValue ? topWindowValue.integerValue : -1;
    if (windowRaw >= ApolloGalleryTopWindowDay && windowRaw <= ApolloGalleryTopWindowAll) {
        window = (ApolloGalleryTopWindow)windowRaw;
    }
    [gallery.feed setSort:sort topWindow:window];
    ApolloLog(@"[Gallery] inherited sort from source feed -> %@", gallery.feed.sortDisplayName);
}

// The menu and the eventual push must construct exactly the same endpoint.
// In particular, Home's parser is not a substitute for a subreddit feed when
// preparation needs to follow its continuation cursor.
static ApolloGalleryViewController *ApolloGalleryControllerForIdentifier(NSString *identifier,
                                                                        NSNumber *sort, NSNumber *window) {
    ApolloGalleryViewController *gallery = nil;
    NSString *multi = ApolloGalleryNormalizedMultiredditPath(identifier);
    NSString *slug = [identifier stringByTrimmingCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@" \t/"]];
    if (multi.length > 0) {
        gallery = [[ApolloGalleryViewController alloc] initWithMultiredditPath:multi];
    } else if ([identifier isEqualToString:@"~home"]) {
        gallery = [[ApolloGalleryViewController alloc] initWithHomeFeed];
    } else if ([slug.lowercaseString hasPrefix:@"u/"] || [slug.lowercaseString hasPrefix:@"user/"]) {
        NSString *username = ApolloGalleryNormalizedUsername(slug);
        return username.length > 0 ? [[ApolloGalleryViewController alloc] initWithUsername:username] : nil;
    } else {
        if ([slug.lowercaseString hasPrefix:@"r/"]) slug = [slug substringFromIndex:2];
        if (slug.length == 0) return nil;
        gallery = [[ApolloGalleryViewController alloc] initWithSubreddit:slug];
    }
    ApolloGalleryApplyInheritedSort(gallery, sort, window);
    return gallery;
}

static NSArray *ApolloGalleryPreparationKey(NSString *identifier, UIViewController *owner,
                                            NSNumber *sort, NSNumber *window) {
    NSDictionary *source = ApolloGallerySourcePreparationState(owner);
    if (!source || identifier.length == 0) return nil;
    // The source state includes live NSFW/spoiler flags, not only link identity.
    // Account identity is checked separately: an account switch must never
    // adopt a feed whose continuation was fetched for the previous account.
    return @[identifier, sort ?: NSNull.null, window ?: NSNull.null, source,
             ApolloActiveAccountUsername() ?: @"", ApolloActiveAccountClient() ?: NSNull.null,
             @(ApolloGalleryGridSavedTileSizeIndex(NSUserDefaults.standardUserDefaults))];
}

+ (void)prepareGalleryForSubreddit:(NSString *)subreddit
               fromViewController:(UIViewController *)sourceViewController
               inheritedSortValue:(NSNumber *)sortValue
          inheritedTopWindowValue:(NSNumber *)topWindowValue {
    if (!NSThread.isMainThread || !sourceViewController.navigationController) return;
    ApolloGalleryPrepareSource(sourceViewController);
    NSArray *key = ApolloGalleryPreparationKey(subreddit, sourceViewController, sortValue, topWindowValue);
    if (!key) return;
    ApolloGalleryViewController *gallery = objc_getAssociatedObject(sourceViewController, &kApolloGalleryPreparedController);
    if (![gallery.preparationKey isEqual:key]) {
        gallery = ApolloGalleryControllerForIdentifier(subreddit, sortValue, topWindowValue);
        if (!gallery || !ApolloGallerySeedFeedFromSource(gallery.feed, sourceViewController)) return;
        gallery.preparationKey = key;
        gallery.preparationWarmRequests = [NSMutableArray array];
        objc_setAssociatedObject(sourceViewController, &kApolloGalleryPreparedController, gallery, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIViewController *weakOwner = sourceViewController;
        __weak ApolloGalleryViewController *weakGallery = gallery;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *owner = weakOwner;
            ApolloGalleryViewController *prepared = weakGallery;
            if (owner && prepared && objc_getAssociatedObject(owner, &kApolloGalleryPreparedController) == prepared) {
                objc_setAssociatedObject(owner, &kApolloGalleryPreparedController, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    }
    gallery.preparationViewport = sourceViewController.viewIfLoaded.bounds.size;
    [gallery apollo_prepareViewport];
}

- (void)apollo_warmPreparedViewport {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    CGSize viewport = self.preparationViewport;
    NSInteger size = ApolloGalleryGridSavedTileSizeIndex(NSUserDefaults.standardUserDefaults);
    NSUInteger count = ApolloGalleryGridWarmPrefixCount(items.count, viewport.width, viewport.height,
        size, 96, ^CGSize(NSUInteger index) { return items[index].pixelSize; });
    for (NSUInteger index = self.preparationWarmedCount; index < count; index++) {
        ApolloGalleryItem *item = items[index];
        ApolloGalleryImageRequest *request = [[ApolloGalleryImageLoader sharedLoader]
            prefetchThumbnailAtURL:(item.thumbnailURL ?: item.imageURL)];
        if (request) [self.preparationWarmRequests addObject:request];
    }
    self.preparationWarmedCount = MAX(self.preparationWarmedCount, count);
}

// Menu time only snapshots the posts the feed already loaded and warms their
// thumbnails. It never requests a listing page: opening "..." and cancelling
// must not spend API-Key-Free budget. Once Gallery View is actually tapped,
// -apollo_fillViewportIfNeeded fetches whatever the grid still needs.
- (void)apollo_prepareViewport {
    [self apollo_warmPreparedViewport];
    if (self.isViewLoaded) [self apollo_scheduleViewportFill];
}

static BOOL ApolloGalleryPush(ApolloGalleryViewController *gallery,
                              UIViewController *sourceViewController) {
    if (!gallery || !sourceViewController) return NO;
    UINavigationController *navigationController = sourceViewController.navigationController;
    if (!navigationController) {
        ApolloLog(@"[Gallery] no navigation controller to push onto from %@", sourceViewController);
        return NO;
    }

    // Apollo's themes paint their own backgrounds; borrow the colour from the
    // screen we came from so the gallery doesn't flash system white/black.
    gallery.gridBackgroundColor = sourceViewController.view.backgroundColor ?: navigationController.view.backgroundColor;
    ApolloGallerySeedFeedFromSource(gallery.feed, sourceViewController);
    [navigationController pushViewController:gallery animated:YES];
    return YES;
}

+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit fromViewController:(UIViewController *)sourceViewController {
    return [self presentGalleryForSubreddit:subreddit
                         fromViewController:sourceViewController
                         inheritedSortValue:nil
                    inheritedTopWindowValue:nil];
}

+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit
                fromViewController:(UIViewController *)sourceViewController
                inheritedSortValue:(NSNumber *)sortValue
           inheritedTopWindowValue:(NSNumber *)topWindowValue {
    if (subreddit.length == 0 || !sourceViewController) return NO;
    NSArray *key = ApolloGalleryPreparationKey(subreddit, sourceViewController, sortValue, topWindowValue);
    ApolloGalleryViewController *prepared = objc_getAssociatedObject(sourceViewController, &kApolloGalleryPreparedController);
    ApolloGalleryViewController *gallery = key && [prepared.preparationKey isEqual:key] &&
        prepared.feed.lastErrorMessage.length == 0 ? prepared : nil;
    // One visit owns the preparation. A later menu opening makes a fresh feed
    // with the then-current source, account, sort and blur flags.
    objc_setAssociatedObject(sourceViewController, &kApolloGalleryPreparedController, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gallery) gallery = ApolloGalleryControllerForIdentifier(subreddit, sortValue, topWindowValue);
    if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
    ApolloLog(@"[Gallery] opened for %@ (%@)", gallery.sourceDescription,
              gallery == prepared ? @"prepared viewport" : @"source snapshot");
    return YES;
}

+ (BOOL)presentGalleryForMultiredditPath:(NSString *)multiredditPath
                      fromViewController:(UIViewController *)sourceViewController {
    return [self apollo_presentGalleryForMultiredditPath:multiredditPath
                                      fromViewController:sourceViewController
                                      inheritedSortValue:nil
                                 inheritedTopWindowValue:nil];
}

+ (BOOL)apollo_presentGalleryForMultiredditPath:(NSString *)multiredditPath
                             fromViewController:(UIViewController *)sourceViewController
                             inheritedSortValue:(NSNumber *)sortValue
                        inheritedTopWindowValue:(NSNumber *)topWindowValue {
    NSString *path = ApolloGalleryNormalizedMultiredditPath(multiredditPath);
    if (path.length == 0 || !sourceViewController) {
        ApolloLog(@"[Gallery] refusing to open: multireddit=%@ source=%@",
                  multiredditPath, sourceViewController);
        return NO;
    }

    ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithMultiredditPath:path];
    ApolloGalleryApplyInheritedSort(gallery, sortValue, topWindowValue);
    if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
    ApolloLog(@"[Gallery] opened for %@", gallery.sourceDescription);
    return YES;
}

+ (BOOL)presentGalleryForUsername:(NSString *)username
               fromViewController:(UIViewController *)sourceViewController {
    NSString *name = ApolloGalleryNormalizedUsername(username);
    if (name.length == 0 || !sourceViewController) {
        ApolloLog(@"[Gallery] refusing to open: username=%@ source=%@",
                  username, sourceViewController);
        return NO;
    }

    ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithUsername:name];
    if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
    ApolloLog(@"[Gallery] opened for %@", gallery.sourceDescription);
    return YES;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Gallery can inherit an opaque navigation-bar appearance when Header
    // Style is Hidden. UIKit would then place this controller's root view
    // below the bar, leaving a solid strip behind when the top bar is moved
    // offscreen. Keep the grid under navigation chrome just like Apollo's
    // native feeds so scrolled tiles fill the space the bar vacates.
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;
    // The grid keeps UIKit's automatic content-inset adjustment: tile 0 rests
    // just below the navigation bar and scrolled tiles pass underneath it, so
    // every Header Style samples real pixels while nothing is parked behind
    // the bar at rest. 3.7.1 cancelled the automatic TOP inset here to make
    // the grid "immersive"; that put the whole first row (and the top of the
    // second) behind the status bar and nav bar on every open, on iOS 26 and
    // 27 alike, in both orientations. Do not compensate the top inset again.
    self.title = @"Gallery";
    self.view.backgroundColor = self.gridBackgroundColor ?: UIColor.systemBackgroundColor;
    self.tileSizeIndex = ApolloGalleryGridSavedTileSizeIndex(NSUserDefaults.standardUserDefaults);

    self.waterfallLayout = [[ApolloGalleryWaterfallLayout alloc] init];
    self.waterfallLayout.spacing = kApolloGalleryTileSpacing;
    self.waterfallLayout.columnCount = [self apollo_columnCountForWidth:self.view.bounds.size.width];

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                           collectionViewLayout:self.waterfallLayout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.prefetchDataSource = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[ApolloGalleryTileCell class] forCellWithReuseIdentifier:kApolloGalleryCellID];
    [self.view addSubview:self.collectionView];

    self.tilePinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_pinchTiles:)];
    self.tilePinch.delegate = self;
    [self.collectionView addGestureRecognizer:self.tilePinch];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(apollo_pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = self.refreshControl;

    self.initialSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.initialSpinner.hidesWhenStopped = YES;
    [self.view addSubview:self.initialSpinner];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textColor = UIColor.secondaryLabelColor;
    self.messageLabel.font = [UIFont systemFontOfSize:15.0];
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.retryButton.tintColor = [self apollo_accentColor];
    [self.retryButton addTarget:self action:@selector(apollo_retryPressed) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];

    // Floating "loading more" pill; a supplementary footer would have to be
    // threaded through the custom layout for the same result.
    self.footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    self.footerLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.footerLabel.textColor = UIColor.whiteColor;
    self.footerLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    self.footerLabel.layer.cornerRadius = 13.0;
    self.footerLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.footerLabel.clipsToBounds = YES;
    self.footerLabel.alpha = 0.0;
    [self.view addSubview:self.footerLabel];

    [self apollo_installNavigationButtons];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(apollo_nsfwBlurInputsChanged:)
               name:ApolloAdultContentBlurPreferenceDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(apollo_nsfwBlurInputsChanged:)
               name:ApolloTagFiltersChangedNotification
             object:nil];
    // Tile autoplay follows the setting, the app's foreground state, and Low
    // Power Mode while a gallery is open, not just at the next open. (The
    // power-state notification arrives off the main thread.)
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(apollo_tilePlaybackInputsChanged:)
                   name:ApolloGalleryAutoplayMediaChangedNotification object:nil];
    [center addObserver:self selector:@selector(apollo_tilePlaybackInputsChanged:)
                   name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(apollo_tilePlaybackInputsChanged:)
                   name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(apollo_applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(apollo_applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    if (self.feed.items.count > 0) {
        // Source posts and their geometry are ready before the push starts.
        // A dense grid may need more than this source page; start filling as
        // soon as the push installs the view, without delaying navigation.
        [self apollo_updateEmptyStateWithError:nil];
        [self apollo_scheduleViewportFill];
    } else {
        [self apollo_beginInitialLoad];
    }
}

- (void)apollo_applyImmersiveNavigationAppearance {
    // Once the grid leaves its scroll edge, UINavigationBar normally swaps to
    // an opaque standard appearance. That layer sits above the configured top
    // edge effect and made a revealed Hidden header look solid. Gallery always
    // supplies content beneath the controls, so keep both navigation states
    // transparent and let Header Style remain the sole owner of the material.
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
    self.navigationItem.compactAppearance = appearance;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyImmersiveNavigationAppearance];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (ApolloGalleryImageRequest *request in _preparationWarmRequests) [request cancel];
}

// The grid is the one screen on Apollo's otherwise portrait-locked phone
// stack that supports landscape (ApolloGalleryOrientation.xm widens the
// container masks while it's topmost). UIKit only re-reads those masks when
// poked, so poke it on the way in — a device already held sideways rotates
// the freshly opened gallery — and on the way out, where the nav's top has
// already flipped to the portrait-only feed, so the same poke is what snaps
// a landscape grid back upright as it pops.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    }
    [self apollo_showPinchIntroductionIfNeeded];
    // Returning from another navigation screen or a cancelled swipe-back.
    // The over-fullscreen viewer explicitly resumes us after its dismissal.
    [self apollo_refreshTilePlayback];
    [self apollo_scheduleViewportFill];
}

// Only the guide's explicit acknowledgement makes this a one-time tip.
- (void)apollo_showPinchIntroductionIfNeeded {
    if ([ApolloGalleryPinchIntroduction hasBeenAcknowledged] ||
        self.presentedViewController || !self.view.window) return;

    ApolloGalleryPinchIntroduction *guide = [ApolloGalleryPinchIntroduction new];
    __weak typeof(self) weakSelf = self;
    guide.dismissalCompletion = ^{
        [weakSelf apollo_refreshTilePlayback];
    };
    [self presentViewController:guide animated:YES completion:nil];
    [self apollo_stopAllTilePlayback];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.galleryContextMenuActive) [self.collectionView.contextMenuInteraction dismissMenu];
    [self apollo_finishTilePinchAnimated:NO];
    if (@available(iOS 16.0, *)) {
        [self.navigationController setNeedsUpdateOfSupportedInterfaceOrientations];
    }
    // Popping, or the viewer going up over the grid: nothing behind it should
    // keep a decoder busy.
    [self apollo_stopAllTilePlayback];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Shed every player and GIF window now, and don't start any more this
    // visit; the next gallery open starts fresh.
    self.tilePlaybackSuspendedForMemory = YES;
    [self apollo_stopAllTilePlayback];
    ApolloLog(@"[Gallery] memory warning: tile autoplay suspended for this visit");
}

- (void)apollo_nsfwBlurInputsChanged:(NSNotification *)notification {
    // The captured Reddit preference can arrive after Gallery's initial cells
    // were configured, or change when the active account switches; the Tag
    // Filters settings can be edited while a Gallery sits in the nav stack.
    [self apollo_reloadGridPreservingContextMenu];
    (void)notification;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.initialSpinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));

    CGFloat messageWidth = MIN(bounds.size.width - 64.0, 420.0);
    CGSize messageSize = [self.messageLabel sizeThatFits:CGSizeMake(messageWidth, CGFLOAT_MAX)];
    self.messageLabel.frame = CGRectMake((bounds.size.width - messageWidth) / 2.0,
                                         CGRectGetMidY(bounds) - messageSize.height / 2.0 - 20.0,
                                         messageWidth, messageSize.height);
    self.retryButton.frame = CGRectMake((bounds.size.width - 160.0) / 2.0,
                                        CGRectGetMaxY(self.messageLabel.frame) + 12.0,
                                        160.0, 40.0);

    CGFloat safeBottom = 0.0;
    if (@available(iOS 11.0, *)) safeBottom = self.view.safeAreaInsets.bottom;
    self.footerLabel.frame = CGRectMake((bounds.size.width - 150.0) / 2.0,
                                        bounds.size.height - safeBottom - 46.0,
                                        150.0, 26.0);

    NSInteger columns = [self apollo_columnCountForWidth:bounds.size.width];
    if (!self.pinchingTiles && !self.tileSizeSettlement && columns != self.waterfallLayout.columnCount) {
        self.waterfallLayout.columnCount = columns;
        [self.waterfallLayout invalidateLayout];
    }

    // UIKit installs Gallery's full-width bottom scroll-edge material after
    // the collection view has already entered the window. Register that late
    // effect after layout so Minimize can keep it hidden behind the compact pill.
    ApolloApplyScrollEdgeEffectStyle(self.collectionView);
    [self apollo_scheduleViewportFill];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.collectionView) [self apollo_scheduleViewportFill];
    if (scrollView != self.collectionView ||
        sTabBarHideStyle != ApolloTabBarHideStyleMinimize ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyNativeHideBarsOnScroll]) return;

    // The first drag can create a fresh edge-effect object after the layout
    // pass above. Only revisit the shared styler while that late object is
    // visible; after it is registered, the Minimize edge state filters subsequent
    // UIKit visibility writes without doing work on every scroll callback.
    SEL bottomSelector = NSSelectorFromString(@"bottomEdgeEffect");
    id effect = [scrollView respondsToSelector:bottomSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(scrollView, bottomSelector)
        : nil;
    if ([effect respondsToSelector:@selector(isHidden)] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(effect, @selector(isHidden))) {
        ApolloApplyScrollEdgeEffectStyle(scrollView);
    }
}

- (NSInteger)apollo_columnCountForWidth:(CGFloat)width {
    return [self apollo_columnCountForWidth:width tileSizeIndex:self.tileSizeIndex];
}

- (NSInteger)apollo_columnCountForWidth:(CGFloat)width tileSizeIndex:(NSInteger)index {
    return ApolloGalleryGridColumnCount(width, index);
}

// Rotation reshuffles the whole waterfall — a different column count and
// column width move every tile to a new y — so carrying the raw point offset
// across lands the user on unrelated tiles. Anchor on the tile nearest the
// MIDDLE of the viewport — the one the user is actually looking at — and put
// its center back at the same relative height of the new viewport. Keeping
// that relative height (rather than snapping the anchor to the exact center)
// is what makes portrait → landscape → portrait land back on the original
// offset instead of drifting a little on every round trip.
- (NSIndexPath *)apollo_visibleAnchorRelativeCenter:(CGFloat *)relativeCenter {
    UICollectionView *collectionView = self.collectionView;
    if (!collectionView || self.feed.items.count == 0) return nil;

    UIEdgeInsets insets = collectionView.adjustedContentInset;
    CGFloat visibleTop = collectionView.contentOffset.y + insets.top;
    // Pinned at the top: leave the offset to UIKit so the grid stays flush
    // under the bar instead of anchoring partway into tile 0.
    if (visibleTop <= 1.0) return nil;
    CGFloat visibleHeight = MAX(collectionView.bounds.size.height - insets.top - insets.bottom, 1.0);
    CGFloat visibleCenter = visibleTop + visibleHeight / 2.0;

    NSIndexPath *anchorPath = nil;
    CGFloat anchorDistance = CGFLOAT_MAX;
    CGFloat anchorRelative = 0.5;
    for (NSIndexPath *indexPath in [collectionView indexPathsForVisibleItems]) {
        UICollectionViewLayoutAttributes *attributes =
            [self.waterfallLayout layoutAttributesForItemAtIndexPath:indexPath];
        // "Visible" includes cells fully underneath the nav bar; skip those.
        if (!attributes || CGRectGetMaxY(attributes.frame) <= visibleTop) continue;
        CGFloat itemCenter = CGRectGetMidY(attributes.frame);
        CGFloat distance = fabs(itemCenter - visibleCenter);
        // Ties (two side-by-side tiles equally near the center) go to the
        // lower index so the pick is deterministic across round trips.
        if (distance + 0.5 < anchorDistance ||
            (fabs(distance - anchorDistance) <= 0.5 && indexPath.item < anchorPath.item)) {
            anchorPath = indexPath;
            anchorDistance = distance;
            anchorRelative = (itemCenter - visibleTop) / visibleHeight;
        }
    }
    if (relativeCenter) *relativeCenter = anchorRelative;
    return anchorPath;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self apollo_finishTilePinchAnimated:NO];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    CGFloat relative = 0.5;
    NSIndexPath *path = [self apollo_visibleAnchorRelativeCenter:&relative];
    if (!path) return;

    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf apollo_scrollToAnchorItem:path relativeCenter:relative forSize:size];
        (void)context;
    } completion:nil];
}

- (void)apollo_scrollToAnchorItem:(NSIndexPath *)anchorPath
                   relativeCenter:(CGFloat)relative
                          forSize:(CGSize)size {
    UICollectionView *collectionView = self.collectionView;
    if (anchorPath.item >= [collectionView numberOfItemsInSection:0]) return;

    // Commit the new-geometry layout before reading the anchor's new frame.
    // Setting the column count here (rather than waiting for
    // viewDidLayoutSubviews) makes the single layoutIfNeeded below produce the
    // final tile positions instead of an intermediate old-column-count pass.
    // Measure the grid itself, not the transition's `size`: for a gallery
    // inside a modally presented subreddit, UIKit hands this controller the
    // container's proposed width (414pt on a landscape iPhone) while the
    // collection view is already at its real 874pt. Deriving columns from the
    // wrong one set a two-column landscape grid (435pt tiles) after a
    // scrolled rotation, and only layout-pass ordering ever hid it.
    CGFloat width = collectionView.bounds.size.width > 0.0 ? collectionView.bounds.size.width : size.width;
    NSInteger columns = [self apollo_columnCountForWidth:width];
    if (columns != self.waterfallLayout.columnCount) {
        self.waterfallLayout.columnCount = columns;
        [self.waterfallLayout invalidateLayout];
    }
    [collectionView layoutIfNeeded];

    UICollectionViewLayoutAttributes *attributes =
        [self.waterfallLayout layoutAttributesForItemAtIndexPath:anchorPath];
    if (!attributes) return;

    UIEdgeInsets insets = collectionView.adjustedContentInset;
    CGFloat visibleHeight = MAX(collectionView.bounds.size.height - insets.top - insets.bottom, 1.0);
    CGFloat target = CGRectGetMidY(attributes.frame)
                     - relative * visibleHeight
                     - insets.top;
    CGFloat maxOffset = collectionView.collectionViewLayout.collectionViewContentSize.height
                        - collectionView.bounds.size.height + insets.bottom;
    target = MIN(target, MAX(maxOffset, -insets.top));
    target = MAX(target, -insets.top);
    [collectionView setContentOffset:CGPointMake(0.0, target) animated:NO];
}

- (UIColor *)apollo_accentColor {
    return ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
}

#pragma mark Tile autoplay

// Which switch governs a tile: "Play Videos in Gallery View" for anything the
// feed badges with a duration, "Play GIFs in Gallery View" for anything it
// badges GIF — however that GIF happens to be played (mp4 rendition or the
// .gif itself). Stills have nothing to play.
static BOOL ApolloGalleryTileAutoplayEnabledForKind(ApolloGalleryMediaKind kind) {
    if (kind == ApolloGalleryMediaKindVideo) return sGalleryAutoplayVideos;
    if (kind == ApolloGalleryMediaKindGIF) return sGalleryAutoplayGIFs;
    return NO;
}

// Whether tiles may move right now: at least one of the two switches, Low
// Power Mode, the app in the foreground, this grid being the visible screen
// (not under the fullscreen viewer, not popped), and no memory warning during
// this visit. Per-kind gating is ApolloGalleryTileAutoplayEnabledForKind.
- (BOOL)apollo_tileAutoplayAllowed {
    if (self.pinchingTiles || self.tileSizeSettlement || self.galleryContextMenuActive) return NO;
    if (!sGalleryAutoplayVideos && !sGalleryAutoplayGIFs) return NO;
    if (self.tilePlaybackSuspendedForMemory) return NO;
    if ([NSProcessInfo processInfo].isLowPowerModeEnabled) return NO;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return NO;
    // OverFullScreen can be presented by an ancestor, and leaves our view
    // mounted. Keep playback paused until the viewer's dismissal completes.
    if (self.activeViewer || self.presentedViewController) return NO;
    return self.viewIfLoaded.window != nil;
}

// Reconcile every on-screen tile with the rules above and the caps. Cheap (a
// dozen-odd visible cells) but deliberately not run per scroll tick: tiles
// start when the grid settles (see the scroll-view callbacks) or first
// appears, and stop the instant they leave the screen.
- (void)apollo_refreshTilePlayback {
    UICollectionView *collectionView = self.collectionView;
    if (!collectionView) return;
    BOOL allowed = [self apollo_tileAutoplayAllowed];
    NSInteger playing = 0;
    NSInteger animatedGIFs = 0;
    NSInteger hostLookups = 0;
    for (NSIndexPath *indexPath in [self apollo_tilesInPlaybackOrder]) {
        ApolloGalleryTileCell *cell = (ApolloGalleryTileCell *)[collectionView cellForItemAtIndexPath:indexPath];
        if (![cell isKindOfClass:[ApolloGalleryTileCell class]]) continue;
        BOOL gif = cell.playsAnimatedGIF;
        BOOL wanted = allowed && cell.canAutoplay &&
                      ApolloGalleryTileAutoplayEnabledForKind(cell.item.kind) &&
                      playing < kApolloGalleryMaxPlayingTiles &&
                      (!gif || animatedGIFs < kApolloGalleryMaxAnimatedGIFTiles);
        if (!wanted) {
            [cell stopPlayback];
            continue;
        }
        [cell startPlayback];
        if (cell.isPlaying) {
            playing++;
            if (gif) animatedGIFs++;
            if (cell.isAwaitingHostedVideo) hostLookups++;
        }
    }
    if (playing != self.lastLoggedPlayingTileCount) {
        self.lastLoggedPlayingTileCount = playing;
        ApolloLog(@"[Gallery] autoplay: %ld tile(s) playing (%ld .gif on cpu, %ld waiting on a host) allowed=%d videos=%d gifs=%d",
                  (long)playing, (long)animatedGIFs, (long)hostLookups, allowed, sGalleryAutoplayVideos,
                  sGalleryAutoplayGIFs);
    }
}

// The visible tiles in the order they claim the cap: those at least half on
// screen first, then the slivers at the top and bottom edges, each group top
// to bottom. Index order alone let a strip peeking out under the nav bar take
// a slot from a whole tile further down once sports clips competed for them.
- (NSArray<NSIndexPath *> *)apollo_tilesInPlaybackOrder {
    UICollectionView *collectionView = self.collectionView;
    CGRect viewport = UIEdgeInsetsInsetRect(collectionView.bounds, collectionView.adjustedContentInset);
    NSMutableArray<NSIndexPath *> *mostlyVisible = [NSMutableArray array];
    NSMutableArray<NSIndexPath *> *slivers = [NSMutableArray array];
    for (NSIndexPath *indexPath in
         [collectionView.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)]) {
        CGRect frame = [collectionView layoutAttributesForItemAtIndexPath:indexPath].frame;
        CGRect shown = CGRectIntersection(frame, viewport);
        BOOL mostly = !CGRectIsNull(shown) && CGRectGetHeight(shown) * 2.0 >= CGRectGetHeight(frame);
        [(mostly ? mostlyVisible : slivers) addObject:indexPath];
    }
    [mostlyVisible addObjectsFromArray:slivers];
    return mostlyVisible;
}

// A refresh run from -collectionView:willDisplayCell:... can't start the tile
// being displayed: UIKit only adds it to indexPathsForVisibleItems after that
// callback returns, so the LAST tile a layout pass brings on screen (the bottom
// row after the first batch, or anything a relayout reveals) sat on its poster
// until the next scroll settled. Run it once the pass is over instead, and
// once per pass rather than once per arriving tile.
- (void)apollo_setNeedsTilePlaybackRefresh {
    if (self.tilePlaybackRefreshQueued) return;
    self.tilePlaybackRefreshQueued = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.tilePlaybackRefreshQueued = NO;
        // A drag that began meanwhile gets its refresh when it settles.
        UICollectionView *collectionView = strongSelf.collectionView;
        if (collectionView.isDragging || collectionView.isDecelerating) return;
        [strongSelf apollo_refreshTilePlayback];
    });
}

- (void)apollo_stopAllTilePlayback {
    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        if ([cell isKindOfClass:[ApolloGalleryTileCell class]]) [(ApolloGalleryTileCell *)cell stopPlayback];
    }
    if (self.lastLoggedPlayingTileCount != 0) {
        self.lastLoggedPlayingTileCount = 0;
        ApolloLog(@"[Gallery] autoplay: all tiles stopped");
    }
}

- (void)apollo_tilePlaybackInputsChanged:(NSNotification *)notification {
    (void)notification;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf apollo_refreshTilePlayback]; });
}

- (void)apollo_applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self apollo_scheduleViewportFill];
    [self apollo_refreshTilePlayback];
}

- (void)apollo_applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    if (self.galleryContextMenuActive) [self.collectionView.contextMenuInteraction dismissMenu];
    [self apollo_finishTilePinchAnimated:NO];
    [self apollo_stopAllTilePlayback];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // Once a new one-finger drag starts, scrolling owns the offset. The brief
    // size settle may finish, but must not keep pulling back to its anchor.
    if (scrollView == self.collectionView && !self.pinchingTiles) self.pinchAnchor = nil;
}

// Start only once the grid has settled: a fling brings dozens of tiles past
// the screen, and spinning up a decoder for each on the way by is wasted work.
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    (void)scrollView;
    [self apollo_refreshTilePlayback];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    (void)scrollView;
    if (!decelerate) [self apollo_refreshTilePlayback];
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView {
    (void)scrollView;
    [self apollo_refreshTilePlayback];
}

#pragma mark Tile sizing

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.tilePinch) {
        return !self.galleryContextMenuActive && self.feed.items.count > 0 && self.collectionView.bounds.size.width > 0.0;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // A pinch can begin while a finger is already scrolling. Permit only
    // that pairing; the pinch still cancels a tile's pending selection.
    return (gestureRecognizer == self.tilePinch && other == self.collectionView.panGestureRecognizer) ||
           (other == self.tilePinch && gestureRecognizer == self.collectionView.panGestureRecognizer);
}

- (void)apollo_restorePinchAnchor {
    NSIndexPath *anchor = self.pinchAnchor;
    if (!anchor || anchor.item >= self.feed.items.count ||
        self.feed.items[anchor.item] != self.pinchAnchorItem) return;
    UICollectionViewLayoutAttributes *attributes =
        [self.waterfallLayout layoutAttributesForItemAtIndexPath:anchor];
    if (!attributes) return;
    // Preserve the point inside the tile, not just its center: a tall image
    // should stay beneath the fingers as it grows. Columns can move sideways
    // in a waterfall, so anchoring is vertical (the grid never scrolls in x).
    CGFloat target = CGRectGetMinY(attributes.frame) + attributes.frame.size.height * self.pinchAnchorFraction
                     - self.pinchViewportY;
    UIEdgeInsets insets = self.collectionView.adjustedContentInset;
    CGFloat maximum = self.waterfallLayout.collectionViewContentSize.height
                      - self.collectionView.bounds.size.height + insets.bottom;
    target = MAX(-insets.top, MIN(target, MAX(-insets.top, maximum)));
    [self.collectionView setContentOffset:CGPointMake(0.0, target) animated:NO];
}

- (void)apollo_applyPinchPosition {
    NSInteger lower = (NSInteger)floor(self.pinchPosition);
    NSInteger upper = MIN(lower + 1, (NSInteger)self.pinchSizeIndices.count - 1);
    CGFloat width = self.collectionView.bounds.size.width;
    self.waterfallLayout.columnCount = [self apollo_columnCountForWidth:width
        tileSizeIndex:self.pinchSizeIndices[lower].integerValue];
    self.waterfallLayout.destinationColumnCount = [self apollo_columnCountForWidth:width
        tileSizeIndex:self.pinchSizeIndices[upper].integerValue];
    self.waterfallLayout.transitionProgress = self.pinchPosition - lower;
    [self.waterfallLayout invalidateLayout];
    [self.collectionView layoutIfNeeded];
    [self apollo_restorePinchAnchor];
}

- (CGFloat)apollo_tileWidthAtPinchPosition:(CGFloat)position {
    NSInteger lower = MAX(0, MIN((NSInteger)self.pinchTileWidths.count - 1, (NSInteger)floor(position)));
    NSInteger upper = MIN(lower + 1, (NSInteger)self.pinchTileWidths.count - 1);
    CGFloat fromWidth = self.pinchTileWidths[lower].doubleValue;
    CGFloat toWidth = self.pinchTileWidths[upper].doubleValue;
    return fromWidth + (toWidth - fromWidth) * (position - lower);
}

- (CGFloat)apollo_pinchPositionForTileWidth:(CGFloat)width {
    if (width <= self.pinchTileWidths.firstObject.doubleValue) return 0.0;
    for (NSUInteger upper = 1; upper < self.pinchTileWidths.count; upper++) {
        CGFloat toWidth = self.pinchTileWidths[upper].doubleValue;
        if (width <= toWidth) {
            CGFloat fromWidth = self.pinchTileWidths[upper - 1].doubleValue;
            return upper - 1.0 + (width - fromWidth) / MAX(toWidth - fromWidth, 1.0);
        }
    }
    return self.pinchTileWidths.count - 1.0;
}

- (void)apollo_finishTilePinchAnimated:(BOOL)animated {
    if (!self.pinchingTiles && !self.tileSizeSettlement) return;
    CGFloat destination = self.tileSizeSettlement ? self.tileSizeSettlementTo : round(self.pinchPosition);
    [self apollo_settleTilePinchToPosition:destination animated:animated];
}

- (void)apollo_settleTilePinchToPosition:(CGFloat)destination animated:(BOOL)animated {
    [self.tileSizeSettlement invalidate];
    self.tileSizeSettlement = nil;
    NSInteger position = MAX(0, MIN((NSInteger)self.pinchSizeIndices.count - 1, (NSInteger)destination));
    // Different saved widths can share one column count in portrait and
    // diverge in landscape. A cancelled/no-net-change pinch must preserve
    // the original width choice instead of canonicalizing it to the first.
    NSInteger chosenIndex = self.pinchSizeIndices[position].integerValue;
    CGFloat width = self.collectionView.bounds.size.width;
    self.tileSizeIndex = [self apollo_columnCountForWidth:width tileSizeIndex:chosenIndex] ==
                        [self apollo_columnCountForWidth:width tileSizeIndex:self.pinchStartTileSizeIndex]
        ? self.pinchStartTileSizeIndex : self.pinchSizeIndices[position].integerValue;
    [NSUserDefaults.standardUserDefaults setObject:@(self.tileSizeIndex) forKey:kApolloGalleryTileSizeKey];
    self.pinchingTiles = NO;
    self.collectionView.panGestureRecognizer.enabled = YES;
    if (animated && !UIAccessibilityIsReduceMotionEnabled() && fabs(position - self.pinchPosition) > 0.001) {
        // Keep layout/model geometry equal to the visible geometry on every
        // frame. UIView's layer animation puts the model at the endpoint
        // immediately; grabbing it with a second pinch would then jump ahead.
        self.tileSizeSettlementFrom = self.pinchPosition;
        self.tileSizeSettlementTo = position;
        self.tileSizeSettlementStart = CACurrentMediaTime();
        self.tileSizeSettlement = [CADisplayLink displayLinkWithTarget:self selector:@selector(apollo_tickTileSizeSettlement:)];
        [self.tileSizeSettlement addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else {
        self.pinchPosition = position;
        [UIView performWithoutAnimation:^{ [self apollo_applyPinchPosition]; }];
        [self apollo_refreshTilePlayback];
        [self apollo_scheduleViewportFill];
    }
}

- (void)apollo_tickTileSizeSettlement:(CADisplayLink *)displayLink {
    CGFloat elapsed = MAX(0.0, MIN(1.0, (displayLink.timestamp - self.tileSizeSettlementStart) / 0.34));
    // Ease into the remaining distance instead of accelerating abruptly as
    // the fingers lift. The settled frame remains interruptible throughout.
    CGFloat progress = elapsed * elapsed * (3.0 - 2.0 * elapsed);
    self.pinchPosition = self.tileSizeSettlementFrom +
                         (self.tileSizeSettlementTo - self.tileSizeSettlementFrom) * progress;
    [UIView performWithoutAnimation:^{ [self apollo_applyPinchPosition]; }];
    if (elapsed >= 1.0) {
        [displayLink invalidate];
        self.tileSizeSettlement = nil;
        [self apollo_refreshTilePlayback];
        [self apollo_scheduleViewportFill];
    }
}

- (void)apollo_pinchTiles:(UIPinchGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        BOOL continuingSettlement = self.tileSizeSettlement != nil;
        self.pinchingTiles = YES;
        [self.tileSizeSettlement invalidate];
        self.tileSizeSettlement = nil;
        self.pinchStartTileSizeIndex = self.tileSizeIndex;
        [self.collectionView setContentOffset:self.collectionView.contentOffset animated:NO];
        if (continuingSettlement) {
            self.pinchStartPosition = self.pinchPosition;
        } else {
            CGFloat width = self.collectionView.bounds.size.width;
            NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
            NSMutableArray<NSNumber *> *tileWidths = [NSMutableArray array];
            NSInteger previousColumns = -1;
            NSInteger currentColumns = [self apollo_columnCountForWidth:width];
            for (NSInteger i = 0; i < kApolloGalleryTileSizeCount; i++) {
                NSInteger columns = [self apollo_columnCountForWidth:width tileSizeIndex:i];
                if (columns == previousColumns) continue;
                if (columns == currentColumns) self.pinchStartPosition = indices.count;
                [indices addObject:@(i)];
                [tileWidths addObject:@(floor((width - kApolloGalleryTileSpacing * (columns - 1)) / columns))];
                previousColumns = columns;
            }
            self.pinchSizeIndices = indices;
            self.pinchTileWidths = tileWidths;
            self.pinchPosition = self.pinchStartPosition;
        }
        self.pinchStartTileWidth = [self apollo_tileWidthAtPinchPosition:self.pinchStartPosition];
        // The custom anchor already follows a moving pinch midpoint. Stop
        // the scroll recognizer from applying that same translation again.
        self.collectionView.panGestureRecognizer.enabled = NO;
        CGPoint point = [gesture locationInView:self.collectionView];
        self.pinchViewportY = point.y - self.collectionView.contentOffset.y;
        self.pinchAnchor = [self.collectionView indexPathForItemAtPoint:point];
        if (!self.pinchAnchor) {
            CGFloat nearest = CGFLOAT_MAX;
            for (NSIndexPath *path in self.collectionView.indexPathsForVisibleItems) {
                CGRect frame = [self.waterfallLayout layoutAttributesForItemAtIndexPath:path].frame;
                CGFloat distance = hypot(CGRectGetMidX(frame) - point.x, CGRectGetMidY(frame) - point.y);
                if (distance < nearest) { nearest = distance; self.pinchAnchor = path; }
            }
        }
        self.pinchAnchorItem = self.pinchAnchor && self.pinchAnchor.item < self.feed.items.count
            ? self.feed.items[self.pinchAnchor.item] : nil;
        CGRect frame = [self.waterfallLayout layoutAttributesForItemAtIndexPath:self.pinchAnchor].frame;
        self.pinchAnchorFraction = MAX(0.0, MIN(1.0, (point.y - CGRectGetMinY(frame)) / MAX(frame.size.height, 1.0)));
        [self apollo_stopAllTilePlayback];
    }
    if (!self.pinchingTiles) return;
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged ||
        gesture.state == UIGestureRecognizerStateEnded) {
        // Deliberately damp finger travel: 60% sensitivity in log-scale space
        // keeps reciprocal spread/pinch distances symmetric. A 20% spread
        // grows a tile by about 12%, giving finer control over column changes
        // than direct 1:1 scaling. This adjusts live tracking, not its settle
        // duration, and still starts from the visible width on a re-grab.
        static CGFloat const sensitivity = 0.6;
        CGFloat effectiveScale = pow(MAX(gesture.scale, 0.01), sensitivity);
        CGFloat tileWidth = self.pinchStartTileWidth * effectiveScale;
        self.pinchPosition = [self apollo_pinchPositionForTileWidth:tileWidth];
        if (gesture.numberOfTouches >= 2) {
            self.pinchViewportY = [gesture locationInView:self.collectionView].y - self.collectionView.contentOffset.y;
        }
        [self apollo_applyPinchPosition];
    }
    if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        [self apollo_settleTilePinchToPosition:round(self.pinchStartPosition) animated:YES];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        [self apollo_finishTilePinchAnimated:YES];
    }
}

- (void)apollo_installNavigationButtons {
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:nil
                                                            action:nil];
    sort.accessibilityLabel = @"Sort";
    sort.menu = [self apollo_buildSortMenu];

    self.filterBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[self apollo_filterButtonImage]
                                                                style:UIBarButtonItemStylePlain
                                                               target:nil
                                                               action:nil];
    self.filterBarButtonItem.accessibilityLabel = @"Filter media";
    self.filterBarButtonItem.menu = [self apollo_buildFilterMenu];

    // Rightmost first. Tile sizing lives directly on the grid via pinch.
    self.navigationItem.rightBarButtonItems = @[sort, self.filterBarButtonItem];
}

// A filled glyph while a filter is narrowing things down, so it's obvious at a
// glance that the grid isn't showing everything.
- (UIImage *)apollo_filterButtonImage {
    BOOL filtering = self.feed.allowedKinds != ApolloGalleryMediaKindAll;
    return [UIImage systemImageNamed:(filtering ? @"line.3.horizontal.decrease.circle.fill"
                                                : @"line.3.horizontal.decrease.circle")];
}

- (UIMenu *)apollo_buildFilterMenu {
    NSArray<NSDictionary *> *kinds = @[
        @{ @"title": @"Photos", @"icon": @"photo",           @"kind": @(ApolloGalleryMediaKindPhoto) },
        @{ @"title": @"GIFs",   @"icon": @"square.stack.3d.forward.dottedline", @"kind": @(ApolloGalleryMediaKindGIF) },
        @{ @"title": @"Videos", @"icon": @"play.rectangle",  @"kind": @(ApolloGalleryMediaKindVideo) },
    ];

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSDictionary *entry in kinds) {
        ApolloGalleryMediaKind kind = (ApolloGalleryMediaKind)((NSNumber *)entry[@"kind"]).unsignedIntegerValue;
        BOOL on = (self.feed.allowedKinds & kind) != 0;
        BOOL isOnlyOneOn = on && (self.feed.allowedKinds == kind);

        NSUInteger count = [self.feed countOfKind:kind];
        UIAction *action = [UIAction actionWithTitle:entry[@"title"]
                                               image:[UIImage systemImageNamed:entry[@"icon"]]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf apollo_toggleKind:kind];
        }];
        action.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        // Turning off the only remaining kind would empty the gallery, so that
        // one row is disabled rather than silently doing nothing.
        if (isOnlyOneOn) action.attributes = UIMenuElementAttributesDisabled;
        if (count > 0 && [action respondsToSelector:@selector(setSubtitle:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(action, @selector(setSubtitle:),
                                                  [NSString stringWithFormat:@"%lu loaded", (unsigned long)count]);
        }
        // iOS 16+ can keep the menu up between taps, which is what makes a
        // multi-select menu feel right; older releases just close each time.
        if (@available(iOS 16.0, *)) {
            action.attributes |= UIMenuElementAttributesKeepsMenuPresented;
        }
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:@"Show" children:children];
}


// Index paths shift or vanish on any wholesale reload (filter toggle, sort
// change, refresh) — the outstanding look-aheads keyed on them are stale, so
// stop the transfers rather than let them finish into nothing.
- (void)apollo_cancelAllPrefetches {
    for (ApolloGalleryImageRequest *request in self.prefetchRequests.allValues) {
        [request cancel];
    }
    [self.prefetchRequests removeAllObjects];
}

- (void)apollo_toggleKind:(ApolloGalleryMediaKind)kind {
    ApolloGalleryMediaKind updated = self.feed.allowedKinds ^ kind;
    if (updated == 0) return;   // never leave the gallery with nothing to show
    [self apollo_cancelAllPrefetches];

    self.feed.allowedKinds = updated;
    self.filterBarButtonItem.image = [self apollo_filterButtonImage];
    self.filterBarButtonItem.menu = [self apollo_buildFilterMenu];
    [self apollo_setFooterText:nil];
    [self apollo_reloadGridPreservingContextMenu];
    [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.adjustedContentInset.top) animated:NO];
    ApolloLog(@"[Gallery] filter -> photo:%d gif:%d video:%d (%lu of %lu shown)",
              (updated & ApolloGalleryMediaKindPhoto) != 0,
              (updated & ApolloGalleryMediaKindGIF) != 0,
              (updated & ApolloGalleryMediaKindVideo) != 0,
              (unsigned long)self.feed.items.count, (unsigned long)self.feed.allItems.count);

    // Setting the filter dropped any batch in flight, and a dropped batch never
    // calls back. When nothing has landed yet (the first load still running,
    // or it failed or came back empty) there is no grid to top up: run the
    // first load again under the new filter, spinner and all, so its
    // completion is what settles the screen. Topping up instead left the
    // spinner turning over the finished grid, under a "No media found" that
    // was never cleared (#1175).
    if (self.initialLoadPending || self.feed.allItems.count == 0) {
        ApolloLog(@"[Gallery] filter changed before the first batch landed; restarting the first load");
        [self apollo_beginInitialLoad];
        return;
    }
    [self apollo_updateEmptyStateWithError:nil];

    // The visible list just shrank; it may no longer fill the screen, so top it
    // up rather than leaving the user on a stub of a grid.
    [self apollo_loadMoreIfNeededForIndex:(NSInteger)self.feed.items.count - 1];
}

// The same options, order, and iconography as Apollo's own subreddit sort
// menu (Best / Hot / Top / New / Rising / Controversial), so the gallery
// doesn't feel like a different app. Best and Rising drop off feeds whose
// listing endpoint rejects them (user profiles).
- (UIMenu *)apollo_buildSortMenu {
    __weak typeof(self) weakSelf = self;
    UIAction * (^makeSort)(NSString *, NSString *, ApolloGallerySort) =
        ^UIAction *(NSString *title, NSString *symbol, ApolloGallerySort sort) {
        UIAction *action = [UIAction actionWithTitle:title
                                               image:[UIImage systemImageNamed:symbol]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf apollo_applySort:sort topWindow:weakSelf.feed.topWindow];
        }];
        if (weakSelf.feed.sort == sort) action.state = UIMenuElementStateOn;
        return action;
    };

    NSMutableArray<UIMenuElement *> *sorts = [NSMutableArray array];
    if (self.feed.supportsBestSort) {
        [sorts addObject:makeSort(@"Best", @"trophy", ApolloGallerySortBest)];
    }
    [sorts addObject:makeSort(@"Hot", @"flame", ApolloGallerySortHot)];
    [sorts addObject:[self apollo_windowedSortMenuWithTitle:@"Top"
                                                     symbol:@"chart.bar"
                                                       sort:ApolloGallerySortTop]];
    [sorts addObject:makeSort(@"New", @"clock", ApolloGallerySortNew)];
    if (self.feed.supportsRisingSort) {
        [sorts addObject:makeSort(@"Rising", @"chart.line.uptrend.xyaxis", ApolloGallerySortRising)];
    }
    [sorts addObject:[self apollo_windowedSortMenuWithTitle:@"Controversial"
                                                     symbol:@"plusminus"
                                                       sort:ApolloGallerySortControversial]];
    return [UIMenu menuWithTitle:@"Sort" children:sorts];
}

// Top and Controversial both open the same time-window submenu, exactly like
// Apollo's native menu.
- (UIMenu *)apollo_windowedSortMenuWithTitle:(NSString *)title
                                      symbol:(NSString *)symbol
                                        sort:(ApolloGallerySort)sort {
    NSArray<NSDictionary *> *windows = @[
        @{ @"title": @"Today",      @"window": @(ApolloGalleryTopWindowDay) },
        @{ @"title": @"This Week",  @"window": @(ApolloGalleryTopWindowWeek) },
        @{ @"title": @"This Month", @"window": @(ApolloGalleryTopWindowMonth) },
        @{ @"title": @"This Year",  @"window": @(ApolloGalleryTopWindowYear) },
        @{ @"title": @"All Time",   @"window": @(ApolloGalleryTopWindowAll) },
    ];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *children = [NSMutableArray array];
    for (NSDictionary *entry in windows) {
        ApolloGalleryTopWindow window = (ApolloGalleryTopWindow)((NSNumber *)entry[@"window"]).integerValue;
        UIAction *action = [UIAction actionWithTitle:entry[@"title"] image:nil identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf apollo_applySort:sort topWindow:window];
        }];
        if (self.feed.sort == sort && self.feed.topWindow == window) {
            action.state = UIMenuElementStateOn;
        }
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:title
                           image:[UIImage systemImageNamed:symbol]
                      identifier:nil
                         options:0
                        children:children];
}

- (void)apollo_applySort:(ApolloGallerySort)sort topWindow:(ApolloGalleryTopWindow)window {
    if (self.feed.sort == sort && (!ApolloGallerySortUsesWindow(sort) || self.feed.topWindow == window)) return;
    [self.feed setSort:sort topWindow:window];
    [self apollo_setFooterText:nil];
    [self apollo_reloadGridPreservingContextMenu];
    [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.adjustedContentInset.top) animated:NO];
    self.navigationItem.rightBarButtonItems.firstObject.menu = [self apollo_buildSortMenu];
    [self apollo_beginInitialLoad];
}

#pragma mark Loading

- (BOOL)apollo_gridCoversContentY:(CGFloat)targetY {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    CGFloat width = self.collectionView.bounds.size.width;
    NSInteger columns = self.waterfallLayout.columnCount;
    // The feed replaces its immutable projection on append/filter/reset.
    // Measure once per data or size change, never walk the listing on every
    // scroll event (which becomes noticeable after thousands of posts).
    if (items != self.coverageItems || width != self.coverageWidth || columns != self.coverageColumns) {
        self.coverageItems = items;
        self.coverageWidth = width;
        self.coverageColumns = columns;
        self.shortestColumnBottom = ApolloGalleryGridCoverage(items.count, width, columns,
            ^CGSize(NSUInteger index) { return items[index].pixelSize; });
    }
    return self.shortestColumnBottom + 0.5 >= targetY;
}

- (void)apollo_scheduleViewportFill {
    if (self.viewportFillQueued) return;
    self.viewportFillQueued = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.viewportFillQueued = NO;
        [strongSelf apollo_fillViewportIfNeeded];
    });
}

- (void)apollo_fillViewportIfNeeded {
    if (!self.collectionView.window || self.navigationController.topViewController != self ||
        self.activeViewer || self.galleryContextMenuActive || self.galleryReloadPendingAfterMenu ||
        self.pinchingTiles || self.tileSizeSettlement || self.initialLoadPending ||
        self.feed.isLoading || self.feed.isExhausted || self.feed.lastErrorMessage.length > 0 ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    NSInteger total = (NSInteger)self.feed.items.count;
    if (total == 0 || self.collectionView.bounds.size.width <= 0.0) return;

    // The last visible index is not a screen-coverage measurement in a
    // waterfall. Fill every column through the bottom, plus one row ahead.
    CGFloat width = self.collectionView.bounds.size.width;
    NSInteger columns = self.waterfallLayout.columnCount;
    CGFloat rowAhead = ApolloGalleryGridTileWidth(width, columns);
    CGFloat visibleBottom = MAX(0.0, CGRectGetMaxY(self.collectionView.bounds) -
                                    self.collectionView.adjustedContentInset.bottom);
    if (![self apollo_gridCoversContentY:visibleBottom + rowAhead]) {
        [self apollo_loadMoreIfNeededForIndex:total - 1];
    }
}

- (void)apollo_beginInitialLoad {
    self.initialLoadPending = YES;
    self.messageLabel.hidden = YES;
    self.retryButton.hidden = YES;
    [self.initialSpinner startAnimating];

    __weak typeof(self) weakSelf = self;
    [self.feed loadNextBatchWithCompletion:^(NSRange addedRange, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.initialLoadPending = NO;
        [strongSelf.initialSpinner stopAnimating];
        [strongSelf.refreshControl endRefreshing];
        [strongSelf apollo_reloadGridPreservingContextMenu];
        [strongSelf apollo_updateEmptyStateWithError:errorMessage];
        // Built before the first fetch, so its "N loaded" subtitles were all
        // zero until now.
        strongSelf.filterBarButtonItem.menu = [strongSelf apollo_buildFilterMenu];
        [strongSelf apollo_scheduleViewportFill];
        (void)addedRange;
    }];
}

- (void)apollo_pullToRefresh {
    [self.feed reset];
    // The reset drops a load-more still in flight, and a dropped batch never
    // calls back to clear its "Loading more…" pill; a sort change clears it
    // the same way.
    [self apollo_setFooterText:nil];
    [self apollo_reloadGridPreservingContextMenu];
    [self apollo_beginInitialLoad];
}

- (void)apollo_retryPressed {
    [self apollo_beginInitialLoad];
}

- (void)apollo_updateEmptyStateWithError:(NSString *)errorMessage {
    if (self.feed.items.count > 0) {
        self.messageLabel.hidden = YES;
        self.retryButton.hidden = YES;
        return;
    }
    if (errorMessage.length > 0) {
        self.messageLabel.text = [NSString stringWithFormat:@"Couldn't load %@.\n%@",
                                  self.sourceDescription, errorMessage];
        self.retryButton.hidden = NO;
    } else if (self.feed.allItems.count > 0) {
        // Media was found, the filter just excluded all of it — say so, rather
        // than implying the subreddit is empty.
        self.messageLabel.text = [NSString stringWithFormat:
            @"Nothing matches the current filter.\n%lu items are loaded — tap the filter button to widen it.",
            (unsigned long)self.feed.allItems.count];
        self.retryButton.hidden = YES;
    } else {
        self.messageLabel.text = [NSString stringWithFormat:@"No media found in %@ (%@).",
                                  self.sourceDescription, self.feed.sortDisplayName];
        self.retryButton.hidden = YES;
    }
    self.messageLabel.hidden = NO;
    self.retryButton.tintColor = [self apollo_accentColor];
    [self.view setNeedsLayout];
}

- (void)apollo_setFooterText:(NSString *)text {
    self.footerLabel.text = text;
    [UIView animateWithDuration:0.2 animations:^{
        self.footerLabel.alpha = text.length > 0 ? 1.0 : 0.0;
    }];
}

// Transient footer states ("That's everything", "Couldn't load more") fade out
// on their own; the persistent "Loading more…" is cleared by its completion.
- (void)apollo_clearFooterAfterDelay {
    NSString *shown = self.footerLabel.text;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        // Only clear if nothing else has claimed the footer since.
        if (strongSelf && [strongSelf.footerLabel.text isEqualToString:shown]) {
            [strongSelf apollo_setFooterText:nil];
        }
    });
}

- (void)apollo_loadMoreIfNeededForIndex:(NSInteger)index {
    if (self.feed.isLoading || self.feed.isExhausted || self.activeViewer || self.galleryContextMenuActive) return;
    NSInteger total = (NSInteger)self.feed.items.count;
    NSInteger slack = self.waterfallLayout.columnCount * kApolloGalleryLoadAheadRows;
    if (index < total - slack) return;

    // Ordinary look-ahead is silent when the screen is already filled. Show
    // the loading state only when the user has reached uncached listing data.
    CGFloat visibleBottom = MAX(0.0, CGRectGetMaxY(self.collectionView.bounds) -
                                    self.collectionView.adjustedContentInset.bottom);
    if (![self apollo_gridCoversContentY:visibleBottom]) [self apollo_setFooterText:@"Loading more…"];
    __weak typeof(self) weakSelf = self;
    [self.feed loadNextBatchWithCompletion:^(NSRange addedRange, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorMessage.length > 0) {
            [strongSelf apollo_setFooterText:@"Couldn't load more"];
            [strongSelf apollo_clearFooterAfterDelay];
            return;
        }
        if (addedRange.length > 0) {
            [strongSelf apollo_syncAppendedItems];
        }
        // A filter can leave the grid empty with "Nothing matches" showing
        // while this batch pages on; tiles that arrive must not land under it.
        [strongSelf apollo_updateEmptyStateWithError:nil];
        if (strongSelf.feed.isExhausted) {
            [strongSelf apollo_setFooterText:@"That's everything"];
            [strongSelf apollo_clearFooterAfterDelay];
        } else {
            [strongSelf apollo_setFooterText:nil];
        }
        if (addedRange.length > 0) [strongSelf apollo_scheduleViewportFill];
    }];
}

// Appends are derived by diffing the collection view's committed count against
// the feed, never by trusting a callback-supplied range: a filter toggle can
// land between a batch starting and finishing, and inserting a stale range is
// exactly the corruption that NSInternalInconsistencyExceptions are made of.
// The count can only have GROWN here — shrinks happen solely in
// apollo_toggleKind, which reloads wholesale.
- (void)apollo_syncAppendedItems {
    if (self.galleryReloadPendingAfterMenu) return;
    NSInteger known = [self.collectionView numberOfItemsInSection:0];
    NSInteger total = (NSInteger)self.feed.items.count;
    if (total <= known) return;
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:(NSUInteger)(total - known)];
    for (NSInteger i = known; i < total; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
    }
    // The waterfall layout rebuilds every frame in -prepareLayout, so it always
    // agrees with the data source after an append.
    // Publish a useful page immediately, including tiles below a short seed.
    // A staged insertion fade would add another delay after the network.
    [UIView performWithoutAnimation:^{
        [self.collectionView performBatchUpdates:^{
            [self.collectionView insertItemsAtIndexPaths:indexPaths];
        } completion:^(BOOL finished) {
            [self apollo_scheduleViewportFill];
        }];
    }];
    // The open viewer reads the same feed; let it pick the new pages up.
    [self.activeViewer feedDidAppendItems];
}

#pragma mark Collection view

#pragma mark Grid context menus

- (UIContextMenuConfiguration *)apollo_contextMenuForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.pinchingTiles || self.galleryContextMenuActive || indexPath.item >= self.feed.items.count) return nil;
    ApolloGalleryTileCell *cell = (ApolloGalleryTileCell *)[self.collectionView cellForItemAtIndexPath:indexPath];
    ApolloGalleryItem *item = self.feed.items[indexPath.item];
    if (![cell isKindOfClass:ApolloGalleryTileCell.class] || cell.item != item || !cell.window) return nil;

    // The action session owns the item, never an index into a mutable feed.
    // Use the stable grid as the share-popover source: a dismissed menu may
    // trigger a pending reload and recycle its original cell before sharing.
    ApolloGalleryMediaActions *actions = [[ApolloGalleryMediaActions alloc] initWithItem:item
        presenter:self sourceView:self.collectionView];
    UIContextMenuConfiguration *configuration = [UIContextMenuConfiguration
        configurationWithIdentifier:NSUUID.UUID.UUIDString previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            (void)suggestedActions;
            return [actions menu];
        }];
    objc_setAssociatedObject(configuration, &kApolloGalleryContextMenuActions, actions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Actions intentionally snapshot the model. Retain the original identity
    // separately only for locating the still-visible tile's native preview.
    objc_setAssociatedObject(configuration, &kApolloGalleryContextMenuSourceItem, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)collectionView;
    (void)point;
    return [self apollo_contextMenuForItemAtIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths point:(CGPoint)point {
    (void)collectionView;
    (void)point;
    return indexPaths.count == 1 ? [self apollo_contextMenuForItemAtIndexPath:indexPaths.firstObject] : nil;
}

- (UITargetedPreview *)apollo_previewForContextMenu:(UIContextMenuConfiguration *)configuration {
    ApolloGalleryItem *sourceItem = objc_getAssociatedObject(configuration, &kApolloGalleryContextMenuSourceItem);
    if (!sourceItem) return nil;
    for (ApolloGalleryTileCell *cell in self.collectionView.visibleCells) {
        if (![cell isKindOfClass:ApolloGalleryTileCell.class] || cell.item != sourceItem || !cell.window) continue;
        // Preview the real content hierarchy, including its NSFW/spoiler
        // cover and badges. No full-size image provider can bypass the blur.
        UIPreviewParameters *parameters = [UIPreviewParameters new];
        parameters.backgroundColor = cell.contentView.backgroundColor ?: self.view.backgroundColor;
        parameters.visiblePath = [UIBezierPath bezierPathWithRoundedRect:cell.contentView.bounds
            cornerRadius:cell.contentView.layer.cornerRadius];
        return [[UITargetedPreview alloc] initWithView:cell.contentView parameters:parameters];
    }
    return nil;
}

- (UITargetedPreview *)collectionView:(UICollectionView *)collectionView
    previewForHighlightingContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    (void)collectionView;
    return [self apollo_previewForContextMenu:configuration];
}

- (UITargetedPreview *)collectionView:(UICollectionView *)collectionView
    previewForDismissingContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    (void)collectionView;
    return [self apollo_previewForContextMenu:configuration];
}

- (UITargetedPreview *)collectionView:(UICollectionView *)collectionView
    contextMenuConfiguration:(UIContextMenuConfiguration *)configuration highlightPreviewForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    (void)indexPath;
    return [self apollo_previewForContextMenu:configuration];
}

- (UITargetedPreview *)collectionView:(UICollectionView *)collectionView
    contextMenuConfiguration:(UIContextMenuConfiguration *)configuration dismissalPreviewForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    (void)indexPath;
    return [self apollo_previewForContextMenu:configuration];
}

- (void)collectionView:(UICollectionView *)collectionView
    willDisplayContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
    animator:(id<UIContextMenuInteractionAnimating>)animator {
    (void)collectionView;
    (void)animator;
    if (!objc_getAssociatedObject(configuration, &kApolloGalleryContextMenuActions)) return;
    if (!self.activeGalleryContextMenus) self.activeGalleryContextMenus = [NSMutableSet set];
    [self.activeGalleryContextMenus addObject:configuration];
    if (self.galleryContextMenuActive) return;
    self.galleryContextMenuActive = YES;
    [self apollo_finishTilePinchAnimated:NO];
    [self apollo_stopAllTilePlayback];
    self.pinchEnabledBeforeContextMenu = self.tilePinch.enabled;
    self.tilePinch.enabled = NO;
    self.contextMenuNavigationBar = self.navigationController.navigationBar;
    self.navigationBarEnabledBeforeContextMenu = self.contextMenuNavigationBar.userInteractionEnabled;
    self.contextMenuNavigationBar.userInteractionEnabled = NO;
    self.contextMenuPopGesture = self.navigationController.interactivePopGestureRecognizer;
    self.popGestureEnabledBeforeContextMenu = self.contextMenuPopGesture.enabled;
    self.contextMenuPopGesture.enabled = NO;
}

- (void)collectionView:(UICollectionView *)collectionView
    willEndContextMenuInteractionWithConfiguration:(UIContextMenuConfiguration *)configuration
    animator:(id<UIContextMenuInteractionAnimating>)animator {
    (void)collectionView;
    // Keep every gate closed until UIKit has finished moving the preview
    // back into place. An action may then route away or present a share sheet.
    void (^finished)(void) = ^{
        ApolloGalleryMediaActions *actions = objc_getAssociatedObject(configuration, &kApolloGalleryContextMenuActions);
        [self.activeGalleryContextMenus removeObject:configuration];
        if (self.galleryContextMenuActive && self.activeGalleryContextMenus.count == 0) {
            self.galleryContextMenuActive = NO;
            self.tilePinch.enabled = self.pinchEnabledBeforeContextMenu;
            self.contextMenuNavigationBar.userInteractionEnabled = self.navigationBarEnabledBeforeContextMenu;
            self.contextMenuPopGesture.enabled = self.popGestureEnabledBeforeContextMenu;
            self.contextMenuNavigationBar = nil;
            self.contextMenuPopGesture = nil;
            if (self.galleryReloadPendingAfterMenu) {
                self.galleryReloadPendingAfterMenu = NO;
                [self.collectionView reloadData];
            }
            [self apollo_setNeedsTilePlaybackRefresh];
            [self apollo_scheduleViewportFill];
        }
        [actions menuDidEnd];
    };
    if (animator) [animator addCompletion:finished];
    else dispatch_async(dispatch_get_main_queue(), finished);
}

- (void)apollo_reloadGridPreservingContextMenu {
    if (self.galleryContextMenuActive) {
        // Do not recycle a cell while UIKit is showing its live preview.
        // The feed may change immediately; the menu's actions still refer to
        // their captured item and the grid catches up after dismissal.
        self.galleryReloadPendingAfterMenu = YES;
        [self.collectionView.contextMenuInteraction dismissMenu];
        return;
    }
    [self.collectionView reloadData];
}

#pragma mark Collection data source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.feed.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloGalleryTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kApolloGalleryCellID
                                                                           forIndexPath:indexPath];
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (indexPath.item < (NSInteger)items.count) {
        [cell configureWithItem:items[indexPath.item]];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    [self apollo_loadMoreIfNeededForIndex:indexPath.item];
    // Tiles arriving while the grid is at rest (first load, a reload, a
    // rotation) start as soon as this layout pass ends; tiles arriving
    // mid-scroll wait for it to settle.
    if (!collectionView.isDragging && !collectionView.isDecelerating) [self apollo_setNeedsTilePlaybackRefresh];
    (void)cell;
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:[ApolloGalleryTileCell class]]) [(ApolloGalleryTileCell *)cell stopPlayback];
    (void)collectionView;
    (void)indexPath;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    if (self.galleryContextMenuActive) return;
    if (indexPath.item >= (NSInteger)self.feed.items.count) return;

    ApolloGalleryImageViewer *viewer = [[ApolloGalleryImageViewer alloc] initWithFeed:self.feed
                                                                        initialIndex:indexPath.item];
    viewer.galleryDelegate = self;
    self.activeViewer = viewer;
    // OverFullScreen retains this view, so viewWillDisappear does not pause
    // the grid for us. Only the fullscreen page should keep playing.
    [self apollo_stopAllTilePlayback];
    [self presentViewController:viewer animated:YES completion:nil];
}

- (void)collectionView:(UICollectionView *)collectionView prefetchItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    for (NSIndexPath *indexPath in indexPaths) {
        if (indexPath.item >= (NSInteger)items.count) continue;
        ApolloGalleryItem *item = items[indexPath.item];
        // Handles are retained so the matching cancel callback can actually
        // stop the download — fire-and-forget prefetch kept stale transfers
        // alive through fast scrolls.
        ApolloGalleryImageRequest *request =
            [[ApolloGalleryImageLoader sharedLoader] prefetchThumbnailAtURL:(item.thumbnailURL ?: item.imageURL)];
        if (request) self.prefetchRequests[indexPath] = request;
    }
}

- (void)collectionView:(UICollectionView *)collectionView cancelPrefetchingForItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    for (NSIndexPath *indexPath in indexPaths) {
        [self.prefetchRequests[indexPath] cancel];
        [self.prefetchRequests removeObjectForKey:indexPath];
    }
}

#pragma mark ApolloGalleryWaterfallLayoutDelegate

- (CGFloat)galleryLayout:(UICollectionViewLayout *)layout aspectRatioForItemAtIndex:(NSInteger)index {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (index < 0 || index >= (NSInteger)items.count) return kApolloGalleryDefaultAspect;
    return ApolloGalleryGridAspectForPixelSize(items[index].pixelSize);
}

#pragma mark ApolloGalleryImageViewerDelegate

- (void)galleryViewer:(ApolloGalleryImageViewer *)viewer didAppendItemsInRange:(NSRange)addedRange {
    // The viewer paged past the end and pulled the batch itself; mirror it into
    // the grid so the two stay in step. Its final callback can arrive after
    // dismissal, while a new grid menu is deferring a wholesale reload.
    [self apollo_syncAppendedItems];
    (void)viewer;
    (void)addedRange;
}

- (void)galleryViewerDidDismiss:(ApolloGalleryImageViewer *)viewer {
    if (self.activeViewer != viewer) return;
    self.activeViewer = nil;
    // A menu's Open Post may already have navigated away in the completion.
    if (self.navigationController.topViewController != self) return;
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    }
    [self apollo_refreshTilePlayback];
    [self apollo_scheduleViewportFill];
}

- (void)galleryViewer:(ApolloGalleryImageViewer *)viewer willDismissAtIndex:(NSInteger)index {
    // Land back on whatever the user was last looking at, Photos-style.
    if (index < 0 || index >= [self.collectionView numberOfItemsInSection:0]) return;
    [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]
                                atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                        animated:NO];
}

@end

#if APOLLO_SIM_BUILD
// simctl has no rotate command, so orientation bugs can't be exercised from
// the CLI without help. `xcrun simctl spawn <dev> notifyutil -p
// apollofix.rotate` toggles the foreground scene between portrait and
// landscape. Sim builds only; device builds never compile this.
static void ApolloGalleryDebugRotate(CFNotificationCenterRef center, void *observer,
                                     CFNotificationName name, const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
                if ([candidate isKindOfClass:[UIWindowScene class]] &&
                    candidate.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)candidate;
                    break;
                }
            }
            if (!scene) return;
            BOOL portrait = UIInterfaceOrientationIsPortrait(scene.interfaceOrientation);
            UIWindowSceneGeometryPreferencesIOS *preferences =
                [[UIWindowSceneGeometryPreferencesIOS alloc]
                    initWithInterfaceOrientations:(portrait ? UIInterfaceOrientationMaskLandscapeRight
                                                            : UIInterfaceOrientationMaskPortrait)];
            [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                ApolloLogError(@"[GalleryDebug] rotate failed: %@", error);
            }];
            ApolloLog(@"[GalleryDebug] rotate -> %@", portrait ? @"landscape" : @"portrait");
        }
    });
}

__attribute__((constructor))
static void ApolloGalleryDebugRotateInstall(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    ApolloGalleryDebugRotate,
                                    CFSTR("apollofix.rotate"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
#endif
