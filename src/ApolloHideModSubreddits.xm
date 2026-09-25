#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
#import "UserDefaultConstants.h"

// MARK: - Hide Moderated Subreddits
//
// Reddit offers no way to leave or delete some dead subreddits you moderate,
// so they're stuck in the MODERATOR section of Apollo's Subreddits list
// forever. This module lets the user hide them from that list, entirely
// through Edit mode, WITHOUT touching the moderator powers you have on those
// subreddits when you actually visit them.
//
// Why the display filter has to be this surgical
// ----------------------------------------------
// Apollo has a single source of truth for "which subreddits do I moderate":
// the `RDKUser.moderatedSubreddits` array. The Subreddits list populates it —
// `RedditListViewController.fetchSubredditData()` assigns the moderated-subs
// fetch result straight into `currentUser.moderatedSubreddits` — and then the
// list reads that very property back to build its MODERATOR section (row count,
// header height, each cell, taps, the context menu all call the getter).
//
// Crucially, the SAME property is what gates moderator powers everywhere else:
// PostsViewController / CommentsViewController decide whether to show the mod
// toolbar by checking `currentUser.moderatedSubreddits`, the inbox colours mod
// mail from it, etc. (~50 read sites across the app).
//
// The original version of this feature (PR #424) hid rows by filtering the
// data layer — wrapping `-[RDKClient moderatedSubredditsWithPagination:
// completion:]` so hidden subs never reached the list. But that fetch result
// is exactly what gets stored into `currentUser.moderatedSubreddits`, so the
// filter shrank the shared source of truth: hide every sub you moderate and
// the app concludes you moderate nothing — no mod badge, no mod tools when you
// open those subreddits. (Reported: "Hiding them all removed moderator
// badge/access to options in subreddits you're a mod on.")
//
// The fix keeps `moderatedSubreddits` complete (mod powers intact) and instead
// filters only the GETTER, and only while the Subreddits list's own table
// methods are running:
//
// 1. The data layer is left untouched, so `currentUser.moderatedSubreddits`
//    always holds the full Reddit-reported set. Every moderator-power check
//    app-wide sees the real list.
// 2. `-[RDKUser moderatedSubreddits]` is hooked. It returns the full array
//    everywhere EXCEPT inside the Subreddits list's row-SIZING/BUILDING table
//    methods (numberOfRows, heightForHeader, cellForRow), where it returns the
//    array with hidden subs removed. A thread-local depth counter, bumped only
//    around those methods' `%orig`, scopes the filtering precisely (and keeps
//    background mod-power checks on other threads unaffected).
// 3. In Edit mode the filter is bypassed so hidden rows reappear (faded, with
//    a green plus circle) and can be unhidden inline.
//
// Because numberOfRows, heightForHeader and cellForRow all read the same
// filtered getter, the MODERATOR section's row count, header and cells stay
// consistent automatically — when every moderated sub is hidden the section
// collapses to nothing. Toggling Edit mode just reloads the table; no network
// refetch is needed.
//
// The methods that NAVIGATE off a row (didSelect, contextMenu) need the same
// filtered view while Apollo RESOLVES which subreddit the tapped row means:
// each table method re-reads moderatedSubreddits and re-sorts it for display
// (verified at runtime: the stored array's order differs from the rendered
// order), so a visible row index is only meaningful against the filtered list
// — translating indices against the stored full array is unfixably fragile.
// But the filter must NOT stay active while the resulting push runs:
// pushViewController: executes the opened subreddit's viewDidLoad/
// viewWillAppear synchronously, and those gate the moderator toolbar on
// reading moderatedSubreddits — under the filter, a moderated-but-hidden sub
// reached from the alphabetical section would lose its mod tools (the PR #500
// bug). So the nav methods set a thread-local flag that scopes the filter to
// row resolution only: a UINavigationController hook clears it the moment the
// push begins (and it is unconditionally reset when %orig returns), so every
// mod-power check during the push sees the complete list.
//
// The hidden list is stored in NSUserDefaults under
// UDKeyHiddenModeratorSubreddits as an array of display names, compared
// case-insensitively. Note: the list is global across Reddit accounts.

@interface RedditListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

// Minimal surface for the model class whose getter we scope. RDKUser is always
// present in Apollo; a forward declaration is enough for the %hook.
@interface RDKUser : NSObject
- (NSArray *)moderatedSubreddits;
@end

// Thread-local nesting depth of "we are currently inside a Subreddits-list
// table method that reads moderatedSubreddits for display." The getter only
// filters when this is > 0, so every other reader (moderator-power checks,
// inbox, jump bar, background work) sees the complete list. Thread-local so a
// mod-power check running on another thread is never caught by the window.
static __thread NSInteger sListFilterDepth = 0;

// While the Subreddits list is in Edit mode the filter is bypassed entirely so
// hidden rows are shown (faded) and can be unhidden. Set on the main thread in
// setEditing:; read by the getter.
static BOOL sShowHiddenForEditing = NO;

// YES only while a MODERATOR-section tap or context-menu %orig is resolving
// which row was selected. The moderatedSubreddits getter filters during this
// window exactly like the display window, so Apollo resolves the row against
// the same (filtered, then Apollo-sorted) list the visible rows were built
// from. Cleared by the UINavigationController push hook the moment navigation
// starts — the pushed controller's synchronous mod-power checks must see the
// complete list — and unconditionally when the nav method's %orig returns.
// Thread-local like the depth counter (all writers run on the main thread).
static __thread BOOL sNavResolveFilterActive = NO;

// Tag + associated keys for the per-cell hide/unhide button.
static const NSInteger kApolloHideModButtonTag = 0x484D53; // 'HMS'
static char kApolloHideModButtonNameKey;

// MARK: - Hidden list persistence

static NSArray<NSString *> *ApolloHideModHiddenList(void) {
    NSArray *list = [[NSUserDefaults standardUserDefaults] stringArrayForKey:UDKeyHiddenModeratorSubreddits];
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

static void ApolloHideModSetHiddenList(NSArray<NSString *> *list) {
    [[NSUserDefaults standardUserDefaults] setObject:(list ?: @[]) forKey:UDKeyHiddenModeratorSubreddits];
    ApolloLog(@"[HideModSubs] hidden list now has %lu entries", (unsigned long)list.count);
}

static BOOL ApolloHideModNameIsHidden(NSString *name) {
    if (name.length == 0) return NO;
    for (NSString *hidden in ApolloHideModHiddenList()) {
        if ([hidden caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    }
    return NO;
}

static void ApolloHideModAddHidden(NSString *name) {
    if (name.length == 0 || ApolloHideModNameIsHidden(name)) return;
    NSMutableArray *list = [ApolloHideModHiddenList() mutableCopy];
    [list addObject:name];
    ApolloHideModSetHiddenList(list);
    ApolloLog(@"[HideModSubs] hid subreddit %@", name);
}

static void ApolloHideModRemoveHidden(NSString *name) {
    if (name.length == 0) return;
    NSMutableArray *list = [ApolloHideModHiddenList() mutableCopy];
    NSUInteger before = list.count;
    for (NSUInteger idx = list.count; idx > 0; idx--) {
        if ([list[idx - 1] caseInsensitiveCompare:name] == NSOrderedSame) [list removeObjectAtIndex:idx - 1];
    }
    if (list.count != before) {
        ApolloHideModSetHiddenList(list);
        ApolloLog(@"[HideModSubs] unhid subreddit %@", name);
    }
}

// MARK: - Getter-level display filter

// The display name of one entry in moderatedSubreddits. Entries are RDKSubreddit
// objects (they respond to -name); fall back to treating the entry as a plain
// name string just in case the model ever changes.
static NSString *ApolloHideModNameForEntry(id entry) {
    if ([entry respondsToSelector:@selector(name)]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(entry, @selector(name));
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    if ([entry isKindOfClass:[NSString class]]) return entry;
    return nil;
}

// Returns the moderated-subreddits array with hidden entries removed. Returns
// the input unchanged when nothing is hidden, so the common case allocates
// nothing.
static NSArray *ApolloHideModFilteredList(NSArray *full) {
    if (![full isKindOfClass:[NSArray class]] || full.count == 0) return full;
    if (ApolloHideModHiddenList().count == 0) return full;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:full.count];
    for (id entry in full) {
        NSString *name = ApolloHideModNameForEntry(entry);
        if (name.length > 0 && ApolloHideModNameIsHidden(name)) continue;
        [filtered addObject:entry];
    }
    if (filtered.count == full.count) return full;
    return filtered;
}

%hook RDKUser

// Source of truth for moderator powers app-wide. Return the full list normally;
// return the hidden-filtered list ONLY while the Subreddits list is reading it
// for display and we're not in Edit mode. This hides the rows without ever
// telling the rest of the app you moderate fewer subreddits.
- (NSArray *)moderatedSubreddits {
    NSArray *full = %orig;
    if (sListFilterDepth <= 0 && !sNavResolveFilterActive) return full;
    if (sShowHiddenForEditing) return full;
    return ApolloHideModFilteredList(full);
}

%end

// Ends the navigation-resolve filter window the instant a push begins: the
// tapped moderator row has been resolved by now, and everything from here on —
// including the pushed subreddit's viewDidLoad/viewWillAppear moderator-toolbar
// gates, which UIKit runs synchronously inside pushViewController: — must read
// the complete moderated list. No-op (one flag test) for every normal push.
%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (sNavResolveFilterActive) {
        sNavResolveFilterActive = NO;
        ApolloLog(@"[HideModSubs] nav filter window closed at push; mod checks see the full list");
    }
    %orig;
}

%end

// MARK: - Subreddits list UI helpers

// Leftmost non-empty UILabel in a view tree. Subreddit list cells contain the
// title label, an icon image, and the favorite star control — the title is
// the only (and leftmost) label. Section headers contain just the title label.
static NSString *ApolloHideModLeftmostLabelText(UIView *root) {
    if (!root) return nil;

    UILabel *best = nil;
    CGFloat bestX = CGFLOAT_MAX;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)candidate;
            NSString *text = [label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) {
                CGFloat minX = CGRectGetMinX([label convertRect:label.bounds toView:root]);
                if (minX < bestX) {
                    best = label;
                    bestX = minX;
                }
            }
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    return [best.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Resolves a section's header title (uppercased) by checking the visible
// header first, then asking the delegate to build one.
// While ApolloFollowingSection's section remap is engaged, the index paths
// reaching this module's hooks are already in Apollo's NATIVE section space,
// where the on-screen header walk (visible space) would lie — ask that module
// for the canonical native title instead.
static NSString *ApolloHideModSectionTitle(id delegate, UITableView *tableView, NSInteger section) {
    NSString *canonical = ApolloFollowingCanonicalTitleForNativeSection(tableView, section);
    if (canonical) return canonical.length > 0 ? canonical : nil;

    if (!tableView || section < 0 || section >= tableView.numberOfSections) return nil;

    UIView *header = [tableView headerViewForSection:section];
    if (!header && [delegate respondsToSelector:@selector(tableView:viewForHeaderInSection:)]) {
        header = [delegate tableView:tableView viewForHeaderInSection:section];
    }
    NSString *text = ApolloHideModLeftmostLabelText(header);
    return text.length > 0 ? text.uppercaseString : nil;
}

static id ApolloHideModObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UITableView *ApolloHideModTableView(UIViewController *viewController) {
    UITableView *tableView = (UITableView *)ApolloHideModObjectIvar(viewController, "tableView");
    return [tableView isKindOfClass:[UITableView class]] ? tableView : nil;
}

// MARK: - Navigation-resolve filter scope

// Whether a tapped/long-pressed row needs the filter active while Apollo
// resolves it: only MODERATOR-section rows (other sections resolve from
// Apollo's sectionedSubreddits model, which is never filtered), only outside
// Edit mode (filter bypassed there — the visible rows already are the full
// list), and only when something is actually hidden.
static BOOL ApolloHideModShouldScopeNavResolve(id viewController, UITableView *tableView, NSIndexPath *indexPath) {
    if (!indexPath || sShowHiddenForEditing) return NO;
    if (ApolloHideModHiddenList().count == 0) return NO;
    return [ApolloHideModSectionTitle(viewController, tableView, indexPath.section) isEqualToString:@"MODERATOR"];
}

// MARK: - Edit-mode hide/unhide control

// Hide/unhide glyph drawn by hand so the visible circle is exactly 22pt —
// the same diameter as the native red delete control. SF Symbols proved
// unusable here: their point size is a font metric (renders ~15% larger)
// and their images carry transparent padding (renders smaller when fitted),
// so explicit geometry is the only way to actually match the native circle.
static UIImage *ApolloHideModGlyph(BOOL hidden) {
    static UIImage *sHideGlyph = nil;
    static UIImage *sUnhideGlyph = nil;
    UIImage *__strong *slot = hidden ? &sUnhideGlyph : &sHideGlyph;
    if (!*slot) {
        CGFloat diameter = 22.0;
        // Bar proportions matched to the native delete circle's minus glyph.
        CGFloat barLength = 11.0;
        CGFloat barThickness = 2.5;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter)];
        UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [(hidden ? [UIColor systemGreenColor] : [UIColor systemBlueColor]) setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] fill];

            [[UIColor whiteColor] setFill];
            UIBezierPath *horizontalBar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake((diameter - barLength) / 2.0,
                                                                                             (diameter - barThickness) / 2.0,
                                                                                             barLength, barThickness)
                                                                     cornerRadius:barThickness / 2.0];
            [horizontalBar fill];
            if (hidden) {
                UIBezierPath *verticalBar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake((diameter - barThickness) / 2.0,
                                                                                               (diameter - barLength) / 2.0,
                                                                                               barThickness, barLength)
                                                                       cornerRadius:barThickness / 2.0];
                [verticalBar fill];
            }
        }];
        *slot = [drawn imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    return *slot;
}

@interface ApolloModeratorToggleButton : UIButton
@end

@implementation ApolloModeratorToggleButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // Expand sideways only, so adjacent rows keep independent tap targets.
    return CGRectContainsPoint(CGRectInset(self.bounds, -24.0, 0.0), point);
}
@end

static void ApolloHideModAnimateControl(UIButton *button, UITableView *table, BOOL appearing) {
    for (UITableViewCell *peer in table.visibleCells) {
        for (UIView *control in peer.subviews) {
            if (![NSStringFromClass(control.class) isEqualToString:@"UITableViewCellEditControl"]) continue;
            CABasicAnimation *position = (id)[control.layer animationForKey:@"position"];
            if (![position isKindOfClass:CABasicAnimation.class] || !position.fromValue || !position.toValue) continue;
            // Preserve UIKit's spring, duration and start time; offset only the
            // horizontal coordinates because the controls occupy different rows.
            CABasicAnimation *move = [position copy];
            CGPoint from = [position.fromValue CGPointValue];
            CGPoint to = [position.toValue CGPointValue];
            CGPoint start = button.layer.position;
            CGPoint end = start;
            if (appearing) start.x += from.x - to.x;
            else end.x += to.x - from.x;
            move.additive = NO; // Coordinates below are absolute, not UIKit’s relative offsets.
            move.fromValue = [NSValue valueWithCGPoint:start];
            move.toValue = [NSValue valueWithCGPoint:end];
            CAAnimation *fade = [[control.layer animationForKey:@"opacity"] copy];
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (!appearing) [CATransaction setCompletionBlock:^{ [button removeFromSuperview]; }];
            button.layer.position = end;
            button.alpha = appearing ? 1.0 : 0.0;
            [button.layer addAnimation:move forKey:@"position"];
            if (fade) [button.layer addAnimation:fade forKey:@"opacity"];
            [CATransaction commit];
            return;
        }
    }
    if (!appearing) [button removeFromSuperview];
}

static char kApolloHideModTransitionKey;

static NSString *ApolloHideModRowKey(UITableView *table, UITableViewCell *cell) {
    NSIndexPath *path = [table indexPathForCell:cell];
    return [NSString stringWithFormat:@"%ld:%@", (long)path.section,
            ApolloHideModLeftmostLabelText(cell.contentView) ?: @""];
}

static void ApolloHideModReloadSections(UITableView *table, NSIndexSet *sections, BOOL animated) {
    NSMutableDictionary *before = [NSMutableDictionary new];
    NSMutableDictionary *headers = [NSMutableDictionary new];
    CGPoint offset = table.contentOffset;
    if (animated) {
        for (UITableViewCell *cell in table.visibleCells) {
            UIView *snapshot = [cell snapshotViewAfterScreenUpdates:NO];
            before[ApolloHideModRowKey(table, cell)] = @[[NSValue valueWithCGRect:cell.frame], snapshot ?: [UIView new]];
        }
        for (NSInteger section = 0; section < table.numberOfSections; section++) {
            headers[@(section)] = [NSValue valueWithCGRect:[table rectForHeaderInSection:section]];
        }
    }
    [UIView performWithoutAnimation:^{
        [table reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
        [table layoutIfNeeded];
    }];
    if (!animated) return;

    NSMutableArray *rows = [NSMutableArray new];
    CGFloat offsetDelta = table.contentOffset.y - offset.y;
    for (UITableViewCell *cell in table.visibleCells) {
        NSString *key = ApolloHideModRowKey(table, cell);
        NSArray *old = before[key];
        [rows addObject:@[cell, [NSValue valueWithCGAffineTransform:cell.transform], @(cell.alpha)]];
        if (old) {
            CGFloat delta = CGRectGetMidY([old[0] CGRectValue]) - CGRectGetMidY(cell.frame) + offsetDelta;
            cell.transform = CGAffineTransformTranslate(cell.transform, 0, delta);
            [before removeObjectForKey:key];
        } else {
            cell.transform = CGAffineTransformScale(cell.transform, 0.88, 0.88);
            cell.alpha = 0;
        }
    }
    for (NSNumber *section in headers) {
        UIView *header = [table headerViewForSection:section.integerValue];
        if (!header) continue;
        [rows addObject:@[header, [NSValue valueWithCGAffineTransform:header.transform], @(header.alpha)]];
        CGFloat delta = CGRectGetMidY([headers[section] CGRectValue]) - CGRectGetMidY([table rectForHeaderInSection:section.integerValue]) + offsetDelta;
        header.transform = CGAffineTransformTranslate(header.transform, 0, delta);
    }
    NSMutableArray *departing = [NSMutableArray new];
    for (NSArray *old in before.allValues) {
        UIView *snapshot = old[1];
        CGRect frame = [old[0] CGRectValue];
        frame.origin.y += offsetDelta;
        snapshot.frame = frame;
        snapshot.userInteractionEnabled = NO;
        [table addSubview:snapshot];
        [departing addObject:snapshot];
    }
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.34
        timingParameters:[[UISpringTimingParameters alloc] initWithDampingRatio:0.88]];
    animator.userInteractionEnabled = YES;
    objc_setAssociatedObject(table, &kApolloHideModTransitionKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [animator addAnimations:^{
        for (NSArray *row in rows) {
            UIView *view = row[0];
            view.transform = [row[1] CGAffineTransformValue];
            view.alpha = [row[2] doubleValue];
        }
        for (UIView *snapshot in departing) {
            snapshot.alpha = 0;
            snapshot.transform = CGAffineTransformMakeScale(0.88, 0.88);
        }
    }];
    [animator addCompletion:^(__unused UIViewAnimatingPosition position) {
        for (UIView *snapshot in departing) [snapshot removeFromSuperview];
        objc_setAssociatedObject(table, &kApolloHideModTransitionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
    // Start after the edit controls have been configured, outside disabled-animation scopes.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(table, &kApolloHideModTransitionKey) == animator) [animator startAnimation];
    });
}

// Applies (or strips) the hide/unhide control and faded look on one cell.
// Called from cellForRowAtIndexPath for every row, so reused cells always
// end up in a consistent state without a prepareForReuse hook.
//
// The button lives on the cell itself, NOT contentView: moderator rows are
// made editable (canEditRow hook below) so UIKit indents contentView to the
// right exactly like the delete-circle rows, and the button occupies the
// gutter that indent exposes — matching the native edit-control position.
static void ApolloHideModDecorateCell(UIViewController *viewController, UITableViewCell *cell,
                                      BOOL isModeratorRow, BOOL editing, NSString *name, BOOL animated) {
    UIButton *button = (UIButton *)[cell viewWithTag:kApolloHideModButtonTag];

    if (!isModeratorRow || !editing || name.length == 0) {
        if (button && animated && isModeratorRow) {
            button.tag = 0;
            button.userInteractionEnabled = NO;
            ApolloHideModAnimateControl(button, ApolloHideModTableView(viewController), NO);
        } else {
            [button removeFromSuperview];
        }
        cell.contentView.alpha = 1.0;
        return;
    }

    BOOL hidden = ApolloHideModNameIsHidden(name);
    BOOL created = button == nil;
    if (!button) {
        button = [ApolloModeratorToggleButton buttonWithType:UIButtonTypeSystem];
        button.tag = kApolloHideModButtonTag;
        CGFloat rowHeight = cell.bounds.size.height >= 30.0 ? cell.bounds.size.height : 58.0;
        CGFloat centerX = 32.0;
        UITableView *table = ApolloHideModTableView(viewController);
        // Match UIKit's actual edit-control column, including safe-area insets.
        for (UITableViewCell *peer in table.visibleCells) {
            BOOL found = NO;
            for (UIView *control in peer.subviews) {
                if ([NSStringFromClass(control.class) isEqualToString:@"UITableViewCellEditControl"]) {
                    CGRect frame = [control convertRect:control.bounds toView:cell];
                    if (peer.isEditing && CGRectGetWidth(frame) > 0 && CGRectGetMidX(frame) >= 32.0) {
                        centerX = CGRectGetMidX(frame); found = YES; break;
                    }
                }
            }
            if (found) break;
        }
        button.frame = CGRectMake(0.0, 0.0, centerX * 2.0, rowHeight);
        button.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        [cell addSubview:button];
    }

    // UIKit reshuffles cell subviews during edit-mode transitions and can
    // land contentView on top of the button, silently eating taps. Re-assert
    // the button as frontmost every time the cell is (re)configured.
    [cell bringSubviewToFront:button];

    [button setImage:ApolloHideModGlyph(hidden) forState:UIControlStateNormal];

    // Fire on touch-down: registers the instant the finger lands instead of
    // waiting for touch-up, so the control never feels like it dropped a tap.
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [button addTarget:viewController action:NSSelectorFromString(@"apolloHideModToggleTapped:") forControlEvents:UIControlEventTouchDown];
    objc_setAssociatedObject(button, &kApolloHideModButtonNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Hidden rows render faded so it's obvious they won't appear outside
    // Edit mode. The button sits outside contentView, so it stays opaque.
    cell.contentView.alpha = hidden ? 0.4 : 1.0;
    if (created && animated) {
        ApolloHideModAnimateControl(button, ApolloHideModTableView(viewController), YES);
    }


    ApolloLog(@"[HideModSubs] decorated moderator row '%@' hidden=%d", name, (int)hidden);
}

// MARK: - Subreddits list hooks

%group ApolloHideModList

%hook RedditListViewController

// One-shot environment dump so user logs show whether the table wiring is
// what we expect (delegate/dataSource identity, edit state).
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UITableView *tableView = ApolloHideModTableView((UIViewController *)self);
    if (!tableView) {
        ApolloLog(@"[HideModSubs] diag: tableView ivar missing on %@", NSStringFromClass([self class]));
        return;
    }
    ApolloLog(@"[HideModSubs] diag: table=%p delegate=%@%@ dataSource=%@%@ editing=%d hiddenCount=%lu",
              tableView,
              NSStringFromClass([tableView.delegate class]), tableView.delegate == (id)self ? @"(self)" : @"",
              NSStringFromClass([tableView.dataSource class]), tableView.dataSource == (id)self ? @"(self)" : @"",
              (int)tableView.isEditing,
              (unsigned long)ApolloHideModHiddenList().count);
}

// --- Display-scope window ---
// These data-source/delegate methods read currentUser.moderatedSubreddits
// (directly or via Apollo's inlined helpers) to SIZE and BUILD the MODERATOR
// section. Bumping the thread-local depth around %orig makes the getter return
// the hidden-filtered list for the whole of that work, so row count, header
// height and cells all agree. Outside this window — and on any other thread —
// the getter returns the full list, so moderator powers are never affected.
//
// Note: the methods that also NAVIGATE off a row (didSelect, contextMenu) use
// the separately scoped sNavResolveFilterActive window instead, which ends as
// soon as the push starts — see those hooks below for why staying filtered
// through the whole push would reintroduce the PR #500 mod-tools bug.

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    sListFilterDepth++;
    long long result = %orig;
    sListFilterDepth--;
    return result;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(long long)section {
    sListFilterDepth++;
    CGFloat result = %orig;
    sListFilterDepth--;
    return result;
}

// Taps and context menus resolve `moderatedSubreddits[row]` themselves — and
// like the display methods they re-sort what the getter returns, so the tapped
// index is only meaningful against the same filtered list the visible rows
// were built from. Scope the filter to that resolution with
// sNavResolveFilterActive rather than the display depth window: the
// UINavigationController hook above drops the flag the moment the push starts,
// so the mod-toolbar checks running synchronously inside the push read the
// complete list (PR #500's guarantee), and the flag is always reset when %orig
// returns, covering pushes deferred past the nav method (resolution has
// happened synchronously by then).
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloHideModShouldScopeNavResolve(self, tableView, indexPath)) {
        %orig;
        return;
    }
    ApolloLog(@"[HideModSubs] scoping tap resolution to filtered list (row %ld)", (long)indexPath.row);
    sNavResolveFilterActive = YES;
    %orig;
    sNavResolveFilterActive = NO;
}

- (id)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (!ApolloHideModShouldScopeNavResolve(self, tableView, indexPath)) {
        return %orig;
    }
    ApolloLog(@"[HideModSubs] scoping context menu resolution to filtered list (row %ld)", (long)indexPath.row);
    sNavResolveFilterActive = YES;
    id configuration = %orig;
    sNavResolveFilterActive = NO;
    return configuration;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    sListFilterDepth++;
    %orig;
    sListFilterDepth--;
}

// Moderator rows natively can't be edited (no unsubscribe for moderated
// subs), so UIKit would not indent them in Edit mode and our gutter button
// would overlap the subreddit icon. Marking them editable with editing
// style None makes UIKit indent the content exactly like the delete-circle
// rows, while drawing no native control of its own.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL original = %orig;
    if (!original && [ApolloHideModSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) {
        return YES;
    }
    return original;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([ApolloHideModSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) {
        return UITableViewCellEditingStyleNone;
    }
    return %orig;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([ApolloHideModSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) {
        return YES;
    }
    return %orig;
}

// Decorate every cell on the way out: moderator rows get the hide/unhide
// control while editing, everything else gets any stale control stripped.
// The %orig is run inside the display-scope window so the filtered getter
// produces the right row content; decoration afterwards only reads the cell.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    sListFilterDepth++;
    UITableViewCell *cell = %orig;
    sListFilterDepth--;
    if (![cell isKindOfClass:[UITableViewCell class]]) return cell;

    NSString *sectionTitle = ApolloHideModSectionTitle(self, tableView, indexPath.section);
    BOOL isModeratorRow = [sectionTitle isEqualToString:@"MODERATOR"];
    NSString *name = isModeratorRow ? ApolloHideModLeftmostLabelText(cell.contentView ?: cell) : nil;

    ApolloHideModDecorateCell((UIViewController *)self, cell, isModeratorRow, tableView.isEditing, name, NO);
    return cell;
}

// Show hidden moderator rows while editing without rebuilding the other sections.
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    BOOL wasEditing = [(UIViewController *)self isEditing];
    if (wasEditing == editing) {
        %orig;
        return;
    }

    UITableView *tableView = ApolloHideModTableView((UIViewController *)self);
    UIViewPropertyAnimator *transition = objc_getAssociatedObject(tableView, &kApolloHideModTransitionKey);
    if (transition) {
        [transition startAnimation];
        [transition stopAnimation:NO];
        [transition finishAnimationAtPosition:UIViewAnimatingPositionEnd];
    }
    sShowHiddenForEditing = editing;
    if (ApolloHideModHiddenList().count) {
        NSMutableIndexSet *changedSections = [NSMutableIndexSet new];
        for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
            NSInteger displayed = [tableView numberOfRowsInSection:section];
            NSInteger updated = [tableView.dataSource tableView:tableView numberOfRowsInSection:section];
            if (displayed != updated) [changedSections addIndex:section];
        }
        // Only moderator visibility changes. Keep all other cells and their
        // loaded icons intact, including when the hidden list belongs to another account.
        if (changedSections.count) {
            ApolloHideModReloadSections(tableView, changedSections,
                                        animated && !UIAccessibilityIsReduceMotionEnabled());
        }
    }
    %orig;
    for (UITableViewCell *cell in tableView.visibleCells) {
        NSIndexPath *path = [tableView indexPathForCell:cell];
        BOOL moderator = [ApolloHideModSectionTitle(self, tableView, path.section) isEqualToString:@"MODERATOR"];
        NSString *name = moderator ? ApolloHideModLeftmostLabelText(cell.contentView) : nil;
        ApolloHideModDecorateCell((UIViewController *)self, cell, moderator, editing, name, animated && !UIAccessibilityIsReduceMotionEnabled());
    }
    ApolloLog(@"[HideModSubs] setEditing=%d hiddenCount=%lu", (int)editing, (unsigned long)ApolloHideModHiddenList().count);
}

%new
- (void)apolloHideModToggleTapped:(UIButton *)sender {
    NSString *name = objc_getAssociatedObject(sender, &kApolloHideModButtonNameKey);
    if (name.length == 0) return;

    BOOL wasHidden = ApolloHideModNameIsHidden(name);
    if (wasHidden) {
        ApolloHideModRemoveHidden(name);
    } else {
        ApolloHideModAddHidden(name);
    }

    // Re-style the tapped row in place; the row only actually disappears
    // when Edit mode ends and the filtered getter takes effect on reload.
    UIView *view = sender;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    if (view) {
        ApolloHideModDecorateCell((UIViewController *)self, (UITableViewCell *)view, YES, YES, name, NO);
    }
    ApolloLog(@"[HideModSubs] toggled '%@' -> hidden=%d", name, (int)!wasHidden);
}

%end

%hook RedditListTableViewCell

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UITableViewCell *cell = (UITableViewCell *)self;
    UIView *button = [cell viewWithTag:kApolloHideModButtonTag];
    // UIKit can put an editing overlay above the custom moderator control.
    if (cell.isEditing && [button isKindOfClass:ApolloModeratorToggleButton.class] &&
        !button.hidden && button.alpha > 0.01 && button.userInteractionEnabled) {
        UIView *hit = [button hitTest:[cell convertPoint:point toView:button] withEvent:event];
        if (hit) return hit;
    }
    return %orig;
}

%end

%end // ApolloHideModList

%ctor {
    %init;

    Class listClass = objc_getClass("Apollo.RedditListViewController");
    if (!listClass) listClass = NSClassFromString(@"Apollo.RedditListViewController");
    if (listClass) {
        %init(ApolloHideModList, RedditListViewController = listClass, RedditListTableViewCell = NSClassFromString(@"Apollo.RedditListTableViewCell"));
        ApolloLog(@"[HideModSubs] list hooks installed on %@", NSStringFromClass(listClass));
    } else {
        ApolloLog(@"[HideModSubs] RedditListViewController class missing; Hide UI unavailable");
    }
}
