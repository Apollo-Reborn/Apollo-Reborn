// ApolloStickiedMarkRead.xm — "Mark Stickied Posts Read": lets Mark Read on
// Scroll mark stickied posts read too (issue #1790).
//
// Apollo's own Mark Read on Scroll deliberately skips stickied posts: the
// scroll-off handler of both feed cell classes
// (LargePostCellNode -didExitVisibleState → FUN_10030815c,
//  CompactPostCellNode -didExitVisibleState → FUN_1007e28ac; Ghidra) runs, in
// this order:
//   1. return if the scene is in the background
//   2. return if the cell's isRead ivar is set
//   3. return if DisableMarkingPostsRead is on, or MarkReadOnScroll is off
//   4. return if [link stickied]                      <- the guard we answer
//   5. return unless the cell left through the top of the table
//   6. actionDelegate (PostCellActionTaker) marks the post read
// Step 6 is Swift (not hookable, and calling binary addresses is banned), so this
// module answers step 4's ObjC message instead: right before %orig it arms the
// cell's own RDKLink, and that link's next main-thread -stickied returns NO,
// once. Everything else Apollo decides stays native (position, isRead,
// background), and the mark-read path itself (step 6) never messages stickied,
// so the one-shot can only be spent by the guard (verified in Ghidra; nothing
// that runs earlier in the handler messages the link either: FUN_10030868c /
// FUN_1007e2e24 are type-metadata accessors, super is ASCellNode, and the other
// tweak hooks on these selectors — ApolloIntelligenceBridge's Siri annotation and
// ApolloCommentVoteFlicker's tracking — never read stickied).
//
// Stickies are only armed once the cell has really scrolled off the TOP of the
// list (its bottom edge at or above the table's top edge). Apollo's own step 5
// is looser (cell top < table bottom), and that also passes for cells that exit
// while still on screen: opening a subreddit reloads the feed as its header and
// subscription state arrive, and the visible cells exit and re-enter (measured:
// the sticky exits at y 362-474 with the list showing 0-704). Apollo already
// marks the normal posts on screen read in that reload (seen on main, toggle
// off); stickies, which always sit at the top, would otherwise go grey the
// moment a subreddit opens instead of when they are scrolled past.
//
// The arm is cleared in @finally after %orig whether or not it was used, so a
// handler that returned early (backgrounded, off-window) leaves nothing behind.
// -stickied is hot (Texture layout specs read it on background threads), so its
// hook bails on a single pointer compare and also requires the main thread.
//
// The setting row is appended to the first section of General > Mark Read /
// Hiding Posts through ApolloSettingsGeneralTable (the one owner of that native
// screen's geometry). That form is dynamic — Disable Marking Posts Read hides
// every other row — so the row is appended after the native rows rather than
// spliced under Mark Read on Scroll, hides with the others while Disable Marking
// Posts Read is on, and greys out while Mark Read on Scroll is off.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsGeneralTable.h"

static NSString *const kSMRRowTitle = @"Mark Stickied Posts Read";
static NSString *const kSMRMarkReadOnScrollTitle = @"Mark Read on Scroll";
// Never hidden (it is the switch that hides the others), so it names the section.
static NSString *const kSMRDisableTitle = @"Disable Marking Posts Read";
// Apollo's own key for the native "Disable Marking Posts Read" switch (read only).
static NSString *const kSMRApolloDisableMarkingPostsReadKey = @"DisableMarkingPostsRead";

#pragma mark - The one-shot guard answer

// The RDKLink whose next main-thread -stickied answers NO. Set and cleared on the
// main thread around one -didExitVisibleState; background readers only compare it.
static void *volatile sSMRArmedLink = NULL;

static BOOL SMRNativeMarkReadOnScrollActive(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:UDKeyApolloMarkReadOnScroll] &&
        ![defaults boolForKey:kSMRApolloDisableMarkingPostsReadKey];
}

// YES when the cell node's table cell sits entirely above the table's visible
// top, i.e. it left by being scrolled past. Same view chain Apollo's handler
// walks (node view -> superview -> UITableViewCell -> UITableView); anything
// else answers NO, which keeps the stock behaviour.
static BOOL SMRCellScrolledOffTop(id cellNode) {
    if (!((BOOL (*)(id, SEL))objc_msgSend)(cellNode, @selector(isNodeLoaded))) return NO;
    UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(cellNode, @selector(view));
    UIView *cell = view.superview.superview;
    UIView *table = cell.superview;
    if (![cell isKindOfClass:[UITableViewCell class]] || ![table isKindOfClass:[UITableView class]]) return NO;
    // 1 pt of slack for fractional frames; a cell exiting mid-screen misses by far more.
    return CGRectGetMaxY(cell.frame) <= CGRectGetMinY(table.bounds) + 1.0;
}

// The cell's link when Apollo's handler is about to reach the stickied guard for
// a stickied post this setting should let through; nil otherwise. Mirrors guard
// steps 2-4 so an arm is only placed when the guard is the next -stickied read,
// and requires a real scroll-off (see the header).
static id SMRArmableLink(id cellNode) {
    if (!sMarkStickiedPostsReadOnScroll || ![NSThread isMainThread]) return nil;
    id link = ApolloObjectIvar(cellNode, "link");
    if (!link || ![link respondsToSelector:@selector(stickied)]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(stickied))) return nil;
    if (ApolloReadBoolIvar(cellNode, "isRead", YES)) return nil;
    if (!SMRNativeMarkReadOnScrollActive()) return nil;
    if (!SMRCellScrolledOffTop(cellNode)) return nil;
    return link;
}

static void SMRRunArmed(id link, void (^orig)(void)) {
    sSMRArmedLink = (__bridge void *)link;
    @try {
        orig();
    } @finally {
        BOOL spent = (sSMRArmedLink == NULL);
        sSMRArmedLink = NULL;
        if (spent) {
            ApolloLog(@"[StickyMarkRead] stickied post handed to Mark Read on Scroll");
        } else {
            // Apollo returned before its stickied check (scene in the background).
            ApolloLog(@"[StickyMarkRead] arm unused (handler returned before the stickied check)");
        }
    }
}

%group ApolloStickiedMarkRead

%hook RDKLink

- (BOOL)stickied {
    if ((__bridge void *)self != sSMRArmedLink) return %orig;
    if (![NSThread isMainThread]) return %orig;
    sSMRArmedLink = NULL;   // one-shot: only the scroll-off guard sees NO
    return NO;
}

%end

%hook LargePostCellNode

- (void)didExitVisibleState {
    id link = SMRArmableLink(self);
    if (!link) { %orig; return; }
    SMRRunArmed(link, ^{ %orig; });
}

%end

%hook CompactPostCellNode

- (void)didExitVisibleState {
    id link = SMRArmableLink(self);
    if (!link) { %orig; return; }
    SMRRunArmed(link, ^{ %orig; });
}

%end

%end

#pragma mark - Settings row (General > Mark Read / Hiding Posts)

static const void *kSMRRowCellKey = &kSMRRowCellKey;
static const void *kSMRNativeSwitchObservedKey = &kSMRNativeSwitchObservedKey;

static BOOL SMRRowVisible(void) {
    return ![[NSUserDefaults standardUserDefaults] boolForKey:kSMRApolloDisableMarkingPostsReadKey];
}

static void SMRApplyRowEnabled(UITableViewCell *cell) {
    UISwitch *sw = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
    if (!sw) return;
    BOOL enabled = SMRNativeMarkReadOnScrollActive();
    sw.enabled = enabled;
    cell.textLabel.enabled = enabled;
}

@interface SMRRowTarget : NSObject
@property (nonatomic, weak) UIViewController *vc;
- (void)rowSwitchToggled:(UISwitch *)sender;
- (void)nativeSwitchToggled:(UISwitch *)sender;
@end

@implementation SMRRowTarget
- (void)rowSwitchToggled:(UISwitch *)sender {
    sMarkStickiedPostsReadOnScroll = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyMarkStickiedPostsReadOnScroll];
    ApolloLog(@"[StickyMarkRead] Mark Stickied Posts Read -> %d", sender.isOn);
}
// Runs after Eureka's own valueChanged target (added when the cell was built), so
// Apollo has already written the native key, and Eureka has finished hiding or
// showing its rows, by the time the row is re-greyed and shown or hidden.
- (void)nativeSwitchToggled:(UISwitch *)sender {
    UIViewController *vc = self.vc;
    SMRApplyRowEnabled(objc_getAssociatedObject(vc, kSMRRowCellKey));
    ApolloNativeSettingsRefreshAppendedRow(vc);
}
@end

static SMRRowTarget *sSMRRowTarget = nil;

// Built once per screen instance, then restyled from the live donor (the
// section's first native row, a switch row) and re-read from defaults on every
// dequeue, so it never goes stale.
static UITableViewCell *SMRBuildRow(UIViewController *vc, UITableViewCell *donor) {
    UITableViewCell *cell = objc_getAssociatedObject(vc, kSMRRowCellKey);
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (!cell || ![sw isKindOfClass:[UISwitch class]]) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = kSMRRowTitle;
        sw = [[UISwitch alloc] init];
        [sw addTarget:sSMRRowTarget action:@selector(rowSwitchToggled:)
     forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        objc_setAssociatedObject(vc, kSMRRowCellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (donor) {   // borrow the sibling switch row's live theming
        cell.backgroundColor = donor.backgroundColor;
        cell.textLabel.font = donor.textLabel.font;
        cell.textLabel.textColor = donor.textLabel.textColor;
    }
    UISwitch *donorSwitch = [donor.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)donor.accessoryView : nil;
    // Match the native switches (nil = system green); the accent is only the
    // fallback when there is no native switch to copy.
    sw.onTintColor = donorSwitch ? donorSwitch.onTintColor : ApolloThemeAccentColor();
    sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyMarkStickiedPostsReadOnScroll];
    SMRApplyRowEnabled(cell);
    return cell;
}

// The two native switches that make the row inert re-grey it the moment they
// change. Eureka hands their cells to the configurator on every dequeue; the
// associated flag keeps it to one target per switch, and the target only holds
// the screen weakly.
static void SMRObserveNativeSwitch(UIViewController *vc, UITableViewCell *cell) {
    UISwitch *sw = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
    if (!sw || objc_getAssociatedObject(sw, kSMRNativeSwitchObservedKey)) return;
    SMRRowTarget *target = [SMRRowTarget new];
    target.vc = vc;
    [sw addTarget:target action:@selector(nativeSwitchToggled:) forControlEvents:UIControlEventValueChanged];
    // UIControl doesn't retain its targets; the switch keeps this one alive.
    objc_setAssociatedObject(sw, kSMRNativeSwitchObservedKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%ctor {
    Class large = objc_getClass("_TtC6Apollo17LargePostCellNode");
    Class compact = objc_getClass("_TtC6Apollo19CompactPostCellNode");
    Class link = objc_getClass("RDKLink");
    SEL exitSel = @selector(didExitVisibleState);
    if (!large || !compact || !link ||
        !class_getInstanceMethod(large, exitSel) || !class_getInstanceMethod(compact, exitSel) ||
        !class_getInstanceMethod(link, @selector(stickied))) {
        // Tripwire: with the hooks missing the row would do nothing, so don't add it.
        ApolloLog(@"[StickyMarkRead] NOT installed: Large=%d Compact=%d RDKLink=%d",
                  large != nil, compact != nil, link != nil);
        return;
    }
    %init(ApolloStickiedMarkRead, LargePostCellNode = large, CompactPostCellNode = compact, RDKLink = link);
    ApolloLog(@"[StickyMarkRead] hook installed (Large/Compact didExitVisibleState + RDKLink stickied)");

    sSMRRowTarget = [SMRRowTarget new];
    ApolloNativeSettingsAppendRow(ApolloNativeSettingsScreenMarkReadHidingPosts, kSMRDisableTitle,
        ^BOOL {
            return SMRRowVisible();
        },
        ^UITableViewCell *(UIViewController *vc, UITableViewCell *donor) {
            return SMRBuildRow(vc, donor);
        });
    for (NSString *title in @[ kSMRMarkReadOnScrollTitle, kSMRDisableTitle ]) {
        ApolloNativeSettingsConfigureNativeRow(ApolloNativeSettingsScreenMarkReadHidingPosts, title,
            ^(UIViewController *vc, UITableViewCell *cell) {
                SMRObserveNativeSwitch(vc, cell);
            });
    }
}
