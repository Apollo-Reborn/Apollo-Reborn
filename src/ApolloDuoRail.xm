#import "ApolloDuoAccount.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoSplitView.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloTextureDecls.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloDeviceGeometry.h"
#import <objc/runtime.h>
#import <objc/message.h>

void ApolloDuoRailRefreshGlyphs(void) {
    UITabBarController *controller = (UITabBarController *)ApolloMainTabBarController();
    if (![controller isKindOfClass:UITabBarController.class]) return;
    [controller.tabBar setNeedsLayout];
    [controller.tabBar layoutIfNeeded];
}

// Refresh native rail geometry across scene activation, rotation,
// and size-class changes. UIKit retains ownership of tab-bar visibility.

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

struct ApolloDuoSizeRange { CGSize min; CGSize max; };
@interface ASTableView : UITableView
- (void)relayoutItems;
- (void)endUpdatesAnimated:(BOOL)animated completion:(void (^)(BOOL))completion;
- (void)waitUntilAllUpdatesAreCommitted;
@end

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

@interface _TtC6Apollo19PostsViewController : UIViewController
@end

@interface _TtC6Apollo20FloatingActionButton : UIButton
@end

@interface ASCellNode : ASDisplayNode
@end

@interface _ASTableViewCell : UITableViewCell
@property (nonatomic, readonly) ASCellNode *node;
@property (nonatomic, readonly) id delegate;
@end

static UIViewController *ApolloDuoTableController(UITableView *table) {
    for (UIResponder *responder = table; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

// Apollo 1.15.11's CommentsViewController.viewDidLayoutSubviews positions this
// pinned control at view.height - tabBar.bounds.height - 55 - 10. A Duo rail
// is almost as tall as the view, so the native Y becomes negative. It is an
// overlay on rootNode, not a table footer. Use the visible comments safe area
// for both axes, including the leading inset of the right split pane.
static CGRect ApolloDuoFullThreadFrame(ASDisplayNode *node, CGRect frame) {
    if (!NSThread.isMainThread || !ApolloDeviceIsDuo() || !ApolloDuoRailHasVisibleSideBar()) return frame;
    ASDisplayNode *parentNode = node.supernode;
    if (!parentNode.isNodeLoaded) return frame;
    UIView *parent = parentNode.view;
    UIViewController *comments = nil;
    for (UIResponder *responder = parent; responder; responder = responder.nextResponder) {
        if (ApolloClassCommentsViewController && [responder isKindOfClass:ApolloClassCommentsViewController]) {
            comments = (id)responder;
            break;
        }
    }
    // Never reposition another control merely because it uses the same class.
    if (!comments.isViewLoaded || ApolloObjectIvar(comments, "viewFullPostNode") != node) return frame;
    CGRect pane = [comments.view convertRect:comments.view.safeAreaLayoutGuide.layoutFrame toView:parent];
    CGFloat height = CGRectGetHeight(frame);
    if (!isfinite(height) || height <= 0.0 || CGRectIsNull(pane) || CGRectIsInfinite(pane)
        || CGRectGetWidth(pane) <= 20.0 || CGRectGetHeight(pane) < height + 20.0) return frame;
    return CGRectMake(CGRectGetMinX(pane) + 10.0, CGRectGetMaxY(pane) - height - 10.0,
                      CGRectGetWidth(pane) - 20.0, height);
}

@interface ApolloDuoFullThreadNode : ASDisplayNode
@end
%group ApolloDuoFullThreadHooks
%hook ApolloDuoFullThreadNode
- (void)setFrame:(CGRect)frame {
    // Repair the native write at its source rather than scheduling another
    // layout or modifying the table's size/insets from a layout callback.
    %orig(ApolloDuoFullThreadFrame((id)self, frame));
}
%end
%end

static CGFloat ApolloDuoComposeContentWidth(UITextView *editor, CGFloat x, CGFloat proposedWidth) {
    if (NSThread.isMainThread && ApolloDuoUsesCoverContentInsets() && editor.superview) {
        UIViewController *compose = nil;
        for (UIResponder *responder = editor; responder; responder = responder.nextResponder) {
            if (ApolloClassComposeViewController && [responder isKindOfClass:ApolloClassComposeViewController]) {
                compose = (id)responder;
                break;
            }
        }
        // PasteableTextView is also used outside the markdown composer.
        if (compose.isViewLoaded && ApolloReadObjectIvar(compose, "composeTextView") == editor) {
            UIView *root = compose.view;
            UIEdgeInsets insets = ApolloDeviceChromeInsetsForView(root);
            CGRect usable = UIEdgeInsetsInsetRect(root.bounds, insets);
            usable = [root convertRect:usable toView:editor.superview];
            CGFloat right = MIN(x + proposedWidth, CGRectGetMaxX(usable));
            CGFloat width = right - x;
            if (!CGRectIsNull(usable) && !CGRectIsInfinite(usable) && isfinite(width) && width > 20.0) {
                return width;
            }
        }
    }
    return proposedWidth;
}

@interface ApolloDuoComposeTextView : UITextView
@end

%group ApolloDuoComposeHooks
%hook ApolloDuoComposeTextView
- (CGSize)sizeThatFits:(CGSize)size {
    __unsafe_unretained UITextView *editor = (id)self;
    // The native composer measures height before assigning the editor frame.
    // Measure at the same usable width so wrapped final lines are not clipped
    // and Apollo can size its scroll content/quoted reply from the real height.
    size.width = ApolloDuoComposeContentWidth(editor, CGRectGetMinX(editor.frame), size.width);
    return %orig(size);
}
- (void)setFrame:(CGRect)frame {
    __unsafe_unretained UITextView *editor = (id)self;
    // Repair Apollo's original full-width write without a second layout pass;
    // native measurement still owns height and keyboard/text insets.
    frame.size.width = ApolloDuoComposeContentWidth(editor, CGRectGetMinX(frame), CGRectGetWidth(frame));
    %orig(frame);
}
%end
%end

static BOOL ApolloDuoIsAccountFeedTable(UITableView *table) {
    if (!table) return NO;
    return ApolloDuoAccountIsOverviewTable(table)
        || ApolloDuoSplitIsAccountFeedController(ApolloDuoTableController(table));
}

static void ApolloDuoSyncOuterCellBackground(_ASTableViewCell *cell) {
    if (!cell || !ApolloDuoRailHasVisibleSideBar()) return;
    // Texture sets this delegate before setElement:, while a dequeued cell
    // need not yet be in the table's view hierarchy.
    id delegate = cell.delegate;
    UITableView *table = [delegate isKindOfClass:UITableView.class] ? delegate : nil;
    if (!table) {
        UIView *parent = cell.superview;
        while (parent && ![parent isKindOfClass:UITableView.class]) parent = parent.superview;
        table = (UITableView *)parent;
    }
    // The card node is constrained to the Overview column. Its UIKit wrapper
    // still spans the table, including the area behind the rail. That outer
    // surface belongs to the page, including for separators and headings.
    BOOL accountFeed = ApolloDuoIsAccountFeedTable(table);
    UIColor *background = accountFeed
        ? (ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor)
        : cell.node.backgroundColor;
    UIViewController *controller = ApolloDuoTableController(table);
    if (!accountFeed && !ApolloDuoSplitIsSidebarController(controller)
        && [NSStringFromClass(controller.class) isEqualToString:@"Apollo.ProfileViewController"]) {
        // The unsplit profile (including closed-landscape Duo) owns a full-width
        // ambient backdrop. NavigationActions draws each row's native fill only
        // inside the content column. Keep the outer cell transparent here too:
        // restoring its node color during reuse/layout flashes card-colored bands
        // behind the rail between scroll callbacks.
        background = UIColor.clearColor;
    } else if (!accountFeed) {
        // Feed/comment nodes are opaque, so UIKit's full-width selection view
        // only ever shows in the strip behind the rail. Apollo builds it once
        // per theme, so after a light/dark switch a row opened and closed
        // again showed the old theme's color there. The profile's shortcut
        // rows clip theirs in NavigationActions instead.
        BOOL besideRail = CGRectGetWidth(cell.bounds) - CGRectGetWidth(cell.contentView.bounds) >= 1.0;
        if (cell.selectedBackgroundView.hidden != besideRail) cell.selectedBackgroundView.hidden = besideRail;
    }
    if (cell.backgroundColor != background && ![cell.backgroundColor isEqual:background]) {
        cell.backgroundColor = background;
    }
}

static void ApolloDuoSyncCellBackground(ASCellNode *node) {
    if (!node.isNodeLoaded || !ApolloDuoRailHasVisibleSideBar()) return;
    UIView *ancestor = node.view.superview;
    while (ancestor && ![ancestor isKindOfClass:UITableViewCell.class]) ancestor = ancestor.superview;
    if ([ancestor isKindOfClass:NSClassFromString(@"_ASTableViewCell")]) {
        _ASTableViewCell *cell = (_ASTableViewCell *)ancestor;
        // A queued update must never repaint a cell recycled for another node.
        if (cell.node == node) ApolloDuoSyncOuterCellBackground(cell);
    }
}

static UIColor *ApolloDuoAccountFeedNodeBackground(ASCellNode *node, UIColor *requested) {
    if (!NSThread.isMainThread || !node.isNodeLoaded) return requested;
    if (ApolloDuoSplitIsGlassSubredditOverlayView(node.view)) return UIColor.clearColor;
    NSString *name = NSStringFromClass(node.class);
    if (![name hasSuffix:@"CommentCellNode"] && ![name hasSuffix:@"PostCellNode"]) return requested;
    UIView *parent = node.view.superview;
    while (parent && ![parent isKindOfClass:UITableView.class]) parent = parent.superview;
    if (!ApolloDuoIsAccountFeedTable((UITableView *)parent)) return requested;
    // Native deselection restores the comment-thread page color even in a
    // profile feed. All account shortcuts share the same independent cards;
    // retain their palette on Back as well as on first display.
    return ApolloThemeCardBackgroundColor() ?: requested;
}

static char kApolloDuoMeasuredWidthKey, kApolloDuoWidthRefreshPendingKey, kApolloDuoWidthRefreshingKey;

void ApolloDuoRailPrepareTableForTransition(UITableView *table) {
    if (!NSThread.isMainThread || !table.window
        || [objc_getAssociatedObject(table, &kApolloDuoWidthRefreshingKey) boolValue]) return;
    CGFloat width = ApolloDuoRailFeedContentWidth(table);
    if (!isfinite(width) || width <= 0.0) return;
    NSNumber *previous = objc_getAssociatedObject(table, &kApolloDuoMeasuredWidthKey);
    if (previous && fabs(previous.doubleValue - width) < 0.5) return;
    if (![table respondsToSelector:@selector(relayoutItems)]
        || ![table respondsToSelector:@selector(endUpdatesAnimated:completion:)]
        || ![table respondsToSelector:@selector(waitUntilAllUpdatesAreCommitted)]) return;

    // A secondary table can retain full-screen bounds while its leading safe
    // area changes. Texture's bounds-width cache therefore sees no resize.
    // Commit the new node widths AND row heights in one native transaction;
    // relayoutItems alone leaves UITableView's old heights until a scroll.
    objc_setAssociatedObject(table, &kApolloDuoMeasuredWidthKey, @(width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(table, &kApolloDuoWidthRefreshingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ASTableView *texture = (ASTableView *)table;
    [texture waitUntilAllUpdatesAreCommitted];
    CGFloat visibleTop = table.contentOffset.y + table.adjustedContentInset.top;
    NSIndexPath *anchor = nil;
    for (NSIndexPath *path in table.indexPathsForVisibleRows) {
        if (CGRectGetMaxY([table rectForRowAtIndexPath:path]) > visibleTop) {
            anchor = path;
            break;
        }
    }
    CGFloat anchorOffset = anchor ? CGRectGetMinY([table rectForRowAtIndexPath:anchor]) - visibleTop : 0.0;
    [UIView performWithoutAnimation:^{
        [texture beginUpdates];
        [texture relayoutItems];
        [texture endUpdatesAnimated:NO completion:nil];
        [texture waitUntilAllUpdatesAreCommitted];
        [table setNeedsLayout];
        [table layoutIfNeeded];
        // Rewrapping rows above the viewport changes their combined height.
        // Keep the same visible comment at the same distance below the header.
        if (anchor && !table.dragging && !table.decelerating
            && anchor.section < table.numberOfSections
            && anchor.row < [table numberOfRowsInSection:anchor.section]) {
            CGFloat offset = CGRectGetMinY([table rectForRowAtIndexPath:anchor])
                - anchorOffset - table.adjustedContentInset.top;
            CGFloat minimum = -table.adjustedContentInset.top;
            CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
            [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(maximum, MAX(minimum, offset))) animated:NO];
            [table layoutIfNeeded];
        }
    }];
    objc_setAssociatedObject(table, &kApolloDuoWidthRefreshingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    os_log_debug(ApolloFixLog(), "[ApolloFix] [DuoMeasure] committed column width %.1f (was %.1f)", width, previous.doubleValue);
}

// Keep the reading position across fold/unfold. A full-width feed is resized
// by UIKit itself: rows rewrap while contentOffset stays in points, so the
// wider display lands posts further down. Anchor the first visible row
// before the transition and restore it once the new layout commits.
static char kApolloDuoFoldAnchorKey;

// The anchor's restore passes run after the transition and again 0.3s later.
// A scroll the reader starts in that window wins: restoring after the finger
// lifts would put the feed back and make the first scroll look ignored.
@interface ApolloDuoFoldAnchorDragObserver : NSObject
+ (instancetype)shared;
- (void)panChanged:(UIPanGestureRecognizer *)pan;
@end
@implementation ApolloDuoFoldAnchorDragObserver
+ (instancetype)shared {
    static ApolloDuoFoldAnchorDragObserver *observer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ observer = [self new]; });
    return observer;
}
- (void)panChanged:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateBegan) return;
    objc_setAssociatedObject(pan.view, &kApolloDuoFoldAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

static void ApolloDuoCollectVisibleTables(UIView *view, NSMutableArray<UITableView *> *tables, NSUInteger depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 24) return;
    if (ApolloClassASTableView && [view isKindOfClass:ApolloClassASTableView]) {
        // Feeds only. The Account page restores its own top after a fold;
        // anchoring its Overview list here landed the page on Overview.
        UIViewController *owner = ApolloDuoTableController((UITableView *)view);
        if (ApolloClassPostsViewController && [owner isKindOfClass:ApolloClassPostsViewController])
            [tables addObject:(UITableView *)view];
        return;
    }
    for (UIView *subview in view.subviews) ApolloDuoCollectVisibleTables(subview, tables, depth + 1);
}

static NSArray<UITableView *> *ApolloDuoFoldAnchorTables(UITabBarController *tabs) {
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    ApolloDuoCollectVisibleTables(tabs.selectedViewController.viewIfLoaded, tables, 0);
    return tables;
}

static void ApolloDuoCaptureFoldAnchor(UITableView *table) {
    if (!table.window || table.indexPathsForVisibleRows.count == 0) return;
    CGFloat visibleTop = table.contentOffset.y + table.adjustedContentInset.top;
    for (NSIndexPath *path in table.indexPathsForVisibleRows) {
        CGRect rect = [table rectForRowAtIndexPath:path];
        if (CGRectGetMaxY(rect) <= visibleTop) continue;
        // Store the offset as a fraction of the row so a row that rewraps to
        // a different height keeps the same part on screen.
        CGFloat fraction = rect.size.height > 0.0 ? (visibleTop - CGRectGetMinY(rect)) / rect.size.height : 0.0;
        objc_setAssociatedObject(table, &kApolloDuoFoldAnchorKey,
            @[path, @(MAX(0.0, MIN(1.0, fraction)))], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // UIKit ignores a target-action pair that is already registered.
        [table.panGestureRecognizer addTarget:[ApolloDuoFoldAnchorDragObserver shared]
                                       action:@selector(panChanged:)];
        return;
    }
}

static void ApolloDuoRestoreFoldAnchor(UITableView *table, BOOL finalPass) {
    NSArray *anchor = objc_getAssociatedObject(table, &kApolloDuoFoldAnchorKey);
    if (finalPass) objc_setAssociatedObject(table, &kApolloDuoFoldAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (anchor.count != 2 || !table.window || table.dragging || table.decelerating || table.tracking) return;
    NSIndexPath *path = anchor[0];
    if (path.section >= table.numberOfSections || path.row >= [table numberOfRowsInSection:path.section]) return;
    SEL commit = @selector(waitUntilAllUpdatesAreCommitted);
    if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
    [table layoutIfNeeded];
    CGRect rect = [table rectForRowAtIndexPath:path];
    CGFloat offset = CGRectGetMinY(rect) + rect.size.height * [anchor[1] doubleValue] - table.adjustedContentInset.top;
    CGFloat minimum = -table.adjustedContentInset.top;
    CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
    offset = MIN(maximum, MAX(minimum, offset));
    if (fabs(offset - table.contentOffset.y) < 0.5) return;
    ApolloLog(@"[DuoRail] fold anchor: row %ld.%ld offset %.1f -> %.1f%@", (long)path.section, (long)path.row,
              table.contentOffset.y, offset, finalPass ? @" (final)" : @"");
    [table setContentOffset:CGPointMake(table.contentOffset.x, offset) animated:NO];
}

// Apollo moves the comments jump button from scroll handling after the
// controller's layout callbacks have returned. Keep the visible comments
// controller so the button's own final geometry writes can be clamped too.
static __weak UIViewController *sApolloDuoActiveComments;
static BOOL sApolloDuoClampingFloatingButton;

static void ApolloDuoAdjustFloatingActionButton(UIView *button) {
    if (sApolloDuoClampingFloatingButton) return;
    sApolloDuoClampingFloatingButton = YES;
    for (UIResponder *responder = button.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            ApolloDuoRailAdjustHideReadButton((UIViewController *)responder);
            break;
        }
    }
    ApolloDuoCoverAdjustJumpButton(sApolloDuoActiveComments);
    sApolloDuoClampingFloatingButton = NO;
}

%group ApolloDuoRailTabs

%hook _TtC6Apollo22ApolloTabBarController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoRailSync();
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoRailSync();
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    // UIKit's own size class for the tab container (never overridden): shows
    // whether the split's size-class pins in ApolloDuoSplitView are needed.
    UITraitCollection *traits = ((UIViewController *)self).traitCollection;
    if (traits.horizontalSizeClass != previous.horizontalSizeClass) {
        ApolloLog(@"[DuoRail] native horizontalSizeClass %ld -> %ld (view %@, mode %d)",
                  (long)previous.horizontalSizeClass, (long)traits.horizontalSizeClass,
                  NSStringFromCGSize(((UIViewController *)self).view.bounds.size), ApolloDuoCurrentMode());
    }
    ApolloDuoRailSync();
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    NSArray<UITableView *> *anchored = ApolloDuoFoldAnchorTables((UITabBarController *)self);
    for (UITableView *table in anchored) ApolloDuoCaptureFoldAnchor(table);
    %orig;
    NSHashTable<UITableView *> *tables = [NSHashTable weakObjectsHashTable];
    for (UITableView *table in anchored) [tables addObject:table];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoRailSync();
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        // Let the split host finish its resize before deciding whether the
        // resulting bottom bar can minimize again.
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloDuoRailSync();
            for (UITableView *table in tables) ApolloDuoRestoreFoldAnchor(table, NO);
        });
        // Media and Focused cards can settle their heights a beat later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UITableView *table in tables) ApolloDuoRestoreFoldAnchor(table, YES);
        });
    }];
}

%end

%end

%group ApolloDuoRailTexture

%hook UIView
- (void)setBackgroundColor:(UIColor *)color {
    %orig(ApolloDuoSplitOverlayBackground(self, color));
}
%end

%hook ASCellNode

- (void)setBackgroundColor:(UIColor *)color {
    %orig(ApolloDuoAccountFeedNodeBackground(self, color));
    // Texture copies the node background to its full-width UIKit cell only
    // when assigning the cell's element. Apollo recolors existing nodes on a
    // theme change without assigning that element again, leaving the exposed
    // rail area in the previous theme. Sync the owning surface so cards keep their
    // fill inside the feed while the exposed rail follows the page theme.
    if (!self.isNodeLoaded) return;
    if (NSThread.isMainThread) {
        ApolloDuoSyncCellBackground(self);
    } else {
        __weak ASCellNode *weakNode = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloDuoSyncCellBackground(weakNode);
        });
    }
}

%end

%hook _ASTableViewCell
- (void)setElement:(id)element {
    %orig(element);
    // Texture assigns the node's color before attaching its content view.
    // Normalize after attachment as well as on display/theme changes, so a
    // recycled card never presents one full-width frame behind the rail.
    ApolloDuoSyncOuterCellBackground(self);
}
%end

// Keep Texture measurements within the native split and trailing safe area.
%hook ASTableView

- (void)tableView:(UITableView *)table willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)path {
    %orig(table, cell, path);
    ApolloDuoAccountGridDisplayCell((UITableView *)self, cell, path);
    if ([cell isKindOfClass:NSClassFromString(@"_ASTableViewCell")]) {
        ASCellNode *node = ((_ASTableViewCell *)cell).node;
        node.backgroundColor = ApolloDuoAccountFeedNodeBackground(node, node.backgroundColor);
        ApolloDuoSyncCellBackground(node);
    }
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    if (ApolloDuoAccountHidesProfileRow((UITableView *)self, path)) return 0;
    CGFloat gridHeight = ApolloDuoAccountGridRowHeight((UITableView *)self, path);
    if (gridHeight >= 0) return gridHeight;
    return %orig(table, path);
}

- (void)safeAreaInsetsDidChange {
    %orig;
    UITableView *table = (UITableView *)self;
    // Sidebar changes can leave bounds untouched while moving the visible pane.
    [table.backgroundView setNeedsLayout];
    CGFloat width = ApolloDuoRailFeedContentWidth(table);
    if (width <= 0.0) return;
    NSNumber *previous = objc_getAssociatedObject(table, &kApolloDuoMeasuredWidthKey);
    if (previous && fabs(previous.doubleValue - width) < 0.5) return;
    if ([objc_getAssociatedObject(table, &kApolloDuoWidthRefreshPendingKey) boolValue]) return;
    objc_setAssociatedObject(table, &kApolloDuoWidthRefreshPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Coalesce safe-area notifications outside UIKit's layout callback. A
    // split-button transition calls the same helper synchronously, making this
    // queued pass a no-op once that destination width has already committed.
    __weak UITableView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *liveTable = weakTable;
        if (!liveTable) return;
        objc_setAssociatedObject(liveTable, &kApolloDuoWidthRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoRailPrepareTableForTransition(liveTable);
    });
}

- (void)didLayoutSubviewsOfTableViewCell:(UITableViewCell *)cell {
    // Rows can survive portrait-to-landscape rotation without willDisplay or
    // another node color assignment. Portrait has no side rail, so its node
    // color updates intentionally skip the outer UIKit cell. Sync that
    // existing surface once it becomes exposed again, including during the
    // transient sizing callback below. This changes no Texture geometry.
    if ([cell isKindOfClass:NSClassFromString(@"_ASTableViewCell")]) {
        ApolloDuoSyncCellBackground(((_ASTableViewCell *)cell).node);
    }
    CGFloat width = ApolloDuoRailFeedContentWidth((UITableView *)self);
    BOOL refreshingWidth = [objc_getAssociatedObject(self, &kApolloDuoWidthRefreshingKey) boolValue];
    if ((ApolloDuoSplitIsResizing() || refreshingWidth) && width > 0.0
        && fabs(CGRectGetWidth(cell.contentView.bounds) - width) > 0.5) {
        // Texture's cell callback remeasures the node from contentView.bounds,
        // bypassing the data-controller constraint above. During reparenting
        // UIKit first lays that content view out without its column safe area.
        // Keep the already measured destination layout until UIKit supplies
        // the matching cell width; its next callback then runs normally.
        return;
    }
    %orig(cell);
}

- (void)endUpdatesAnimated:(BOOL)animated completion:(void (^)(BOOL))completion {
    // Folding already has a UIKit transition. Texture otherwise starts its
    // own height animation after remeasuring, making post text settle twice.
    __weak UITableView *weakTable = (id)self;
    // Keep the block outside %orig: CI's pinned Logos does not parse multiline
    // block arguments, although newer local Logos versions accept them.
    void (^duoCompletion)(BOOL) = ^(BOOL finished) {
        if (completion) completion(finished);
        UITableView *table = weakTable;
        // Only the hosted profile table has a shortcuts column to refresh.
        // Other Texture lists (and every ordinary iPhone) need no queued
        // notification after each content/height update.
        if (ApolloDuoAccountIsOverviewTable(table)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ApolloDuoAccountIsOverviewTable(table)) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloDuoProfileMenuUpdated" object:table];
                }
            });
        }
    };
    %orig(ApolloDuoSplitIsResizing() ? NO : animated, duoCompletion);
}

// Texture caches the table's bounds width, subtracting contentInset but not
// adjustedContentInset/safeAreaInsets. Supply the usable width before nodes
// are measured, rather than clipping or resizing their rendered views later.
- (struct ApolloDuoSizeRange)dataController:(id)dataController
        constrainedSizeForNodeAtIndexPath:(NSIndexPath *)indexPath {
    struct ApolloDuoSizeRange range = %orig(dataController, indexPath);
    CGFloat width = ApolloDuoRailFeedContentWidth((UITableView *)self);
    if (width > 0.0) {
        // On a fold/unfold the native range can still contain the old
        // display width. Both ends must use the destination measurement.
        if (ApolloDuoSplitIsResizing()) {
            range.min.width = range.max.width = width;
        } else {
            range.max.width = MIN(range.max.width, width);
            range.min.width = MIN(range.min.width, range.max.width);
        }
    }
#if APOLLO_SIM_BUILD
    static char traceKey;
    UITableView *table = (UITableView *)self;
    NSString *geometry = [NSString stringWithFormat:@"table=%.1f safe=%.1f/%.1f content=%.1f/%.1f desired=%.1f measured=%.1f resize=%d", table.bounds.size.width, table.safeAreaInsets.left, table.safeAreaInsets.right, table.contentInset.left, table.contentInset.right, width, range.max.width, ApolloDuoSplitIsResizing()];
    if (![objc_getAssociatedObject(self, &traceKey) isEqual:geometry]) {
        objc_setAssociatedObject(self, &traceKey, geometry, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloLog(@"[DuoMeasure] %p %@", self, geometry);
    }
#endif
    return range;
}

- (void)layoutSubviews {
    %orig;
    ApolloDuoRailAlignFeedScrollIndicator((UIScrollView *)self);
}

%end

%end

// Clamp after the concrete comments controller finishes its native layout,
// so each jump-button position remains inside the Duo content edge.
%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sApolloDuoActiveComments = (UIViewController *)self;
    ApolloDuoCoverAdjustJumpButton((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    sApolloDuoActiveComments = (UIViewController *)self;
    %orig(animated);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    if (sApolloDuoActiveComments == (UIViewController *)self) {
        sApolloDuoActiveComments = nil;
    }
}

%end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoRailAdjustHideReadButton((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloDuoRailAdjustHideReadButton((UIViewController *)self);
}

%end

// The scroll path sets FloatingActionButton geometry after the feed/comments
// controller's delegate callbacks. Clamp after those writes rather than
// racing them from scrollViewDidScroll:. The guard lets the helper assign the
// corrected frame without recursively entering this hook.
%hook _TtC6Apollo20FloatingActionButton

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    ApolloDuoAdjustFloatingActionButton(self);
}

- (void)setCenter:(CGPoint)center {
    %orig(center);
    ApolloDuoAdjustFloatingActionButton(self);
}

%end

%hook UINavigationController

- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    ApolloDuoRailPrepareFeedContent(controller);
    %orig(controller, animated);
}

%end

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    ApolloDuoRailPrepareFeedContent(self);
    %orig(animated);
}

%end

%ctor {
    if (!ApolloDeviceIsDuo()) {
        ApolloLog(@"[DuoRail] not an iPhone Duo; rail adapters NOT installed");
        return;
    }
    %init;
    Class fullThread = objc_getClass("_TtC6Apollo16ViewFullPostNode");
    if (fullThread) %init(ApolloDuoFullThreadHooks, ApolloDuoFullThreadNode = fullThread);
    Class composeText = objc_getClass("_TtC6Apollo17PasteableTextView");
    if (composeText) %init(ApolloDuoComposeHooks, ApolloDuoComposeTextView = composeText);
    Class tabs = objc_getClass("_TtC6Apollo22ApolloTabBarController");
    if (!tabs) {
        ApolloLog(@"[DuoRail] ApolloTabBarController missing; rail inactive");
        return;
    }
    %init(ApolloDuoRailTabs);
    if (objc_getClass("ASTableView")) {
        %init(ApolloDuoRailTexture);
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloDuoRailSync();
    }];
    ApolloLog(@"[DuoRail] native trailing rail adapters installed");
}
