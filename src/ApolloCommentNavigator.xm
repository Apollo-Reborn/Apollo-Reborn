// Reuse Apollo's floating jump button for new-since-last-visit comments.
//
// Native 1.15.11 evidence: CommentCellNode's initializer (0x100500fd0,
// comparison at 0x100501bf8) reads NewCommentsTracker on its serial queue,
// compares snapshot.timestamp < comment.createdUTC, then excludes the selected
// account's own author (0x100503a5c..0x100503d88). Its display toggle is
// ShowUnreadComments; that controls the background, not our navigation mode.
// PostCommentsSnapshots is the same tracker's published JSON (Swift Date uses
// seconds since 2001). Snapshot it before native loading creates the nodes so
// leaving to another screen cannot change the baseline halfway through a visit.
//
// Read Texture's displayed row model on each tap. This includes offscreen
// comments and excludes children removed by a collapsed branch. Never inspect
// background colors, retain a stale Swift tree array, or hide/reorder rows.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloAccountCredentials.h"
#import "ApolloClasses.h"
#import "ApolloCommentNavigationModel.h"
#import "ApolloCommentNavigator.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"
#import "ApolloToast.h"
#import "UserDefaultConstants.h"

@interface RDKComment : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSDate *createdUTC;
@property (nonatomic, readonly) NSString *author;
@end

@interface ASCellNode : NSObject
@property (nonatomic, readonly) BOOL isNodeLoaded;
@property (nonatomic, readonly) UIView *view;
@end

@interface ASTableNode : NSObject
@property (nonatomic, readonly) UITableView *view;
- (ASCellNode *)nodeForRowAtIndexPath:(NSIndexPath *)path;
@end

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

@interface ApolloCommentNavigationVisit : NSObject
@property (nonatomic, copy) NSData *snapshotJSON;
@property (nonatomic, copy) NSString *postID;
@property (nonatomic, strong) NSDate *baseline;
@property (nonatomic, copy) NSString *lastCommentID;
@property (nonatomic) CGFloat lastOffset;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL pending;
@end
@implementation ApolloCommentNavigationVisit
@end

@interface ApolloCommentNavigationTarget : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) NSIndexPath *path;
@property (nonatomic) CGFloat position;
@end
@implementation ApolloCommentNavigationTarget
@end

@interface ApolloCommentNavigationButtonStyle : NSObject
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic) UIEdgeInsets imageInsets;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *hint;
@end
@implementation ApolloCommentNavigationButtonStyle
@end

static char kCNVisitKey, kCNButtonStyleKey;
static NSHashTable<UIViewController *> *sCNControllers;

static void CNCancel(UIViewController *controller) {
    ApolloCommentNavigationVisit *visit = objc_getAssociatedObject(controller, &kCNVisitKey);
    visit.generation++;
    visit.pending = NO;
    visit.lastCommentID = nil;
}

static ASTableNode *CNTableNode(UIViewController *controller) {
    id node = ApolloObjectIvar(controller, "tableNode");
    return [node respondsToSelector:@selector(nodeForRowAtIndexPath:)] &&
        [node respondsToSelector:@selector(view)] ? node : nil;
}

static NSString *CNPostID(UIViewController *controller) {
    id link = ApolloObjectIvar(controller, "link");
    NSString *identifier = [link respondsToSelector:@selector(identifier)] ? [link identifier] : nil;
    if (!identifier.length) identifier = ApolloReadSwiftStringIvar(controller, "linkID");
    return identifier;
}

static ApolloCommentNavigationVisit *CNVisit(UIViewController *controller) {
    ApolloCommentNavigationVisit *visit = objc_getAssociatedObject(controller, &kCNVisitKey);
    if (!visit) {
        visit = [ApolloCommentNavigationVisit new];
        visit.snapshotJSON = [[NSUserDefaults standardUserDefaults] dataForKey:@"PostCommentsSnapshots"];
        objc_setAssociatedObject(controller, &kCNVisitKey, visit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Keep the native/default path cheap: capture immutable bytes now, but
    // decode the one post's cutoff only when new-comment navigation is used.
    if (ApolloCommentNavigatorMode() != ApolloCommentNavigationModeNewComments) return visit;
    NSString *postID = CNPostID(controller);
    if (postID.length && ![postID isEqualToString:visit.postID]) {
        visit.postID = postID;
        visit.baseline = ApolloCommentNavigationBaseline(visit.snapshotJSON, postID);
        visit.lastCommentID = nil;
        visit.pending = NO;
        visit.generation++;
        ApolloLog(@"[CommentNavigator] Visit baseline %@", visit.baseline ? @"available" : @"not available");
    }
    return visit;
}

ApolloCommentNavigationMode ApolloCommentNavigatorMode(void) {
    return sCommentNavigationMode == 1 ? ApolloCommentNavigationModeNewComments : ApolloCommentNavigationModeParentThreads;
}

// Apollo's chevron is the template asset "comment-jump-button-arrow", so it
// renders in the image view's effective tint, which follows the theme. Match
// that exact color; white is only for a non-template (pre-tinted) image.
static void CNTintBadge(UIButton *button, ApolloCommentNavigationButtonStyle *style) {
    UIImage *image = button.currentImage;
    BOOL templated = image.renderingMode == UIImageRenderingModeAlwaysTemplate ||
        (image.renderingMode == UIImageRenderingModeAutomatic && image.symbolImage);
    style.badge.textColor = templated ? (button.imageView.tintColor ?: button.tintColor) : UIColor.whiteColor;
}

static void CNStyleButton(UIViewController *controller) {
    id raw = ApolloObjectIvar(controller, "commentJumpButton");
    if (![raw isKindOfClass:UIButton.class]) return;
    UIButton *button = raw;
    ApolloCommentNavigationButtonStyle *style = objc_getAssociatedObject(button, &kCNButtonStyleKey);
    if (ApolloCommentNavigatorMode() == ApolloCommentNavigationModeParentThreads) {
        if (!style) return;
        [style.badge removeFromSuperview];
        button.imageEdgeInsets = style.imageInsets;
        button.accessibilityLabel = style.label;
        button.accessibilityHint = style.hint;
        objc_setAssociatedObject(button, &kCNButtonStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!style) {
        style = [ApolloCommentNavigationButtonStyle new];
        style.label = button.accessibilityLabel;
        style.hint = button.accessibilityHint;
        style.imageInsets = button.imageEdgeInsets;
        style.badge = [UILabel new];
        style.badge.text = @"NEW";
        style.badge.font = [UIFont systemFontOfSize:8 weight:UIFontWeightSemibold];
        style.badge.textAlignment = NSTextAlignmentCenter;
        style.badge.userInteractionEnabled = NO;
        style.badge.isAccessibilityElement = NO;
        style.badge.translatesAutoresizingMaskIntoConstraints = NO;
        [button addSubview:style.badge];
        [NSLayoutConstraint activateConstraints:@[
            [style.badge.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
            // Apollo's visible circle is inset inside a larger touch target.
            // Place the caption under its centered chevron, inside that art.
            [style.badge.centerYAnchor constraintEqualToAnchor:button.centerYAnchor constant:7.0],
            [style.badge.widthAnchor constraintEqualToAnchor:button.widthAnchor],
            [style.badge.heightAnchor constraintEqualToConstant:10.0],
        ]];
        objc_setAssociatedObject(button, &kCNButtonStyleKey, style, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Keep the caption independent of Apollo's image configuration and initial
    // zero-sized bounds. Constraints are installed once, outside layout hooks.
    // Center the chevron and caption as a single stack. Preserve the native
    // insets so switching back restores Apollo's exact original appearance.
    UIEdgeInsets insets = style.imageInsets;
    insets.top -= 6.0;
    insets.bottom += 6.0;
    button.imageEdgeInsets = insets;
    CNTintBadge(button, style);
    [button bringSubviewToFront:style.badge];
    button.accessibilityLabel = @"Next new comment";
    button.accessibilityHint = @"Hold to jump to the previous new comment.";
}

void ApolloCommentNavigatorSetMode(ApolloCommentNavigationMode mode) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloCommentNavigatorSetMode(mode); });
        return;
    }
    sCommentNavigationMode = mode == ApolloCommentNavigationModeNewComments ? 1 : 0;
    [[NSUserDefaults standardUserDefaults] setInteger:sCommentNavigationMode forKey:UDKeyCommentNavigationMode];
    for (UIViewController *controller in sCNControllers.allObjects) {
        ApolloCommentNavigationVisit *visit = objc_getAssociatedObject(controller, &kCNVisitKey);
        visit.generation++;
        visit.pending = NO;
        visit.lastCommentID = nil;
        CNStyleButton(controller);
    }
    ApolloLog(@"[CommentNavigator] Mode changed to %@", sCommentNavigationMode ? @"new comments" : @"parent threads");
}

static NSArray<ApolloCommentNavigationTarget *> *CNTargets(ASTableNode *node, NSDate *baseline) {
    UITableView *table = node.view;
    NSMutableArray *targets = [NSMutableArray array];
    NSString *username = ApolloActiveAccountUsername();
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        NSInteger count = [table numberOfRowsInSection:section];
        for (NSInteger row = 0; row < count; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            ASCellNode *cell = [node nodeForRowAtIndexPath:path];
            if (!ApolloClassCommentCellNode || ![cell isKindOfClass:ApolloClassCommentCellNode]) continue;
            RDKComment *comment = ApolloObjectIvar(cell, "comment");
            if (![comment isKindOfClass:ApolloClassRDKComment] ||
                !ApolloCommentNavigationIsNew(comment.createdUTC, baseline, comment.author, username)) continue;
            NSString *identifier = comment.identifier;
            CGRect rect = [table rectForRowAtIndexPath:path];
            if (!identifier.length || !isfinite(rect.origin.y) || rect.size.height <= 0) continue;
            ApolloCommentNavigationTarget *target = [ApolloCommentNavigationTarget new];
            target.identifier = identifier;
            target.path = path;
            target.position = rect.origin.y;
            [targets addObject:target];
        }
    }
    return targets;
}

static CGFloat CNOffset(UITableView *table, NSIndexPath *path) {
    CGFloat top = table.adjustedContentInset.top;
    CGFloat maxOffset = MAX(-top, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
    return MIN(maxOffset, MAX(-top, [table rectForRowAtIndexPath:path].origin.y - top - 8.0));
}

static void CNFlash(ASTableNode *node, NSIndexPath *path) {
    ASCellNode *cell = [node nodeForRowAtIndexPath:path];
    if (!cell.isNodeLoaded) return;
    UIView *view = cell.view;
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3.0, view.bounds.size.height)];
    line.backgroundColor = ApolloThemeAccentColor() ?: view.tintColor;
    line.userInteractionEnabled = NO;
    line.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    [view addSubview:line];
    [UIView animateWithDuration:0.65 delay:0.25 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        line.alpha = 0;
    } completion:^(__unused BOOL finished) { [line removeFromSuperview]; }];
}

// Row heights may change after the animated jump (media/previews). Re-find the
// ID in the current displayed model, then correct a bounded number of times.
// A new tap, leaving, changing mode or dragging invalidates this generation.
static void CNVerifyLanding(UIViewController *controller, NSUInteger generation, NSUInteger pass) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((pass == 0 ? 0.40 : 0.25) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        ApolloCommentNavigationVisit *visit = objc_getAssociatedObject(strongController, &kCNVisitKey);
        if (!strongController.viewIfLoaded.window || visit.generation != generation ||
            ApolloCommentNavigatorMode() != ApolloCommentNavigationModeNewComments) return;
        ASTableNode *node = CNTableNode(strongController);
        UITableView *table = node.view;
        if (!table || table.tracking || table.dragging || table.decelerating) {
            visit.pending = NO;
            return;
        }
        if (table.hasUncommittedUpdates) {
            if (pass < 2) CNVerifyLanding(strongController, generation, pass + 1);
            else visit.pending = NO;
            return;
        }
        ApolloCommentNavigationTarget *target;
        for (ApolloCommentNavigationTarget *candidate in CNTargets(node, visit.baseline)) {
            if ([candidate.identifier isEqualToString:visit.lastCommentID]) { target = candidate; break; }
        }
        if (!target) { visit.pending = NO; return; }
        CGFloat desired = CNOffset(table, target.path);
        if (fabs(table.contentOffset.y - desired) > 2.0 && !table.hasUncommittedUpdates) {
            [table setContentOffset:CGPointMake(table.contentOffset.x, desired) animated:NO];
        }
        visit.lastOffset = desired;
        if (pass == 0) CNFlash(node, target.path);
        if (pass < 2) CNVerifyLanding(strongController, generation, pass + 1);
        else visit.pending = NO;
    });
}

static void CNJump(UIViewController *controller, NSInteger direction) {
    ApolloCommentNavigationVisit *visit = CNVisit(controller);
    ASTableNode *node = CNTableNode(controller);
    UITableView *table = node.view;
    if (!table || table.hasUncommittedUpdates) {
        ApolloShowToastWithStyle(@"Comments are still loading", nil, ApolloToastStyleInfo, nil);
        return;
    }
    if (!visit.baseline) {
        ApolloShowToastWithStyle(@"No previous visit recorded", @"Revisit this post later to jump to new comments.", ApolloToastStyleInfo, nil);
        return;
    }
    NSArray<ApolloCommentNavigationTarget *> *targets = CNTargets(node, visit.baseline);
    if (!targets.count) {
        ApolloShowToastWithStyle(@"No new comments in loaded threads", @"Replies inside collapsed threads are skipped.", ApolloToastStyleInfo, nil);
        ApolloLog(@"[CommentNavigator] No eligible displayed comments");
        return;
    }
    NSMutableArray<NSNumber *> *positions = [NSMutableArray arrayWithCapacity:targets.count];
    NSInteger current = NSNotFound;
    for (NSUInteger i = 0; i < targets.count; i++) {
        [positions addObject:@(targets[i].position)];
        if ([targets[i].identifier isEqualToString:visit.lastCommentID]) current = (NSInteger)i;
    }
    BOOL useCurrent = current != NSNotFound &&
        (visit.pending || fabs(table.contentOffset.y - visit.lastOffset) <= 4.0);
    BOOL wrapped = NO;
    NSInteger index = ApolloCommentNavigationTargetIndex(positions,
        table.contentOffset.y + table.adjustedContentInset.top + 8.0, direction, current, useCurrent, &wrapped);
    if (index == NSNotFound) return;
    ApolloCommentNavigationTarget *target = targets[index];
    visit.lastCommentID = target.identifier;
    visit.generation++;
    visit.pending = YES;
    CGFloat desired = CNOffset(table, target.path);
    visit.lastOffset = desired;
    [table setContentOffset:CGPointMake(table.contentOffset.x, desired) animated:!UIAccessibilityIsReduceMotionEnabled()];
    if (UIAccessibilityIsVoiceOverRunning()) {
        NSString *message = [NSString stringWithFormat:@"%@New comment %ld of %lu",
            wrapped ? (direction > 0 ? @"Back to first · " : @"Back to last · ") : @"", (long)(index + 1), (unsigned long)targets.count];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    }
    CNVerifyLanding(controller, visit.generation, 0);
    ApolloLog(@"[CommentNavigator] Jump %@ %ld/%lu section=%ld row=%ld wrapped=%d",
        direction > 0 ? @"next" : @"previous", (long)(index + 1), (unsigned long)targets.count,
        (long)target.path.section, (long)target.path.row, wrapped);
}

%hook _TtC6Apollo22CommentsViewController
- (void)viewDidLoad {
    UIViewController *controller = (UIViewController *)self;
    CNVisit(controller);
    [sCNControllers addObject:controller];
    %orig;
    CNStyleButton(controller);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    CNStyleButton((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    CNStyleButton((UIViewController *)self);
}

- (void)commentJumpButtonUpdatedWithNotification:(id)notification {
    %orig(notification);
    CNStyleButton((UIViewController *)self);
}

- (void)commentJumpButtonTappedWithSender:(id)sender {
    // Apollo also calls this handler with nil after collapsing a comment.
    // Preserve that native auto-advance; the preference changes the button's
    // explicit action, not an unrelated table interaction.
    id button = ApolloObjectIvar(self, "commentJumpButton");
    BOOL fromButton = button && (sender == button ||
        ([sender isKindOfClass:UIGestureRecognizer.class] && [(UIGestureRecognizer *)sender view] == button));
    if (ApolloCommentNavigatorMode() == ApolloCommentNavigationModeNewComments && fromButton) {
        CNStyleButton((UIViewController *)self);
        CNJump((UIViewController *)self, 1);
    }
    else %orig(sender);
}

- (void)commentJumpButtonLongPressedWithSender:(id)sender {
    // UILongPressGestureRecognizer invokes its target at Began, Changed and
    // Ended. Jump exactly once per hold; retain Apollo's original native path.
    if (ApolloCommentNavigatorMode() == ApolloCommentNavigationModeNewComments) {
        if (![sender isKindOfClass:UIGestureRecognizer.class] || [(UIGestureRecognizer *)sender state] == UIGestureRecognizerStateBegan) {
            CNJump((UIViewController *)self, -1);
        }
    } else %orig(sender);
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    CNCancel((UIViewController *)self);
    %orig(scrollView);
}

- (void)refreshControlActivatedWithSender:(id)sender {
    CNCancel((UIViewController *)self);
    %orig(sender);
}

- (void)sortBarButtonItemTappedWithSender:(id)sender {
    CNCancel((UIViewController *)self);
    %orig(sender);
}

- (void)viewDidDisappear:(BOOL)animated {
    ApolloCommentNavigationVisit *visit = objc_getAssociatedObject(self, &kCNVisitKey);
    visit.generation++;
    visit.pending = NO;
    %orig(animated);
}
%end

// The native button is added only after the asynchronous comment load on some
// launch paths, after the controller's appearance callbacks have already run.
// Style it at attachment, once the owning ivar has been assigned. Never drive
// constraints from layoutSubviews to chase its position.
%hook _TtC6Apollo20FloatingActionButton
- (void)didMoveToWindow {
    %orig;
    __weak UIView *weakButton = (UIView *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *button = weakButton;
        if (!button.window) return;
        for (UIViewController *controller in sCNControllers.allObjects) {
            if (ApolloObjectIvar(controller, "commentJumpButton") == button) CNStyleButton(controller);
        }
    });
}

// A theme switch retints the chevron in place; keep the caption in step.
- (void)tintColorDidChange {
    %orig;
    UIButton *button = (UIButton *)self;
    ApolloCommentNavigationButtonStyle *style = objc_getAssociatedObject(button, &kCNButtonStyleKey);
    if (style) CNTintBadge(button, style);
}
%end

// Collapse/expand and load-more commit their displayed-model changes here.
// Cancel the old landing before Texture removes or inserts any destination;
// a subsequent tap resolves fresh paths. Other tables are untouched.
static void CNCancelForTable(UITableView *table) {
    for (UIViewController *controller in sCNControllers.allObjects) {
        ApolloCommentNavigationVisit *visit = objc_getAssociatedObject(controller, &kCNVisitKey);
        if (!visit.pending && !visit.lastCommentID) continue;
        if (CNTableNode(controller).view == table) CNCancel(controller);
    }
}

%hook UITableView
- (void)deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(UITableViewRowAnimation)animation {
    CNCancelForTable(self);
    %orig(paths, animation);
}
- (void)insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(UITableViewRowAnimation)animation {
    CNCancelForTable(self);
    %orig(paths, animation);
}
%end

%ctor {
    sCNControllers = [NSHashTable weakObjectsHashTable];
    ApolloLog(@"[CommentNavigator] Native jump-button hooks installed");
}
