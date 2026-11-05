#import "ApolloDuoAccount.h"
// ApolloProfileMoreMenu.xm
//
// A "..." for the signed-in user's own profile tab, so the button is universal
// across profiles instead of vanishing on your own.
//
// Apollo only ever shows its more-options "..." on someone ELSE'S profile
// (Private Message / Follow / Add Friend / Block / Share — all things you
// can't do to yourself), so the signed-in tab historically had a bare corner:
// the tweak's Recently Read clock sat where the "..." would be, and editing
// hid behind an Edit pill floating over the header art. This module gives the
// own profile the same "..." affordance, holding everything self-directed:
//
//   • Gallery View                — the same grid the subreddit/profile
//                                   menus open, pointed at your own posts
//   • Edit Profile                — Reddit's profile editor, opened inside
//                                   Apollo and signed in as this account
//                                   (ApolloProfileEditorWebViewController.m);
//                                   what the header's Edit pill used to do
//                                   (the pill itself is deleted from
//                                   ApolloUserAvatars.xm)
//   • Share Profile               — share sheet for your
//                                   reddit.com/user/<name> URL, mirroring the
//                                   Share row on other people's menus
//
// On Liquid Glass the button is a plain UIBarButtonItem with a UIMenu, which
// renders as the same pull-down Apollo's converted "..." menus use there. The
// standard build's "..." menus are Apollo's own bottom ActionController sheets,
// so there the button calls Apollo's moreOptionsBarButtonItemTappedWithSender:
// and the sheet Apollo builds has its rows replaced with ours (see
// ApolloProfileMoreMenuPreparePresentation) — Apollo's real cells, icons,
// presentation and Cancel button, just our actions.
//
// This module is also the single owner of a profile screen's right-bar
// LAYOUT (see ApolloProfileMoreMenuNormalize): Apollo rewrites a pushed
// profile's rightBarButtonItems when the user's data arrives, which would
// wipe any tweak button appended at viewDidLoad — so our "..." is enforced
// through UINavigationItem setter hooks instead of one-shot appends.
//
// Rules, re-checked on every normalization pass:
//   • Apollo's own moreOptionsBarButtonItem installed → someone else's
//     profile; keep our button out (ApolloGalleryMenu.xm handles injecting
//     Gallery View into Apollo's menu there).
//   • The screen clearly shows a different user than the active account →
//     leave it alone even if Apollo's "..." hasn't landed yet.
//   • PUSHED profiles (not the tab root) must positively resolve to the
//     signed-in account before ours installs — "not clearly someone else"
//     isn't enough while the username is still nil, so ours never flashes on
//     a pushed profile that turns out to be someone else's.
//   • Signed out → nothing to edit or share; no "...".
// Menu handlers re-resolve the username at tap time, so a menu built before
// the profile finished loading still acts on the right user.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloActionMenu.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloGalleryViewController.h"
#import "ApolloProfileEditorWebViewController.h"
#import "ApolloProfileMoreMenu.h"

// Defined in ApolloUserAvatars.xm.
extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);
// ApolloSwiftIvarBridge.swift: ARC-safe Optional<String> assignment.
extern "C" void ApolloSwiftAssignOptionalString(void *storage, const char *utf8Value);

// Our bar button, associated to the profile view controller that owns it.
static char kApolloProfileMoreMenuItemKey;
// The own profile whose "..." tap is synchronously building Apollo's sheet.
// Scoped to that one call so no other ActionController is ever touched.
static __weak UIViewController *sApolloProfileMoreMenuBuildingOwner;
// Set on a profile view controller's UINavigationItem: an NSHashTable holding
// the view controller weakly, so the setter hooks below can find their way
// back without retaining it.
static char kApolloProfileMoreMenuNavOwnerKey;
// Set (to @YES) on the specific UINavigationItem the normalizer is currently
// writing, so the setter hooks pass that write through untouched. Per-item
// rather than a global flag: everything here is main-thread, but if a write
// ever triggers Apollo into synchronously rewriting a DIFFERENT profile's nav
// item from inside our setter call, that item's normalize still runs instead
// of being silently suppressed by a process-wide guard.
static char kApolloProfileMoreMenuNormalizingKey;

static BOOL ApolloProfileMoreMenuIsNormalizing(UINavigationItem *navigationItem) {
    return [objc_getAssociatedObject(navigationItem, &kApolloProfileMoreMenuNormalizingKey) boolValue];
}

#pragma mark - Resolution helpers

// Apollo's own "..." item. The ivar always exists (it's a stored `let` on the
// Swift class); whether it's INSTALLED in the navigation item is what varies.
static UIBarButtonItem *ApolloProfileMoreMenuApolloItem(UIViewController *viewController) {
    id value = ApolloObjectIvar(viewController, "moreOptionsBarButtonItem");
    return [value isKindOfClass:[UIBarButtonItem class]] ? (UIBarButtonItem *)value : nil;
}

// The username this menu should act on: whatever the profile screen resolves
// to, else the active account (covers the tab before userInfo loads).
static NSString *ApolloProfileMoreMenuUsername(UIViewController *viewController) {
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    if (resolved.length > 0) return resolved;
    return ApolloActiveAccountUsername();
}

#pragma mark - Actions

static void ApolloProfileMoreMenuComplainNotReady(UIViewController *viewController, NSString *what) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:what
                                                                   message:@"Couldn't confirm this profile's username yet. Try again once the profile has finished loading."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [viewController presentViewController:alert animated:YES completion:nil];
}

static void ApolloProfileMoreMenuOpenGallery(UIViewController *viewController) {
    NSString *username = ApolloProfileMoreMenuUsername(viewController);
    if (username.length == 0) {
        ApolloProfileMoreMenuComplainNotReady(viewController, @"Gallery View");
        return;
    }
    [ApolloGalleryViewController presentGalleryForUsername:username
                                        fromViewController:viewController];
}

static void ApolloProfileMoreMenuShare(UIViewController *viewController) {
    NSString *username = ApolloProfileMoreMenuUsername(viewController);
    if (username.length == 0) {
        ApolloProfileMoreMenuComplainNotReady(viewController, @"Share Profile");
        return;
    }
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]] ?: username;
    NSURL *url = [NSURL URLWithString:[@"https://www.reddit.com/user/" stringByAppendingString:encoded]];
    if (!url) return;

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    // iPad presents this as a popover and requires an anchor; our "..." is the
    // natural one.
    UIBarButtonItem *anchor = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    activity.popoverPresentationController.barButtonItem = anchor;
    [viewController presentViewController:activity animated:YES completion:nil];
    ApolloLog(@"[ProfileMoreMenu] Sharing u/%@", username);
}

#pragma mark - Menu construction

UIMenu *ApolloProfileMoreMenuForController(UIViewController *viewController) {
    __weak UIViewController *weakVC = viewController;

    UIAction *gallery = [UIAction actionWithTitle:@"Gallery View"
                                            image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                       identifier:nil
                                          handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileMoreMenuOpenGallery(vc);
    }];

    // Keep Gallery View in its own section, matching other profile menus.
    UIMenu *gallerySection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[gallery]];

    UIAction *edit = [UIAction actionWithTitle:@"Edit Profile"
                                         image:[UIImage systemImageNamed:@"pencil"]
                                    identifier:nil
                                       handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileEditorOpenFromViewController(vc);
    }];

    UIAction *share = [UIAction actionWithTitle:@"Share Profile"
                                          image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                     identifier:nil
                                        handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileMoreMenuShare(vc);
    }];
    UIMenu *actionsSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[edit, share]];

    return [UIMenu menuWithTitle:@"" children:@[gallerySection, actionsSection]];
}

#pragma mark - Standard-build sheet

// Standard build: keep Apollo's real ActionController (row styling,
// presentation controller, Cancel button) and only replace this own-profile
// sheet's visible rows. The Liquid Glass menu above stays independent.
static NSArray<ApolloActionMenuSpec *> *ApolloProfileMoreMenuSheetRows(UIViewController *viewController) {
    __weak UIViewController *weakVC = viewController;
    NSMutableArray<ApolloActionMenuSpec *> *rows = [NSMutableArray array];
    void (^addRow)(NSString *, NSString *, NSString *, void (^)(UIViewController *)) =
        ^(NSString *identifier, NSString *title, NSString *symbol, void (^perform)(UIViewController *)) {
        ApolloActionMenuSpec *row = [ApolloActionMenuSpec new];
        row.identifier = identifier;
        row.title = ^NSString *(__unused id controller, __unused UITableViewCell *donor) { return title; };
        row.image = ^UIImage *(__unused id controller, __unused UITableViewCell *donor) {
            return ApolloActionMenuSymbolIcon(symbol);
        };
        row.legacyDismissesSheet = YES;
        row.perform = ^(__unused id controller) {
            UIViewController *vc = weakVC;
            if (vc.viewIfLoaded.window) perform(vc);
        };
        [rows addObject:row];
    };
    addRow(@"own-profile-gallery", @"Gallery View", @"square.grid.2x2", ^(UIViewController *vc) {
        ApolloProfileMoreMenuOpenGallery(vc);
    });
    addRow(@"own-profile-edit", @"Edit Profile", @"pencil", ^(UIViewController *vc) {
        ApolloProfileEditorOpenFromViewController(vc);
    });
    addRow(@"own-profile-share", @"Share Profile", @"square.and.arrow.up", ^(UIViewController *vc) {
        ApolloProfileMoreMenuShare(vc);
    });
    return rows;
}

// Called from ApolloNativeActionMenus.xm's presentation hooks. Apollo presents
// profile sheets from the navigation controller, so match either presenter.
BOOL ApolloProfileMoreMenuPreparePresentation(UIViewController *presenter, UIViewController *controller) {
    if (IsLiquidGlass()) return YES;
    UIViewController *owner = sApolloProfileMoreMenuBuildingOwner;
    if (!owner || (presenter != owner && presenter != owner.navigationController) ||
        ![controller isKindOfClass:ApolloClassActionController]) return YES;
    if (!ApolloActionMenuSetLegacyReplacementRows(controller, ApolloProfileMoreMenuSheetRows(owner))) {
        ApolloLogError(@"[ProfileMoreMenu] Could not prepare own-profile action sheet");
        return NO;
    }
    ApolloLog(@"[ProfileMoreMenu] Presenting Apollo's own-profile action sheet");
    return YES;
}

#pragma mark - Nav-item normalization

// The single owner of a profile screen's rightBarButtonItems layout. Takes
// whatever is currently installed (Apollo's own "..." included) and enforces
// our own-profile "..." at index 0 (the trailing slot), unless the adaptive
// navigation layout has explicitly placed it on the leading side. Never
// publish the same item on both sides of the bar.
//
// Runs from the lifecycle hooks below AND from the UINavigationItem setter
// hooks: Apollo rewrites a pushed profile's items outright when the user's
// data arrives (that write installs its own "..."), and anything the tweak
// placed with a one-shot append would be silently shed — normalizing after
// every write is what makes our button stick.
static void ApolloProfileMoreMenuNormalize(UIViewController *viewController) {
    if (!viewController) return;
    UINavigationItem *navigationItem = viewController.navigationItem;
    if (ApolloProfileMoreMenuIsNormalizing(navigationItem)) return;

    UIBarButtonItem *apolloItem = ApolloProfileMoreMenuApolloItem(viewController);
    NSArray<UIBarButtonItem *> *currentItems = navigationItem.rightBarButtonItems ?: @[];
    NSMutableArray<UIBarButtonItem *> *desired = [currentItems mutableCopy];
    NSArray<UIBarButtonItem *> *currentLeadingItems = navigationItem.leftBarButtonItems ?: @[];
    NSMutableArray<UIBarButtonItem *> *desiredLeading = [currentLeadingItems mutableCopy];

    UIBarButtonItem *ours = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);

    NSString *active = ApolloActiveAccountUsername();
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    BOOL bothKnown = resolved.length > 0 && active.length > 0;
    BOOL resolvedAsOwn = bothKnown && [resolved caseInsensitiveCompare:active] == NSOrderedSame;
    BOOL clearlySomeoneElse = bothKnown && !resolvedAsOwn;
    BOOL apolloMenuInstalled = apolloItem && [currentItems containsObject:apolloItem];
    // On a PUSHED profile the username hasn't necessarily resolved by the
    // first normalize pass, and before it does `clearlySomeoneElse` can't
    // fire — installing on "not clearly someone else" alone would flash our
    // button until Apollo's own "..." (or the resolved name) evicted it. A
    // pushed screen therefore has to positively resolve to the signed-in
    // account before ours goes in; the tab root is always the signed-in
    // user's own profile, so it keeps the immediate install.
    BOOL pushedProfile = viewController.navigationController != nil &&
        viewController.navigationController.viewControllers.firstObject != viewController;
    // The signed-in user's profile: an account is active, the screen isn't
    // (and, if pushed, provably can't be) showing someone else, and Apollo
    // hasn't put up its own "...".
    BOOL wantOurs = active.length > 0 && !clearlySomeoneElse && !apolloMenuInstalled &&
        (!pushedProfile || resolvedAsOwn);

    if (wantOurs) {
        if (!ours) {
            // Borrow Apollo's own glyph so the button is pixel-identical to
            // the "..." on other profiles, on both the glass and legacy
            // chromes.
            UIImage *image = apolloItem.image ?: [UIImage systemImageNamed:@"ellipsis"];
            // Built once for the button's lifetime: every handler re-resolves
            // its username (and view controller) at tap time, so there is
            // nothing account- or state-dependent baked in that a later pass
            // would need to refresh — and never reassigning .menu means a
            // normalize can't collapse or re-render the pull-down while the
            // user has it open.
            if (IsLiquidGlass()) {
                ours = [[UIBarButtonItem alloc] initWithImage:image menu:nil];
                ours.menu = ApolloProfileMoreMenuForController(viewController);
            } else {
                ours = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain
                    target:viewController action:@selector(moreOptionsBarButtonItemTappedWithSender:)];
            }
            ours.accessibilityLabel = @"More Options";
            objc_setAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey, ours,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[ProfileMoreMenu] Built own-profile '...' for u/%@ (glyph=%@)",
                      active, apolloItem.image ? @"Apollo's" : @"SF ellipsis");
        }
        if ([desiredLeading containsObject:ours]) {
            [desired removeObject:ours];
        } else if (![desired containsObject:ours]) {
            // Index 0 = the trailing (rightmost) slot, exactly where Apollo
            // puts its "..." on other profiles.
            [desired insertObject:ours atIndex:0];
        }
    } else if (ours) {
        [desired removeObject:ours];
        [desiredLeading removeObject:ours];
    }

    // Load-bearing, not just an optimization: our write below re-enters the
    // setter hooks (suppressed by the per-item flag), but if Apollo REACTS to
    // that write by rewriting the items itself, that rewrite re-enters
    // normalize un-suppressed — this early-out is what makes the second pass
    // converge instead of ping-ponging setter → normalize → setter forever.
    BOOL trailingChanged = ![desired isEqualToArray:currentItems];
    BOOL leadingChanged = ![desiredLeading isEqualToArray:currentLeadingItems];
    if (!trailingChanged && !leadingChanged) return;

    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNormalizingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (leadingChanged) navigationItem.leftBarButtonItems = desiredLeading;
    if (trailingChanged) navigationItem.rightBarButtonItems = desired;
    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNormalizingKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[ProfileMoreMenu] Normalized profile nav items (%lu → %lu; ours=%@ apollo=%@)",
              (unsigned long)currentItems.count, (unsigned long)desired.count,
              wantOurs ? @"YES" : @"NO", apolloMenuInstalled ? @"YES" : @"NO");
}

// The profile view controller a navigation item belongs to, recorded at
// viewDidLoad so the setter hooks can re-normalize after any rewrite. Held
// weakly: the navigation item is owned by the view controller, so a strong
// back-reference would cycle.
static UIViewController *ApolloProfileMoreMenuOwnerForNavigationItem(UINavigationItem *navigationItem) {
    NSHashTable *holder = objc_getAssociatedObject(navigationItem, &kApolloProfileMoreMenuNavOwnerKey);
    return holder.anyObject;
}

static void ApolloProfileMoreMenuAdoptNavigationItem(UIViewController *viewController) {
    UINavigationItem *navigationItem = viewController.navigationItem;
    NSHashTable *holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:viewController];
    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNavOwnerKey, holder,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloProfileMoreMenuNavigationItemChanged(UINavigationItem *navigationItem) {
    UIViewController *owner = ApolloProfileMoreMenuOwnerForNavigationItem(navigationItem);
    if (owner) ApolloProfileMoreMenuNormalize(owner);
}

#pragma mark - Hooks

%hook _TtC6Apollo21ProfileViewController

// Standard build, own profile: let Apollo build its real sheet, and mark this
// controller as the owner so the presentation hook swaps in our rows.
- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    UIViewController *viewController = (UIViewController *)self;
    UIBarButtonItem *ours = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    if (IsLiquidGlass() || !ours || sender != ours) {
        %orig;
        return;
    }
    void *signedInTypeStorage = NULL;
    BOOL tabRoot = viewController.navigationController.viewControllers.firstObject == viewController;
    if (tabRoot) {
        // Apollo 1.15.11's sheet builder (0x1007bc048) reads profileType's two
        // String words and returns early when word 1 is nil (.signedInUser),
        // so the account tab would get no sheet. The class metadata declares a
        // 16-byte enum, with hasVotesPublic next. Supply the live username only
        // for this synchronous build, via Swift assignment for ownership, then
        // restore .signedInUser.
        ptrdiff_t offset = ApolloIvarOffset(object_getClass(self), "profileType");
        ptrdiff_t next = ApolloIvarOffset(object_getClass(self), "hasVotesPublic");
        if (offset < 0 || next != offset + 16 ||
            (size_t)next > class_getInstanceSize(object_getClass(self))) {
            ApolloLogError(@"[ProfileMoreMenu] Unrecognized account profile type layout");
            return;
        }
        uint64_t *words = (uint64_t *)((uint8_t *)(__bridge void *)self + offset);
        // Apollo checks only the second word for nil.
        if (words[1] == 0) signedInTypeStorage = words;
    }
    NSString *active = ApolloActiveAccountUsername();
    if (signedInTypeStorage && active.length == 0) return;
    UIViewController *previousOwner = sApolloProfileMoreMenuBuildingOwner;
    sApolloProfileMoreMenuBuildingOwner = viewController;
    @try {
        if (signedInTypeStorage) ApolloSwiftAssignOptionalString(signedInTypeStorage, active.UTF8String);
        %orig;
    } @finally {
        if (signedInTypeStorage) ApolloSwiftAssignOptionalString(signedInTypeStorage, NULL);
        sApolloProfileMoreMenuBuildingOwner = previousOwner;
    }
}

- (void)viewDidLoad {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    ApolloProfileMoreMenuAdoptNavigationItem(viewController);
    ApolloProfileMoreMenuNormalize(viewController);
}

// Re-assert once the screen settles: userInfo may only resolve after the first
// layout, and Apollo installs its own "..." for pushed profiles around
// presentation time.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileMoreMenuNormalize((UIViewController *)self);
}

// Account switches repoint the tab at a different user (or none): rebuild.
- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloProfileMoreMenuNormalize(viewController);
    });
}

%end

// Apollo replaces a pushed profile's rightBarButtonItems outright once the
// user's data arrives (that write is what installs its own "..."), which used
// to wipe any button the tweak had appended at viewDidLoad — the Hidden &
// Deleted eye simply vanished on other people's profiles. Catching the setters
// re-normalizes after every rewrite, whoever makes it and whenever it lands.
// Non-profile navigation items carry no owner association and fall straight
// through to %orig.
%hook UINavigationItem

- (void)setRightBarButtonItems:(NSArray *)items {
    %orig;
    ApolloProfileMoreMenuNavigationItemChanged(self);
}

- (void)setRightBarButtonItems:(NSArray *)items animated:(BOOL)animated {
    %orig;
    ApolloProfileMoreMenuNavigationItemChanged(self);
}

// The singular form doesn't necessarily funnel through the plural public
// setter, so it gets its own hook.
- (void)setRightBarButtonItem:(UIBarButtonItem *)item {
    %orig;
    ApolloProfileMoreMenuNavigationItemChanged(self);
}

%end

%ctor {
    %init;
    ApolloLog(@"[ProfileMoreMenu] Own-profile '...' menu hooks installed");
}
