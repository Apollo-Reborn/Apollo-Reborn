#import "ApolloPalHomeScene.h"
#import <UIKit/UIKit.h>
#import "ApolloPixelPalCoats.h"
#import "ApolloPalHomeChrome.h"
#import "ApolloPalHomeHaptics.h"
#import "ApolloPalHomeShelter.h"
#import "ApolloPalHomeShelterView.h"
#import "ApolloPalSpecies.h"
#import "ApolloRebornPalSprites.h"
#import "ApolloPalHomeChiptune.h"
#if __has_include("ApolloCommon.h")
#import "ApolloCommon.h"
#define APDebugLog(...) ApolloLog(__VA_ARGS__)
#else
#define APDebugLog(...) do {} while (0)
#endif

static SKTexture *APTexture(APCanvas *c) {
    CGImageRef image = APCanvasCreateCGImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    texture.filteringMode = SKTextureFilteringNearest;
    return texture;
}

static SKSpriteNode *APSprite(APCanvas *c) {
    SKSpriteNode *node = [SKSpriteNode spriteNodeWithTexture:APTexture(c)];
    node.anchorPoint = CGPointZero;
    return node;
}

static UIColor *APUIColor(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

// Moves a node while snapping to whole art pixels every frame, so moving
// things stay on the pixel grid like the rest of the room.
static SKAction *APPixelMove(CGPoint from, CGPoint to, NSTimeInterval duration) {
    return [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        CGFloat t = duration > 0 ? MIN(1, elapsed / duration) : 1;
        node.position = CGPointMake(round(from.x + (to.x - from.x) * t), round(from.y + (to.y - from.y) * t));
    }];
}

typedef NS_ENUM(NSInteger, APPalMode) { APPalIdle, APPalWalking, APPalSleeping, APPalPlaying, APPalPerched };

@interface ApolloPalHomeScene ()
@property (nonatomic, copy, readwrite) NSDictionary *roomDocument;
@property (nonatomic, copy, nullable) NSDictionary *previewSaved; // the real room while previewing
@property (nonatomic, strong, readwrite) APRoomLayout *layout;
@property (nonatomic, copy) NSArray<ApolloPalHomeResident *> *residents;
@property (nonatomic, readwrite) BOOL hasPalArtwork;
@property (nonatomic) BOOL reducedMotion;
@property (nonatomic) CGFloat topReserve, bottomReserve;

@property (nonatomic, strong) SKSpriteNode *backdrop;
@property (nonatomic, strong) SKNode *roomNode;
@property (nonatomic, strong) SKSpriteNode *sign;
@property (nonatomic, copy, readwrite, nullable) NSString *signTitle;
@property (nonatomic, strong) SKSpriteNode *grid;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SKNode *> *itemNodes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<SKTexture *> *> *clips;
@property (nonatomic) int renderedMinute;

// Pal.
@property (nonatomic, strong, nullable) SKSpriteNode *pal;
@property (nonatomic) int palX, palY;
@property (nonatomic) APPalMode palMode;
@property (nonatomic, copy, nullable) void (^movingInDone)(void);
@property (nonatomic, strong, nullable) SKNode *movingInSign;
@property (nonatomic, copy, nullable) NSString *palBedUID;
@property (nonatomic, copy, nullable) NSString *heistUID; // the goose is carrying this item
@property (nonatomic, copy, readwrite, nullable) NSString *toy;  // "ball" / "wand" while a game is on
@property (nonatomic) NSInteger toyScore;
@property (nonatomic) BOOL ballFlying;
@property (nonatomic) CGPoint wandTile;
@property (nonatomic) CFTimeInterval lastPounce;
@property (nonatomic, copy, nullable) void (^playStep)(void);

// Editing.
@property (nonatomic, strong, readwrite, nullable) APPlacedItem *selectedItem;
@property (nonatomic) BOOL dragging, dragMoved;
@property (nonatomic) CGPoint dragGrab; // tiles between touch and item origin
@property (nonatomic) int dragX, dragY;
@end

@implementation ApolloPalHomeScene

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeFill;
        self.anchorPoint = CGPointZero;
        self.backgroundColor = APUIColor(0x1C1310);
        _itemNodes = [NSMutableDictionary dictionary];
        _clips = [NSMutableDictionary dictionary];
        _roomNode = [SKNode node];
        [self addChild:_roomNode];
        _palX = 3; _palY = 4;
        _renderedMinute = -1;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(memoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)memoryWarning:(NSNotification *)note {
    // Sprite clips rebuild on demand; drop everything we can.
    [self.clips removeAllObjects];
}

#pragma mark - Configuration

static int APCurrentMinute(void) {
    NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:NSDate.date];
    return (int)(parts.hour * 60 + parts.minute);
}

- (void)configureWithRoom:(NSDictionary *)room residents:(NSArray<ApolloPalHomeResident *> *)residents {
    self.residents = residents;
    self.roomDocument = room;
    [self rebuildRoomKeepingPal:NO];
}

// New stats for the same Pal (a meal, a game): just the sign, so whatever
// the Pal is doing carries on.
- (void)refreshResidents:(NSArray<ApolloPalHomeResident *> *)residents {
    if (![residents.firstObject.identifier isEqual:self.resident.identifier]) {
        [self configureWithRoom:self.roomDocument residents:residents];
        return;
    }
    self.residents = residents;
    [self updateSign];
    [self relayout:NO];
}

- (void)setMotionReduced:(BOOL)reduced {
    if (_reducedMotion == reduced) return;
    _reducedMotion = reduced;
    if (self.roomDocument) [self rebuildRoomKeepingPal:YES];
}

- (void)didChangeSize:(CGSize)oldSize {
    [super didChangeSize:oldSize];
    [self relayout:NO];
}

- (void)setTopReserve:(CGFloat)top bottomReserve:(CGFloat)bottom animated:(BOOL)animated {
    self.topReserve = top;
    self.bottomReserve = bottom;
    [self relayout:animated];
}

- (CGRect)roomFrame {
    return CGRectMake(self.roomNode.position.x, self.roomNode.position.y, APShellWidth, APShellHeight);
}

- (CGRect)postcardFrame {
    CGRect frame = self.roomFrame;
    if (self.sign && self.sign.alpha > 0) frame = CGRectUnion(frame, CGRectMake(self.sign.position.x, self.sign.position.y, self.sign.size.width, self.sign.size.height));
    return CGRectIntegral(CGRectInset(frame, -6, -6));
}

- (void)relayout:(BOOL)animated {
    CGSize size = self.size;
    if (size.width < 1 || size.height < 1) return;
    // The void around the room: regenerate to fill the scene exactly.
    [self.backdrop removeFromParent];
    APCanvas *back = APBackdropCanvas((int)ceil(size.width), (int)ceil(size.height), self.layout.style);
    self.backdrop = APSprite(back);
    APCanvasFree(back);
    self.backdrop.zPosition = -100;
    [self addChild:self.backdrop];
    [self animateBackdrop];

    CGFloat signH = self.sign && !self.editing ? self.sign.size.height - 4 : 0;
    CGFloat avail = size.height - self.topReserve - self.bottomReserve - signH;
    CGFloat x = floor((size.width - APShellWidth) / 2);
    CGFloat y = avail >= APShellHeight ? floor(self.bottomReserve + (avail - APShellHeight) / 2)
                                       : floor(size.height - self.topReserve - signH - APShellHeight);
    CGPoint target = CGPointMake(x, y);
    [self.roomNode removeActionForKey:@"slide"];
    if (animated && !self.reducedMotion) {
        [self.roomNode runAction:[SKAction sequence:@[APPixelMove(self.roomNode.position, target, 0.28)]] withKey:@"slide"];
    } else {
        self.roomNode.position = target;
    }
    [self positionSign:target animated:animated];
}

// The world outside the room comes alive per style: twinkling stars,
// rising bubbles, fireflies or drifting dust.
- (void)animateBackdrop {
    APBackdropAnim kind = self.layout.style.backdropAnim;
    if (kind == APBackdropAnimNone || self.reducedMotion) return;
    CGSize size = self.size;
    SKSpriteNode *backdrop = self.backdrop;
    __weak SKSpriteNode *weakBackdrop = backdrop;
    if (kind == APBackdropAnimStars) {
        for (int i = 0; i < 18; i++) {
            SKSpriteNode *star = [SKSpriteNode spriteNodeWithColor:APUIColor(0xFFF4D8) size:CGSizeMake(1, 1)];
            star.anchorPoint = CGPointZero;
            star.position = CGPointMake(arc4random_uniform((uint32_t)size.width), arc4random_uniform((uint32_t)size.height));
            star.alpha = 0;
            [backdrop addChild:star];
            NSTimeInterval period = 2 + arc4random_uniform(300) / 100.0;
            [star runAction:[SKAction sequence:@[[SKAction waitForDuration:arc4random_uniform(400) / 100.0],
                [SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:1 duration:period / 2], [SKAction fadeAlphaTo:0 duration:period / 2]]]]]]];
        }
        SKAction *shoot = [SKAction runBlock:^{
            SKSpriteNode *parent = weakBackdrop;
            if (!parent) return;
            SKSpriteNode *streak = [SKSpriteNode spriteNodeWithColor:APUIColor(0xFFFFFF) size:CGSizeMake(3, 1)];
            streak.anchorPoint = CGPointZero;
            CGPoint from = CGPointMake(size.width * (0.5 + arc4random_uniform(50) / 100.0), size.height - arc4random_uniform((uint32_t)(size.height / 4)));
            CGPoint to = CGPointMake(from.x - 50, from.y - 22);
            streak.position = from;
            [parent addChild:streak];
            [streak runAction:[SKAction sequence:@[[SKAction group:@[APPixelMove(from, to, 0.6), [SKAction fadeOutWithDuration:0.6]]], [SKAction removeFromParent]]]];
        }];
        [backdrop runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:9 withRange:10], shoot]]]];
    } else if (kind == APBackdropAnimBubbles || kind == APBackdropAnimDust) {
        BOOL bubbles = kind == APBackdropAnimBubbles;
        SKAction *spawn = [SKAction runBlock:^{
            SKSpriteNode *parent = weakBackdrop;
            if (!parent) return;
            SKSpriteNode *mote;
            if (bubbles && arc4random_uniform(3) == 0) {
                APCanvas *ring = APCanvasCreate(3, 3);
                APPx(ring, 1, 0, 0xA8E0F0); APPx(ring, 0, 1, 0xA8E0F0); APPx(ring, 2, 1, 0x7AC0D8); APPx(ring, 1, 2, 0x7AC0D8);
                mote = APSprite(ring);
                APCanvasFree(ring);
            } else {
                mote = [SKSpriteNode spriteNodeWithColor:APUIColor(bubbles ? 0xA8E0F0 : 0xE8C890) size:CGSizeMake(1, 1)];
                mote.anchorPoint = CGPointZero;
            }
            mote.alpha = bubbles ? 0.8 : 0.45;
            CGFloat x = arc4random_uniform((uint32_t)size.width);
            CGPoint from = CGPointMake(x, bubbles ? -3 : arc4random_uniform((uint32_t)size.height));
            NSTimeInterval d = bubbles ? 6 + arc4random_uniform(400) / 100.0 : 9 + arc4random_uniform(600) / 100.0;
            CGFloat rise = bubbles ? size.height + 6 : 30;
            mote.position = from;
            [parent addChild:mote];
            SKAction *drift = [SKAction customActionWithDuration:d actionBlock:^(SKNode *node, CGFloat t) {
                CGFloat f = t / d;
                node.position = CGPointMake(round(from.x + sin(t * (bubbles ? 1.6 : 0.6) + x) * 2), round(from.y + rise * f));
            }];
            NSArray *fade = bubbles ? @[] : @[[SKAction sequence:@[[SKAction waitForDuration:d * 0.7], [SKAction fadeOutWithDuration:d * 0.3]]]];
            [mote runAction:[SKAction sequence:@[[SKAction group:[@[drift] arrayByAddingObjectsFromArray:fade]], [SKAction removeFromParent]]]];
        }];
        [backdrop runAction:[SKAction repeatActionForever:[SKAction sequence:@[spawn, [SKAction waitForDuration:bubbles ? 0.35 : 0.6]]]]];
    } else if (kind == APBackdropAnimFireflies) {
        for (int i = 0; i < 14; i++) [self addFireflyTo:backdrop inRect:CGRectMake(0, 0, size.width, size.height) color:0xE8F06A];
    } else if (kind == APBackdropAnimBats) {
        // A few faint stars, and every so often a bat flaps past the moon.
        for (int i = 0; i < 10; i++) {
            SKSpriteNode *star = [SKSpriteNode spriteNodeWithColor:APUIColor(0xD8C8F0) size:CGSizeMake(1, 1)];
            star.anchorPoint = CGPointZero;
            star.position = CGPointMake(arc4random_uniform((uint32_t)size.width), size.height / 2 + arc4random_uniform((uint32_t)(size.height / 2)));
            star.alpha = 0.2;
            [backdrop addChild:star];
            NSTimeInterval period = 3 + arc4random_uniform(300) / 100.0;
            [star runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:0.8 duration:period / 2], [SKAction fadeAlphaTo:0.2 duration:period / 2]]]]];
        }
        NSMutableArray<SKTexture *> *wings = [NSMutableArray array];
        for (int frame = 0; frame < 2; frame++) {
            APCanvas *bat = APCanvasCreate(7, 4);
            uint32_t ink = 0x0C0612;
            APRect(bat, 3, 1, 1, 2, ink); APPx(bat, 2, 1, ink); APPx(bat, 4, 1, ink);
            if (frame == 0) { APPx(bat, 1, 0, ink); APPx(bat, 0, 0, ink); APPx(bat, 5, 0, ink); APPx(bat, 6, 0, ink); }
            else { APPx(bat, 1, 2, ink); APPx(bat, 0, 3, ink); APPx(bat, 5, 2, ink); APPx(bat, 6, 3, ink); }
            SKSpriteNode *sprite = APSprite(bat);
            APCanvasFree(bat);
            [wings addObject:sprite.texture];
        }
        SKAction *flap = [SKAction runBlock:^{
            SKSpriteNode *parent = weakBackdrop;
            if (!parent) return;
            SKSpriteNode *bat = [SKSpriteNode spriteNodeWithTexture:wings[0]];
            bat.anchorPoint = CGPointZero;
            BOOL leftward = arc4random_uniform(2);
            CGFloat y0 = size.height * (0.55 + arc4random_uniform(35) / 100.0), x0 = leftward ? size.width + 8 : -8, x1 = leftward ? -8 : size.width + 8;
            NSTimeInterval d = 4 + arc4random_uniform(300) / 100.0;
            bat.position = CGPointMake(x0, y0);
            [parent addChild:bat];
            [bat runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:wings timePerFrame:0.12]]];
            SKAction *fly = [SKAction customActionWithDuration:d actionBlock:^(SKNode *node, CGFloat t) {
                CGFloat f = t / d;
                node.position = CGPointMake(round(x0 + (x1 - x0) * f), round(y0 + sin(t * 5) * 2 + sin(t * 1.3) * 4));
            }];
            [bat runAction:[SKAction sequence:@[fly, [SKAction removeFromParent]]]];
        }];
        [backdrop runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:6 withRange:8], flap]]]];
    }
}

- (void)addFireflyTo:(SKNode *)parent inRect:(CGRect)rect color:(uint32_t)color {
    SKSpriteNode *fly = [SKSpriteNode spriteNodeWithColor:APUIColor(color) size:CGSizeMake(1, 1)];
    fly.anchorPoint = CGPointZero;
    fly.alpha = 0;
    CGFloat ox = rect.origin.x + arc4random_uniform((uint32_t)MAX(rect.size.width, 1));
    CGFloat oy = rect.origin.y + arc4random_uniform((uint32_t)MAX(rect.size.height, 1));
    fly.position = CGPointMake(ox, oy);
    [parent addChild:fly];
    CGFloat phase = arc4random_uniform(628) / 100.0, rx = MIN(6, rect.size.width / 2), ry = MIN(4, rect.size.height / 2);
    CGFloat cx = MIN(MAX(ox, rect.origin.x + rx), CGRectGetMaxX(rect) - rx), cy = MIN(MAX(oy, rect.origin.y + ry), CGRectGetMaxY(rect) - ry);
    SKAction *wander = [SKAction customActionWithDuration:12 actionBlock:^(SKNode *node, CGFloat t) {
        node.position = CGPointMake(round(cx + sin(t * 0.52 + phase) * rx), round(cy + sin(t * 0.79 + phase * 2) * ry));
    }];
    NSTimeInterval pulse = 1.4 + arc4random_uniform(160) / 100.0;
    [fly runAction:[SKAction repeatActionForever:wander]];
    [fly runAction:[SKAction sequence:@[[SKAction waitForDuration:arc4random_uniform(200) / 100.0],
        [SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:1 duration:pulse / 2], [SKAction fadeAlphaTo:0.1 duration:pulse / 2]]]]]]];
}

- (void)positionSign:(CGPoint)roomOrigin animated:(BOOL)animated {
    if (!self.sign) return;
    CGPoint target = CGPointMake(floor(roomOrigin.x + (APShellWidth - self.sign.size.width) / 2), roomOrigin.y + APShellHeight - 3);
    [self.sign removeActionForKey:@"slide"];
    if (animated && !self.reducedMotion) [self.sign runAction:APPixelMove(self.sign.position, target, 0.28) withKey:@"slide"];
    else self.sign.position = target;
    [self.sign runAction:[SKAction fadeAlphaTo:self.editing ? 0 : 1 duration:animated ? 0.2 : 0]];
}

- (void)updateSign {
    [self.sign removeFromParent];
    self.sign = nil;
    ApolloPalHomeResident *pal = self.residents.firstObject;
    if (!pal) return;
    NSString *title = [NSString stringWithFormat:@"%@’s Home", pal.name];
    if (APTextWidth(title.uppercaseString, APFontLarge) > APShellWidth - 24) title = pal.name;
    if (APTextWidth(title.uppercaseString, APFontLarge) > APShellWidth - 24) title = @"Home Sweet Home";
    self.signTitle = title;
    double hearts = pal.hearts ? pal.hearts.doubleValue : -1;
    APCanvas *plaque = APChromeSign(APChromeThemeForStyle(self.layout.style.identifier), title, hearts, 6);
    self.sign = APSprite(plaque);
    APCanvasFree(plaque);
    self.sign.zPosition = 500;
    [self addChild:self.sign];
}

#pragma mark - Building the room

- (CGPoint)nodePointForShellX:(CGFloat)x y:(CGFloat)y height:(CGFloat)h {
    return CGPointMake(x, APShellHeight - y - h);
}

- (void)rebuildRoomKeepingPal:(BOOL)keepPal {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSString *selectedUID = self.selectedItem.uid;
    [self.roomNode removeAllChildren];
    [self.itemNodes removeAllObjects];
    self.layout = [APRoomLayout layoutWithRoom:self.roomDocument ?: [APCatalog starterRoom]];
    self.renderedMinute = APCurrentMinute();
    [self.layout renderAtMinute:self.renderedMinute];

    SKSpriteNode *shell = APSprite(self.layout.litShell.canvas);
    shell.zPosition = 0;
    [self.roomNode addChild:shell];
    // Light blooms are additive and clipped to the room so they never spill
    // speckles onto the dark surroundings.
    SKCropNode *glows = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:UIColor.whiteColor size:CGSizeMake(APShellWidth - 2 * APSideWall, APShellHeight - APFrontLip)];
    mask.anchorPoint = CGPointZero;
    mask.position = CGPointMake(APSideWall, APFrontLip);
    glows.maskNode = mask;
    glows.zPosition = 900;
    glows.name = @"glows";
    [self.roomNode addChild:glows];
    for (APPlacedItem *item in self.layout.items) [self buildNodeForItem:item];

    APCanvas *gridCanvas = [self gridCanvas];
    self.grid = APSprite(gridCanvas);
    APCanvasFree(gridCanvas);
    self.grid.zPosition = 45;
    self.grid.alpha = self.editing ? 1 : 0;
    [self.roomNode addChild:self.grid];

    [self updateSign];
    [self relayout:NO];
    [self buildPalKeepingPosition:keepPal];
    [self removeActionForKey:@"clock"];
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:15],
        [SKAction runBlock:^{ [weakSelf minuteTick]; }]]]] withKey:@"clock"];
    self.selectedItem = selectedUID ? [self.layout itemWithUID:selectedUID] : nil;
    [self showSelection];
    [self scheduleSpooks];
    APDebugLog(@"[PalHome] room rebuilt in %.1fms (%lu items)", (CFAbsoluteTimeGetCurrent() - started) * 1000, (unsigned long)self.layout.items.count);
}

- (void)minuteTick {
    int minute = APCurrentMinute();
    if (minute == self.renderedMinute) return;
    if (self.dragging) return; // never rebuild under a finger; try next tick
    // A new hour changes the sky and daylight; otherwise only clocks move.
    if (minute / 60 != self.renderedMinute / 60) { [self rebuildRoomKeepingPal:YES]; return; }
    self.renderedMinute = minute;
    for (APPlacedItem *item in self.layout.items) {
        BOOL clock = NO;
        for (APAnim *anim in item.art.anims) clock = clock || anim.kind == APAnimClockHands;
        if (!clock) continue;
        item.art = APRenderItem(item.spec, item.variant, item.on, minute);
        APCanvas *lit = APCanvasCreate(item.spec.pixelWidth, item.spec.pixelHeight);
        APDraw(lit, item.art.base, 0, 0, item.flip);
        for (int y = 0; y < lit->h; y++) for (int x = 0; x < lit->w; x++) {
            uint32_t p = lit->px[y * lit->w + x];
            if (!(p >> 24)) continue;
            float r, g, b;
            [self.layout lightAtX:item.px + x y:item.py + y r:&r g:&g b:&b];
            lit->px[y * lit->w + x] = (p & 0xFF000000u) | APMultiply(p, r, g, b);
        }
        SKSpriteNode *base = (SKSpriteNode *)[self.itemNodes[item.uid] childNodeWithName:@"base"];
        base.texture = APTexture(lit);
        APCanvasFree(lit);
    }
}

- (APCanvas *)gridCanvas {
    APCanvas *c = APCanvasCreate(APShellWidth, APShellHeight);
    for (int row = 0; row <= APRows; row++) for (int x = APSideWall; x < APShellWidth - APSideWall; x += 2) {
        APBlendPx(c, x, APFloorTop + row * APTile - (row == APRows), 0xFFF4D8, 0.35f);
    }
    for (int col = 0; col <= APCols; col++) for (int y = APFloorTop; y < APFloorTop + APRows * APTile; y += 2) {
        APBlendPx(c, APSideWall + col * APTile - (col == APCols), y, 0xFFF4D8, 0.35f);
    }
    int wallTop = APCeiling + APCrown;
    for (int row = 0; row <= APWallRows; row++) for (int x = APSideWall; x < APShellWidth - APSideWall; x += 3) {
        APBlendPx(c, x, wallTop + row * APTile, 0xFFF4D8, 0.22f);
    }
    for (int col = 0; col <= APCols; col++) for (int y = wallTop; y < wallTop + APWallRows * APTile; y += 3) {
        APBlendPx(c, APSideWall + col * APTile - (col == APCols), y, 0xFFF4D8, 0.22f);
    }
    return c;
}

- (void)buildNodeForItem:(APPlacedItem *)item {
    int H = item.spec.pixelHeight;
    SKNode *container = [SKNode node];
    container.name = item.uid;
    container.position = [self nodePointForShellX:item.px y:item.py height:H];
    container.zPosition = item.z;
    [self.roomNode addChild:container];
    self.itemNodes[item.uid] = container;

    SKSpriteNode *base = APSprite(item.lit.canvas);
    base.name = @"base";
    [container addChild:base];
    // Most items have no emissive or front layer; skip empty sprites entirely
    // (fewer textures to upload, fewer nodes to draw every frame).
    SKSpriteNode *glowing = nil;
    if (!APCanvasIsEmpty(item.glowing.canvas)) {
        glowing = APSprite(item.glowing.canvas);
        glowing.name = @"glowing";
        glowing.zPosition = 0.01;
        [container addChild:glowing];
    }
    if (!APCanvasIsEmpty(item.litFront.canvas)) {
        SKSpriteNode *front = APSprite(item.litFront.canvas);
        front.name = @"front";
        front.zPosition = 0.03;
        [container addChild:front];
    }

    for (APAnim *anim in item.art.anims) [self attachAnim:anim toItem:item container:container glowingSprite:glowing];
}

// Item-local rect (top-left origin) → container coordinates, honouring flip.
- (CGPoint)localPointForItem:(APPlacedItem *)item x:(int)x y:(int)y w:(int)w h:(int)h {
    int W = item.spec.pixelWidth, H = item.spec.pixelHeight;
    int lx = item.flip ? W - x - w : x;
    return CGPointMake(lx, H - y - h);
}

- (void)attachAnim:(APAnim *)anim toItem:(APPlacedItem *)item container:(SKNode *)container glowingSprite:(nullable SKSpriteNode *)glowing {
    BOOL still = self.reducedMotion;
    switch (anim.kind) {
        case APAnimFire: {
            BOOL hearth = anim.w > 10;
            NSArray<APCanvasBox *> *frames = APFireFrames(anim.w, anim.h, still ? 1 : 12, hearth ? 1 : 0, 7);
            NSMutableArray *textures = [NSMutableArray array];
            for (APCanvasBox *frame in frames) [textures addObject:APTexture(frame.canvas)];
            SKSpriteNode *fire = [SKSpriteNode spriteNodeWithTexture:textures.firstObject];
            fire.anchorPoint = CGPointZero;
            fire.position = [self localPointForItem:item x:anim.x y:anim.y w:anim.w h:anim.h];
            fire.zPosition = 0.02;
            if (item.flip) { fire.xScale = -1; fire.position = CGPointMake(fire.position.x + anim.w, fire.position.y); }
            [container addChild:fire];
            if (!still) [fire runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:textures timePerFrame:0.085]]];
            break;
        }
        case APAnimEmbers: {
            if (still) break;
            CGPoint origin = [self localPointForItem:item x:anim.x y:anim.y w:anim.w h:1];
            __weak SKNode *weakContainer = container;
            SKAction *spawn = [SKAction runBlock:^{
                SKNode *parent = weakContainer;
                if (!parent) return;
                SKSpriteNode *ember = [SKSpriteNode spriteNodeWithColor:APUIColor(arc4random_uniform(2) ? 0xFFB040 : 0xFF7A2A) size:CGSizeMake(1, 1)];
                ember.anchorPoint = CGPointZero;
                CGPoint from = CGPointMake(origin.x + arc4random_uniform((uint32_t)MAX(anim.w, 1)), origin.y);
                CGPoint to = CGPointMake(from.x + (int)arc4random_uniform(7) - 3, from.y + 8 + arc4random_uniform(10));
                ember.position = from;
                ember.zPosition = 0.025;
                [parent addChild:ember];
                NSTimeInterval d = 0.9 + arc4random_uniform(60) / 100.0;
                [ember runAction:[SKAction sequence:@[[SKAction group:@[APPixelMove(from, to, d), [SKAction fadeOutWithDuration:d]]],
                                                      [SKAction removeFromParent]]]];
            }];
            [container runAction:[SKAction repeatActionForever:[SKAction sequence:@[spawn, [SKAction waitForDuration:0.45 withRange:0.5]]]]];
            break;
        }
        case APAnimCandle: {
            if (still) break;
            // Flicker: the flame tip hops between a tall, short and leaning pose.
            SKSpriteNode *tip = [SKSpriteNode spriteNodeWithColor:APUIColor(0xFFFBE0) size:CGSizeMake(1, 1)];
            tip.anchorPoint = CGPointZero;
            CGPoint p = [self localPointForItem:item x:anim.x y:anim.y w:1 h:1];
            tip.position = p;
            tip.zPosition = 0.02;
            [container addChild:tip];
            NSMutableArray *steps = [NSMutableArray array];
            for (int i = 0; i < 10; i++) {
                int dx = (int)arc4random_uniform(3) == 0 ? (arc4random_uniform(2) ? 1 : -1) : 0;
                int dy = arc4random_uniform(3) == 0 ? -1 : 0;
                [steps addObject:[SKAction moveTo:CGPointMake(p.x + dx, p.y + dy) duration:0]];
                [steps addObject:[SKAction fadeAlphaTo:0.6 + arc4random_uniform(40) / 100.0 duration:0]];
                [steps addObject:[SKAction waitForDuration:0.08 + arc4random_uniform(18) / 100.0]];
            }
            [tip runAction:[SKAction repeatActionForever:[SKAction sequence:steps]]];
            break;
        }
        case APAnimTwinkle: {
            if (still) break;
            APCanvas *halo = APCanvasCreate(3, 4);
            APBlendPx(halo, 1, 0, anim.color, 0.9f); APBlendPx(halo, 0, 1, anim.color, 0.5f);
            APBlendPx(halo, 2, 1, anim.color, 0.5f); APBlendPx(halo, 1, 1, 0xFFFFFF, 1);
            APBlendPx(halo, 1, 2, anim.color, 0.9f); APBlendPx(halo, 1, 3, anim.color, 0.4f);
            SKSpriteNode *spark = APSprite(halo);
            APCanvasFree(halo);
            CGPoint p = [self localPointForItem:item x:anim.x - 1 y:anim.y - 1 w:3 h:4];
            spark.position = p;
            spark.zPosition = 0.02;
            spark.blendMode = SKBlendModeAdd;
            spark.alpha = 0;
            [container addChild:spark];
            NSTimeInterval period = 1.2 + arc4random_uniform(200) / 100.0;
            [spark runAction:[SKAction sequence:@[[SKAction waitForDuration:arc4random_uniform(300) / 100.0],
                [SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:0.9 duration:period / 2],
                                                                    [SKAction fadeAlphaTo:0.1 duration:period / 2]]]]]]];
            break;
        }
        case APAnimSteam: {
            if (still) break;
            CGPoint origin = [self localPointForItem:item x:anim.x y:anim.y w:1 h:1];
            __weak SKNode *weakContainer = container;
            SKAction *spawn = [SKAction runBlock:^{
                SKNode *parent = weakContainer;
                if (!parent) return;
                SKSpriteNode *wisp = [SKSpriteNode spriteNodeWithColor:APUIColor(0xF4F0E8) size:CGSizeMake(1, 1)];
                wisp.anchorPoint = CGPointZero;
                wisp.alpha = 0.55;
                wisp.position = origin;
                wisp.zPosition = 0.04;
                [parent addChild:wisp];
                SKAction *rise = [SKAction customActionWithDuration:1.6 actionBlock:^(SKNode *node, CGFloat t) {
                    node.position = CGPointMake(origin.x + round(sin(t * 5) * 1.0), origin.y + round(t * 4));
                }];
                [wisp runAction:[SKAction sequence:@[[SKAction group:@[rise, [SKAction fadeOutWithDuration:1.6]]], [SKAction removeFromParent]]]];
            }];
            [container runAction:[SKAction repeatActionForever:[SKAction sequence:@[spawn, [SKAction waitForDuration:0.5]]]]];
            break;
        }
        case APAnimWindow: [self attachWeather:anim item:item container:container]; break;
        case APAnimPendulum: {
            int len = anim.size;
            NSMutableArray *textures = [NSMutableArray array];
            float angles[] = {-0.32f, -0.2f, 0, 0.2f, 0.32f, 0.2f, 0, -0.2f};
            for (int i = 0; i < 8; i++) {
                APCanvas *c = APCanvasCreate(len * 2 + 3, len + 3);
                int bx = len + 1 + (int)lroundf(sinf(angles[i]) * len), by = (int)lroundf(cosf(angles[i]) * len);
                APLine(c, len + 1, 0, bx, by, 0x8A6418);
                APCircle(c, bx, by, 1, anim.color);
                APPx(c, bx - 1, by - 1, 0xFCE69A);
                [textures addObject:APTexture(c)];
                APCanvasFree(c);
            }
            SKSpriteNode *pendulum = [SKSpriteNode spriteNodeWithTexture:textures[2]];
            pendulum.anchorPoint = CGPointZero;
            pendulum.position = [self localPointForItem:item x:anim.x - len - 1 y:anim.y w:len * 2 + 3 h:len + 3];
            pendulum.zPosition = -0.01;
            [container addChild:pendulum];
            if (!still) [pendulum runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:textures timePerFrame:0.16]]];
            break;
        }
        case APAnimNeon: {
            if (still) break;
            SKAction *buzz = [SKAction sequence:@[[SKAction waitForDuration:5 withRange:6],
                [SKAction fadeAlphaTo:0.25 duration:0], [SKAction waitForDuration:0.06], [SKAction fadeAlphaTo:1 duration:0],
                [SKAction waitForDuration:0.1], [SKAction fadeAlphaTo:0.4 duration:0], [SKAction waitForDuration:0.05],
                [SKAction fadeAlphaTo:1 duration:0]]];
            [glowing runAction:[SKAction repeatActionForever:buzz]];
            break;
        }
        case APAnimNotes: {
            if (still) break;
            CGPoint origin = [self localPointForItem:item x:anim.x y:anim.y w:1 h:1];
            __weak SKNode *weakContainer = container;
            __block int n = 0;
            SKAction *spawn = [SKAction runBlock:^{
                SKNode *parent = weakContainer;
                if (!parent) return;
                APCanvas *glyph = APIconCanvas(@"note");
                uint32_t tints[] = {0xF4E8D0, 0xF0A8B8, 0xA8D0F0, 0xF8D870};
                APTint(glyph, tints[n++ % 4]);
                SKSpriteNode *note = APSprite(glyph);
                APCanvasFree(glyph);
                note.position = origin;
                note.zPosition = 0.05;
                [parent addChild:note];
                CGPoint to = CGPointMake(origin.x + (n % 2 ? 5 : -4), origin.y + 13);
                [note runAction:[SKAction sequence:@[[SKAction group:@[APPixelMove(origin, to, 2.2),
                    [SKAction sequence:@[[SKAction waitForDuration:1.2], [SKAction fadeOutWithDuration:1.0]]]]], [SKAction removeFromParent]]]];
            }];
            [container runAction:[SKAction repeatActionForever:[SKAction sequence:@[spawn, [SKAction waitForDuration:1.1]]]]];
            break;
        }
        case APAnimGlow: {
            // Blooms repeat a lot (every lamp, candle shelf…): share textures.
            static NSCache<NSString *, SKTexture *> *blooms;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ blooms = [NSCache new]; });
            NSString *bloomKey = [NSString stringWithFormat:@"%d:%06x", anim.size, anim.color];
            SKTexture *bloomTexture = [blooms objectForKey:bloomKey];
            if (!bloomTexture) {
                APCanvas *glowCanvas = APGlowCanvas(anim.size, anim.color);
                bloomTexture = APTexture(glowCanvas);
                APCanvasFree(glowCanvas);
                [blooms setObject:bloomTexture forKey:bloomKey];
            }
            SKSpriteNode *bloom = [SKSpriteNode spriteNodeWithTexture:bloomTexture];
            bloom.anchorPoint = CGPointZero;
            bloom.blendMode = SKBlendModeAdd;
            CGPoint centre = [self localPointForItem:item x:anim.x y:anim.y w:1 h:1];
            bloom.position = CGPointMake(container.position.x + centre.x - anim.size, container.position.y + centre.y - anim.size);
            bloom.alpha = 0.45;
            bloom.name = item.uid;
            [[self.roomNode childNodeWithName:@"glows"] addChild:bloom];
            if (still) break;
            if (anim.variant == 1) {
                // Slow breathing pulse (reactors, jellyfish, fireflies).
                [bloom runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:0.6 duration:1.6], [SKAction fadeAlphaTo:0.25 duration:1.6]]]]];
                break;
            }
            BOOL fire = NO;
            for (APAnim *other in item.art.anims) fire = fire || other.kind == APAnimFire;
            NSMutableArray *steps = [NSMutableArray array];
            for (int i = 0; i < 14; i++) {
                CGFloat a = fire ? 0.35 + arc4random_uniform(35) / 100.0 : 0.38 + arc4random_uniform(12) / 100.0;
                [steps addObject:[SKAction fadeAlphaTo:a duration:fire ? 0.1 + arc4random_uniform(15) / 100.0 : 1.2]];
            }
            [bloom runAction:[SKAction repeatActionForever:[SKAction sequence:steps]]];
            break;
        }
        case APAnimBlink: {
            if (still) break;
            // The light is baked into the emissive layer; blink by covering it.
            SKSpriteNode *off = [SKSpriteNode spriteNodeWithColor:APUIColor(APShade(anim.color, 0.3f)) size:CGSizeMake(1, 1)];
            off.anchorPoint = CGPointZero;
            off.position = [self localPointForItem:item x:anim.x y:anim.y w:1 h:1];
            off.zPosition = 0.02;
            off.alpha = 0;
            [container addChild:off];
            NSTimeInterval on = 0.4 + arc4random_uniform(160) / 100.0, gap = 0.2 + arc4random_uniform(80) / 100.0;
            [off runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:on], [SKAction fadeAlphaTo:1 duration:0],
                                                                              [SKAction waitForDuration:gap], [SKAction fadeAlphaTo:0 duration:0]]]]];
            break;
        }
        case APAnimBubbles: {
            if (still) break;
            CGPoint origin = [self localPointForItem:item x:anim.x y:anim.y w:1 h:1];
            uint32_t tint = anim.color ?: 0xC8F0F8;
            __weak SKNode *weakContainer = container;
            SKAction *spawn = [SKAction runBlock:^{
                SKNode *parent = weakContainer;
                if (!parent) return;
                SKSpriteNode *bubble = [SKSpriteNode spriteNodeWithColor:APUIColor(tint) size:CGSizeMake(1, 1)];
                bubble.anchorPoint = CGPointZero;
                bubble.alpha = 0.8;
                bubble.position = origin;
                bubble.zPosition = 0.05;
                [parent addChild:bubble];
                SKAction *rise = [SKAction customActionWithDuration:2.4 actionBlock:^(SKNode *node, CGFloat t) {
                    node.position = CGPointMake(origin.x + round(sin(t * 4) * 1.2), origin.y + round(t * 9));
                }];
                [bubble runAction:[SKAction sequence:@[[SKAction group:@[rise, [SKAction sequence:@[[SKAction waitForDuration:1.8], [SKAction fadeOutWithDuration:0.6]]]]],
                                                       [SKAction removeFromParent]]]];
            }];
            [container runAction:[SKAction repeatActionForever:[SKAction sequence:@[spawn, [SKAction waitForDuration:0.9 withRange:0.8]]]]];
            break;
        }
        case APAnimFireflies: {
            if (still) break;
            CGPoint origin = [self localPointForItem:item x:anim.x y:anim.y w:anim.w h:anim.h];
            SKNode *swarm = [SKNode node];
            swarm.zPosition = 0.02;
            [container addChild:swarm];
            for (int i = 0; i < 3; i++) [self addFireflyTo:swarm inRect:CGRectMake(origin.x, origin.y, anim.w, anim.h) color:anim.color];
            break;
        }
        case APAnimClockHands: break; // re-rendered by -minuteTick
    }
}

- (void)attachWeather:(APAnim *)anim item:(APPlacedItem *)item container:(SKNode *)container {
    if (self.reducedMotion) return;
    int hour = self.renderedMinute / 60;
    BOOL night = hour < 6 || hour >= 20;
    CGPoint origin = [self localPointForItem:item x:anim.x y:anim.y w:anim.w h:anim.h];
    int w = anim.w, h = anim.h;
    // Particles stay inside the glass: a crop node masks them to the pane.
    SKCropNode *crop = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:UIColor.whiteColor size:CGSizeMake(w, h)];
    mask.anchorPoint = CGPointZero;
    mask.position = origin;
    crop.maskNode = mask;
    crop.zPosition = 0.015;
    [container addChild:crop];
    __weak SKCropNode *weakCrop = crop;
    if (anim.variant == 5) {
        // Ocean porthole: bubbles, and now and then a fish swims past.
        SKAction *bubble = [SKAction runBlock:^{
            SKCropNode *parent = weakCrop;
            if (!parent) return;
            SKSpriteNode *b = [SKSpriteNode spriteNodeWithColor:APUIColor(0xC8F0F8) size:CGSizeMake(1, 1)];
            b.anchorPoint = CGPointZero;
            CGPoint from = CGPointMake(origin.x + arc4random_uniform((uint32_t)w), origin.y - 1), to = CGPointMake(from.x + 1, origin.y + h + 1);
            b.position = from;
            [parent addChild:b];
            [b runAction:[SKAction sequence:@[APPixelMove(from, to, 2.2), [SKAction removeFromParent]]]];
        }];
        SKAction *fish = [SKAction runBlock:^{
            SKCropNode *parent = weakCrop;
            if (!parent) return;
            uint32_t colours[] = {0xF2A040, 0xE8E060, 0xF07AA0, 0x7AE0F0};
            uint32_t colour = colours[arc4random_uniform(4)];
            APCanvas *f = APCanvasCreate(5, 3);
            APRect(f, 1, 0, 3, 3, colour); APPx(f, 0, 1, colour); APPx(f, 4, 0, colour); APPx(f, 4, 2, colour); APPx(f, 1, 1, 0x1A1A1A);
            SKSpriteNode *swimmer = APSprite(f);
            APCanvasFree(f);
            BOOL left = arc4random_uniform(2);
            CGFloat y = origin.y + 3 + arc4random_uniform((uint32_t)MAX(1, h - 6));
            CGPoint from = CGPointMake(left ? origin.x + w + 2 : origin.x - 6, y), to = CGPointMake(left ? origin.x - 6 : origin.x + w + 2, y);
            if (!left) {
                swimmer.xScale = -1;
                from.x += 5;
                to.x += 5;
            }
            swimmer.position = from;
            [parent addChild:swimmer];
            [swimmer runAction:[SKAction sequence:@[APPixelMove(from, to, 4.5), [SKAction removeFromParent]]]];
        }];
        [crop runAction:[SKAction repeatActionForever:[SKAction sequence:@[bubble, [SKAction waitForDuration:0.5 withRange:0.6]]]]];
        [crop runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:6 withRange:6], fish]]]];
        return;
    }
    if (anim.variant == 4) night = YES; // space: always starry
    if (anim.variant == 0 || anim.variant == 2) {
        BOOL snow = anim.variant == 0;
        SKAction *spawn = [SKAction runBlock:^{
            SKCropNode *parent = weakCrop;
            if (!parent) return;
            SKSpriteNode *drop = [SKSpriteNode spriteNodeWithColor:APUIColor(snow ? 0xF4F8FC : 0xA8C0E0) size:CGSizeMake(1, snow ? 1 : 2)];
            drop.anchorPoint = CGPointZero;
            drop.alpha = snow ? 0.95 : 0.7;
            CGPoint from = CGPointMake(origin.x + arc4random_uniform((uint32_t)w + 4) - 2, origin.y + h);
            CGPoint to = CGPointMake(from.x + (snow ? (int)arc4random_uniform(5) - 2 : -3), origin.y - 2);
            drop.position = from;
            [parent addChild:drop];
            NSTimeInterval d = snow ? 2.6 + arc4random_uniform(150) / 100.0 : 0.45;
            SKAction *fall = snow ? [SKAction customActionWithDuration:d actionBlock:^(SKNode *node, CGFloat t) {
                CGFloat f = t / d;
                node.position = CGPointMake(round(from.x + (to.x - from.x) * f + sin(t * 2.4) * 1.2), round(from.y + (to.y - from.y) * f));
            }] : APPixelMove(from, to, d);
            [drop runAction:[SKAction sequence:@[fall, [SKAction removeFromParent]]]];
        }];
        [crop runAction:[SKAction repeatActionForever:[SKAction sequence:@[spawn, [SKAction waitForDuration:snow ? 0.22 : 0.06]]]]];
    } else if (night) {
        // Clear nights: a few stars twinkle.
        for (int i = 0; i < 5; i++) {
            SKSpriteNode *star = [SKSpriteNode spriteNodeWithColor:APUIColor(0xFFF4D0) size:CGSizeMake(1, 1)];
            star.anchorPoint = CGPointZero;
            star.position = CGPointMake(origin.x + arc4random_uniform((uint32_t)w), origin.y + h / 3 + arc4random_uniform((uint32_t)(h * 2 / 3)));
            star.alpha = 0;
            [crop addChild:star];
            NSTimeInterval period = 1.5 + arc4random_uniform(250) / 100.0;
            [star runAction:[SKAction sequence:@[[SKAction waitForDuration:arc4random_uniform(300) / 100.0],
                [SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:1 duration:period / 2], [SKAction fadeAlphaTo:0 duration:period / 2]]]]]]];
        }
        // And the odd shooting star.
        SKAction *shoot = [SKAction runBlock:^{
            SKCropNode *parent = weakCrop;
            if (!parent) return;
            SKSpriteNode *streak = [SKSpriteNode spriteNodeWithColor:APUIColor(0xFFFFFF) size:CGSizeMake(2, 1)];
            streak.anchorPoint = CGPointZero;
            CGPoint from = CGPointMake(origin.x + w, origin.y + h - 2), to = CGPointMake(origin.x - 4, origin.y + h / 2);
            streak.position = from;
            [parent addChild:streak];
            [streak runAction:[SKAction sequence:@[APPixelMove(from, to, 0.5), [SKAction removeFromParent]]]];
        }];
        [crop runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:25 withRange:20], shoot]]]];
    }
}

#pragma mark - Pal

- (NSArray<SKTexture *> *)framesForResident:(ApolloPalHomeResident *)resident action:(NSString *)action {
    NSString *species = resident.species, *coat = resident.coat ?: @"original";
    if (!species) return @[];
    NSString *key = [NSString stringWithFormat:@"%@-%@|%@", species, action, coat];
    NSArray *cached = self.clips[key];
    if (cached) return cached;
    // Apollo's sheet or a Reborn species', in this resident's own coat.
    CGImageRef sheetImage = APPalCreateSheetForUI(species, coat, action);
    UIImage *image = sheetImage ? [UIImage imageWithCGImage:sheetImage] : nil;
    if (sheetImage) CGImageRelease(sheetImage);
    if (!image.CGImage) return @[];
    NSUInteger width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
    // Fail softly on an incompatible IPA. Do not ask SpriteKit for a missing
    // named texture (it otherwise draws its conspicuous placeholder rectangle).
    if (height != 14 || width == 0 || width % 32 || width / 32 > 32) return @[];
    NSUInteger count = width / 32;
    SKTexture *sheet = [SKTexture textureWithImage:image];
    sheet.filteringMode = SKTextureFilteringNearest;
    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        SKTexture *frame = [SKTexture textureWithRect:CGRectMake((CGFloat)i / count, 0, 1.0 / count, 1) inTexture:sheet];
        frame.filteringMode = SKTextureFilteringNearest;
        [frames addObject:frame];
    }
    self.clips[key] = frames;
    return frames;
}

- (ApolloPalHomeResident *)resident { return self.residents.firstObject; }

// Pal feet for a floor tile, in node coordinates.
- (CGPoint)feetForTileX:(int)x y:(int)y {
    return CGPointMake(APSideWall + x * APTile + 8, APShellHeight - (APFloorTop + y * APTile + 12));
}

- (CGFloat)zForFeet:(CGPoint)feet {
    CGFloat shellY = APShellHeight - feet.y;
    return 100 + (shellY - APFloorTop);
}

- (void)tintPal {
    if (!self.pal) return;
    float r, g, b;
    CGPoint feet = self.pal.position;
    [self.layout lightAtX:(int)feet.x y:(int)(APShellHeight - feet.y - 6) r:&r g:&g b:&b];
    self.pal.color = [UIColor colorWithRed:MIN(1, r) green:MIN(1, g) blue:MIN(1, b) alpha:1];
    self.pal.colorBlendFactor = 1;
    if (self.isGhost) {
        // Ghosts make their own light: barely shaded at night, with a halo.
        BOOL night = [self isNight];
        self.pal.colorBlendFactor = night ? 0.15 : 0.6;
        [self.pal childNodeWithName:@"halo"].alpha = night ? 0.55 : 0;
        if (!self.editing && ![self.pal actionForKey:@"fade"]) self.pal.alpha = [self palOpacity];
    } else if ([self luminousColour]) {
        // Glow-in-the-dark coats: the darker it is where they stand, the less
        // the room shades them and the brighter the pool of light around them.
        float darkness = 1 - MIN(1, MAX(r, MAX(g, b)));
        float glow = MAX(0, MIN(1, (darkness - 0.15f) / 0.55f));
        self.pal.colorBlendFactor = 1 - glow * 0.9f;
        [self.pal childNodeWithName:@"halo"].alpha = glow * 0.75f;
        [self.pal childNodeWithName:@"pool"].alpha = glow * 0.6f;
    }
}

// The colour of light this Pal gives off (ghosts, Glow coats), else 0.
- (uint32_t)luminousColour {
    if (self.isGhost) return 0xD8F0FF;
    return [APPixelPalCoats glowColourForSpecies:self.resident.species coat:self.resident.coat];
}

- (void)buildPalKeepingPosition:(BOOL)keep {
    [self.pal removeFromParent];
    self.pal = nil;
    self.hasPalArtwork = NO;
    ApolloPalHomeResident *resident = self.resident;
    SKTexture *texture = [self framesForResident:resident action:@"sit"].firstObject;
    if (!resident || !texture) return;
    self.hasPalArtwork = YES;
    self.pal = [SKSpriteNode spriteNodeWithTexture:texture size:CGSizeMake(32, 14)];
    self.pal.anchorPoint = CGPointMake(0.5, 0);
    self.pal.name = @"pal";
    [self.roomNode addChild:self.pal];
    if (!keep || ![self.layout isWalkableTileX:self.palX y:self.palY]) {
        int x = 3, y = 4;
        [self nearestWalkableFromX:x y:y outX:&x outY:&y];
        self.palX = x; self.palY = y;
    }
    self.pal.alpha = self.editing ? 0 : [self palOpacity];
    [self dressSpeciesPal];
    if (keep && self.palMode == APPalSleeping && [self.layout itemWithUID:self.palBedUID ?: @""]) {
        [self sleepInBed:[self.layout itemWithUID:self.palBedUID] announce:NO hop:NO];
    } else {
        [self settlePal];
    }
}

- (void)nearestWalkableFromX:(int)x y:(int)y outX:(int *)ox outY:(int *)oy {
    int best = INT_MAX;
    for (int ty = 0; ty < APRows; ty++) for (int tx = 0; tx < APCols; tx++) {
        if (![self.layout isWalkableTileX:tx y:ty]) continue;
        int d = abs(tx - x) + abs(ty - y);
        if (d < best) { best = d; *ox = tx; *oy = ty; }
    }
}

// Sit where we are, then let the idle brain take over.
- (void)settlePal {
    SKSpriteNode *pal = self.pal;
    if (!pal) return;
    [pal removeAllActions];
    [self removeActionForKey:@"brain"];
    self.palMode = APPalIdle;
    self.palBedUID = nil;
    self.playStep = nil;
    [self abandonHeist];
    pal.position = [self feetForTileX:self.palX y:self.palY];
    pal.zPosition = [self zForFeet:pal.position];
    pal.texture = [self framesForResident:self.resident action:@"sit"].firstObject;
    [self tintPal];
    [self scheduleBrain];
}

- (void)scheduleBrain {
    [self removeActionForKey:@"brain"];
    if (self.reducedMotion || self.editing || !self.pal) return;
    __weak typeof(self) weakSelf = self;
    APPersonality p = self.personality;
    NSTimeInterval wait = p == APPersonalityChaosGremlin || p == APPersonalityZoomies ? 2.5 : p == APPersonalityGentleSoul ? 7 : 4.5;
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:wait withRange:wait * 0.8], [SKAction runBlock:^{ [weakSelf think]; }]]]
            withKey:@"brain"];
}

- (APPersonality)personality { return (APPersonality)self.resident.personality; }

- (void)think {
    if (self.palMode != APPalIdle || self.editing || self.toy) { [self scheduleBrain]; return; }
    int hour = self.renderedMinute / 60;
    BOOL sleepy = hour >= 21 || hour < 7;
    APPersonality p = self.personality;
    // Weighted choice; personality tilts the odds.
    float nap = (sleepy ? 10 : 4) * (p == APPersonalityNapper ? 3 : p == APPersonalityChaosGremlin ? 0.3f : 1);
    float fire = 12 * (p == APPersonalityFireGazer ? 3 : 1);
    float perch = 12 * (p == APPersonalityCouchPotato ? 3 : p == APPersonalityChaosGremlin ? 0.5f : 1);
    float window = 10 * (p == APPersonalityWindowWatcher ? 3 : 1);
    float thought = 10 * (p == APPersonalityDramaQueen ? 3 : (p == APPersonalitySnackBandit || p == APPersonalityVelcro) ? 1.8f : 1);
    float amble = 25 * (p == APPersonalityChaosGremlin ? 2.5f : p == APPersonalityZoomies ? 2 : p == APPersonalityGentleSoul ? 0.6f : p == APPersonalityCouchPotato ? 0.5f : 1);
    float zoom = p == APPersonalityZoomies || p == APPersonalityChaosGremlin ? 6 : 0;
    float rest = 15 * (p == APPersonalityGentleSoul ? 2 : p == APPersonalityChaosGremlin ? 0.2f : 1);
    float heist = self.isGoose && !self.readOnly ? 7 * (p == APPersonalityChaosGremlin ? 2 : 1) : 0;
    float weights[] = {nap, fire, perch, window, thought, amble, zoom, rest, heist};
    int count = (int)(sizeof(weights) / sizeof(weights[0]));
    float total = 0;
    for (int i = 0; i < count; i++) total += weights[i];
    float pick = arc4random_uniform(10000) / 10000.0f * total;
    int choice = 0;
    for (; choice < count - 1; choice++) { if (pick < weights[choice]) break; pick -= weights[choice]; }
    switch (choice) {
        case 0: if (self.layout.petBeds.count) { [self napAnnounce:NO]; return; } break;
        case 1: if ([self warmByFire]) return; break;
        case 2: if ([self perchSomewhere]) return; break;
        case 3: if ([self watchFromWindow]) return; break;
        case 4: [self showThought:[self thoughtForRoom]]; [self scheduleBrain]; return;
        case 5: if ([self ambleRunning:p == APPersonalityChaosGremlin]) return; break;
        case 6: if ([self ambleRunning:YES]) return; break;
        case 8: if ([self gooseHeist]) return; break;
        default: break;
    }
    [self scheduleBrain];
}

- (BOOL)warmByFire {
    for (APPlacedItem *item in self.layout.items) {
        BOOL fire = NO;
        for (APAnim *anim in item.art.anims) fire = fire || anim.kind == APAnimFire;
        if (!fire || item.spec.layer != APLayerFloor) continue;
        int tx = item.x + item.spec.w / 2, ty = item.y + item.spec.d;
        if ([self.layout isWalkableTileX:tx y:ty] && [self pathFromX:self.palX y:self.palY toX:tx y:ty]) {
            __weak typeof(self) weakSelf = self;
            [self walkToX:tx y:ty run:NO completion:^{
                if (arc4random_uniform(3) == 0) [weakSelf showThought:@"t.flame"];
                [weakSelf scheduleBrain];
            }];
            return YES;
        }
    }
    return NO;
}

- (BOOL)ambleRunning:(BOOL)run {
    NSMutableArray *spots = [NSMutableArray array];
    int reach = run ? 6 : 4;
    for (int y = 0; y < APRows; y++) for (int x = 0; x < APCols; x++) {
        if ([self.layout isWalkableTileX:x y:y] && abs(x - self.palX) + abs(y - self.palY) <= reach && (x != self.palX || y != self.palY)) {
            [spots addObject:@[@(x), @(y)]];
        }
    }
    if (!spots.count) return NO;
    NSArray *spot = spots[arc4random_uniform((uint32_t)spots.count)];
    [self walkToX:[spot[0] intValue] y:[spot[1] intValue] run:run completion:nil];
    return YES;
}

- (void)welcomeHome {
    SKSpriteNode *pal = self.pal;
    if (!pal || self.editing) return;
    [pal removeAllActions];
    [self removeActionForKey:@"brain"];
    self.palMode = APPalIdle;
    int tx = 3, ty = 4;
    [self nearestWalkableFromX:tx y:ty outX:&tx outY:&ty];
    CGPoint to = [self feetForTileX:tx y:ty];
    self.palX = tx; self.palY = ty;
    if (self.reducedMotion) {
        [self settlePal];
        [self floatIcon:@"smallheart" count:3 color:0];
        return;
    }
    // In through the front, hopping with joy.
    CGPoint from = CGPointMake(to.x, -12);
    pal.position = from;
    pal.zPosition = 990;
    pal.xScale = 1;
    NSArray *frames = [self framesForResident:self.resident action:@"run"];
    if (frames.count) [pal runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:frames timePerFrame:0.4 / frames.count]] withKey:@"legs"];
    __weak typeof(self) weakSelf = self;
    [pal runAction:[SKAction sequence:@[APPixelMove(from, to, 0.9), [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf settlePal];
        APHapticPlay(APHapticHop);
        [strongSelf floatIcon:@"smallheart" count:3 color:0];
        [strongSelf showThought:@"t.heart"];
    }]]]];
}

- (void)waveGoodbye:(void (^)(void))completion {
    SKSpriteNode *pal = self.pal;
    if (!pal || self.reducedMotion) { completion(); return; }
    [pal removeAllActions];
    [self removeActionForKey:@"brain"];
    [self tumbleYuzus];
    self.palMode = APPalWalking;
    [self floatIcon:@"smallheart" count:2 color:0];
    [self showThought:@"t.heart"];
    CGPoint from = pal.position, out = CGPointMake(pal.position.x, -16);
    NSArray *frames = [self framesForResident:self.resident action:@"walk"];
    pal.zPosition = 990;
    __weak typeof(self) weakSelf = self;
    [pal runAction:[SKAction sequence:@[[SKAction waitForDuration:1.0], [SKAction runBlock:^{
        if (frames.count) [weakSelf.pal runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:frames timePerFrame:0.11]] withKey:@"legs"];
    }], APPixelMove(from, out, 1.4), [SKAction runBlock:^{
        [weakSelf.pal removeActionForKey:@"legs"];
        completion();
    }]]]];
}

// Breadth-first path over walkable tiles.
- (NSArray<NSValue *> *)pathFromX:(int)sx y:(int)sy toX:(int)tx y:(int)ty {
    if (![self.layout isWalkableTileX:tx y:ty]) return nil;
    BOOL ghost = self.isGhost;
    int prev[APCols * APRows];
    for (int i = 0; i < APCols * APRows; i++) prev[i] = -2;
    int queue[APCols * APRows], head = 0, tail = 0;
    int start = sy * APCols + sx, goal = ty * APCols + tx;
    queue[tail++] = start;
    prev[start] = -1;
    while (head < tail) {
        int cur = queue[head++];
        if (cur == goal) break;
        int cx = cur % APCols, cy = cur / APCols;
        int dirs[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
        for (int d = 0; d < 4; d++) {
            int nx = cx + dirs[d][0], ny = cy + dirs[d][1];
            if (nx < 0 || ny < 0 || nx >= APCols || ny >= APRows) continue;
            // Ghosts drift straight through furniture (they still stop on a free tile).
            if (!ghost && ![self.layout isWalkableTileX:nx y:ny]) continue;
            int n = ny * APCols + nx;
            if (prev[n] != -2) continue;
            prev[n] = cur;
            queue[tail++] = n;
        }
    }
    if (prev[goal] == -2) return nil;
    NSMutableArray *path = [NSMutableArray array];
    for (int cur = goal; cur != start && cur >= 0; cur = prev[cur]) {
        [path insertObject:[NSValue valueWithCGPoint:CGPointMake(cur % APCols, cur / APCols)] atIndex:0];
    }
    return path;
}

- (void)walkToX:(int)tx y:(int)ty run:(BOOL)run completion:(void (^_Nullable)(void))completion {
    SKSpriteNode *pal = self.pal;
    if (!pal) return;
    [self removeActionForKey:@"brain"];
    NSArray<NSValue *> *path = [self pathFromX:self.palX y:self.palY toX:tx y:ty];
    if (self.reducedMotion || !path) {
        if (path) { self.palX = tx; self.palY = ty; }
        pal.position = [self feetForTileX:self.palX y:self.palY];
        pal.zPosition = [self zForFeet:pal.position];
        [self tintPal];
        if (completion) completion(); else [self scheduleBrain];
        return;
    }
    [pal removeAllActions];
    if (self.palMode == APPalPerched) pal.position = [self feetForTileX:self.palX y:self.palY];
    [[self.roomNode childNodeWithName:@"thought"] removeFromParent];
    self.palMode = APPalWalking;
    NSArray *frames = [self framesForResident:self.resident action:run ? @"run" : @"walk"];
    if (frames.count) [pal runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:frames timePerFrame:(run ? 0.4 : 0.8) / frames.count]] withKey:@"legs"];
    NSMutableArray *steps = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    CGPoint from = pal.position;
    for (NSValue *value in path) {
        CGPoint tile = value.CGPointValue;
        CGPoint to = [self feetForTileX:(int)tile.x y:(int)tile.y];
        CGPoint stepFrom = from;
        [steps addObject:[SKAction runBlock:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (to.x != stepFrom.x) strongSelf.pal.xScale = to.x < stepFrom.x ? -1 : 1;
            // Sort against furniture by whichever row is nearer the viewer.
            strongSelf.pal.zPosition = MAX([strongSelf zForFeet:stepFrom], [strongSelf zForFeet:to]);
        }]];
        [steps addObject:APPixelMove(stepFrom, to, run ? 0.22 : 0.5)];
        [steps addObject:[SKAction runBlock:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            strongSelf.palX = (int)tile.x;
            strongSelf.palY = (int)tile.y;
            strongSelf.pal.zPosition = [strongSelf zForFeet:to];
            [strongSelf tintPal];
        }]];
        from = to;
    }
    [steps addObject:[SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.pal removeActionForKey:@"legs"];
        strongSelf.pal.texture = [strongSelf framesForResident:strongSelf.resident action:@"sit"].firstObject;
        strongSelf.palMode = APPalIdle;
        if (completion) completion(); else [strongSelf scheduleBrain];
    }]];
    [pal runAction:[SKAction sequence:steps] withKey:@"walk"];
}

#pragma mark Seats, windows and thoughts

// Hop up onto a sofa/armchair/throne for a while, like a real pet would.
- (BOOL)perchSomewhere {
    NSMutableArray<APPlacedItem *> *seats = [NSMutableArray array];
    for (APPlacedItem *item in self.layout.items) {
        if (!item.spec.seat) continue;
        int fx = item.x + item.spec.w / 2, fy = item.y + item.spec.d;
        if ([self.layout isWalkableTileX:fx y:fy] && ((fx == self.palX && fy == self.palY) || [self pathFromX:self.palX y:self.palY toX:fx y:fy])) {
            [seats addObject:item];
        }
    }
    if (!seats.count) return NO;
    APPlacedItem *seat = seats[arc4random_uniform((uint32_t)seats.count)];
    __weak typeof(self) weakSelf = self;
    [self walkToX:seat.x + seat.spec.w / 2 y:seat.y + seat.spec.d run:NO completion:^{ [weakSelf hopOnto:seat]; }];
    return YES;
}

- (SKAction *)hopFrom:(CGPoint)from to:(CGPoint)to {
    CGPoint mid = CGPointMake(round((from.x + to.x) / 2), MAX(from.y, to.y) + 5);
    return [SKAction sequence:@[APPixelMove(from, mid, 0.12), APPixelMove(mid, to, 0.14)]];
}

- (void)hopOnto:(APPlacedItem *)seat {
    SKSpriteNode *pal = self.pal;
    if (!pal || self.editing) return;
    self.palMode = APPalPerched;
    int sx = [seat shellXForLocalX:seat.spec.seatX], sy = [seat shellYForLocalY:seat.spec.seatY];
    CGPoint to = CGPointMake(sx, APShellHeight - sy), from = pal.position;
    pal.zPosition = seat.z + 0.1;
    pal.xScale = arc4random_uniform(2) ? 1 : -1;
    pal.texture = [self framesForResident:self.resident action:@"sit"].firstObject;
    __weak typeof(self) weakSelf = self;
    [pal runAction:[SKAction sequence:@[[self hopFrom:from to:to], [SKAction runBlock:^{
        APHapticPlay(APHapticHop);
        [weakSelf tintPal];
        if (arc4random_uniform(2)) [weakSelf showThought:@"t.heart"];
    }]]]];
    // Stay a while, then hop back down.
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:12 withRange:10], [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf.palMode != APPalPerched) return;
        CGPoint down = [strongSelf feetForTileX:strongSelf.palX y:strongSelf.palY];
        [strongSelf.pal runAction:[SKAction sequence:@[[strongSelf hopFrom:strongSelf.pal.position to:down], [SKAction runBlock:^{
            [weakSelf settlePal];
        }]]]];
    }]]] withKey:@"brain"];
}

- (BOOL)watchFromWindow {
    int hour = self.renderedMinute / 60;
    for (APPlacedItem *item in self.layout.items) {
        APAnim *glass = nil;
        for (APAnim *anim in item.art.anims) if (anim.kind == APAnimWindow) glass = anim;
        if (!glass || item.spec.layer != APLayerWall) continue;
        int tx = item.x + (item.spec.w - 1) / 2, ty = 0;
        if (![self.layout isWalkableTileX:tx y:ty]) ty = 1;
        if (![self.layout isWalkableTileX:tx y:ty] || ![self pathFromX:self.palX y:self.palY toX:tx y:ty]) continue;
        NSString *thought = glass.variant == 4 ? @"t.star" : glass.variant == 5 ? @"t.fish"
            : glass.variant == 0 ? @"t.snow" : (hour >= 8 && hour < 18) ? @"t.sun" : @"t.moon";
        __weak typeof(self) weakSelf = self;
        [self walkToX:tx y:ty run:NO completion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            strongSelf.pal.xScale = 1;
            [strongSelf showThought:thought];
            [strongSelf scheduleBrain];
        }];
        return YES;
    }
    return NO;
}

- (NSString *)thoughtForRoom {
    int hour = self.renderedMinute / 60;
    NSMutableArray *ideas = [NSMutableArray arrayWithObjects:@"t.heart", @"t.yarn", @"t.star", nil];
    NSString *snack = [APSpecies speciesWithID:self.resident.species].snackThought ?: @"t.fish";
    if ((hour >= 7 && hour < 9) || hour == 12 || (hour >= 18 && hour < 20)) {
        [ideas addObject:snack];
        [ideas addObject:snack];
    }
    if (hour >= 21 || hour < 6) [ideas addObject:@"t.moon"];
    switch (self.personality) {
        case APPersonalitySnackBandit: for (int i = 0; i < 4; i++) [ideas addObject:snack]; break;
        case APPersonalityVelcro: for (int i = 0; i < 4; i++) [ideas addObject:@"t.heart"]; break;
        case APPersonalityNapper: [ideas addObject:@"t.moon"]; [ideas addObject:@"t.moon"]; break;
        case APPersonalityZoomies: case APPersonalityChaosGremlin: [ideas addObject:@"t.yarn"]; [ideas addObject:@"t.star"]; break;
        default: break;
    }
    for (APPlacedItem *item in self.layout.items) {
        for (APAnim *anim in item.art.anims) {
            if (anim.kind == APAnimFire) [ideas addObject:@"t.flame"];
            if (anim.kind == APAnimNotes) { [ideas addObject:@"t.note"]; [ideas addObject:@"t.note"]; }
            if (anim.kind == APAnimWindow && anim.variant == 0) [ideas addObject:@"t.snow"];
        }
    }
    return ideas[arc4random_uniform((uint32_t)ideas.count)];
}

// A little pixel thought bubble above the Pal's head.
- (void)showThought:(NSString *)iconName {
    SKSpriteNode *pal = self.pal;
    if (!pal || self.editing) return;
    [[self.roomNode childNodeWithName:@"thought"] removeFromParent];
    APCanvas *icon = APIconCanvas(iconName);
    int w = MAX(icon->w + 6, 11), h = MAX(icon->h + 5, 9);
    APCanvas *bubble = APCanvasCreate(w, h + 4);
    APRoundRect(bubble, 0, 0, w, h, 0xFAF6EE);
    APOutlineInside(bubble, 0x3A2A22);
    APPx(bubble, 3, h, 0xFAF6EE); APPx(bubble, 2, h + 1, 0x3A2A22); APPx(bubble, 4, h, 0x3A2A22); APPx(bubble, 3, h + 1, 0x3A2A22);
    APPx(bubble, 1, h + 3, 0x3A2A22);
    APDraw(bubble, icon, (w - icon->w) / 2, (h - icon->h) / 2, NO);
    APCanvasFree(icon);
    SKSpriteNode *node = APSprite(bubble);
    APCanvasFree(bubble);
    node.name = @"thought";
    node.position = CGPointMake(round(pal.position.x + 2), pal.position.y + 12);
    node.zPosition = 960;
    node.alpha = 0;
    [self.roomNode addChild:node];
    [node runAction:[SKAction sequence:@[[SKAction fadeInWithDuration:0.15], [SKAction waitForDuration:2.6],
                                         [SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
}

- (void)floatIcon:(NSString *)name count:(int)count color:(uint32_t)tint {
    if (!self.pal) return;
    for (int i = 0; i < count; i++) {
        APCanvas *icon = APIconCanvas(name);
        if (tint) APTint(icon, tint);
        SKSpriteNode *node = APSprite(icon);
        APCanvasFree(icon);
        CGPoint from = CGPointMake(round(self.pal.position.x - 2 + (i - count / 2) * 5), self.pal.position.y + 12 + (i % 2) * 2);
        node.position = from;
        node.zPosition = 950;
        [self.roomNode addChild:node];
        if (self.reducedMotion) {
            [node runAction:[SKAction sequence:@[[SKAction waitForDuration:1.4], [SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
            continue;
        }
        CGPoint to = CGPointMake(from.x + (i % 2 ? 2 : -2), from.y + 14);
        [node runAction:[SKAction sequence:@[[SKAction waitForDuration:i * 0.18],
            [SKAction group:@[APPixelMove(from, to, 1.4), [SKAction sequence:@[[SKAction waitForDuration:0.8], [SKAction fadeOutWithDuration:0.6]]]]],
            [SKAction removeFromParent]]]];
    }
}

- (void)announce:(NSString *)message { [self.homeDelegate palHomeScene:self announce:message]; }

- (void)petResident {
    SKSpriteNode *pal = self.pal;
    if (!pal || self.editing) return;
    if (self.palMode == APPalSleeping) {
        [self wakeUp];
        [self announce:[NSString stringWithFormat:@"%@ wakes up with a stretch.", self.resident.name]];
        return;
    }
    if (self.isGhost && self.palMode == APPalIdle) { [self boo]; return; }
    if (self.isGoose && self.palMode == APPalIdle) { [self honk]; return; }
    APHapticPlay(APHapticPurr);
    if ([self stackYuzu]) return;
    [pal removeActionForKey:@"hop"];
    [self floatIcon:@"smallheart" count:3 color:0];
    if (!self.reducedMotion && self.palMode == APPalIdle) {
        CGPoint p = pal.position;
        [pal runAction:[SKAction sequence:@[[SKAction moveTo:CGPointMake(p.x, p.y + 2) duration:0], [SKAction waitForDuration:0.1],
            [SKAction moveTo:CGPointMake(p.x, p.y + 3) duration:0], [SKAction waitForDuration:0.1],
            [SKAction moveTo:CGPointMake(p.x, p.y + 1) duration:0], [SKAction waitForDuration:0.08],
            [SKAction moveTo:p duration:0], [SKAction waitForDuration:0.15],
            [SKAction moveTo:CGPointMake(p.x, p.y + 2) duration:0], [SKAction waitForDuration:0.1],
            [SKAction moveTo:p duration:0]]] withKey:@"hop"];
    }
    [self announce:[NSString stringWithFormat:@"%@ loves that.", self.resident.name]];
}

#pragma mark - Capybara: yuzu

// Capybaras famously let anything sit on their heads, and in Japan they soak
// in hot springs with yuzu floating around them. So: pet a capybara and a
// yuzu lands on its head. Then another. Up to three, balanced with total
// serenity (no excited hop, it's a capybara). They tumble off the moment it
// gets up to do anything.
- (void)setPalMode:(APPalMode)palMode {
    _palMode = palMode;
    if (palMode != APPalIdle && palMode != APPalPerched) [self tumbleYuzus];
}

- (NSArray<SKNode *> *)yuzus {
    NSMutableArray *stack = [NSMutableArray array];
    for (SKNode *child in self.pal.children) if ([child.name isEqualToString:@"yuzu"]) [stack addObject:child];
    return stack;
}

- (APCanvas *)yuzuCanvas {
    APCanvas *c = APCanvasCreate(4, 5);
    APRect(c, 1, 1, 2, 4, 0xF2B320);
    APRect(c, 0, 2, 4, 2, 0xF2B320);
    APPx(c, 1, 2, 0xFFE07A);              // shine
    APPx(c, 2, 4, 0xD08A10); APPx(c, 3, 3, 0xD08A10);
    APPx(c, 2, 0, 0x5A9A3A); APPx(c, 3, 0, 0x7AC24A); // leaf
    return c;
}

- (BOOL)stackYuzu {
    SKSpriteNode *pal = self.pal;
    if (![self.resident.species isEqualToString:@"capybara"] || !pal) return NO;
    if (self.palMode != APPalIdle && self.palMode != APPalPerched) return NO;
    NSString *name = self.resident.name;
    NSArray<SKNode *> *stack = [self yuzus];
    if (stack.count >= 3) {
        // The tower is complete. The top one wobbles; the capybara does not.
        SKNode *top = stack.lastObject;
        [top runAction:[SKAction sequence:@[[SKAction moveByX:1 y:0 duration:0], [SKAction waitForDuration:0.12],
                                            [SKAction moveByX:-2 y:0 duration:0], [SKAction waitForDuration:0.12],
                                            [SKAction moveByX:1 y:0 duration:0]]]];
        [self floatIcon:@"smallheart" count:1 color:0];
        [self announce:[NSString stringWithFormat:@"%@ is perfectly balanced, as all things should be.", name]];
        return YES;
    }
    CGPoint head = APRebornHeadTop(@"capybara", @"sit");
    APCanvas *canvas = [self yuzuCanvas];
    SKSpriteNode *yuzu = APSprite(canvas);
    APCanvasFree(canvas);
    yuzu.name = @"yuzu";
    yuzu.color = pal.color;
    yuzu.colorBlendFactor = pal.colorBlendFactor;
    yuzu.zPosition = 0.1 + stack.count * 0.01;
    // Pal node: anchor at the feet, 32×14 frame. Each yuzu sits on the last.
    CGPoint rest = CGPointMake(head.x - 1 - 16 + (stack.count == 1 ? 1 : 0), 14 - head.y + (int)stack.count * 4);
    [pal addChild:yuzu];
    if (self.reducedMotion) {
        yuzu.position = rest;
    } else {
        CGPoint high = CGPointMake(rest.x, rest.y + 14);
        yuzu.position = high;
        [yuzu runAction:[SKAction sequence:@[APPixelMove(high, CGPointMake(rest.x, rest.y - 1), 0.22),
                                             [SKAction moveTo:CGPointMake(rest.x, rest.y + 1) duration:0], [SKAction waitForDuration:0.08],
                                             [SKAction moveTo:rest duration:0]]]];
    }
    // Nobody walks off wearing yuzu: a long, serene sit before the brain
    // gets any ideas (each new yuzu restarts it).
    [self removeActionForKey:@"brain"];
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:14 withRange:6], [SKAction runBlock:^{ [weakSelf scheduleBrain]; }]]]
            withKey:@"brain"];
    NSArray *lines = @[@"A yuzu lands on %@'s head. %@ is unbothered.", @"Another yuzu. %@ remains at peace.",
                       @"Three yuzu. %@ has achieved enlightenment."];
    [self announce:[NSString stringWithFormat:lines[MIN(stack.count, lines.count - 1)], name, name]];
    if (stack.count == 2) [self floatIcon:@"smallheart" count:2 color:0];
    return YES;
}

- (void)tumbleYuzus {
    NSArray<SKNode *> *stack = [self yuzus];
    if (!stack.count) return;
    SKSpriteNode *pal = self.pal;
    CGFloat floor = pal.position.y;
    for (NSUInteger i = 0; i < stack.count; i++) {
        SKNode *yuzu = stack[i];
        CGPoint p = [pal convertPoint:yuzu.position toNode:self.roomNode];
        [yuzu removeFromParent];
        yuzu.position = CGPointMake(round(p.x), round(p.y));
        yuzu.zPosition = pal.zPosition + 0.1;
        [self.roomNode addChild:yuzu];
        if (self.reducedMotion) { [yuzu removeFromParent]; continue; }
        CGFloat dx = (i % 2 ? -1 : 1) * (4 + 3 * (CGFloat)i);
        CGPoint land = CGPointMake(yuzu.position.x + dx, floor);
        [yuzu runAction:[SKAction sequence:@[APPixelMove(yuzu.position, land, 0.25 + 0.05 * i),
                                             APPixelMove(land, CGPointMake(land.x + dx / 2, floor + 2), 0.1),
                                             APPixelMove(CGPointMake(land.x + dx / 2, floor + 2), CGPointMake(land.x + dx, floor), 0.1),
                                             [SKAction waitForDuration:1.2], [SKAction fadeOutWithDuration:0.4], [SKAction removeFromParent]]]];
    }
}

- (void)wakeUp {
    SKSpriteNode *pal = self.pal;
    [pal removeAllActions];
    [self removeActionForKey:@"zzz"];
    self.palMode = APPalIdle;
    // Hop off the bed onto the nearest free tile.
    int x = self.palX, y = self.palY;
    if (![self.layout isWalkableTileX:x y:y]) [self nearestWalkableFromX:x y:y outX:&x outY:&y];
    self.palX = x; self.palY = y;
    [self settlePal];
}

- (APCanvas *)yarnCanvas {
    APCanvas *c = APCanvasCreate(6, 6);
    APCircle(c, 2, 3, 2, 0xE88AA8);
    APPx(c, 1, 2, 0xF8C8D8); APPx(c, 2, 3, 0xF8C8D8); APPx(c, 3, 4, 0xC86A88);
    APPx(c, 4, 1, 0xE88AA8); APPx(c, 5, 0, 0xE88AA8);
    return c;
}

- (void)playWithResident {
    [self stopGame];
    SKSpriteNode *pal = self.pal;
    if (!pal || self.editing) return;
    if (self.palMode == APPalSleeping) [self wakeUp];
    [[self.roomNode childNodeWithName:@"yarn"] removeFromParent];
    [pal removeAllActions];
    [self removeActionForKey:@"brain"];
    [self announce:[NSString stringWithFormat:@"%@ pounces on the yarn!", self.resident.name]];
    NSMutableArray *spots = [NSMutableArray array];
    for (int y = 0; y < APRows; y++) for (int x = 0; x < APCols; x++) {
        if ([self.layout isWalkableTileX:x y:y] && [self pathFromX:self.palX y:self.palY toX:x y:y]) [spots addObject:@[@(x), @(y)]];
    }
    if (!spots.count || self.reducedMotion) {
        [self floatIcon:@"smallheart" count:1 color:0];
        [self settlePal];
        return;
    }
    APCanvas *yarnCanvas = [self yarnCanvas];
    SKSpriteNode *yarn = APSprite(yarnCanvas);
    APCanvasFree(yarnCanvas);
    yarn.name = @"yarn";
    yarn.position = CGPointMake(pal.position.x + 8, pal.position.y);
    yarn.zPosition = pal.zPosition + 0.2;
    [self.roomNode addChild:yarn];
    self.palMode = APPalPlaying;
    __block int bounces = 3;
    __weak typeof(self) weakSelf = self;
    // The yarn rolls to a random reachable spot; the Pal chases it, three times.
    self.playStep = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SKSpriteNode *ball = (SKSpriteNode *)[strongSelf.roomNode childNodeWithName:@"yarn"];
        if (!strongSelf || !ball || strongSelf.palMode != APPalPlaying) return;
        if (bounces-- <= 0) {
            [ball runAction:[SKAction sequence:@[[SKAction fadeOutWithDuration:0.4], [SKAction removeFromParent]]]];
            [strongSelf floatIcon:@"smallheart" count:2 color:0];
            [strongSelf settlePal];
            return;
        }
        NSArray *spot = spots[arc4random_uniform((uint32_t)spots.count)];
        int tx = [spot[0] intValue], ty = [spot[1] intValue];
        CGPoint feet = [strongSelf feetForTileX:tx y:ty];
        CGPoint target = CGPointMake(feet.x + 5, feet.y + 1);
        ball.zPosition = MAX(ball.zPosition, [strongSelf zForFeet:feet] + 0.2);
        [ball runAction:[SKAction sequence:@[APPixelMove(ball.position, target, 0.7),
            [SKAction runBlock:^{ ball.zPosition = [weakSelf zForFeet:feet] + 0.2; }]]]];
        [strongSelf walkToX:tx y:ty run:YES completion:^{
            __strong typeof(weakSelf) innerSelf = weakSelf;
            APHapticPlay(APHapticHop); // pounce!
            innerSelf.palMode = APPalPlaying;
            if (innerSelf.playStep) innerSelf.playStep();
        }];
    };
    self.playStep();
}

#pragma mark - Ghost and goose

- (BOOL)isGhost { return [self.resident.species isEqualToString:@"ghost"]; }
- (BOOL)isGoose { return [self.resident.species isEqualToString:@"goose"]; }
- (BOOL)isNight { int hour = self.renderedMinute / 60; return hour >= 19 || hour < 6; }

// Ghosts are see-through by day and glow at night; everyone else is solid.
- (CGFloat)palOpacity { return self.isGhost ? ([self isNight] ? 0.95 : 0.72) : 1; }

// Species extras on a freshly built Pal: the ghost's halo and float.
// A soft, ordered-dither glow (additive), w × h art pixels.
static SKSpriteNode *APGlowSprite(int w, int h, uint32_t colour, float strength) {
    APCanvas *halo = APCanvasCreate(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float dx = (x - (w - 1) / 2.0f) / (w / 2.0f), dy = (y - (h - 1) / 2.0f) / (h / 2.0f), d = dx * dx + dy * dy;
        if (d < 1 && APBayer(x, y) < (1 - d) * strength) APPx(halo, x, y, colour);
    }
    SKSpriteNode *glow = APSprite(halo);
    APCanvasFree(halo);
    glow.blendMode = SKBlendModeAdd;
    glow.alpha = 0;
    return glow;
}

- (void)dressSpeciesPal {
    [self removeActionForKey:@"ghostbob"];
    SKSpriteNode *pal = self.pal;
    uint32_t light = [self luminousColour];
    if (!pal || !light) return;
    // A halo round the body…
    SKSpriteNode *glow = APGlowSprite(self.isGhost ? 24 : 28, self.isGhost ? 18 : 16, light, 0.7f);
    glow.name = @"halo";
    glow.anchorPoint = CGPointMake(0.5, 0);
    glow.position = CGPointMake(-1, -2);
    glow.zPosition = -0.01;
    [pal addChild:glow];
    // …and, for glow-in-the-dark coats, a pool of light on the floor around
    // them, so they really do light up the room as they wander about.
    if (!self.isGhost) {
        SKSpriteNode *pool = APGlowSprite(64, 26, light, 0.55f);
        pool.name = @"pool";
        pool.anchorPoint = CGPointMake(0.5, 0.5);
        pool.position = CGPointMake(0, 2);
        pool.zPosition = -0.02;
        [pal addChild:pool];
        [self tintPal];
        return;
    }
    if (self.reducedMotion) return;
    // A gentle float a pixel or two off the floor, whatever else it's doing
    // (on the scene, so the Pal's own actions never cancel it).
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction repeatActionForever:[SKAction customActionWithDuration:2.6 actionBlock:^(SKNode *node, CGFloat t) {
        SKSpriteNode *ghost = weakSelf.pal;
        CGFloat lift = round(1 + sin(t / 2.6 * 2 * M_PI));
        ghost.anchorPoint = CGPointMake(0.5, -lift / 14.0);
    }]] withKey:@"ghostbob"];
}

// A pixel word bubble ("BOO!", "HONK!") above the Pal.
- (void)shoutWord:(NSString *)word {
    SKSpriteNode *pal = self.pal;
    if (!pal) return;
    [[self.roomNode childNodeWithName:@"thought"] removeFromParent];
    int tw = APTextWidth(word, APFontSmall), w = tw + 6, h = 9;
    APCanvas *bubble = APCanvasCreate(w, h + 3);
    APRoundRect(bubble, 0, 0, w, h, 0xFAF6EE);
    APOutlineInside(bubble, 0x3A2A22);
    APPx(bubble, 3, h, 0xFAF6EE); APPx(bubble, 2, h, 0x3A2A22); APPx(bubble, 4, h, 0x3A2A22); APPx(bubble, 3, h + 1, 0x3A2A22);
    APText(bubble, word, 3, 2, APFontSmall, 0x3A2A22);
    SKSpriteNode *node = APSprite(bubble);
    APCanvasFree(bubble);
    node.name = @"thought";
    node.position = CGPointMake(round(pal.position.x + 2), pal.position.y + 13);
    node.zPosition = 960;
    [self.roomNode addChild:node];
    SKAction *pop = self.reducedMotion ? [SKAction waitForDuration:0] :
        [SKAction sequence:@[[SKAction moveByX:0 y:2 duration:0], [SKAction waitForDuration:0.08], [SKAction moveByX:0 y:-2 duration:0]]];
    [node runAction:[SKAction sequence:@[pop, [SKAction waitForDuration:1.6], [SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
}

// The alert frame for a moment, then back to sitting.
- (void)startle:(NSTimeInterval)duration {
    SKSpriteNode *pal = self.pal;
    SKTexture *alert = [self framesForResident:self.resident action:@"alert"].firstObject;
    SKTexture *sit = [self framesForResident:self.resident action:@"sit"].firstObject;
    if (!pal || !alert || !sit) return;
    pal.texture = alert;
    [pal runAction:[SKAction sequence:@[[SKAction waitForDuration:duration], [SKAction setTexture:sit]]] withKey:@"startle"];
}

- (void)playJingle:(APJingle)jingle {
    id<ApolloPalHomeSceneDelegate> delegate = self.homeDelegate;
    if ([delegate respondsToSelector:@selector(palHomeScene:wantsJingle:)]) [delegate palHomeScene:self wantsJingle:jingle];
}

// Pet a ghost: "BOO!" (affectionately), and the lights flicker.
- (void)boo {
    [self startle:0.8];
    [self shoutWord:@"BOO!"];
    [self playJingle:APJingleBoo];
    APHapticPlay(APHapticThump);
    [self floatIcon:@"smallheart" count:2 color:0];
    [self flickerLights];
    [self announce:[NSString stringWithFormat:@"%@ says boo! The lights flicker.", self.resident.name]];
}

// The room's lights stutter (a dark veil flicked on and off).
- (void)flickerLights {
    if (self.reducedMotion) return;
    SKSpriteNode *dark = [SKSpriteNode spriteNodeWithColor:APUIColor(0x0A0614) size:CGSizeMake(APShellWidth, APShellHeight)];
    dark.anchorPoint = CGPointZero;
    dark.zPosition = 940;
    dark.alpha = 0;
    [self.roomNode addChild:dark];
    SKAction *(^flick)(CGFloat, NSTimeInterval) = ^SKAction *(CGFloat a, NSTimeInterval wait) {
        return [SKAction sequence:@[[SKAction fadeAlphaTo:a duration:0], [SKAction waitForDuration:wait]]];
    };
    [dark runAction:[SKAction sequence:@[[SKAction waitForDuration:0.15], flick(0.55, 0.07), flick(0.1, 0.06), flick(0.6, 0.12),
                                         flick(0.2, 0.05), [SKAction fadeAlphaTo:0 duration:0.25], [SKAction removeFromParent]]]];
}

// Pet a goose: HONK.
- (void)honk {
    [self startle:0.6];
    [self shoutWord:@"HONK!"];
    [self playJingle:APJingleHonk];
    APHapticPlay(APHapticPop);
    [self announce:[NSString stringWithFormat:@"%@ honks. Affectionately, probably.", self.resident.name]];
}

// Geese take things. Waddle to a small piece of furniture, pick it up, carry
// it somewhere else entirely, put it down, honk about it. The move is saved
// (it's their house too).
- (BOOL)gooseHeist {
    if (self.readOnly || self.editing || self.reducedMotion || !self.pal) return NO;
    NSMutableArray<APPlacedItem *> *loot = [NSMutableArray array];
    for (APPlacedItem *item in self.layout.items) {
        APItemSpec *spec = item.spec;
        if (spec.layer != APLayerFloor || spec.w != 1 || spec.d != 1 || spec.backWall || spec.petBed) continue;
        if ([spec.identifier isEqualToString:@"boxes"]) continue;
        [loot addObject:item];
    }
    if (!loot.count) return NO;
    APPlacedItem *item = loot[arc4random_uniform((uint32_t)loot.count)];
    // Stand on it (walkable things) or next to it.
    int sx = -1, sy = -1;
    int around[5][2] = {{0, 0}, {-1, 0}, {1, 0}, {0, 1}, {0, -1}};
    for (int i = 0; i < 5 && sx < 0; i++) {
        int x = item.x + around[i][0], y = item.y + around[i][1];
        if ([self.layout isWalkableTileX:x y:y] && ((x == self.palX && y == self.palY) || [self pathFromX:self.palX y:self.palY toX:x y:y])) { sx = x; sy = y; }
    }
    if (sx < 0) return NO;
    // Somewhere else to leave it: a free tile it could stand on, not too near.
    NSMutableArray *spots = [NSMutableArray array];
    for (int y = 1; y < APRows; y++) for (int x = 0; x < APCols; x++) {
        if (abs(x - item.x) + abs(y - item.y) < 3) continue;
        if (![self.layout canPlace:item.spec x:x y:y ignoringUID:item.uid] || ![self.layout isWalkableTileX:x y:y]) continue;
        if (![self pathFromX:sx y:sy toX:x y:y]) continue;
        [spots addObject:@[@(x), @(y)]];
    }
    if (!spots.count) return NO;
    NSArray *spot = spots[arc4random_uniform((uint32_t)spots.count)];
    int dx = [spot[0] intValue], dy = [spot[1] intValue];
    NSString *uid = item.uid, *title = item.spec.title;
    __weak typeof(self) weakSelf = self;
    APDebugLog(@"[PalHome] goose heist: %@ (%d,%d) -> (%d,%d)", item.spec.identifier, item.x, item.y, dx, dy);
    [self walkToX:sx y:sy run:NO completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        APPlacedItem *target = [strongSelf.layout itemWithUID:uid];
        SKNode *node = strongSelf.itemNodes[uid];
        if (!strongSelf || !target || !node || strongSelf.editing) { [strongSelf scheduleBrain]; return; }
        // Snatch: the piece vanishes from its spot and appears in the beak.
        strongSelf.heistUID = uid;
        node.hidden = YES;
        SKSpriteNode *carried = APSprite(target.lit.canvas);
        carried.name = @"loot";
        carried.anchorPoint = CGPointMake(0.5, 0);
        carried.position = CGPointMake(11, 3);
        carried.zPosition = 0.02;
        [strongSelf.pal addChild:carried];
        strongSelf.pal.xScale = dx < strongSelf.palX ? -1 : dx > strongSelf.palX ? 1 : strongSelf.pal.xScale;
        [strongSelf startle:0.4];
        APHapticPlay(APHapticSelect);
        [strongSelf runAction:[SKAction sequence:@[[SKAction waitForDuration:0.5], [SKAction runBlock:^{
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (![innerSelf.heistUID isEqualToString:uid]) return;
            [innerSelf walkToX:dx y:dy run:YES completion:^{
                __strong typeof(weakSelf) finalSelf = weakSelf;
                if (![finalSelf.heistUID isEqualToString:uid]) return;
                [[finalSelf.pal childNodeWithName:@"loot"] removeFromParent];
                finalSelf.heistUID = nil;
                // Step beside the spot first unless it's something to stand on,
                // so the rebuild below keeps the goose here.
                APItemSpec *spec = [APCatalog itemWithID:[finalSelf.layout itemWithUID:uid].spec.identifier ?: @""];
                if (!spec.walkable) {
                    int sides[4][2] = {{-1, 0}, {1, 0}, {0, 1}, {0, -1}};
                    for (int i = 0; i < 4; i++) {
                        int nx = dx + sides[i][0], ny = dy + sides[i][1];
                        if ([finalSelf.layout isWalkableTileX:nx y:ny]) { finalSelf.palX = nx; finalSelf.palY = ny; break; }
                    }
                }
                // Put it down here, for good (commitRoom rebuilds and saves).
                [finalSelf updateRecord:uid change:^(NSMutableDictionary *record) { record[@"x"] = @(dx); record[@"y"] = @(dy); }];
                APHapticPlay(APHapticPlace);
                [finalSelf honk];
                [finalSelf announce:[NSString stringWithFormat:@"%@ moved the %@. No reason given.", finalSelf.resident.name, title]];
            }];
        }]]] withKey:@"heist"];
    }];
    return YES;
}

// Interrupted mid-heist (petted, fed, decorating): drop it back where it was.
- (void)abandonHeist {
    if (!self.heistUID) return;
    self.itemNodes[self.heistUID].hidden = NO;
    [[self.pal childNodeWithName:@"loot"] removeFromParent];
    [self removeActionForKey:@"heist"];
    self.heistUID = nil;
}

#pragma mark - Haunted Manor: things that go bump

// In a Haunted Manor room, every so often something spooky happens, Scooby-Doo
// style, picked from what's actually in the room: eyes peeking out of the
// dark beside the furniture, a book sliding off the shelf, the portrait
// tilting by itself, a sheet ghost popping up behind the armchair, the spider
// dropping from its web, a bat swooping through, the lights stuttering. The
// Pal reacts (a goose honks at it; a ghost Pal just says BOO back).

- (BOOL)isHaunted { return [self.layout.style.identifier isEqualToString:@"manor"]; }

- (void)scheduleSpooks {
    [self removeActionForKey:@"spooks"];
    if (!self.isHaunted || self.reducedMotion) return;
    NSTimeInterval wait = 27, range = 25; // 15-40s
#if APOLLO_SIM_BUILD
    // Sim testing: APOLLO_SIM_SPOOK_INTERVAL=4 makes the manor busy.
    double debug = [NSProcessInfo.processInfo.environment[@"APOLLO_SIM_SPOOK_INTERVAL"] doubleValue];
    if (debug > 0) { wait = debug; range = 0; }
#endif
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:wait withRange:range],
        [SKAction runBlock:^{ [weakSelf spook]; }]]]] withKey:@"spooks"];
}

- (nullable APPlacedItem *)randomItemWhere:(BOOL (^)(APPlacedItem *item))test {
    NSMutableArray *found = [NSMutableArray array];
    for (APPlacedItem *item in self.layout.items) if (test(item)) [found addObject:item];
    return found.count ? found[arc4random_uniform((uint32_t)found.count)] : nil;
}

// Shell coordinates (top-left origin, y down) → room node coordinates.
static CGPoint APShellPoint(CGFloat x, CGFloat y) { return CGPointMake(x, APShellHeight - y); }

- (void)spook {
    if (self.editing || !self.isHaunted || !self.pal) return;
    __weak typeof(self) weakSelf = self;
    NSMutableArray<void (^)(void)> *events = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    void (^add)(NSString *, void (^)(void)) = ^(NSString *name, void (^event)(void)) { [names addObject:name]; [events addObject:event]; };
    APPlacedItem *furniture = [self randomItemWhere:^BOOL(APPlacedItem *i) { return i.spec.layer == APLayerFloor && i.spec.pixelHeight >= 20; }];
    if (furniture) add(@"eyes", ^{ [weakSelf eyesInTheDarkBeside:furniture]; });
    if (furniture) add(@"sheet", ^{ [weakSelf sheetPeekBehind:furniture]; });
    APPlacedItem *books = [self randomItemWhere:^BOOL(APPlacedItem *i) {
        return [i.spec.identifier isEqualToString:@"bookshelf"] || [i.spec.identifier isEqualToString:@"shelf.books"] || [i.spec.identifier isEqualToString:@"bookstack"];
    }];
    if (books) add(@"book", ^{ [weakSelf bookFallsFrom:books]; });
    APPlacedItem *art = [self randomItemWhere:^BOOL(APPlacedItem *i) { return i.spec.layer == APLayerWall && ([i.spec.identifier hasPrefix:@"art."] || [i.spec.identifier hasPrefix:@"clock"]); }];
    if (art) add(@"tilt", ^{ [weakSelf tiltItem:art]; });
    APPlacedItem *web = [self randomItemWhere:^BOOL(APPlacedItem *i) { return [i.spec.identifier isEqualToString:@"spiderweb"]; }];
    if (web) add(@"spider", ^{ [weakSelf spiderDropsFrom:web]; });
    add(@"bat", ^{ [weakSelf batSwoop]; });
    add(@"lights", ^{ [weakSelf flickerLights]; APHapticPlay(APHapticToggle); });
    uint32_t pick = arc4random_uniform((uint32_t)events.count);
    APDebugLog(@"[PalHome] spook: %@ (of %lu)", names[pick], (unsigned long)events.count);
    events[pick]();
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:0.6], [SKAction runBlock:^{ [weakSelf reactToSpook]; }]]]];
}

- (void)reactToSpook {
    if (!self.pal || self.toy || self.editing || self.palMode == APPalSleeping || self.palMode == APPalPlaying) return;
    if (self.isGhost) { [self shoutWord:@"BOO!"]; [self floatIcon:@"smallheart" count:1 color:0]; return; }
    if (self.isGoose) { [self honk]; return; }
    if (self.palMode != APPalIdle) return;
    [self startle:0.7];
    [self shoutWord:@"!"];
    APHapticPlay(APHapticHop);
    if (arc4random_uniform(2)) {
        __weak typeof(self) weakSelf = self;
        [self runAction:[SKAction sequence:@[[SKAction waitForDuration:0.7], [SKAction runBlock:^{ [weakSelf ambleRunning:YES]; }]]]];
    }
}

static SKTexture *APEyesTexture(int look) {
    // look: -1 left, 1 right, 0 blink.
    APCanvas *c = APCanvasCreate(7, 2);
    for (int e = 0; e < 2; e++) {
        int x = e * 4;
        if (look == 0) { APHLine(c, x, 1, 3, 0xF8E890); continue; }
        APRect(c, x, 0, 3, 2, 0xFAF2A8);
        APRect(c, x + (look < 0 ? 0 : 2), 0, 1, 2, 0x140A04);
    }
    SKTexture *t = APTexture(c);
    APCanvasFree(c);
    return t;
}

// A pair of eyes in the dark beside a piece of furniture: blink, look, gone.
- (void)eyesInTheDarkBeside:(APPlacedItem *)item {
    BOOL left = arc4random_uniform(2);
    int x = left ? item.px - 8 : item.px + item.spec.pixelWidth + 1;
    if (x < APSideWall + 1) x = item.px + item.spec.pixelWidth + 1;
    if (x > APShellWidth - APSideWall - 8) x = item.px - 8;
    int y = item.py + item.spec.pixelHeight - 12;
    SKTexture *l = APEyesTexture(-1), *r = APEyesTexture(1), *shut = APEyesTexture(0);
    SKSpriteNode *eyes = [SKSpriteNode spriteNodeWithTexture:left ? r : l];
    eyes.anchorPoint = CGPointZero;
    eyes.position = APShellPoint(x, y);
    eyes.zPosition = item.z - 0.01;
    eyes.alpha = 0;
    [self.roomNode addChild:eyes];
    SKAction *blink = [SKAction sequence:@[[SKAction setTexture:shut], [SKAction waitForDuration:0.12], [SKAction setTexture:left ? r : l]]];
    [eyes runAction:[SKAction sequence:@[[SKAction fadeInWithDuration:0.5], [SKAction waitForDuration:0.7], blink, [SKAction waitForDuration:0.5],
        [SKAction setTexture:left ? l : r], [SKAction waitForDuration:0.6], [SKAction setTexture:left ? r : l], [SKAction waitForDuration:0.3], blink,
        [SKAction waitForDuration:0.4], [SKAction fadeOutWithDuration:0.25], [SKAction removeFromParent]]]];
}

// A little sheet ghost pops up from behind the furniture, looks, ducks.
- (void)sheetPeekBehind:(APPlacedItem *)item {
    APCanvas *c = APCanvasCreate(11, 11);
    APEllipse(c, 0, 0, 11, 9, 0xF2F2FA);
    APRect(c, 0, 5, 11, 6, 0xF2F2FA);
    for (int x = 0; x < 11; x += 3) APPx(c, x, 10, 0);
    APPx(c, 3, 4, 0x1A161E); APPx(c, 3, 5, 0x1A161E); APPx(c, 7, 4, 0x1A161E); APPx(c, 7, 5, 0x1A161E);
    APOutlineInside(c, 0x2A2834);
    SKSpriteNode *sheet = APSprite(c);
    APCanvasFree(c);
    int x = item.px + item.spec.pixelWidth / 2 - 5;
    CGPoint hidden = APShellPoint(x, item.py + 12), up = APShellPoint(x, item.py - 7);
    sheet.position = hidden;
    sheet.zPosition = item.z - 0.02;
    [self.roomNode addChild:sheet];
    [sheet runAction:[SKAction sequence:@[APPixelMove(hidden, up, 0.25), [SKAction waitForDuration:0.25],
        [SKAction moveByX:-1 y:0 duration:0], [SKAction waitForDuration:0.3], [SKAction moveByX:2 y:0 duration:0], [SKAction waitForDuration:0.3],
        [SKAction moveByX:-1 y:0 duration:0], [SKAction waitForDuration:0.3], APPixelMove(up, hidden, 0.12), [SKAction removeFromParent]]]];
}

// A book slides off the shelf and lands on the floor in front.
- (void)bookFallsFrom:(APPlacedItem *)item {
    uint32_t colours[] = {0x8A2A2A, 0x2A4A8A, 0x3A6A3A, 0x6A4A8A};
    uint32_t colour = colours[arc4random_uniform(4)];
    APCanvas *up = APCanvasCreate(2, 5), *flat = APCanvasCreate(5, 2);
    APRect(up, 0, 0, 2, 5, colour); APPx(up, 1, 1, 0xE8D8B0);
    APRect(flat, 0, 0, 5, 2, colour); APPx(flat, 1, 0, 0xE8D8B0);
    SKTexture *flatTexture = APTexture(flat);
    SKSpriteNode *book = APSprite(up);
    APCanvasFree(up); APCanvasFree(flat);
    int x = item.px + 3 + (int)arc4random_uniform((uint32_t)MAX(1, item.spec.pixelWidth - 8));
    int y = item.py + 8 + (int)arc4random_uniform((uint32_t)MAX(1, item.spec.pixelHeight - 24));
    int floorY = MIN(APFloorTop + APRows * APTile - 4, item.py + item.spec.pixelHeight + 2);
    CGPoint from = APShellPoint(x, y), to = APShellPoint(x + 3, floorY);
    book.position = from;
    book.zPosition = item.z + 0.5;
    [self.roomNode addChild:book];
    SKAction *fall = [SKAction customActionWithDuration:0.4 actionBlock:^(SKNode *node, CGFloat elapsed) {
        CGFloat p = elapsed / 0.4;
        node.position = CGPointMake(round(from.x + (to.x - from.x) * p), round(from.y + (to.y - from.y) * p * p));
    }];
    [book runAction:[SKAction sequence:@[[SKAction moveByX:1 y:0 duration:0], [SKAction waitForDuration:0.3], fall,
        [SKAction setTexture:flatTexture resize:YES], [SKAction runBlock:^{ APHapticPlay(APHapticThump); }],
        [SKAction moveByX:0 y:2 duration:0.06], [SKAction moveByX:0 y:-2 duration:0.06],
        [SKAction waitForDuration:2.5], [SKAction fadeOutWithDuration:0.4], [SKAction removeFromParent]]]];
}

// A painting (or clock) tilts by itself, hangs crooked, then rights itself.
- (void)tiltItem:(APPlacedItem *)item {
    SKNode *node = self.itemNodes[item.uid];
    if (!node) return;
    CGFloat angle = arc4random_uniform(2) ? 0.14 : -0.14;
    [node runAction:[SKAction sequence:@[[SKAction rotateToAngle:angle * 0.4 duration:0.08], [SKAction rotateToAngle:angle duration:0.5],
        [SKAction waitForDuration:1.4], [SKAction rotateToAngle:-angle * 0.15 duration:0.12], [SKAction rotateToAngle:0 duration:0.1]]]];
}

// The spider drops down on a thread, dangles, climbs back.
- (void)spiderDropsFrom:(APPlacedItem *)item {
    CGPoint top = APShellPoint(item.px + 8, item.py + 9);
    int drop = 26 + (int)arc4random_uniform(14);
    SKSpriteNode *thread = [SKSpriteNode spriteNodeWithColor:APUIColor(0xC8C4CC) size:CGSizeMake(1, 1)];
    thread.anchorPoint = CGPointMake(0, 1);
    thread.position = top;
    thread.zPosition = 930;
    APCanvas *c = APCanvasCreate(5, 4);
    APRect(c, 1, 1, 3, 2, 0x1A161E);
    APPx(c, 0, 0, 0x1A161E); APPx(c, 4, 0, 0x1A161E); APPx(c, 0, 3, 0x1A161E); APPx(c, 4, 3, 0x1A161E);
    APPx(c, 2, 1, 0xE84A4A);
    SKSpriteNode *spider = APSprite(c);
    APCanvasFree(c);
    spider.anchorPoint = CGPointMake(0.5, 1);
    spider.zPosition = 931;
    [self.roomNode addChild:thread];
    [self.roomNode addChild:spider];
    SKAction *(^lengthTo)(CGFloat, CGFloat, NSTimeInterval) = ^SKAction *(CGFloat from, CGFloat to, NSTimeInterval d) {
        return [SKAction customActionWithDuration:d actionBlock:^(SKNode *node, CGFloat elapsed) {
            CGFloat len = round(from + (to - from) * (elapsed / d));
            thread.size = CGSizeMake(1, MAX(1, len));
            spider.position = CGPointMake(top.x + 0.5, top.y - len);
        }];
    };
    SKAction *dangle = [SKAction customActionWithDuration:1.2 actionBlock:^(SKNode *node, CGFloat elapsed) {
        CGFloat len = drop + round(sin(elapsed * 9) * 1.5);
        thread.size = CGSizeMake(1, len);
        spider.position = CGPointMake(top.x + 0.5, top.y - len);
    }];
    [self runAction:[SKAction sequence:@[lengthTo(1, drop, 0.9), dangle, lengthTo(drop, 1, 1.1), [SKAction runBlock:^{
        [thread removeFromParent];
        [spider removeFromParent];
    }]]]];
}

// A bat swoops through the room.
- (void)batSwoop {
    NSMutableArray<SKTexture *> *wings = [NSMutableArray array];
    for (int frame = 0; frame < 2; frame++) {
        APCanvas *bat = APCanvasCreate(7, 4);
        uint32_t ink = 0x1A1020;
        APRect(bat, 3, 1, 1, 2, ink); APPx(bat, 2, 1, ink); APPx(bat, 4, 1, ink);
        if (frame == 0) { APPx(bat, 1, 0, ink); APPx(bat, 0, 0, ink); APPx(bat, 5, 0, ink); APPx(bat, 6, 0, ink); }
        else { APPx(bat, 1, 2, ink); APPx(bat, 0, 3, ink); APPx(bat, 5, 2, ink); APPx(bat, 6, 3, ink); }
        APPx(bat, 2, 1, 0xF0D040); APPx(bat, 4, 1, 0xF0D040);
        [wings addObject:APTexture(bat)];
        APCanvasFree(bat);
    }
    SKSpriteNode *bat = [SKSpriteNode spriteNodeWithTexture:wings[0]];
    bat.anchorPoint = CGPointZero;
    bat.zPosition = 945;
    BOOL leftward = arc4random_uniform(2);
    CGFloat x0 = leftward ? APShellWidth - APSideWall - 2 : APSideWall - 5, x1 = leftward ? APSideWall - 8 : APShellWidth - APSideWall + 2;
    CGFloat y0 = APShellHeight - (APCeiling + 12 + arc4random_uniform(20));
    NSTimeInterval d = 2.0;
    bat.position = CGPointMake(x0, y0);
    [self.roomNode addChild:bat];
    [bat runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:wings timePerFrame:0.08]]];
    [bat runAction:[SKAction sequence:@[[SKAction customActionWithDuration:d actionBlock:^(SKNode *node, CGFloat elapsed) {
        CGFloat p = elapsed / d;
        node.position = CGPointMake(round(x0 + (x1 - x0) * p), round(y0 - sin(p * M_PI) * 40 + sin(elapsed * 9) * 3));
    }], [SKAction removeFromParent]]]];
}

#pragma mark - Toys: Beacon Ball and the Wand

// Shell (top-left, y down) ↔ room node coordinates, and the floor tile under a point.
- (CGPoint)nodePointForShell:(CGPoint)p { return CGPointMake(p.x, APShellHeight - p.y); }
- (CGPoint)floorTileForShell:(CGPoint)p {
    int tx = MAX(0, MIN(APCols - 1, (int)floor((p.x - APSideWall) / APTile)));
    int ty = MAX(0, MIN(APRows - 1, (int)floor((p.y - APFloorTop) / APTile)));
    return CGPointMake(tx, ty);
}
// The floor area, in shell coordinates (things land inside it).
- (CGPoint)clampToFloor:(CGPoint)p {
    return CGPointMake(MAX(APSideWall + 4, MIN(APShellWidth - APSideWall - 4, p.x)),
                       MAX(APFloorTop + 6, MIN(APFloorTop + APRows * APTile - 4, p.y)));
}

- (void)beginToy:(NSString *)toy {
    [self stopGame];
    SKSpriteNode *pal = self.pal;
    if (!pal || self.editing) return;
    if (self.palMode == APPalSleeping) [self wakeUp];
    [pal removeAllActions];
    [self removeActionForKey:@"brain"];
    [[self.roomNode childNodeWithName:@"yarn"] removeFromParent];
    self.palMode = APPalIdle;
    self.toy = toy;
    self.toyScore = 0;
    [self pokeToyIdle];
}

// A game ends on its own after a while without you.
- (void)pokeToyIdle {
    __weak typeof(self) weakSelf = self;
    [self removeActionForKey:@"toyIdle"];
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:25], [SKAction runBlock:^{ [weakSelf stopGame]; }]]] withKey:@"toyIdle"];
}

- (void)stopGame {
    NSString *toy = self.toy;
    if (!toy) return;
    self.toy = nil;
    self.ballFlying = NO;
    [self removeActionForKey:@"toyIdle"];
    for (NSString *name in @[@"beaconball", @"wand"]) {
        SKNode *node = [self.roomNode childNodeWithName:name];
        [node removeAllActions];
        [node runAction:[SKAction sequence:@[[SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
    }
    if (self.toyScore > 0) [self floatIcon:@"smallheart" count:2 color:0];
    [self settlePal];
    id<ApolloPalHomeSceneDelegate> delegate = self.homeDelegate;
    if ([delegate respondsToSelector:@selector(palHomeScene:gameEnded:score:)]) [delegate palHomeScene:self gameEnded:toy score:self.toyScore];
}

#pragma mark Beacon Ball

- (void)startBallGame {
    [self beginToy:@"ball"];
    if (!self.toy) return;
    APCanvas *c = APCanvasCreate(6, 6);
    APEllipse(c, 0, 0, 6, 6, 0xE84A4A);
    APEllipse(c, 1, 1, 3, 2, 0xF88A7A);
    APPx(c, 1, 1, 0xFFF0E8);
    APOutlineInside(c, 0x5A1414);
    SKSpriteNode *ball = APSprite(c);
    APCanvasFree(c);
    ball.name = @"beaconball";
    ball.anchorPoint = CGPointMake(0.5, 0);
    ball.position = CGPointMake(self.pal.position.x + 14, self.pal.position.y);
    ball.zPosition = self.pal.zPosition + 0.2;
    [self.roomNode addChild:ball];
    [self announce:@"Beacon Ball! Tap anywhere in the room to throw it."];
    [self chaseBall];
}

// The ball arcs to a point (shell coordinates), bounces once, then the Pal goes after it.
- (void)throwBallTo:(CGPoint)shellPoint fromPlayer:(BOOL)fromPlayer {
    SKSpriteNode *ball = (SKSpriteNode *)[self.roomNode childNodeWithName:@"beaconball"];
    if (!ball || ![self.toy isEqualToString:@"ball"]) return;
    if (fromPlayer) [self pokeToyIdle];
    [ball removeAllActions];
    self.ballFlying = YES;
    CGPoint from = ball.position, to = [self nodePointForShell:[self clampToFloor:shellPoint]];
    double distance = hypot(to.x - from.x, to.y - from.y), d = MAX(0.35, MIN(0.9, distance / 110)), h = 10 + distance * 0.18;
    SKAction *arc = [SKAction customActionWithDuration:d actionBlock:^(SKNode *node, CGFloat t) {
        CGFloat f = t / d;
        node.position = CGPointMake(round(from.x + (to.x - from.x) * f), round(from.y + (to.y - from.y) * f + sin(f * M_PI) * h));
    }];
    SKAction *bounce = [SKAction sequence:@[[SKAction moveByX:0 y:4 duration:0.08], [SKAction moveByX:0 y:-4 duration:0.08]]];
    __weak typeof(self) weakSelf = self;
    ball.zPosition = 960; // in the air, over everything
    [ball runAction:[SKAction sequence:@[arc, [SKAction runBlock:^{
        ball.zPosition = [weakSelf zForFeet:to] + 0.2;
        APHapticPlay(APHapticTap);
    }], bounce, [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.ballFlying = NO;
        [strongSelf chaseBall];
    }]]]];
}

- (void)chaseBall {
    SKSpriteNode *ball = (SKSpriteNode *)[self.roomNode childNodeWithName:@"beaconball"];
    if (!ball || !self.pal || ![self.toy isEqualToString:@"ball"] || self.ballFlying) return;
    CGPoint tile = [self floorTileForShell:CGPointMake(ball.position.x, APShellHeight - ball.position.y)];
    int tx = (int)tile.x, ty = (int)tile.y;
    if (![self.layout isWalkableTileX:tx y:ty]) [self nearestWalkableFromX:tx y:ty outX:&tx outY:&ty];
    __weak typeof(self) weakSelf = self;
    [self walkToX:tx y:ty run:YES completion:^{ [weakSelf bonkBall]; }];
}

// Bonk! The Pal bats it away to somewhere new, and chases it again.
- (void)bonkBall {
    SKSpriteNode *ball = (SKSpriteNode *)[self.roomNode childNodeWithName:@"beaconball"];
    SKSpriteNode *pal = self.pal;
    if (!ball || !pal || ![self.toy isEqualToString:@"ball"] || self.ballFlying) return;
    self.toyScore++;
    APHapticPlay(APHapticPop);
    pal.xScale = ball.position.x < pal.position.x ? -1 : 1;
    CGPoint p = pal.position;
    [pal runAction:[SKAction sequence:@[[SKAction moveTo:CGPointMake(p.x, p.y + 4) duration:0.08], [SKAction moveTo:p duration:0.1]]]];
    if (self.toyScore % 3 == 0) [self floatIcon:@"smallheart" count:1 color:0];
    NSMutableArray *spots = [NSMutableArray array];
    for (int y = 0; y < APRows; y++) for (int x = 0; x < APCols; x++) {
        int d = abs(x - self.palX) + abs(y - self.palY);
        if (d >= 2 && d <= 5 && [self.layout isWalkableTileX:x y:y]) [spots addObject:@[@(x), @(y)]];
    }
    if (!spots.count) return;
    NSArray *spot = spots[arc4random_uniform((uint32_t)spots.count)];
    CGPoint feet = [self feetForTileX:[spot[0] intValue] y:[spot[1] intValue]];
    [self throwBallTo:CGPointMake(feet.x + 4, APShellHeight - feet.y) fromPlayer:NO];
}

#pragma mark The Wand

- (void)startWandGame {
    [self beginToy:@"wand"];
    if (!self.toy) return;
    APCanvas *c = APIconCanvas(@"wand");
    SKSpriteNode *wand = APSprite(c);
    APCanvasFree(c);
    wand.name = @"wand";
    wand.anchorPoint = CGPointMake(0.85, 0.85); // the star tip sits at your finger
    wand.zPosition = 970;
    CGPoint start = [self feetForTileX:MIN(APCols - 1, self.palX + 2) y:self.palY];
    wand.position = CGPointMake(start.x, start.y + 18);
    [self.roomNode addChild:wand];
    // A slow sparkle off the tip.
    __weak typeof(self) weakSelf = self;
    [wand runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction waitForDuration:0.18], [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SKNode *w = [strongSelf.roomNode childNodeWithName:@"wand"];
        if (!w) return;
        SKSpriteNode *spark = [SKSpriteNode spriteNodeWithColor:[UIColor colorWithRed:1 green:0.93 blue:0.55 alpha:1] size:CGSizeMake(1, 1)];
        spark.position = CGPointMake(round(w.position.x + arc4random_uniform(5) - 2.0), round(w.position.y - 1 - arc4random_uniform(3)));
        spark.zPosition = 969;
        [strongSelf.roomNode addChild:spark];
        [spark runAction:[SKAction sequence:@[[SKAction group:@[[SKAction moveByX:0 y:-6 duration:0.6], [SKAction fadeOutWithDuration:0.6]]],
                                              [SKAction removeFromParent]]]];
    }]]]]];
    self.wandTile = CGPointMake(-1, -1);
    [self announce:@"The wand! Drag around the room and your Pal will chase it."];
    [self chaseWand];
}

- (void)moveWandToShell:(CGPoint)shellPoint {
    SKNode *wand = [self.roomNode childNodeWithName:@"wand"];
    if (!wand) return;
    CGPoint clamped = CGPointMake(MAX(APSideWall + 2, MIN(APShellWidth - APSideWall - 2, shellPoint.x)),
                                  MAX(APCeiling + 4, MIN(APFloorTop + APRows * APTile - 2, shellPoint.y)));
    wand.position = [self nodePointForShell:clamped];
    [self pokeToyIdle];
    [self chaseWand];
}

// Head for the floor under the wand (or the front of the wall, if it's up high).
- (void)chaseWand {
    SKNode *wand = [self.roomNode childNodeWithName:@"wand"];
    if (!wand || !self.pal || ![self.toy isEqualToString:@"wand"]) return;
    CGPoint shell = CGPointMake(wand.position.x, APShellHeight - wand.position.y + 10);
    CGPoint tile = [self floorTileForShell:shell];
    int tx = (int)tile.x, ty = (int)tile.y;
    if (![self.layout isWalkableTileX:tx y:ty]) [self nearestWalkableFromX:tx y:ty outX:&tx outY:&ty];
    if (CGPointEqualToPoint(self.wandTile, CGPointMake(tx, ty)) && self.palMode == APPalWalking) return; // already on the way
    self.wandTile = CGPointMake(tx, ty);
    if (tx == self.palX && ty == self.palY) { [self pounceAtWand]; return; }
    __weak typeof(self) weakSelf = self;
    [self walkToX:tx y:ty run:YES completion:^{ [weakSelf pounceAtWand]; }];
}

// Caught up: a leap at the sparkly end (not too often).
- (void)pounceAtWand {
    SKNode *wand = [self.roomNode childNodeWithName:@"wand"];
    SKSpriteNode *pal = self.pal;
    if (!wand || !pal || ![self.toy isEqualToString:@"wand"]) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastPounce < 0.9) return;
    self.lastPounce = now;
    self.toyScore++;
    APHapticPlay(APHapticHop);
    pal.xScale = wand.position.x < pal.position.x ? -1 : 1;
    CGPoint p = pal.position;
    CGFloat leap = MIN(14, MAX(5, (wand.position.y - p.y) * 0.4));
    SKTexture *alert = [self framesForResident:self.resident action:@"alert"].firstObject;
    SKTexture *sit = [self framesForResident:self.resident action:@"sit"].firstObject;
    NSMutableArray *steps = [NSMutableArray array];
    if (alert) [steps addObject:[SKAction setTexture:alert]];
    [steps addObjectsFromArray:@[[SKAction moveTo:CGPointMake(p.x, p.y + leap) duration:0.14], [SKAction moveTo:p duration:0.16]]];
    if (sit) [steps addObject:[SKAction setTexture:sit]];
    [pal runAction:[SKAction sequence:steps] withKey:@"pounce"];
    if (self.toyScore % 3 == 0) [self floatIcon:@"smallheart" count:1 color:0];
}

#pragma mark - Feeding

// Supper: the Pal trots to the Food & Water bowls if there are some (or a
// dish appears beside them), crouches over it and eats, crumbs and all. The
// snack is the species' own (fish, bone, yuzu…). Stats are the store's job;
// this is just the show.
- (BOOL)feedResident {
    [self stopGame];
    SKSpriteNode *pal = self.pal;
    APPlacedItem *preferred = self.feedingSpot;
    self.feedingSpot = nil;
    if (!pal || self.editing) return NO;
    if (self.palMode == APPalSleeping) [self wakeUp];
    [pal removeAllActions];
    [self removeActionForKey:@"brain"];
    [[self.roomNode childNodeWithName:@"dish"] removeFromParent];
    APPlacedItem *bowl = nil;
    BOOL (^reachable)(APPlacedItem *) = ^BOOL(APPlacedItem *item) {
        return [self.layout isWalkableTileX:item.x y:item.y] && [self pathFromX:self.palX y:self.palY toX:item.x y:item.y] != nil;
    };
    if (preferred && [self.layout.items containsObject:preferred] && reachable(preferred)) bowl = preferred;
    for (NSString *kind in @[@"bowls", @"candybowl"]) {
        for (APPlacedItem *item in self.layout.items) {
            if (bowl) break;
            if ([item.spec.identifier isEqualToString:kind] && reachable(item)) bowl = item;
        }
    }
    BOOL candy = [bowl.spec.identifier isEqualToString:@"candybowl"];
    __weak typeof(self) weakSelf = self;
    void (^eat)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf.pal) return;
        [strongSelf eatAtBowl:bowl != nil candy:candy];
    };
    if (bowl && !self.reducedMotion && (bowl.x != self.palX || bowl.y != self.palY)) {
        [self walkToX:bowl.x y:bowl.y run:NO completion:eat];
    } else {
        eat();
    }
    return candy;
}

- (void)eatAtBowl:(BOOL)atBowl candy:(BOOL)candy {
    SKSpriteNode *pal = self.pal;
    NSString *snack = [APSpecies speciesWithID:self.resident.species].snackThought ?: @"t.fish";
    BOOL facingLeft = pal.xScale < 0;
    // The dish (or just the snack, in the bowl), in front of the nose.
    APCanvas *dish = APCanvasCreate(9, 6);
    if (!atBowl) {
        APRect(dish, 0, 4, 9, 2, 0xE8E4DC);
        APHLine(dish, 1, 5, 7, 0xB8B0A4);
    }
    if (candy) {
        // A wrapped sweet: twisted ends either side.
        uint32_t wrapper = (uint32_t[]){0xE84A5A, 0x5AB0E8, 0xF2C040, 0x9A5AE0}[arc4random_uniform(4)];
        APRect(dish, 3, 3, 3, 3, wrapper); APPx(dish, 3, 3, APShade(wrapper, 1.3f));
        APPx(dish, 2, 3, wrapper); APPx(dish, 1, 2, wrapper); APPx(dish, 1, 4, wrapper);
        APPx(dish, 6, 4, wrapper); APPx(dish, 7, 3, wrapper); APPx(dish, 7, 5, wrapper);
    } else {
        APCanvas *food = APIconCanvas(snack);
        if (food) { APDraw(dish, food, (9 - food->w) / 2, MAX(0, 4 - food->h + 1), NO); APCanvasFree(food); }
    }
    SKSpriteNode *plate = APSprite(dish);
    APCanvasFree(dish);
    plate.name = @"dish";
    plate.position = CGPointMake(pal.position.x + (facingLeft ? -15 : 6), pal.position.y);
    plate.zPosition = pal.zPosition + 0.05;
    [self.roomNode addChild:plate];
    self.palMode = APPalPlaying; // busy: the brain waits, yuzu tumble
    NSArray<SKTexture *> *crouch = [self framesForResident:self.resident action:@"crouch"];
    NSTimeInterval meal = self.reducedMotion ? 0.6 : 2.4;
    if (crouch.count && !self.reducedMotion) {
        [pal runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:crouch timePerFrame:0.12]] withKey:@"eat"];
    }
    APHapticPlay(APHapticNom);
    __weak typeof(self) weakSelf = self;
    // Nom, nom: the snack gets smaller, then it's gone.
    [plate runAction:[SKAction sequence:@[[SKAction waitForDuration:meal * 0.5], [SKAction runBlock:^{ plate.alpha = 0.6; }],
                                          [SKAction waitForDuration:meal * 0.5], [SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:meal], [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.pal removeActionForKey:@"eat"];
        [strongSelf floatIcon:@"smallheart" count:2 color:0];
        [strongSelf settlePal];
    }]]] withKey:@"meal"];
}

- (void)restResident {
    [self stopGame];
    if (!self.pal || self.editing) return;
    [self napAnnounce:YES];
}

- (void)napAnnounce:(BOOL)announce {
    APPlacedItem *best = nil;
    NSUInteger bestLength = NSUIntegerMax;
    for (APPlacedItem *bed in self.layout.petBeds) {
        int tx = bed.x + bed.spec.w / 2, ty = bed.y + bed.spec.d - 1;
        NSArray *path = [self pathFromX:self.palX y:self.palY toX:tx y:ty];
        if (path && path.count < bestLength) { best = bed; bestLength = path.count; }
    }
    if (!best) {
        // No reachable bed: curl up right here.
        [self.pal removeAllActions];
        [self sleepHereAnnounce:announce];
        return;
    }
    int tx = best.x + best.spec.w / 2, ty = best.y + best.spec.d - 1;
    __weak typeof(self) weakSelf = self;
    if (announce) [self announce:[NSString stringWithFormat:@"%@ trots off for a nap.", self.resident.name]];
    [self walkToX:tx y:ty run:NO completion:^{ [weakSelf sleepInBed:best announce:NO hop:YES]; }];
}

- (void)sleepHereAnnounce:(BOOL)announce {
    self.palMode = APPalSleeping;
    self.palBedUID = nil;
    [self startSleepAnimation];
    if (announce) [self announce:[NSString stringWithFormat:@"%@ curls up for a nap. Pet them to wake up.", self.resident.name]];
}

// `hop`: hop in (with the same landing haptic as a sofa); NO when restoring a
// sleeping Pal after a rebuild.
- (void)sleepInBed:(APPlacedItem *)bed announce:(BOOL)announce hop:(BOOL)hop {
    SKSpriteNode *pal = self.pal;
    if (!pal || !bed) return;
    [pal removeAllActions];
    self.palMode = APPalSleeping;
    self.palBedUID = bed.uid;
    int sx = [bed shellXForLocalX:bed.spec.sleepX], sy = [bed shellYForLocalY:bed.spec.sleepY];
    CGPoint to = CGPointMake(sx, APShellHeight - sy), from = pal.position;
    pal.zPosition = bed.z + 0.1;
    pal.xScale = bed.flip ? -1 : 1;
    if (hop && !self.reducedMotion && hypot(to.x - from.x, to.y - from.y) > 1) {
        __weak typeof(self) weakSelf = self;
        pal.texture = [self framesForResident:self.resident action:@"sit"].firstObject;
        [pal runAction:[SKAction sequence:@[[self hopFrom:from to:to], [SKAction runBlock:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf.palMode != APPalSleeping) return;
            APHapticPlay(APHapticHop);
            [strongSelf tintPal];
            [strongSelf startSleepAnimation];
        }]]]];
    } else {
        pal.position = to;
        if (hop) APHapticPlay(APHapticHop);
        [self tintPal];
        [self startSleepAnimation];
    }
    if (announce) [self announce:[NSString stringWithFormat:@"%@ is having a cosy nap.", self.resident.name]];
}

- (void)startSleepAnimation {
    SKSpriteNode *pal = self.pal;
    [self removeActionForKey:@"brain"];
    NSArray *frames = [self framesForResident:self.resident action:@"sleep"];
    if (frames.count) pal.texture = frames.firstObject;
    if (self.reducedMotion) return;
    if (frames.count) [pal runAction:[SKAction repeatActionForever:[SKAction animateWithTextures:frames timePerFrame:1.6 / frames.count]]];
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction runBlock:^{
        [weakSelf floatIcon:@"z" count:1 color:0];
    }], [SKAction waitForDuration:2.2]]]] withKey:@"zzz"];
    // Dozes, then wakes by itself if nobody's around.
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:40 withRange:30], [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf.palMode == APPalSleeping && !strongSelf.editing) [strongSelf wakeUp];
    }]]] withKey:@"brain"];
}

#pragma mark - Touches

- (CGPoint)shellPointForTouch:(UITouch *)touch {
    CGPoint p = [touch locationInNode:self.roomNode];
    return CGPointMake(floor(p.x), floor(APShellHeight - p.y));
}

- (APPlacedItem *)itemAtShellPoint:(CGPoint)p {
    for (APPlacedItem *item in self.layout.items.reverseObjectEnumerator) {
        int lx = (int)p.x - item.px, ly = (int)p.y - item.py;
        if (lx < 0 || ly < 0 || lx >= item.spec.pixelWidth || ly >= item.spec.pixelHeight) continue;
        // Pixel-accurate with a little slop so thin things (lamps) are tappable.
        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
            if (APOpaqueAt(item.lit.canvas, lx + dx, ly + dy) || APOpaqueAt(item.glowing.canvas, lx + dx, ly + dy)) return item;
        }
    }
    return nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.toy isEqualToString:@"wand"]) { [self moveWandToShell:[self shellPointForTouch:touches.anyObject]]; return; }
    if (!self.editing) return;
    CGPoint p = [self shellPointForTouch:touches.anyObject];
    APPlacedItem *hit = [self itemAtShellPoint:p];
    self.dragMoved = NO;
    self.dragging = NO;
    if (!hit) return;
    if (hit != self.selectedItem) {
        self.selectedItem = hit;
        APHapticPlay(APHapticSelect);
        [self showSelection];
        [self.homeDelegate palHomeSceneSelectionDidChange:self];
    }
    self.dragging = YES;
    self.dragX = hit.x;
    self.dragY = hit.y;
    CGPoint tile = [self gridPointForShellPoint:p spec:hit.spec];
    self.dragGrab = CGPointMake(tile.x - hit.x, tile.y - hit.y);
}

- (CGPoint)gridPointForShellPoint:(CGPoint)p spec:(APItemSpec *)spec {
    if (spec.layer == APLayerWall) return CGPointMake(floor((p.x - APSideWall) / APTile), floor((p.y - APCeiling - APCrown) / APTile));
    if (spec.layer == APLayerTrim) return CGPointMake(floor((p.x - APSideWall) / APTile), 0);
    return CGPointMake(floor((p.x - APSideWall) / APTile), floor((p.y - APFloorTop) / APTile));
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.toy isEqualToString:@"wand"]) { [self moveWandToShell:[self shellPointForTouch:touches.anyObject]]; return; }
    if (!self.editing || !self.dragging || !self.selectedItem) return;
    APPlacedItem *item = self.selectedItem;
    CGPoint tile = [self gridPointForShellPoint:[self shellPointForTouch:touches.anyObject] spec:item.spec];
    int rows = item.spec.layer == APLayerWall ? APWallRows : item.spec.layer == APLayerTrim ? 1 : APRows;
    int x = MAX(0, MIN((int)(tile.x - self.dragGrab.x), APCols - item.spec.w));
    int y = item.spec.layer == APLayerTrim ? 0 : MAX(0, MIN((int)(tile.y - self.dragGrab.y), rows - item.spec.d));
    if (item.spec.backWall) y = 0;
    if (x == self.dragX && y == self.dragY) return;
    self.dragX = x;
    self.dragY = y;
    self.dragMoved = YES;
    int px, py;
    [APPlacedItem placementForSpec:item.spec x:x y:y px:&px py:&py];
    SKNode *container = self.itemNodes[item.uid];
    container.position = [self nodePointForShellX:px y:py height:item.spec.pixelHeight];
    // Lift while dragging; red when it can't go there.
    container.zPosition = 800;
    [[self.roomNode childNodeWithName:@"glows"] enumerateChildNodesWithName:item.uid usingBlock:^(SKNode *glow, BOOL *stop) { glow.hidden = YES; }];
    BOOL ok = [self.layout canPlace:item.spec x:x y:y ignoringUID:item.uid];
    SKSpriteNode *base = (SKSpriteNode *)[container childNodeWithName:@"base"];
    base.color = ok ? UIColor.whiteColor : APUIColor(0xFF5A5A);
    base.colorBlendFactor = ok ? 0 : 0.55;
    APHapticPlay(APHapticSelect);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.movingInDone) { [self finishMovingInDay]; return; }
    if ([self.toy isEqualToString:@"wand"]) return;
    if ([self.toy isEqualToString:@"ball"]) {
        if (!self.ballFlying) { APHapticPlay(APHapticSelect); [self throwBallTo:[self shellPointForTouch:touches.anyObject] fromPlayer:YES]; }
        return;
    }
    if (self.editing) {
        APPlacedItem *item = self.selectedItem;
        if (self.dragging && self.dragMoved && item) {
            BOOL ok = [self.layout canPlace:item.spec x:self.dragX y:self.dragY ignoringUID:item.uid];
            if (ok) {
                [self updateRecord:item.uid change:^(NSMutableDictionary *record) {
                    record[@"x"] = @(self.dragX);
                    record[@"y"] = @(self.dragY);
                }];
            } else {
                [self rebuildRoomKeepingPal:YES]; // snap back
            }
        } else if (!self.dragging) {
            [self deselect];
        }
        self.dragging = NO;
        return;
    }
    CGPoint p = [self shellPointForTouch:touches.anyObject];
    if (self.pal) {
        CGRect palRect = CGRectMake(self.pal.position.x - 10, APShellHeight - self.pal.position.y - 16, 20, 18);
        if (CGRectContainsPoint(palRect, p)) { [self petResident]; return; }
    }
    APPlacedItem *hit = [self itemAtShellPoint:p];
    if ([hit.spec.identifier isEqualToString:@"boxes"] && !self.readOnly) {
        [self unpackBoxes:hit];
        return;
    }
    if (hit.spec.toggleable && !self.readOnly) {
        BOOL on = !hit.on;
        [self updateRecord:hit.uid change:^(NSMutableDictionary *record) { record[@"off"] = @(!on); }];
        APHapticPlay(APHapticToggle);
        BOOL curtains = [hit.spec.identifier hasPrefix:@"window"];
        [self announce:curtains ? (on ? @"Curtains open." : @"Curtains drawn.")
                                : [NSString stringWithFormat:@"%@ %@.", hit.spec.title, on ? @"on" : @"off"]];
        return;
    }
    if (hit && [self reactToItem:hit]) return;
    // Tap the floor to call your Pal over.
    CGPoint tile = CGPointMake(floor((p.x - APSideWall) / APTile), floor((p.y - APFloorTop) / APTile));
    if (tile.y >= 0 && [self.layout isWalkableTileX:(int)tile.x y:(int)tile.y] && self.pal) {
        if (self.palMode == APPalSleeping) { [self wakeUp]; return; }
        if (self.palMode == APPalPlaying) return;
        [self walkToX:(int)tile.x y:(int)tile.y run:NO completion:nil];
    }
}

// Tapping furniture (outside decorate mode): the Pal uses it if it can, and
// everything else gives a little wobble so no tap goes unanswered. Walkable
// floor things (rugs) fall through to "come here".
- (BOOL)reactToItem:(APPlacedItem *)item {
    id<ApolloPalHomeSceneDelegate> delegate = self.homeDelegate;
    NSString *identifier = item.spec.identifier;
    BOOL palFree = self.pal && self.palMode != APPalPlaying;
    if (([identifier isEqualToString:@"bowls"] || [identifier isEqualToString:@"candybowl"]) && self.pal &&
        [delegate respondsToSelector:@selector(palHomeScene:wantsCare:)]) {
        self.feedingSpot = item;
        [delegate palHomeScene:self wantsCare:@"feed"];
        self.feedingSpot = nil;
        return YES;
    }
    if ([identifier isEqualToString:@"yarn"] && self.pal && [delegate respondsToSelector:@selector(palHomeScene:wantsCare:)]) {
        [self wobbleItem:item];
        [delegate palHomeScene:self wantsCare:@"play"];
        return YES;
    }
    if (item.spec.petBed && palFree) {
        // Off to bed: trot over, then curl up.
        if (self.palMode == APPalSleeping) [self wakeUp];
        int fx = item.x + item.spec.w / 2, fy = MIN(item.y + item.spec.d, APRows - 1);
        __weak typeof(self) weakSelf = self;
        [self.pal removeAllActions];
        [self removeActionForKey:@"brain"];
        void (^bed)(void) = ^{ [weakSelf sleepInBed:item announce:YES hop:YES]; };
        if (!self.reducedMotion && [self.layout isWalkableTileX:fx y:fy] && [self pathFromX:self.palX y:self.palY toX:fx y:fy]) {
            [self walkToX:fx y:fy run:NO completion:bed];
        } else {
            bed();
        }
        return YES;
    }
    if (item.spec.seat && palFree && self.palMode != APPalSleeping) {
        int fx = item.x + item.spec.w / 2, fy = item.y + item.spec.d;
        if (fy < APRows && [self.layout isWalkableTileX:fx y:fy] &&
            ((fx == self.palX && fy == self.palY) || [self pathFromX:self.palX y:self.palY toX:fx y:fy])) {
            [self.pal removeAllActions];
            [self removeActionForKey:@"brain"];
            __weak typeof(self) weakSelf = self;
            [self walkToX:fx y:fy run:NO completion:^{ [weakSelf hopOnto:item]; }];
            [self announce:[NSString stringWithFormat:@"%@ hops up onto the %@.", self.resident.name, item.spec.title.lowercaseString]];
            return YES;
        }
    }
    if (item.spec.walkable) return NO;
    [self wobbleItem:item];
    return YES;
}

- (void)wobbleItem:(APPlacedItem *)item {
    SKNode *container = self.itemNodes[item.uid];
    if (!container || [container actionForKey:@"wobble"]) return;
    APHapticPlay(APHapticTap);
    if (self.reducedMotion) return;
    CGPoint p = container.position;
    [container runAction:[SKAction sequence:@[
        [SKAction moveTo:CGPointMake(p.x, p.y + 1) duration:0], [SKAction waitForDuration:0.07],
        [SKAction moveTo:CGPointMake(p.x + 1, p.y) duration:0], [SKAction waitForDuration:0.06],
        [SKAction moveTo:CGPointMake(p.x - 1, p.y) duration:0], [SKAction waitForDuration:0.06],
        [SKAction moveTo:p duration:0]]] withKey:@"wobble"];
}

#pragma mark - Moving-in day

- (void)dustAt:(CGPoint)centre count:(int)count {
    for (int i = 0; i < count; i++) {
        APCanvas *mote = APCanvasCreate(2, 2);
        APRect(mote, 0, 0, 2, 2, i % 3 ? 0xD8C8A8 : 0xF0E6D0);
        SKSpriteNode *puff = APSprite(mote);
        APCanvasFree(mote);
        puff.position = CGPointMake(round(centre.x), round(centre.y));
        puff.zPosition = 900;
        [self.roomNode addChild:puff];
        CGFloat angle = (CGFloat)i / count * M_PI * 2;
        CGPoint to = CGPointMake(round(centre.x + cos(angle) * (9 + i % 3 * 3)), round(centre.y + fabs(sin(angle)) * 6 + 2));
        [puff runAction:[SKAction sequence:@[APPixelMove(puff.position, to, 0.35), [SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
    }
}

- (void)playMovingInDay:(void (^)(void))completion {
    if (self.movingInDone) [self finishMovingInDay];
    self.movingInDone = completion ?: ^{};
    [self removeActionForKey:@"brain"];
    if (self.reducedMotion || !self.roomNode) {
        [self welcomeHome];
        [self finishMovingInDay];
        return;
    }
    // The Pal waits outside until the boxes are in.
    [self.pal removeAllActions];
    self.pal.position = CGPointMake(self.pal.position.x, -40);
    // Boxes drop one after another, squash on landing, dust.
    NSTimeInterval t = 0.35;
    for (APPlacedItem *item in self.layout.items) {
        if (![item.spec.identifier isEqualToString:@"boxes"]) continue;
        SKNode *box = self.itemNodes[item.uid];
        if (!box) continue;
        CGPoint rest = box.position;
        CGPoint high = CGPointMake(rest.x, rest.y + 70);
        box.position = high;
        box.alpha = 0;
        CGPoint foot = CGPointMake(rest.x + item.spec.pixelWidth / 2.0, rest.y + 2);
        __weak typeof(self) weakSelf = self;
        [box runAction:[SKAction sequence:@[[SKAction waitForDuration:t], [SKAction fadeInWithDuration:0], APPixelMove(high, rest, 0.32),
            [SKAction runBlock:^{
                [weakSelf dustAt:foot count:8];
                APHapticPlay(APHapticThump);
            }],
            [SKAction moveTo:CGPointMake(rest.x, rest.y + 3) duration:0], [SKAction waitForDuration:0.07],
            [SKAction moveTo:rest duration:0]]] withKey:@"movingIn"];
        t += 0.45;
    }
    // A sign swings down from the ceiling.
    APCanvas *plaque = APChromeSign(APChromeThemeForStyle(self.layout.style.identifier), @"Moving Day!", -1, 0);
    SKSpriteNode *sign = APSprite(plaque);
    int signW = plaque->w, signH = plaque->h;
    APCanvasFree(plaque);
    SKNode *pivot = [SKNode node];
    pivot.position = CGPointMake(round(APShellWidth / 2.0), APShellHeight + signH + 4);
    pivot.zPosition = 950;
    sign.position = CGPointMake(-signW / 2, -signH);
    [pivot addChild:sign];
    [self.roomNode addChild:pivot];
    self.movingInSign = pivot;
    CGPoint shown = CGPointMake(pivot.position.x, APShellHeight - 10);
    [pivot runAction:[SKAction sequence:@[APPixelMove(pivot.position, shown, 0.3), [SKAction runBlock:^{ APHapticPlay(APHapticTap); }],
        [SKAction rotateToAngle:0.08 duration:0.18], [SKAction rotateToAngle:-0.05 duration:0.22], [SKAction rotateToAngle:0 duration:0.2],
        [SKAction waitForDuration:MAX(1.0, t + 0.6)],
        APPixelMove(shown, CGPointMake(shown.x, APShellHeight + signH + 4), 0.3), [SKAction removeFromParent]]]];
    // Then your Pal arrives.
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:t + 0.2], [SKAction runBlock:^{ [weakSelf welcomeHome]; }],
                                         [SKAction waitForDuration:1.4], [SKAction runBlock:^{ [weakSelf finishMovingInDay]; }]]]
            withKey:@"movingInDay"];
}

// Ends the show (or skips to its end), once.
- (void)finishMovingInDay {
    void (^done)(void) = self.movingInDone;
    if (!done) return;
    self.movingInDone = nil;
    if ([self actionForKey:@"movingInDay"]) {
        // Skipped: everything straight to where it ends up.
        [self removeActionForKey:@"movingInDay"];
        for (APPlacedItem *item in self.layout.items) {
            SKNode *box = self.itemNodes[item.uid];
            if (![box actionForKey:@"movingIn"]) continue;
            [box removeActionForKey:@"movingIn"];
            box.alpha = 1;
            box.position = [self nodePointForShellX:item.px y:item.py height:item.spec.pixelHeight];
        }
        [self.movingInSign removeFromParent];
        [self welcomeHome];
    }
    self.movingInSign = nil;
    APHapticPlay(APHapticSuccess);
    done();
}

// Moving-in day: the boxes burst open in a puff of dust and packing
// peanuts, your Pal perks up, and decorating begins.
- (void)unpackBoxes:(APPlacedItem *)boxes {
    SKNode *container = self.itemNodes[boxes.uid];
    CGPoint centre = CGPointMake(container.position.x + boxes.spec.pixelWidth / 2.0, container.position.y + boxes.spec.pixelHeight / 2.0);
    APHapticPlay(APHapticPop);
    if (!self.reducedMotion) {
        // Dust.
        for (int i = 0; i < 10; i++) {
            APCanvas *mote = APCanvasCreate(2, 2);
            APRect(mote, 0, 0, 2, 2, i % 3 ? 0xD8C8A8 : 0xF0E6D0);
            SKSpriteNode *puff = APSprite(mote);
            APCanvasFree(mote);
            puff.position = CGPointMake(round(centre.x), round(centre.y));
            puff.zPosition = 900;
            [self.roomNode addChild:puff];
            CGFloat angle = (CGFloat)i / 10 * M_PI * 2;
            CGPoint to = CGPointMake(round(centre.x + cos(angle) * (10 + i % 3 * 3)), round(centre.y + sin(angle) * 8 + 4));
            [puff runAction:[SKAction sequence:@[APPixelMove(puff.position, to, 0.35), [SKAction fadeOutWithDuration:0.3], [SKAction removeFromParent]]]];
        }
        // Packing peanuts, arcing out and falling.
        for (int i = 0; i < 6; i++) {
            APCanvas *bit = APCanvasCreate(2, 1);
            APRect(bit, 0, 0, 2, 1, 0xFFFDF4);
            SKSpriteNode *peanut = APSprite(bit);
            APCanvasFree(bit);
            peanut.position = CGPointMake(round(centre.x), round(centre.y + 6));
            peanut.zPosition = 901;
            [self.roomNode addChild:peanut];
            CGFloat dx = (i - 2.5) * 5;
            CGPoint top = CGPointMake(round(centre.x + dx * 0.5), round(centre.y + 16 + (i % 2) * 4));
            CGPoint land = CGPointMake(round(centre.x + dx), round(container.position.y + 2));
            [peanut runAction:[SKAction sequence:@[APPixelMove(peanut.position, top, 0.2), APPixelMove(top, land, 0.35),
                                                   [SKAction waitForDuration:0.8], [SKAction fadeOutWithDuration:0.4], [SKAction removeFromParent]]]];
        }
        [container runAction:[SKAction sequence:@[[SKAction scaleXTo:1.15 y:0.85 duration:0.08], [SKAction fadeOutWithDuration:0.15]]]];
    }
    if (self.pal && self.palMode != APPalSleeping) [self floatIcon:@"smallheart" count:1 color:0];
    [self announce:@"Unpacked! Time to make it home."];
    __weak typeof(self) weakSelf = self;
    [self runAction:[SKAction sequence:@[[SKAction waitForDuration:self.reducedMotion ? 0 : 0.45], [SKAction runBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableDictionary *room = [strongSelf mutableRoom];
        room[@"items"] = [room[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, id b) {
            return ![record[@"uid"] isEqual:boxes.uid];
        }]];
        [strongSelf commitRoom:room selecting:nil];
        id<ApolloPalHomeSceneDelegate> delegate = strongSelf.homeDelegate;
        if ([delegate respondsToSelector:@selector(palHomeSceneDidUnpack:)]) [delegate palHomeSceneDidUnpack:strongSelf];
    }]]]];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.dragging && self.dragMoved) [self rebuildRoomKeepingPal:YES];
    self.dragging = NO;
}

#pragma mark - Editing

- (void)setEditing:(BOOL)editing {
    if (_editing == editing) return;
    _editing = editing;
    [self.grid runAction:[SKAction fadeAlphaTo:editing ? 1 : 0 duration:0.2]];
    if (editing) {
        [self stopGame];
        [self removeActionForKey:@"brain"];
        [self removeActionForKey:@"zzz"];
        [self abandonHeist];
        [self.pal removeAllActions];
        [[self.roomNode childNodeWithName:@"yarn"] removeFromParent];
        // The Pal steps out while you rearrange (Animal Crossing style).
        [self.pal runAction:[SKAction fadeAlphaTo:0 duration:0.2]];
    } else {
        [self deselect];
        // Furniture may now stand where the Pal was.
        [self settlePalAfterEdit];
        [self.pal runAction:[SKAction fadeAlphaTo:[self palOpacity] duration:0.2]];
    }
}

- (void)settlePalAfterEdit {
    if (!self.pal) return;
    int x = self.palX, y = self.palY;
    if (![self.layout isWalkableTileX:x y:y]) [self nearestWalkableFromX:x y:y outX:&x outY:&y];
    self.palX = x; self.palY = y;
    [self settlePal];
}

- (void)showSelection {
    for (SKNode *container in self.itemNodes.allValues) {
        [[container childNodeWithName:@"outline"] removeFromParent];
        [[container childNodeWithName:@"footprint"] removeFromParent];
    }
    APPlacedItem *item = self.selectedItem;
    SKNode *container = item ? self.itemNodes[item.uid] : nil;
    if (!container || !self.editing) return;
    int W = item.spec.pixelWidth, H = item.spec.pixelHeight;
    APCanvas *shape = APCanvasCreate(W, H);
    APDraw(shape, item.lit.canvas, 0, 0, NO);
    APDraw(shape, item.glowing.canvas, 0, 0, NO);
    APDraw(shape, item.litFront.canvas, 0, 0, NO);
    APCanvas *outline = APCanvasOutline(shape, 0xFFF8E0);
    APCanvasFree(shape);
    SKSpriteNode *ring = APSprite(outline);
    APCanvasFree(outline);
    ring.name = @"outline";
    ring.position = CGPointMake(-1, -1);
    ring.zPosition = 0.05;
    [container addChild:ring];
    if (!self.reducedMotion) {
        [ring runAction:[SKAction repeatActionForever:[SKAction sequence:@[[SKAction fadeAlphaTo:0.35 duration:0.5], [SKAction fadeAlphaTo:1 duration:0.5]]]]];
    }
    if (item.spec.layer == APLayerFloor || item.spec.layer == APLayerRug) {
        int fw = item.spec.w * APTile, fh = item.spec.d * APTile;
        APCanvas *foot = APCanvasCreate(fw, fh);
        for (int x = 0; x < fw; x += 2) { APBlendPx(foot, x, 0, 0xFFF8E0, 0.8f); APBlendPx(foot, x, fh - 1, 0xFFF8E0, 0.8f); }
        for (int y = 0; y < fh; y += 2) { APBlendPx(foot, 0, y, 0xFFF8E0, 0.8f); APBlendPx(foot, fw - 1, y, 0xFFF8E0, 0.8f); }
        APBlendRect(foot, 1, 1, fw - 2, fh - 2, 0xFFF8E0, 0.12f);
        SKSpriteNode *footprint = APSprite(foot);
        APCanvasFree(foot);
        footprint.name = @"footprint";
        footprint.zPosition = -item.z + 46; // just above rugs and the grid
        [container addChild:footprint];
    }
}

- (void)deselect {
    if (!self.selectedItem) return;
    self.selectedItem = nil;
    [self showSelection];
    [self.homeDelegate palHomeSceneSelectionDidChange:self];
}

- (void)commitRoom:(NSDictionary *)room selecting:(nullable NSString *)uid {
    self.previewSaved = nil;
    self.roomDocument = room;
    [self rebuildRoomKeepingPal:YES];
    if (uid) self.selectedItem = [self.layout itemWithUID:uid];
    [self showSelection];
    // Persist the cleaned-up records (invalid placements dropped).
    NSMutableDictionary *clean = [self.roomDocument mutableCopy];
    clean[@"items"] = self.layout.itemRecords;
    self.roomDocument = clean;
    [self.homeDelegate palHomeSceneDidChangeRoom:self];
    [self.homeDelegate palHomeSceneSelectionDidChange:self];
}

- (NSMutableDictionary *)mutableRoom {
    NSMutableDictionary *room = [(self.roomDocument ?: [APCatalog starterRoom]) mutableCopy];
    room[@"items"] = self.layout.itemRecords;
    room[@"wallpaper"] = self.layout.wallpaper.identifier;
    room[@"floor"] = self.layout.floor.identifier;
    room[@"style"] = self.layout.style.identifier;
    return room;
}

- (void)updateRecord:(NSString *)uid change:(void (^)(NSMutableDictionary *record))change {
    NSMutableDictionary *room = [self mutableRoom];
    NSMutableArray *items = [room[@"items"] mutableCopy];
    for (NSUInteger i = 0; i < items.count; i++) {
        if (![items[i][@"uid"] isEqual:uid]) continue;
        NSMutableDictionary *record = [items[i] mutableCopy];
        change(record);
        items[i] = record;
    }
    room[@"items"] = items;
    [self commitRoom:room selecting:self.selectedItem.uid];
}

- (BOOL)addItem:(APItemSpec *)spec {
    int x, y;
    if (![self.layout findSpotForSpec:spec x:&x y:&y]) return NO;
    NSMutableDictionary *room = [self mutableRoom];
    NSString *uid = NSUUID.UUID.UUIDString;
    room[@"items"] = [room[@"items"] arrayByAddingObject:@{@"uid": uid, @"item": spec.identifier, @"x": @(x), @"y": @(y), @"variant": @0}];
    [self commitRoom:room selecting:uid];
    [self announce:[NSString stringWithFormat:@"%@ placed.", spec.title]];
    return YES;
}

- (void)flipSelected {
    NSString *uid = self.selectedItem.uid;
    if (!uid) return;
    BOOL flip = !self.selectedItem.flip;
    [self updateRecord:uid change:^(NSMutableDictionary *record) { record[@"flip"] = @(flip); }];
}

- (void)cycleSelectedVariant {
    APPlacedItem *item = self.selectedItem;
    if (!item || item.spec.variants.count < 2) return;
    int next = (item.variant + 1) % (int)item.spec.variants.count;
    [self updateRecord:item.uid change:^(NSMutableDictionary *record) { record[@"variant"] = @(next); }];
    [self announce:item.spec.variants[next]];
}

- (void)toggleSelected {
    APPlacedItem *item = self.selectedItem;
    if (!item.spec.toggleable) return;
    BOOL on = !item.on;
    [self updateRecord:item.uid change:^(NSMutableDictionary *record) { record[@"off"] = @(!on); }];
}

- (void)removeSelected {
    APPlacedItem *item = self.selectedItem;
    if (!item) return;
    NSMutableDictionary *room = [self mutableRoom];
    room[@"items"] = [room[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, id b) {
        return ![record[@"uid"] isEqual:item.uid];
    }]];
    self.selectedItem = nil;
    [self commitRoom:room selecting:nil];
    APHapticPlay(APHapticRemove);
    [self announce:[NSString stringWithFormat:@"%@ put away.", item.spec.title]];
}

- (BOOL)moveSelectedByX:(int)dx y:(int)dy {
    APPlacedItem *item = self.selectedItem;
    if (!item) return NO;
    int x = item.x + dx, y = item.y + dy;
    if (![self.layout canPlace:item.spec x:x y:y ignoringUID:item.uid]) return NO;
    [self updateRecord:item.uid change:^(NSMutableDictionary *record) { record[@"x"] = @(x); record[@"y"] = @(y); }];
    return YES;
}

- (void)setWallpaper:(NSString *)identifier {
    NSMutableDictionary *room = [self mutableRoom];
    room[@"wallpaper"] = identifier;
    [self commitRoom:room selecting:self.selectedItem.uid];
}

- (void)setFloor:(NSString *)identifier {
    NSMutableDictionary *room = [self mutableRoom];
    room[@"floor"] = identifier;
    [self commitRoom:room selecting:self.selectedItem.uid];
}

- (void)previewRoom:(NSDictionary *)room {
    if (room) {
        if (!self.previewSaved) self.previewSaved = self.roomDocument ?: [APCatalog starterRoom];
        self.selectedItem = nil;
        self.roomDocument = room;
    } else {
        if (!self.previewSaved) return;
        self.roomDocument = self.previewSaved;
        self.previewSaved = nil;
    }
    [self rebuildRoomKeepingPal:YES];
    [self relayout:NO]; // the backdrop belongs to the style
    [self showSelection];
}

- (NSDictionary *)committedRoomDocument { return self.previewSaved ?: self.roomDocument; }

- (void)replaceRoom:(NSDictionary *)room {
    self.selectedItem = nil;
    [self commitRoom:room selecting:nil];
    [self relayout:NO]; // the backdrop belongs to the style
}

- (void)cycleLighting {
    NSArray *modes = @[@"auto", @"day", @"evening", @"night", @"candle", @"overcast"];
    NSMutableDictionary *room = [self mutableRoom];
    NSUInteger index = [modes indexOfObject:room[@"lighting"] ?: @"auto"];
    room[@"lighting"] = modes[(index == NSNotFound ? 0 : index + 1) % modes.count];
    [self commitRoom:room selecting:self.selectedItem.uid];
}

@end
