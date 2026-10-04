#import "ApolloPalHomeViewController.h"
#import "ApolloPalHomeScene.h"
#import "ApolloPalHomeDrawer.h"
#import "ApolloPalHomePixelUI.h"
#import "ApolloPalHomeWardrobe.h"
#import "ApolloPalHomeShelterView.h"
#import "ApolloPalHomeAmbience.h"
#import "ApolloPalHomeHaptics.h"
#import "ApolloPalHomeWidgetRenderer.h"
#import "ApolloCommon.h"
#import "ApolloIPadTabBarBottom.h"
#import <LinkPresentation/LinkPresentation.h>
#import "settings/ApolloSettingsShortcutsViewController.h"
#import "settings/ApolloPalHomeSettingsViewController.h"

// Gives the share sheet a real preview and title for the postcard.
@interface ApolloPalHomePostcardItem : NSObject <UIActivityItemSource>
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) NSString *title;
@end

@implementation ApolloPalHomePostcardItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller { return self.image; }
- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type { return self.image; }
- (LPLinkMetadata *)activityViewControllerLinkMetadata:(UIActivityViewController *)controller API_AVAILABLE(ios(13.0)) {
    LPLinkMetadata *metadata = [LPLinkMetadata new];
    metadata.title = self.title;
    NSItemProvider *provider = [[NSItemProvider alloc] initWithObject:self.image];
    metadata.imageProvider = provider;
    metadata.iconProvider = provider;
    return metadata;
}
@end

// Full-screen Pal Home. The whole screen is the pixel-art room: the navigation
// bar and tab bar are hidden, and all chrome is drawn in art pixels.
@interface ApolloPalHomeViewController () <ApolloPalHomeSceneDelegate, ApolloPalHomeDrawerDelegate, UIGestureRecognizerDelegate, ApolloPalHomeWardrobeDelegate, ApolloPalHomeShelterDelegate>
@property (nonatomic, strong) ApolloPalHomeStore *store;
@property (nonatomic, strong) ApolloPalHomeScene *homeScene;
@property (nonatomic, strong) SKView *roomView;
@property (nonatomic, strong) ApolloPixelButton *backButton, *cameraButton, *soundButton;
@property (nonatomic, strong) ApolloPalHomeAmbience *ambience;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) ApolloPixelImageView *toolbarPanel;
@property (nonatomic, copy) NSArray<ApolloPixelButton *> *toolbarButtons;
@property (nonatomic) BOOL movedInHinted;
// Whose home we're in: nil = the Pal on the island. Visiting another Pal
// shows their room and cares for them without changing the island.
@property (nonatomic, copy, nullable) NSString *homeID;
@property (nonatomic, strong) ApolloPixelButton *decorateButton, *feedButton;
@property (nonatomic, strong) ApolloPixelLabel *foodBadge;
@property (nonatomic, strong) ApolloPalHomeDrawer *drawer;
@property (nonatomic, strong, nullable) UIControl *wardrobeScrim;
@property (nonatomic, strong, nullable) ApolloPalHomeWardrobe *wardrobe;
@property (nonatomic, strong, nullable) ApolloPalHomeShelterView *shelter;
@property (nonatomic) CGFloat pixelScale;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL editing;
@property (nonatomic, weak) id<UIGestureRecognizerDelegate> savedPopDelegate;
@property (nonatomic) BOOL hadNavigationBarHidden;
@property (nonatomic, copy, nullable) NSDictionary *roomBeforeStyle; // one-step undo while decorating
@end

@implementation ApolloPalHomeViewController

static NSString *sPendingVisit;

// The link route always opens a fresh Pal Home, which takes this on init.
+ (void)visitResidentOnOpen:(NSString *)residentID {
    sPendingVisit = residentID.length ? [residentID copy] : nil;
    ApolloLog(@"[PalHome] visit requested: %@", residentID ?: @"(island Pal)");
}

- (instancetype)initWithNibName:(NSString *)nibName bundle:(NSBundle *)bundle {
    if ((self = [super initWithNibName:nibName bundle:bundle])) {
        self.hidesBottomBarWhenPushed = YES;
        self.title = @"Pal Home";
        self.homeID = sPendingVisit; // refreshHome drops it if they're the island Pal or gone
        sPendingVisit = nil;
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersHomeIndicatorAutoHidden { return !self.editing; }

- (ApolloPixelButton *)toolButton:(NSString *)icon label:(NSString *)label hint:(NSString *)hint action:(SEL)action {
    ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:icon accessibilityLabel:label];
    button.accessibilityHint = hint;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0x1C / 255.0 green:0x13 / 255.0 blue:0x10 / 255.0 alpha:1];
    self.store = [ApolloPalHomeStore new];
    self.pixelScale = 2;

    self.roomView = [SKView new];
    self.roomView.ignoresSiblingOrder = YES;
    self.roomView.accessibilityIdentifier = @"pal-home.room";
    self.roomView.isAccessibilityElement = YES;
    self.roomView.accessibilityTraits = UIAccessibilityTraitImage | UIAccessibilityTraitAllowsDirectInteraction;
    self.roomView.accessibilityCustomActions = @[
        [[UIAccessibilityCustomAction alloc] initWithName:@"Pet your Pal" target:self selector:@selector(accessiblePet)],
        [[UIAccessibilityCustomAction alloc] initWithName:@"Play with your Pal" target:self selector:@selector(accessiblePlay)],
        [[UIAccessibilityCustomAction alloc] initWithName:@"Let your Pal nap" target:self selector:@selector(accessibleRest)]];
    [self.view addSubview:self.roomView];
    self.homeScene = [[ApolloPalHomeScene alloc] initWithSize:CGSizeMake(200, 400)];
    self.homeScene.homeDelegate = self;
    [self.roomView presentScene:self.homeScene];
    self.roomView.paused = YES;

    self.backButton = [self toolButton:@"back" label:@"Back" hint:@"Leaves Pal Home." action:@selector(goBack)];
    self.backButton.tileWidth = 18;
    self.backButton.tileHeight = 16;
    [self.view addSubview:self.backButton];
    self.cameraButton = [self toolButton:@"camera" label:@"Take a postcard" hint:@"Saves a picture of your Pal\u2019s home to share." action:@selector(takePostcard)];
    self.cameraButton.tileWidth = 18;
    self.cameraButton.tileHeight = 16;
    [self.view addSubview:self.cameraButton];
    self.ambience = [ApolloPalHomeAmbience new];
    self.soundButton = [self toolButton:@"speaker" label:@"Sound" hint:@"Cosy room sounds. They follow the silent switch." action:@selector(toggleSound)];
    self.soundButton.tileWidth = 18;
    self.soundButton.tileHeight = 16;
    [self.view addSubview:self.soundButton];
    [self updateSoundButton];

    self.toolbar = [UIView new];
    self.toolbarPanel = [ApolloPixelImageView new];
    [self.toolbar addSubview:self.toolbarPanel];
    ApolloPixelButton *pet = [self toolButton:@"heart" label:@"Pet" hint:@"Give your Pal some love." action:@selector(pet)];
    self.feedButton = [self toolButton:@"food" label:@"Feed" hint:@"Feed your Pal from the pantry. Food turns up while you scroll, upvote, comment and post." action:@selector(feed)];
    self.feedButton.accessibilityIdentifier = @"pal-home.feed";
    ApolloPixelButton *play = [self toolButton:@"ball" label:@"Play" hint:@"Roll a ball of yarn. Playing earns hearts, once every few hours." action:@selector(play)];
    ApolloPixelButton *nap = [self toolButton:@"moon" label:@"Nap" hint:@"Your Pal heads to bed." action:@selector(rest)];
    self.decorateButton = [self toolButton:@"brush" label:@"Decorate" hint:@"Rearrange furniture, wallpaper and flooring." action:@selector(decorate)];
    ApolloPixelButton *pals = [self toolButton:@"paw" label:@"Your Pal" hint:@"Your Pal\u2019s card: personality, name, household and the shelter." action:@selector(openWardrobe)];
    pet.accessibilityIdentifier = @"pal-home.pet";
    play.accessibilityIdentifier = @"pal-home.play";
    nap.accessibilityIdentifier = @"pal-home.nap";
    self.decorateButton.accessibilityIdentifier = @"pal-home.decorate";
    self.toolbarButtons = @[pet, self.feedButton, play, nap, self.decorateButton, pals];
    for (ApolloPixelButton *button in self.toolbarButtons) [self.toolbar addSubview:button];
    // How much food is in the pantry, on the Feed button.
    self.foodBadge = [ApolloPixelLabel new];
    self.foodBadge.font = APFontSmall;
    self.foodBadge.isAccessibilityElement = NO;
    self.foodBadge.userInteractionEnabled = NO;
    [self.toolbar addSubview:self.foodBadge];
    [self.view addSubview:self.toolbar];

    self.drawer = [ApolloPalHomeDrawer new];
    self.drawer.delegate = self;
    self.drawer.category = APCategoryFurniture;
    self.drawer.hidden = YES;
    [self.view addSubview:self.drawer];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                             UIAccessibilityReduceMotionStatusDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
    }
    [self refreshHome];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

// The Pal whose home this is (the visited one, else the island Pal).
- (ApolloPalHomeResident *)homeResident {
    ApolloPalHomeResident *visited = self.homeID ? [self.store residentWithID:self.homeID] : nil;
    if (self.homeID && !visited) self.homeID = nil; // gone (rehomed elsewhere)
    return visited ?: self.store.residents.firstObject;
}

- (NSArray<ApolloPalHomeResident *> *)homeResidents {
    ApolloPalHomeResident *home = [self homeResident];
    return home ? @[home] : @[];
}

// The household with whoever's home first (the Pal card shows them).
- (NSArray<ApolloPalHomeResident *> *)homeHousehold {
    ApolloPalHomeResident *home = [self homeResident];
    NSMutableArray *list = [NSMutableArray arrayWithObject:home ?: self.store.household.firstObject];
    for (ApolloPalHomeResident *resident in self.store.household) if (![resident.identifier isEqual:home.identifier]) [list addObject:resident];
    return list;
}

#pragma mark - Appearance

// On phones without a Dynamic Island, Apollo's Pal walks along the tab bar
// (a PixelPalView in the window). Inside Pal Home that's a second copy of the
// Pal wandering under the room, so it steps out while we're on screen. The
// island Pal (inside the FauxCutOutView pill) stays: it's the island.
- (void)setTabBarPalHidden:(BOOL)hidden {
    static Class palView, cutOut;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palView = NSClassFromString(@"_TtC6Apollo12PixelPalView");
        cutOut = NSClassFromString(@"_TtC6Apollo14FauxCutOutView");
    });
    UIWindow *window = self.view.window ?: self.navigationController.view.window;
    if (!palView || !window) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:palView]) {
            BOOL inIsland = NO;
            for (UIView *up = view.superview; up && !inIsland; up = up.superview) inIsland = cutOut && [up isKindOfClass:cutOut];
            // alpha, not hidden: Apollo re-sets `hidden` as it updates the Pal.
            if (!inIsland && (view.alpha < 0.5) != hidden) {
                view.alpha = hidden ? 0 : 1;
                ApolloLog(@"[PalHome] tab-bar Pal %@ (%@)", hidden ? @"hidden" : @"shown", NSStringFromCGRect(view.frame));
            }
            continue;
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.hadNavigationBarHidden = self.navigationController.navigationBarHidden;
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    // iPad's top tabs ignore hidesBottomBarWhenPushed.
    ApolloIPadSetTabBarSuppressed(self.tabBarController, YES);
    [self refreshHome];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setTabBarPalHidden:YES];
    // Switched off from the Pal card's Settings: Classic it is, so step out.
    if (!ApolloPalHomeStore.isPalHomeEnabled && self.navigationController.topViewController == self &&
        self.navigationController.viewControllers.firstObject != self) {
        ApolloLog(@"[PalHome] Pal Home was turned off; leaving");
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.visible = YES;
    // With the bar hidden UIKit stops offering the edge swipe back; keep it.
    UIGestureRecognizer *pop = self.navigationController.interactivePopGestureRecognizer;
    if (pop.delegate != self) self.savedPopDelegate = pop.delegate;
    pop.delegate = self;
    [self updateActivity];
    [self setNeedsStatusBarAppearanceUpdate];
    // First visit: meet the shelter (your current Pal can stay, of course).
    if (!self.store.shelterSeen && !self.shelter) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.visible && !weakSelf.store.shelterSeen) [weakSelf openShelter];
        });
    } else if (![self.store hasMovedIn:self.homeResident.identifier] && !self.movedInHinted) {
        self.movedInHinted = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.visible && !weakSelf.shelter) [weakSelf arriveHome];
        });
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self setTabBarPalHidden:NO];
    self.visible = NO;
    if (self.editing) [self setEditingMode:NO];
    UIGestureRecognizer *pop = self.navigationController.interactivePopGestureRecognizer;
    if (pop.delegate == self) pop.delegate = self.savedPopDelegate;
    [self.navigationController setNavigationBarHidden:self.hadNavigationBarHidden animated:animated];
    ApolloIPadSetTabBarSuppressed(self.tabBarController, NO);
    [self updateActivity];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.navigationController.interactivePopGestureRecognizer) {
        return !self.editing && self.navigationController.viewControllers.count > 1 && !self.navigationController.transitionCoordinator;
    }
    return YES;
}

- (void)environmentChanged:(NSNotification *)notification {
    [self.homeScene setMotionReduced:UIAccessibilityIsReduceMotionEnabled()];
    [self updateActivity];
    if ([notification.name isEqual:UIApplicationWillResignActiveNotification]) self.roomView.paused = YES;
}

- (void)updateActivity {
    // Pixel art at ~30fps is plenty; halve it in Low Power Mode.
    self.roomView.preferredFramesPerSecond = NSProcessInfo.processInfo.lowPowerModeEnabled ? 15 : 30;
    BOOL live = self.visible && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    self.roomView.paused = !live;
    if (live && ApolloPalHomeAmbience.isEnabled) {
        [self.ambience updateForLayout:self.homeScene.layout minuteOfDay:[self minuteOfDay]];
        [self.ambience start];
    } else {
        [self.ambience stop];
    }
}

- (int)minuteOfDay {
    NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:NSDate.date];
    return (int)(parts.hour * 60 + parts.minute);
}

- (void)toggleSound {
    ApolloPalHomeAmbience.enabled = !ApolloPalHomeAmbience.isEnabled;
    [self updateSoundButton];
    [self updateActivity];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, ApolloPalHomeAmbience.isEnabled ? @"Sound on" : @"Sound off");
}

- (void)updateSoundButton {
    BOOL on = ApolloPalHomeAmbience.isEnabled;
    self.soundButton.iconName = on ? @"speaker" : @"mute";
    self.soundButton.accessibilityValue = on ? @"On" : @"Off";
}

- (void)refreshHome {
    [self.store reconcileIsland]; // also refreshes; settles a slot Apollo's chooser moved away from
    [self.homeScene setMotionReduced:UIAccessibilityIsReduceMotionEnabled()];
    self.homeScene.readOnly = !self.store.canEdit;
    ApolloPalHomeResident *home = [self homeResident];
    [self.homeScene configureWithRoom:[self.store roomForResident:home.identifier] ?: [APCatalog starterRoom] residents:[self homeResidents]];
    [self applyChrome];
    for (ApolloPixelButton *button in [self.toolbarButtons subarrayWithRange:NSMakeRange(0, 4)]) button.enabled = self.homeScene.hasPalArtwork;
    [self updateFoodBadge];
    self.decorateButton.enabled = self.store.canEdit;
    [self updateRoomDescription];
}

- (void)updateRoomDescription {
    ApolloPalHomeResident *pal = [self homeResident];
    NSMutableArray *names = [NSMutableArray array];
    for (APPlacedItem *item in self.homeScene.layout.items) if (item.spec.layer != APLayerTrim) [names addObject:item.spec.title.lowercaseString];
    NSString *home = [NSString stringWithFormat:@"%@’s home: %@ walls and %@. ", pal.name,
                      self.homeScene.layout.wallpaper.title, self.homeScene.layout.floor.title.lowercaseString];
    NSString *furnished = names.count ? [NSString stringWithFormat:@"Furnished with %@.", [names componentsJoinedByString:@", "]] : @"The room is empty.";
    NSString *hearts = pal.hearts ? [NSString stringWithFormat:@" %@ of 6 friendship hearts.",
                                     [NSNumberFormatter localizedStringFromNumber:pal.hearts numberStyle:NSNumberFormatterDecimalStyle]] : @"";
    self.roomView.accessibilityLabel = [[home stringByAppendingString:furnished] stringByAppendingString:hearts];
    self.roomView.accessibilityHint = self.homeScene.hasPalArtwork ? @"Tap your Pal to pet them, tap the floor to call them, tap lamps to switch them."
                                                                   : @"This copy of Apollo is missing your Pal's artwork.";
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    // Pick a pixel size that's a whole number of device pixels and fits the
    // room plus its chrome: crisp, evenly sized pixels on every device.
    CGFloat screenScale = self.view.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat byWidth = floor(size.width * screenScale / (APShellWidth + 10));
    CGFloat byHeight = floor((size.height - safe.top - safe.bottom) * screenScale / (APShellHeight + 58));
    CGFloat devicePixels = MAX(1, MIN(byWidth, byHeight));
    CGFloat p = devicePixels / screenScale;
    self.pixelScale = p;

    self.roomView.frame = self.view.bounds;
    CGSize sceneSize = CGSizeMake(size.width / p, size.height / p);
    if (!CGSizeEqualToSize(self.homeScene.size, sceneSize)) self.homeScene.size = sceneSize;

    // Back button, top-left inside the safe area.
    self.backButton.pixelScale = p;
    self.backButton.frame = CGRectMake(MAX(safe.left, 0) + 4 * p, safe.top + 3 * p, self.backButton.pixelSize.width, self.backButton.pixelSize.height);
    self.cameraButton.pixelScale = p;
    self.cameraButton.frame = CGRectMake(size.width - MAX(safe.right, 0) - 4 * p - self.cameraButton.pixelSize.width, safe.top + 3 * p,
                                         self.cameraButton.pixelSize.width, self.cameraButton.pixelSize.height);
    self.soundButton.pixelScale = p;
    self.soundButton.frame = CGRectMake(CGRectGetMinX(self.cameraButton.frame) - 2 * p - self.soundButton.pixelSize.width, safe.top + 3 * p,
                                        self.soundButton.pixelSize.width, self.soundButton.pixelSize.height);

    // Toolbar: a wooden shelf of six buttons.
    int bw = 20, bh = 20, gap = 2, pad = 4;
    int tw = pad * 2 + bw * (int)self.toolbarButtons.count + gap * ((int)self.toolbarButtons.count - 1), th = bh + pad * 2 - 1;
    APCanvas *panel = APPanelCanvas(tw, th);
    self.toolbarPanel.pixelScale = p;
    [self.toolbarPanel setCanvas:panel];
    APCanvasFree(panel);
    CGFloat toolbarY = size.height - MAX(safe.bottom, 6 * p) - th * p - 2 * p;
    self.toolbar.frame = CGRectMake(round((size.width - tw * p) / 2 / p) * p, toolbarY, tw * p, th * p);
    self.toolbarPanel.frame = self.toolbar.bounds;
    for (NSUInteger i = 0; i < self.toolbarButtons.count; i++) {
        ApolloPixelButton *button = self.toolbarButtons[i];
        button.pixelScale = p;
        button.tileWidth = bw;
        button.tileHeight = bh;
        button.frame = CGRectMake((pad + (int)i * (bw + gap)) * p, (pad - 1) * p, bw * p, bh * p);
    }
    self.foodBadge.pixelScale = p;
    [self layoutFoodBadge];

    // Drawer: full width, anchored to the bottom edge.
    int drawerW = (int)floor(size.width / p) - 4;
    self.drawer.pixelScale = p;
    self.drawer.pixelWidth = drawerW;
    CGFloat drawerH = self.drawer.pixelHeight * p + safe.bottom;
    CGFloat drawerY = self.editing ? size.height - drawerH : size.height + 4;
    self.drawer.frame = CGRectMake(round((size.width - drawerW * p) / 2 / p) * p, drawerY, drawerW * p, drawerH);

    [self updateSceneReserves:NO];
    [self layoutWardrobe];
    if (self.shelter) {
        self.shelter.frame = self.view.bounds;
        self.shelter.pixelScale = self.pixelScale;
        self.shelter.safeInsets = self.view.safeAreaInsets;
    }
}

- (void)updateSceneReserves:(BOOL)animated {
    CGFloat p = self.pixelScale;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat top = (safe.top + 3 * p) / p;
    CGFloat bottom = self.editing ? self.drawer.frame.size.height / p : (self.view.bounds.size.height - self.toolbar.frame.origin.y) / p + 2;
    [self.homeScene setTopReserve:top bottomReserve:bottom animated:animated];
}

#pragma mark - Actions

- (void)goBack {
    // Presented on its own (no stack to pop back through): dismiss instead.
    UINavigationController *nav = self.navigationController;
    if ((!nav || nav.viewControllers.firstObject == self) && (nav.presentingViewController || self.presentingViewController)) {
        [(nav.presentingViewController ? nav : self) dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [nav popViewControllerAnimated:YES];
}
- (void)pet { [self.homeScene petResident]; }
- (void)play {
    // Always fun; earns a heart (Apollo's rule) once every 5 hours.
    NSString *home = [self homeResident].identifier;
    APCareResult result = home ? [self.store playWithResident:home] : APCareUnavailable;
    [self.homeScene playWithResident];
    if (result == APCareDone) {
        [self.ambience playJingle:APJingleHeart];
        APHapticPlay(APHapticHeart);
        [self.homeScene refreshResidents:[self homeResidents]];
        [self toast:@[@"+1/4 heart!", [NSString stringWithFormat:@"%@ had a great time.", [self homeResident].name]]];
    }
}

- (void)feed {
    double gain = 0;
    ApolloPalHomeResident *pal = [self homeResident];
    APCareResult result = pal ? [self.store feedResident:pal.identifier gain:&gain] : APCareUnavailable;
    switch (result) {
        case APCareDone: {
            BOOL treat = [self.homeScene feedResident];
            [self.homeScene refreshResidents:[self homeResidents]];
            [self updateFoodBadge];
            [self.ambience playJingle:APJingleYum];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ APHapticPlay(APHapticHeart); });
            NSInteger left = self.store.foodTokens;
            [self toast:@[treat ? @"Trick or treat! +1/4 heart" : @"Yum! +1/4 heart",
                          treat ? [NSString stringWithFormat:@"%@ picked a sweet and gained %@.", pal.name, APCareWeightText(gain)]
                                : [NSString stringWithFormat:@"%@ gained %@.", pal.name, APCareWeightText(gain)],
                          left ? [NSString stringWithFormat:@"%ld food left", (long)left] : @"That was the last of the food."]];
            break;
        }
        case APCareNoFood:
            APHapticPlay(APHapticNope);
            [self.feedButton shake];
            [self toast:@[@"The pantry is empty!", @"Food turns up while you scroll,", @"upvote, comment and post."]];
            break;
        case APCareTooSoon:
            APHapticPlay(APHapticNope);
            [self.feedButton shake];
            [self toast:@[[NSString stringWithFormat:@"%@ is full!", pal.name],
                          [NSString stringWithFormat:@"Hungry again in %@.", APCareWaitText([self.store waitBeforeFeeding:pal.identifier])]]];
            break;
        case APCareUnavailable:
            [self.feedButton shake];
            break;
    }
}

static NSString *APCareWaitText(NSTimeInterval wait) {
    int minutes = MAX(1, (int)ceil(wait / 60));
    if (minutes < 60) return [NSString stringWithFormat:@"%d min", minutes];
    return minutes % 60 ? [NSString stringWithFormat:@"%dh %dm", minutes / 60, minutes % 60] : [NSString stringWithFormat:@"%dh", minutes / 60];
}

static NSString *APCareWeightText(double lbs) {
    if (lbs < 0.1) return [NSString stringWithFormat:@"%.0f oz", MAX(1, lbs * 16)];
    return [NSString stringWithFormat:@"%.1f lbs", lbs];
}

- (void)updateFoodBadge {
    NSInteger food = self.store.foodTokens;
    // A chrome change re-themes labels; the badge keeps its own colours.
    self.foodBadge.shadowColor = 0x3A1010;
    self.foodBadge.color = 0xFFFFFF;
    self.foodBadge.text = food > 99 ? @"99+" : food > 0 ? [NSString stringWithFormat:@"%ld", (long)food] : @"";
    self.feedButton.accessibilityValue = food == 1 ? @"1 food" : [NSString stringWithFormat:@"%ld food", (long)food];
    [self layoutFoodBadge];
}

- (void)layoutFoodBadge {
    CGSize size = self.foodBadge.intrinsicContentSize;
    CGRect button = self.feedButton.frame;
    CGFloat p = self.pixelScale;
    self.foodBadge.frame = CGRectMake(CGRectGetMaxX(button) - size.width - 2 * p, CGRectGetMinY(button) + 2 * p, size.width, size.height);
}
- (void)rest { [self.homeScene restResident]; }
- (BOOL)accessiblePet { [self pet]; return self.homeScene.hasPalArtwork; }
- (BOOL)accessiblePlay { [self play]; return self.homeScene.hasPalArtwork; }
- (BOOL)accessibleRest { [self rest]; return self.homeScene.hasPalArtwork; }

- (void)decorate { [self setEditingMode:YES]; }

- (void)setEditingMode:(BOOL)editing {
    if (self.editing == editing) return;
    if (editing && !self.store.canEdit) return;
    self.editing = editing;
    self.homeScene.editing = editing;
    self.roomBeforeStyle = nil;
    self.drawer.canUndo = NO;
    if (@available(iOS 26.0, *)) {
        // Dragging furniture must not become a full-screen swipe back.
        self.navigationController.interactiveContentPopGestureRecognizer.enabled = !editing;
    }
    [self.drawer updateWithSelection:self.homeScene.selectedItem layout:self.homeScene.layout];
    if (editing) {
        self.drawer.category = self.drawer.category;
        self.drawer.hidden = NO;
    }
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    [UIView animateWithDuration:still ? 0 : 0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self viewDidLayoutSubviews];
        self.toolbar.alpha = editing ? 0 : 1;
        self.backButton.alpha = editing ? 0 : 1;
        self.cameraButton.alpha = editing ? 0 : 1;
        self.soundButton.alpha = editing ? 0 : 1;
    } completion:^(BOOL finished) {
        if (!self.editing) self.drawer.hidden = YES;
    }];
    self.toolbar.userInteractionEnabled = !editing;
    self.backButton.userInteractionEnabled = !editing;
    self.cameraButton.userInteractionEnabled = !editing;
    self.soundButton.userInteractionEnabled = !editing;
    [self updateSceneReserves:YES];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, editing ? self.drawer : self.roomView);
}

#pragma mark - Postcard

// Snapshot the live room (Pal and all) onto a little pixel postcard.
- (void)takePostcard {
    CGRect crop = self.homeScene.postcardFrame;
    // Snapshot exactly what's on screen (Pal mid-pose and all), then crop to
    // the room + sign in device pixels: scene units × pixel scale, y flipped.
    CGFloat p = self.pixelScale, screenScale = self.view.window.screen.scale ?: UIScreen.mainScreen.scale;
    UIGraphicsImageRendererFormat *snapFormat = [UIGraphicsImageRendererFormat preferredFormat];
    snapFormat.scale = screenScale;
    UIImage *screen = [[[UIGraphicsImageRenderer alloc] initWithBounds:self.roomView.bounds format:snapFormat] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [self.roomView drawViewHierarchyInRect:self.roomView.bounds afterScreenUpdates:NO];
    }];
    CGFloat viewH = self.roomView.bounds.size.height;
    CGRect pixels = CGRectMake(crop.origin.x * p * screenScale, (viewH - CGRectGetMaxY(crop) * p) * screenScale,
                               crop.size.width * p * screenScale, crop.size.height * p * screenScale);
    pixels = CGRectIntersection(CGRectIntegral(pixels), CGRectMake(0, 0, CGImageGetWidth(screen.CGImage), CGImageGetHeight(screen.CGImage)));
    CGImageRef shot = CGImageCreateWithImageInRect(screen.CGImage, pixels);
    ApolloLog(@"[PalHome] postcard crop=%@ pixels=%@", NSStringFromCGRect(crop), NSStringFromCGRect(pixels));
    if (!shot) return;
    crop.size = CGSizeMake(round(CGImageGetWidth(shot) / (p * screenScale)), round(CGImageGetHeight(shot) / (p * screenScale)));
    int artW = (int)crop.size.width, artH = (int)crop.size.height;
    // Device px per art px in the snapshot, then a whole-number upscale so
    // the shared picture is ~1500px wide and still perfectly crisp.
    CGFloat k = MAX(1, round(CGImageGetWidth(shot) / (CGFloat)artW));
    k *= MAX(1, round(1500 / (k * (artW + 12))));
    int margin = 6, captionH = 14;
    APChromeTheme theme = APChromeCurrent();
    APCanvas *card = APCanvasCreate(artW + margin * 2, artH + margin + captionH);
    APRect(card, 0, 0, card->w, card->h, 0xF4ECD8);
    APDitherRect(card, 0, 0, card->w, card->h, 0xE8DCC0, 0.18f);
    APRectOutline(card, 0, 0, card->w, card->h, 0xC8B898);
    APRect(card, margin - 1, margin - 1, artW + 2, artH + 2, 0x3A2A22);
    NSString *title = self.homeScene.signTitle ?: @"Pal Home";
    APText(card, title.uppercaseString, margin, artH + margin + 4, APFontSmall, 0x3A2A22);
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"d MMM yyyy";
    NSString *date = [formatter stringFromDate:NSDate.date].uppercaseString;
    APText(card, date, card->w - margin - APTextWidth(date, APFontSmall), artH + margin + 4, APFontSmall, APShade(theme.accent, 0.6f));
    CGImageRef cardImage = APCanvasCreateCGImage(card);
    CGSize size = CGSizeMake(card->w * k, card->h * k);
    APCanvasFree(card);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *postcard = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        CGContextTranslateCTM(ctx, 0, size.height);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, size.width, size.height), cardImage);
        CGContextDrawImage(ctx, CGRectMake(margin * k, size.height - (margin + artH) * k, artW * k, artH * k), shot);
    }];
    CGImageRelease(cardImage);
    CGImageRelease(shot);

    // Shutter flash.
    UIView *flash = [[UIView alloc] initWithFrame:self.view.bounds];
    flash.backgroundColor = UIColor.whiteColor;
    flash.userInteractionEnabled = NO;
    [self.view addSubview:flash];
    [UIView animateWithDuration:0.35 animations:^{ flash.alpha = 0; } completion:^(BOOL finished) { [flash removeFromSuperview]; }];
    APHapticPlay(APHapticPop); // shutter

#if APOLLO_SIM_BUILD
    [UIImagePNGRepresentation(postcard) writeToFile:@"/tmp/palhome-postcard.png" atomically:YES];
#endif
    ApolloPalHomePostcardItem *item = [ApolloPalHomePostcardItem new];
    item.image = postcard;
    item.title = [NSString stringWithFormat:@"A postcard from %@", title];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.cameraButton;
    share.popoverPresentationController.sourceRect = self.cameraButton.bounds;
    ApolloLog(@"[PalHome] postcard %.0fx%.0f presenting share sheet", postcard.size.width, postcard.size.height);
    [self presentViewController:share animated:YES completion:nil];
}

#pragma mark - Wardrobe

- (void)openWardrobe {
    ApolloPalHomeResident *pal = [self homeResident];
    if (!pal || self.wardrobe) return;
    self.wardrobeScrim = [UIControl new];
    self.wardrobeScrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.wardrobeScrim.frame = self.view.bounds;
    self.wardrobeScrim.isAccessibilityElement = NO;
    [self.wardrobeScrim addTarget:self action:@selector(closeWardrobe) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.wardrobeScrim];
    self.wardrobe = [ApolloPalHomeWardrobe new];
    self.wardrobe.delegate = self;
    self.wardrobe.pixelScale = self.pixelScale;
    self.wardrobe.foodTokens = self.store.foodTokens;
    self.wardrobe.islandEnabled = self.store.islandEnabled;
    self.wardrobe.islandResidentID = self.store.residents.firstObject.identifier;
    [self.wardrobe configureWithHousehold:[self homeHousehold]];
    [self.view addSubview:self.wardrobe];
    [self layoutWardrobe];
    self.wardrobeScrim.alpha = 0;
    self.wardrobe.transform = CGAffineTransformMakeTranslation(0, 24 * self.pixelScale);
    self.wardrobe.alpha = 0;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.22 animations:^{
        self.wardrobeScrim.alpha = 1;
        self.wardrobe.alpha = 1;
        self.wardrobe.transform = CGAffineTransformIdentity;
    }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.wardrobe);
}

- (void)layoutWardrobe {
    if (!self.wardrobe) return;
    CGFloat p = self.pixelScale;
    self.wardrobeScrim.frame = self.view.bounds;
    self.wardrobe.pixelScale = p;
    // A big household makes a tall card: step the pixel size down until it
    // fits between the status bar and the toolbar.
    CGFloat room = self.toolbar.frame.origin.y - self.view.safeAreaInsets.top - 8;
    while (p > 1 && (self.wardrobe.pixelHeight + 4) * p > room) {
        p -= 1;
        self.wardrobe.pixelScale = p;
    }
    CGFloat w = self.wardrobe.pixelWidth * p, h = self.wardrobe.pixelHeight * p;
    // Sits just above the toolbar, pixel-aligned.
    CGFloat y = MAX(self.view.safeAreaInsets.top, floor((self.toolbar.frame.origin.y - h - 4 * p) / p) * p);
    self.wardrobe.frame = CGRectMake(round((self.view.bounds.size.width - w) / 2 / p) * p, y, w, h);
}

- (void)closeWardrobe {
    UIView *wardrobe = self.wardrobe, *scrim = self.wardrobeScrim;
    self.wardrobe = nil;
    self.wardrobeScrim = nil;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.18 animations:^{
        wardrobe.alpha = 0;
        scrim.alpha = 0;
    } completion:^(BOOL finished) {
        [wardrobe removeFromSuperview];
        [scrim removeFromSuperview];
    }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.roomView);
}

- (void)wardrobeDidFinish:(ApolloPalHomeWardrobe *)wardrobe { [self closeWardrobe]; }

- (void)wardrobeWantsShelter:(ApolloPalHomeWardrobe *)wardrobe {
    [self closeWardrobe];
    [self openShelter];
}

- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe wantsRename:(ApolloPalHomeResident *)resident {
    [self closeWardrobe];
    [self presentShelterView];
    [self.shelter showRenameForResident:resident.identifier species:resident.species coat:resident.coat currentName:resident.name];
}

// Visiting: their home, their care; the island keeps its Pal.
- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe switchTo:(ApolloPalHomeResident *)resident {
    self.homeID = resident.active ? nil : resident.identifier;
    [self closeWardrobe];
    [self refreshHome];
    [self arriveHome];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [NSString stringWithFormat:@"Visiting %@.", resident.name]);
}

- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe putOnIsland:(ApolloPalHomeResident *)resident {
    if (![self.store makeActiveResident:resident.identifier]) { APHapticPlay(APHapticNope); return; }
    APHapticPlay(APHapticSuccess);
    self.homeID = nil;
    wardrobe.islandResidentID = self.store.residents.firstObject.identifier;
    [wardrobe configureWithHousehold:[self homeHousehold]];
    [self layoutWardrobe];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
        [NSString stringWithFormat:@"%@ is on the Dynamic Island now.", resident.name]);
}

- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe wantsGoodbye:(ApolloPalHomeResident *)resident {
    if (self.store.household.count < 2) {
        APHapticPlay(APHapticNope);
        [self closeWardrobe];
        [self toast:@[[NSString stringWithFormat:@"%@ is your only Pal!", resident.name], @"They're staying right here with you."]];
        return;
    }
    [self closeWardrobe];
    NSString *name = resident.name, *identifier = resident.identifier;
    __weak typeof(self) weakSelf = self;
    [self confirmWithTitle:[NSString stringWithFormat:@"Say goodbye to %@?", name]
                      body:@"They'll go to a loving new family, and take their room and memories with them."
                    cancel:@"Stay" confirm:@"Goodbye" confirmIcon:@"wave" handler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        APHapticPlay(APHapticRemove);
        [strongSelf.homeScene waveGoodbye:^{
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (![innerSelf.store rehomeResident:identifier]) { [innerSelf refreshHome]; return; }
            innerSelf.homeID = nil;
            [innerSelf refreshHome];
            [innerSelf arriveHome];
            [innerSelf toast:@[[NSString stringWithFormat:@"%@ found a lovely new family.", name], @"Changed your mind? Adopt a Pal → Old friends brings them back."]];
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [NSString stringWithFormat:@"%@ went to a new home.", name]);
        }];
    }];
}

// A small pixel dialog: a headline, a sentence, and two choices.
- (void)confirmWithTitle:(NSString *)title body:(NSString *)body cancel:(NSString *)cancel confirm:(NSString *)confirm
             confirmIcon:(NSString *)icon handler:(void (^)(void))handler {
    CGFloat p = self.pixelScale;
    int W = 132;
    UIControl *scrim = [[UIControl alloc] initWithFrame:self.view.bounds];
    scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    UIView *dialog = [UIView new];
    ApolloPixelLabel *head = [ApolloPixelLabel new];
    head.pixelScale = p; head.font = APFontSmall; head.themeRole = 2; head.maxWidth = W - 10; head.text = title;
    ApolloPixelLabel *text = [ApolloPixelLabel new];
    text.pixelScale = p; text.font = APFontSmall; text.themeRole = 0; text.maxWidth = W - 14; text.smooth = YES; text.text = body;
    int H = 6 + 8 + text.pixelHeight + 6 + 16 + 6;
    APCanvas *panelCanvas = APPanelCanvas(W, H);
    ApolloPixelImageView *panel = [ApolloPixelImageView new];
    panel.pixelScale = p;
    [panel setCanvas:panelCanvas];
    APCanvasFree(panelCanvas);
    [dialog addSubview:panel];
    CGSize hs = head.intrinsicContentSize, ts = text.intrinsicContentSize;
    head.frame = CGRectMake((W * p - hs.width) / 2, 6 * p, hs.width, hs.height);
    text.frame = CGRectMake((W * p - ts.width) / 2, 14 * p, ts.width, ts.height);
    [dialog addSubview:head];
    [dialog addSubview:text];
    __weak UIControl *weakScrim = scrim;
    void (^dismiss)(void) = ^{
        UIControl *s = weakScrim;
        [UIView animateWithDuration:0.15 animations:^{ s.alpha = 0; } completion:^(BOOL finished) { [s removeFromSuperview]; }];
    };
    ApolloPixelButton *(^word)(NSString *, NSString *) = ^ApolloPixelButton *(NSString *iconName, NSString *label) {
        APCanvas *icn = APIconCanvas(iconName);
        int tw = APTextWidth(label.uppercaseString, APFontSmall);
        APCanvas *content = APCanvasCreate(icn->w + 3 + tw, MAX(icn->h, 6));
        APDraw(content, icn, 0, (content->h - icn->h) / 2, NO);
        APTextShadow(content, label.uppercaseString, icn->w + 3, (content->h - 6) / 2, APFontSmall, APChromeCurrent().text, APChromeCurrent().shadow);
        APCanvasFree(icn);
        ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:label];
        button.iconName = nil;
        button.content = [APCanvasBox boxWithCanvas:content];
        button.tileWidth = content->w + 10;
        button.tileHeight = 16;
        button.pixelScale = p;
        return button;
    };
    ApolloPixelButton *stay = word(@"heart", cancel), *go = word(icon, confirm);
    int by = H - 22;
    stay.frame = CGRectMake(6 * p, by * p, stay.tileWidth * p, 16 * p);
    go.frame = CGRectMake((W - 6 - go.tileWidth) * p, by * p, go.tileWidth * p, 16 * p);
    [stay addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { dismiss(); }] forControlEvents:UIControlEventTouchUpInside];
    [go addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { dismiss(); handler(); }] forControlEvents:UIControlEventTouchUpInside];
    [scrim addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { dismiss(); }] forControlEvents:UIControlEventTouchUpInside];
    [dialog addSubview:stay];
    [dialog addSubview:go];
    dialog.frame = CGRectMake(round((self.view.bounds.size.width - W * p) / 2 / p) * p, round((self.view.bounds.size.height - H * p) / 2 / p) * p, W * p, H * p);
    dialog.accessibilityViewIsModal = YES;
    [scrim addSubview:dialog];
    [self.view addSubview:scrim];
    scrim.alpha = 0;
    [UIView animateWithDuration:0.15 animations:^{ scrim.alpha = 1; }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, head);
}

- (void)wardrobeToggledIsland:(ApolloPalHomeWardrobe *)wardrobe {
    BOOL on = !self.store.islandEnabled;
    APHapticPlay(APHapticToggle);
    self.store.islandEnabled = on;
    wardrobe.islandEnabled = on;
    [wardrobe configureWithHousehold:[self homeHousehold]];
    [self layoutWardrobe];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
        on ? [NSString stringWithFormat:@"%@ is back on the Dynamic Island.", self.store.residents.firstObject.name]
           : @"Your Pal is staying home.");
}

- (void)wardrobeWantsSettings:(ApolloPalHomeWardrobe *)wardrobe {
    [self closeWardrobe];
    UIViewController *settings = [[ApolloPalHomeSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:settings animated:YES];
}

- (void)wardrobeWantsWidgetCode:(ApolloPalHomeWardrobe *)wardrobe {
    NSString *code = [self.store widgetCodeForResident:[self homeResident].identifier room:self.homeScene.roomDocument];
    if (!code) return;
    [UIPasteboard.generalPasteboard setItems:@[@{@"public.utf8-plain-text": code}]
                                     options:@{UIPasteboardOptionLocalOnly: @YES,
                                               UIPasteboardOptionExpirationDate: [NSDate dateWithTimeIntervalSinceNow:10 * 60]}];
    [self closeWardrobe];
    [self toast:@[@"Pal code copied!", @"Long-press the Pal Home widget,", @"Edit Widget, paste into Pal Code."]];
}

// A small notice that fades away: a pixel headline, then plain-spoken detail.
- (void)toast:(NSArray<NSString *> *)lines {
    if (!lines.count) return;
    CGFloat p = self.pixelScale;
    UIView *view = [UIView new];
    ApolloPixelLabel *title = [ApolloPixelLabel new];
    title.pixelScale = p;
    title.font = APFontSmall;
    title.themeRole = 2;
    title.text = lines.firstObject;
    ApolloPixelLabel *detail = nil;
    if (lines.count > 1) {
        detail = [ApolloPixelLabel new];
        detail.pixelScale = p;
        detail.font = APFontSmall;
        detail.themeRole = 0;
        detail.maxWidth = 140;
        detail.smooth = YES;
        detail.text = [[lines subarrayWithRange:NSMakeRange(1, lines.count - 1)] componentsJoinedByString:@"\n"];
    }
    int titleW = (int)ceil(title.intrinsicContentSize.width / p);
    int detailW = detail ? (int)ceil(detail.image.size.width / p) : 0;
    // Hug the detail text (it's laid out centred across maxWidth).
    if (detail) {
        CGFloat used = 0;
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:MAX(11, round(p * 4.8)) weight:UIFontWeightSemibold]};
        for (NSString *line in [detail.text componentsSeparatedByString:@"\n"]) used = MAX(used, [line sizeWithAttributes:attrs].width);
        detailW = MIN(detailW, (int)ceil(used / p) + 2);
    }
    int w = MAX(titleW, detailW) + 14;
    int h = 6 + 7 + (detail ? detail.pixelHeight + 2 : 0) + 3;
    APCanvas *canvas = APPanelCanvas(w, h);
    ApolloPixelImageView *panel = [ApolloPixelImageView new];
    panel.pixelScale = p;
    [panel setCanvas:canvas];
    APCanvasFree(canvas);
    [view addSubview:panel];
    title.frame = CGRectMake(round((w - titleW) / 2.0) * p, 5 * p, title.intrinsicContentSize.width, title.intrinsicContentSize.height);
    [view addSubview:title];
    if (detail) {
        CGSize size = detail.intrinsicContentSize;
        detail.frame = CGRectMake((w * p - size.width) / 2, 13 * p, size.width, size.height);
        [view addSubview:detail];
    }
    view.frame = CGRectMake(round((self.view.bounds.size.width - w * p) / 2 / p) * p, self.toolbar.frame.origin.y - (h + 4) * p, w * p, h * p);
    view.isAccessibilityElement = YES;
    view.accessibilityLabel = [lines componentsJoinedByString:@" "];
    [self.view addSubview:view];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, view.accessibilityLabel);
    view.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ view.alpha = 1; } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.4 delay:3.0 options:0 animations:^{ view.alpha = 0; } completion:^(BOOL done) { [view removeFromSuperview]; }];
    }];
}

#pragma mark - Shelter

- (void)presentShelterView {
    if (self.shelter) return;
    if (self.editing) [self setEditingMode:NO];
    self.shelter = [[ApolloPalHomeShelterView alloc] initWithFrame:self.view.bounds];
    self.shelter.delegate = self;
    self.shelter.pixelScale = self.pixelScale;
    self.shelter.safeInsets = self.view.safeAreaInsets;
    [self.view addSubview:self.shelter];
    self.shelter.alpha = 0;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.22 animations:^{ self.shelter.alpha = 1; }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.shelter);
}

- (void)openShelter {
    NSMutableSet *owned = [NSMutableSet set];
    for (ApolloPalHomeResident *resident in self.store.household) [owned addObject:resident.species];
    [self presentShelterView];
    self.shelter.rehomed = self.store.rehomed;
    self.shelter.full = self.store.householdFull;
    [self.shelter showRoster:[APShelter animalsExcludingSpecies:owned] keepName:self.store.shelterSeen ? nil : self.store.residents.firstObject.name];
}

- (void)closeShelter {
    UIView *shelter = self.shelter;
    self.shelter = nil;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.18 animations:^{ shelter.alpha = 0; }
                     completion:^(BOOL finished) { [shelter removeFromSuperview]; }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.roomView);
}

- (void)shelterDidClose:(ApolloPalHomeShelterView *)shelter {
    BOOL firstVisit = !self.store.shelterSeen;
    if (firstVisit) [self.store markShelterSeen];
    [self closeShelter];
    // "Maybe later" on the first visit: your current Pal still moves in.
    if (firstVisit && ![self.store hasMovedIn:self.homeResident.identifier]) [self arriveHome];
}

- (void)shelter:(ApolloPalHomeShelterView *)shelter adopt:(APShelterAnimal *)animal name:(NSString *)name {
    if (![self.store adoptAnimal:animal name:name]) {
        APHapticPlay(APHapticNope);
        return;
    }
    [self closeShelter];
    self.homeID = nil; // the new Pal is on the island: their home
    [self refreshHome];
    BOOL movedIn = [self.store hasMovedIn:self.homeResident.identifier];
    [self arriveHome];
    APHapticPlay(APHapticSuccess);
    if (movedIn) [self.ambience playJingle:APJingleAdopt]; // (moving-in day has its own)
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [NSString stringWithFormat:@"Welcome home, %@!", name]);
}

- (void)shelterHomeIsFull:(ApolloPalHomeShelterView *)shelter {
    APHapticPlay(APHapticNope);
    [self toast:@[[NSString stringWithFormat:@"Your home is full (%lu Pals)!", (unsigned long)APHouseholdLimit],
                  @"Say goodbye to someone to make room. They can always come home later."]];
}

- (void)shelter:(ApolloPalHomeShelterView *)shelter bringBack:(NSString *)archiveID {
    NSString *name = nil;
    for (NSDictionary *entry in self.store.rehomed) if ([entry[@"id"] isEqual:archiveID]) name = entry[@"name"];
    NSString *restored = [self.store restoreRehomed:archiveID];
    if (!restored) { APHapticPlay(APHapticNope); return; }
    [self closeShelter];
    self.homeID = restored; // visit them; the island keeps its Pal
    [self refreshHome];
    [self.homeScene welcomeHome];
    APHapticPlay(APHapticSuccess);
    [self.ambience playJingle:APJingleAdopt];
    [self toast:@[[NSString stringWithFormat:@"%@ came home!", name ?: @"Your Pal"], @"Their room was just as they left it."]];
}

- (void)shelter:(ApolloPalHomeShelterView *)shelter rename:(NSString *)residentID name:(NSString *)name {
    [self.store renameResident:residentID to:name];
    [self closeShelter];
    [self refreshHome];
    [self.homeScene petResident];
}

- (void)keyboardChanged:(NSNotification *)note {
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
        self.shelter.keyboardHeight = overlap;
        [self.shelter layoutIfNeeded];
    }];
}

- (void)openPixelPals {
    UIViewController *chooser = ApolloSettingsNativeShortcutScreen(@"Pixel Pals");
    if (chooser) {
        [self.navigationController pushViewController:chooser animated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Pixel Pals"
        message:@"Open Pixel Pals from Apollo’s main Settings screen to choose your companion."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Scene delegate

// The UI's materials follow the home style.
- (void)applyChrome {
    APChromeSetStyle(self.homeScene.layout.style.identifier);
    [self updateFoodBadge];
    [self.view setNeedsLayout];
}

- (void)palHomeScene:(ApolloPalHomeScene *)scene wantsJingle:(NSInteger)jingle {
    [self.ambience playJingle:(APJingle)jingle];
}

- (void)palHomeScene:(ApolloPalHomeScene *)scene wantsCare:(NSString *)action {
    if ([action isEqualToString:@"feed"]) [self feed];
    else if ([action isEqualToString:@"play"]) [self play];
}

// Coming home: moving-in day for a Pal who hasn't moved in yet (their own
// empty room, the boxes), otherwise the usual hop-in-through-the-front.
- (void)arriveHome {
    NSString *home = [self homeResident].identifier;
    if ([self.store hasMovedIn:home] || !self.store.canEdit || self.editing) {
        [self.homeScene welcomeHome];
        return;
    }
    [self.ambience playJingle:APJingleMovingDay];
    __weak typeof(self) weakSelf = self;
    [self.homeScene playMovingInDay:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.store markMovedIn:home];
        if (!strongSelf.visible || strongSelf.shelter || strongSelf.editing) return;
        [strongSelf toast:@[@"Welcome to your new place!", @"Tap the boxes to unpack, or the brush to decorate."]];
        [strongSelf.decorateButton shake];
    }];
}

- (void)palHomeSceneDidUnpack:(ApolloPalHomeScene *)scene {
    APHapticPlay(APHapticSuccess);
    [self.ambience playJingle:APJingleUnpack];
    // The drawer sliding up is the cue (a toast would sit on top of it).
    [self setEditingMode:YES];
}

- (void)palHomeSceneDidChangeRoom:(ApolloPalHomeScene *)scene {
    [self applyChrome];
    [self.ambience updateForLayout:scene.layout minuteOfDay:[self minuteOfDay]];
    if (![self.store saveRoom:scene.roomDocument forResident:[self homeResident].identifier]) ApolloLog(@"[PalHome] Room not saved (read-only or invalid document)");
    [self updateRoomDescription];
}

- (void)palHomeSceneSelectionDidChange:(ApolloPalHomeScene *)scene {
    [self.drawer updateWithSelection:scene.selectedItem layout:scene.layout];
}

- (void)palHomeScene:(ApolloPalHomeScene *)scene announce:(NSString *)message {
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}

#pragma mark - Drawer delegate

- (void)drawer:(ApolloPalHomeDrawer *)drawer didPickItem:(APItemSpec *)spec sender:(ApolloPixelButton *)sender {
    if ([self.homeScene addItem:spec]) {
        APHapticPlay(APHapticPlace);
    } else {
        [sender shake];
        APHapticPlay(APHapticNope);
        [drawer flashTitle:@"No room for that!"];
    }
}

- (void)drawer:(ApolloPalHomeDrawer *)drawer didPickSurface:(APSurfaceSpec *)surface isFloor:(BOOL)isFloor {
    if (isFloor) [self.homeScene setFloor:surface.identifier];
    else [self.homeScene setWallpaper:surface.identifier];
    [drawer flashTitle:surface.title];
}

- (void)drawer:(ApolloPalHomeDrawer *)drawer didPickStyle:(APStyleSpec *)style apply:(APStyleApply)apply {
    // Keep what was there so one tap brings it back.
    NSDictionary *current = self.homeScene.roomDocument ?: [APCatalog starterRoom];
    if (!self.roomBeforeStyle) self.roomBeforeStyle = current;
    NSDictionary *template = style.room();
    NSMutableDictionary *room;
    if (apply == APStyleFurnished) {
        room = [template mutableCopy];
        // Fresh identities so nothing collides with the old room's records.
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *record in room[@"items"]) {
            NSMutableDictionary *copy = [record mutableCopy];
            copy[@"uid"] = NSUUID.UUID.UUIDString;
            [items addObject:copy];
        }
        room[@"items"] = items;
    } else {
        // The style's shell, walls, floor and light; your things or nothing.
        room = [current mutableCopy];
        for (NSString *key in @[@"style", @"wallpaper", @"floor", @"lighting"]) if (template[key]) room[key] = template[key];
        if (apply == APStyleBare) room[@"items"] = @[];
    }
    [self.homeScene replaceRoom:room];
    APHapticPlay(APHapticPop);
    drawer.canUndo = YES;
    [drawer flashTitle:apply == APStyleFurnished ? style.title : apply == APStyleBare ? @"A blank canvas" : @"Same things, new walls"];
}

- (void)drawerStartFresh:(ApolloPalHomeDrawer *)drawer {
    if (!self.roomBeforeStyle) self.roomBeforeStyle = self.homeScene.roomDocument ?: [APCatalog starterRoom];
    NSMutableDictionary *room = [[APCatalog starterRoom] mutableCopy];
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *record in room[@"items"]) {
        NSMutableDictionary *copy = [record mutableCopy];
        copy[@"uid"] = NSUUID.UUID.UUIDString;
        [items addObject:copy];
    }
    room[@"items"] = items;
    [self.homeScene replaceRoom:room];
    // The boxes thump in (your Pal is out while you decorate).
    [self.ambience playJingle:APJingleMovingDay];
    [self.homeScene playMovingInDay:nil];
    drawer.canUndo = YES;
    [drawer flashTitle:@"Moving day!"];
}

- (void)drawerUndo:(ApolloPalHomeDrawer *)drawer {
    if (!self.roomBeforeStyle) return;
    [self.homeScene replaceRoom:self.roomBeforeStyle];
    self.roomBeforeStyle = nil;
    drawer.canUndo = NO;
    [drawer flashTitle:@"Back as it was"];
}

- (void)drawerDidFinish:(ApolloPalHomeDrawer *)drawer { [self setEditingMode:NO]; }
- (void)drawerFlip:(ApolloPalHomeDrawer *)drawer { [self.homeScene flipSelected]; }
- (void)drawerCycleVariant:(ApolloPalHomeDrawer *)drawer { [self.homeScene cycleSelectedVariant]; }
- (void)drawerToggle:(ApolloPalHomeDrawer *)drawer { [self.homeScene toggleSelected]; }
- (void)drawerPutAway:(ApolloPalHomeDrawer *)drawer { [self.homeScene removeSelected]; }
- (BOOL)drawer:(ApolloPalHomeDrawer *)drawer moveSelectionByX:(int)dx y:(int)dy { return [self.homeScene moveSelectedByX:dx y:dy]; }

- (void)drawerCycleLighting:(ApolloPalHomeDrawer *)drawer {
    [self.homeScene cycleLighting];
    NSDictionary *titles = @{@"auto": @"Mood: Follow the clock", @"day": @"Mood: Sunny day", @"evening": @"Mood: Cosy evening",
                             @"night": @"Mood: Night", @"candle": @"Mood: Candlelight", @"overcast": @"Mood: Rainy day"};
    [drawer flashTitle:titles[self.homeScene.roomDocument[@"lighting"] ?: @"auto"] ?: @"Lights"];
}

@end
