// Jump Button Navigation: one mode picker shared by native General settings
// and the comments navigation bar's More menu. The existing table/menu owners
// perform all row insertion and index remapping; this module supplies specs.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloActionMenu.h"
#import "ApolloActionMenuLayout.h"
#import "ApolloClasses.h"
#import "ApolloCommentNavigator.h"
#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloSettingsForm.h"
#import "settings/ApolloSettingsGeneralTable.h"

static NSString *const kCNTitle = @"Jump Button Navigation";
static char kCNSettingsCellKey;
static char kCNMenuOwnerKey;

// Short enough to fit beside "Jump Button Navigation" in the settings row.
static NSArray<NSString *> *CNModeTitles(void) {
    return @[@"Threads", @"New Comments"];
}

static NSString *CNModeTitle(void) {
    return CNModeTitles()[ApolloCommentNavigatorMode() == ApolloCommentNavigationModeNewComments ? 1 : 0];
}

static void CNRefreshSettingsDetail(void) {
    UIViewController *general = ApolloGeneralTableActiveVC();
    UITableViewCell *cell = objc_getAssociatedObject(general, &kCNSettingsCellKey);
    cell.detailTextLabel.text = CNModeTitle();
    [cell setNeedsLayout];
}

static UIMenu *CNModeMenu(void) {
    NSMutableArray<UIMenuElement *> *choices = [NSMutableArray array];
    NSArray<NSString *> *titles = CNModeTitles();
    for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
        UIAction *action = [UIAction actionWithTitle:titles[index] image:nil identifier:nil
            handler:^(__unused UIAction *selected) {
                ApolloCommentNavigatorSetMode((ApolloCommentNavigationMode)index);
                CNRefreshSettingsDetail();
            }];
        action.state = ApolloCommentNavigatorMode() == index ? UIMenuElementStateOn : UIMenuElementStateOff;
        [choices addObject:action];
    }
    return [UIMenu menuWithTitle:@"Jump Button Navigation"
                         image:ApolloActionMenuSymbolIcon(@"arrow.down.to.line")
                    identifier:nil options:0 children:choices];
}

void ApolloCommentNavigatorPresentModePicker(UIViewController *presenter, UIView *sourceView) {
    if (!presenter.viewIfLoaded.window || presenter.presentedViewController || presenter.isBeingDismissed) {
        ApolloLog(@"[CommentNavigator] Mode picker skipped: presenter is unavailable or already presenting");
        return;
    }
    if (!IsLiquidGlass()) {
        // Standard builds use the settings screens' shared action sheet; the
        // anchored UIMenu belongs to Liquid Glass.
        ApolloSettingsPresentPicker(presenter, sourceView.window ? sourceView : nil, kCNTitle,
            CNModeTitles(), ApolloCommentNavigatorMode() == ApolloCommentNavigationModeNewComments ? 1 : 0,
            ^(NSInteger picked) {
                ApolloCommentNavigatorSetMode((ApolloCommentNavigationMode)picked);
                CNRefreshSettingsDetail();
            });
        // Follow Apollo's theme like its own sheets: accent-tinted actions and
        // the theme's light/dark style rather than the system defaults.
        UIViewController *sheet = presenter.presentedViewController;
        if ([sheet isKindOfClass:UIAlertController.class]) {
            sheet.view.tintColor = ApolloThemeAccentColor() ?: presenter.view.tintColor;
            sheet.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle;
        }
        ApolloLog(@"[CommentNavigator] Navigation mode action sheet presented");
        return;
    }
    UIView *anchor = sourceView.window ? sourceView : presenter.view;
    BOOL presented = ApolloNativeActionMenuPresentCaptured(CNModeMenu(), anchor, presenter, nil);
    ApolloLog(@"[CommentNavigator] Navigation mode UIMenu %@", presented ? @"presented" : @"unavailable");
}

static UITableViewCell *CNSettingsCell(UIViewController *vc, UITableViewCell *donor) {
    UITableViewCell *cell = objc_getAssociatedObject(vc, &kCNSettingsCellKey);
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.textLabel.text = kCNTitle;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // A value picker opens at this row; no disclosure arrow implying a page.
        cell.accessoryType = UITableViewCellAccessoryNone;
        objc_setAssociatedObject(vc, &kCNSettingsCellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.backgroundColor = donor.backgroundColor ?: ApolloThemeCardBackgroundColor();
    cell.textLabel.font = donor.textLabel.font ?: cell.textLabel.font;
    cell.detailTextLabel.font = donor.detailTextLabel.font ?: cell.textLabel.font;
    cell.textLabel.textColor = ApolloThemeSettingsTextColor() ?: donor.textLabel.textColor;
    cell.detailTextLabel.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = CNModeTitle();
    return cell;
}

// The action-menu context is captured by the existing presentation owner.
// Resolve its visible comments screen once, then retain it weakly on that
// exact ActionController. The legacy owner dismisses before invoking perform,
// so looking at presentingViewController only at tap time would be too late.
static UIViewController *CNVisibleCommentsController(UIViewController *vc) {
    if (!vc || !vc.viewIfLoaded.window) return nil;
    UIViewController *found = CNVisibleCommentsController(vc.presentedViewController);
    if (found) return found;
    // topViewController, not visibleViewController: the legacy More sheet
    // asks for its rows once presented, and visibleViewController is then
    // that sheet rather than the comments screen under it.
    if ([vc isKindOfClass:UINavigationController.class]) {
        return CNVisibleCommentsController(((UINavigationController *)vc).topViewController);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return CNVisibleCommentsController(((UITabBarController *)vc).selectedViewController);
    }
    // On iPad the visible comments controller can live in a split container.
    for (UIViewController *child in vc.childViewControllers.reverseObjectEnumerator) {
        found = CNVisibleCommentsController(child);
        if (found) return found;
    }
    return ApolloClassCommentsViewController && [vc isKindOfClass:ApolloClassCommentsViewController] ? vc : nil;
}

static UIViewController *CNMenuOwner(id controller, BOOL claim) {
    NSHashTable *holder = objc_getAssociatedObject(controller, &kCNMenuOwnerKey);
    if (holder || !claim) return holder.anyObject;
    if (![ApolloActionMenuContextForController(controller) isEqualToString:ApolloActionMenuContextPostDetail]) return nil;

    UIViewController *owner = CNVisibleCommentsController(((UIViewController *)controller).presentingViewController);
    if (!owner) {
        for (UIWindow *window in ApolloAllWindows()) {
            if (!window.isKeyWindow) continue;
            owner = CNVisibleCommentsController(window.rootViewController);
            if (owner) break;
        }
    }
    if (!owner) return nil;
    holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:owner];
    objc_setAssociatedObject(controller, &kCNMenuOwnerKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return owner;
}

// Set only for the duration of the synchronous More-tap that reopens the
// sheet, so no other presentation can pick up the mode rows.
static __weak UIViewController *sCNModeSheetOwner;

static NSArray<ApolloActionMenuSpec *> *CNModeSheetRows(void) {
    NSArray<NSString *> *titles = CNModeTitles();
    NSArray<NSString *> *symbols = @[@"text.bubble", @"sparkles"];
    NSMutableArray<ApolloActionMenuSpec *> *rows = [NSMutableArray array];
    for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
        ApolloActionMenuSpec *row = [ApolloActionMenuSpec new];
        row.identifier = [NSString stringWithFormat:@"CommentNavigatorMode%ld", (long)index];
        row.title = ^NSString *(__unused id controller, __unused UITableViewCell *donor) { return titles[index]; };
        row.image = ^UIImage *(__unused id controller, __unused UITableViewCell *donor) {
            return ApolloActionMenuSymbolIcon(symbols[index]);
        };
        row.checked = ^BOOL(__unused id controller) { return ApolloCommentNavigatorMode() == index; };
        row.legacyDismissesSheet = YES;
        row.perform = ^(__unused id controller) {
            ApolloCommentNavigatorSetMode((ApolloCommentNavigationMode)index);
            CNRefreshSettingsDetail();
        };
        [rows addObject:row];
    }
    return rows;
}

void ApolloCommentNavigatorPreparePresentation(UIViewController *controller) {
    if (!sCNModeSheetOwner || IsLiquidGlass() || !ApolloClassActionController ||
        ![controller isKindOfClass:ApolloClassActionController]) return;
    sCNModeSheetOwner = nil;
    BOOL replaced = ApolloActionMenuSetLegacyReplacementRows(controller, CNModeSheetRows());
    ApolloLog(@"[CommentNavigator] Standard mode sheet %@", replaced ? @"prepared" : @"could not be prepared");
}

%ctor {
    ApolloGeneralTableInjectSelectableRow(@"Jump Button Position", @"Show Jump Button",
        ^UITableViewCell *(UIViewController *vc, UITableViewCell *donor) {
            return CNSettingsCell(vc, donor);
        },
        ^(UIViewController *vc) {
            ApolloCommentNavigatorPresentModePicker(vc, objc_getAssociatedObject(vc, &kCNSettingsCellKey));
        });

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"CommentNavigator";
    spec.order = 30;
    spec.placement = ApolloActionMenuPlacementAppend;
    spec.legacyDismissesSheet = YES;
    spec.matches = ^BOOL(id controller, __unused NSString *menuTitle) {
        return CNMenuOwner(controller, YES) != nil;
    };
    spec.title = ^NSString *(__unused id controller, __unused UITableViewCell *donor) {
        return @"Jump Button Navigation";
    };
    spec.image = ^UIImage *(__unused id controller, __unused UITableViewCell *donor) {
        return ApolloActionMenuSymbolIcon(@"arrow.down.to.line");
    };
    spec.buildElement = ^(__unused id controller, NSMutableArray<UIMenuElement *> *children) {
        // A real submenu: selection changes the preference directly, without
        // dismissing More and presenting a second modal. The shared owner
        // applies the saved row order/hidden setting to this element too.
        [children addObject:CNModeMenu()];
    };
    spec.perform = ^(id controller) {
        // Standard builds have no nested menus. Once the More sheet has
        // dismissed, reopen Apollo's own More sheet from the same screen and
        // swap its rows for the two modes (see ApolloCommentNavigatorPreparePresentation).
        UIViewController *owner = CNMenuOwner(controller, NO);
        SEL selector = @selector(moreOptionsBarButtonItemTappedWithSender:);
        if (!owner.viewIfLoaded.window || ![owner respondsToSelector:selector]) return;
        sCNModeSheetOwner = owner;
        ((void (*)(id, SEL, id))objc_msgSend)(owner, selector, ApolloObjectIvar(owner, "moreOptionsBarButtonItem"));
        if (sCNModeSheetOwner) ApolloLogError(@"[CommentNavigator] Apollo did not present a More sheet for the mode picker");
        sCNModeSheetOwner = nil;
    };
    ApolloActionMenuRegister(spec);
    ApolloLog(@"[CommentNavigator] Settings row and comments More-menu shortcut registered");
}
