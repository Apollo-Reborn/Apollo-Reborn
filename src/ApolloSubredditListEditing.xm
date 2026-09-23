#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"

// Overlay confirmation buttons without shifting or clearing the row.
static char kListConfirmation, kCellConfirmation, kEditingRightMargin, kEditingStarPriorities, kEditingSelection;

static UITableView *ApolloEditingTable(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
    }
    return nil;
}

static BOOL ApolloEditingIsList(UITableView *table) {
    Class cls = NSClassFromString(@"Apollo.RedditListViewController");
    return cls && [(id)table.dataSource isKindOfClass:cls];
}

static id ApolloEditingIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

// Use a consistent editing margin; restore it on exit. Apply at lifecycle
// entry points to avoid layoutSubviews recursion.
static void ApolloEditingAlignStar(UITableViewCell *cell, BOOL editing) {
    UIButton *star = ApolloEditingIvar(cell, "accessoryButton");
    if (![star isKindOfClass:UIButton.class]) return;
    NSNumber *original = objc_getAssociatedObject(cell, &kEditingRightMargin);
    NSArray<NSNumber *> *priorities = objc_getAssociatedObject(cell, &kEditingStarPriorities);
    UIEdgeInsets margins = cell.contentView.layoutMargins;
    if (editing && ApolloEditingIsList(ApolloEditingTable(cell))) {
        // Keep the star button from stretching and shifting its glyph.
        if (!priorities) {
            priorities = @[@([star contentHuggingPriorityForAxis:UILayoutConstraintAxisHorizontal]),
                           @([star contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisHorizontal])];
            objc_setAssociatedObject(cell, &kEditingStarPriorities, priorities, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [star setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [star setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        if (!original) objc_setAssociatedObject(cell, &kEditingRightMargin, @(margins.right), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!objc_getAssociatedObject(cell, &kCellConfirmation)) margins.right = 23.0;
    } else if (original) {
        margins.right = original.doubleValue;
        if (priorities.count == 2) {
            [star setContentHuggingPriority:priorities[0].floatValue forAxis:UILayoutConstraintAxisHorizontal];
            [star setContentCompressionResistancePriority:priorities[1].floatValue forAxis:UILayoutConstraintAxisHorizontal];
            objc_setAssociatedObject(cell, &kEditingStarPriorities, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(cell, &kEditingRightMargin, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        return;
    }
    cell.contentView.layoutMargins = margins;
}

@interface ApolloListEditConfirmation : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, weak) UITableViewCell *cell;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UITapGestureRecognizer *outsideTap;
@property(nonatomic, weak) UIView *star;
@property(nonatomic) CGAffineTransform starTransform;
@property(nonatomic) UIEdgeInsets contentMargins;
@property(nonatomic) BOOL closing;
@property(nonatomic, strong) NSMutableArray<NSArray *> *reorderControls;
- (void)dismiss;
- (void)close;
- (void)confirm;
@end

@implementation ApolloListEditConfirmation
- (void)dismiss {
    // Restore grip interaction after dismissal, reload, or reuse.
    for (NSArray *entry in self.reorderControls) {
        ((UIView *)entry[0]).userInteractionEnabled = [entry[1] boolValue];
    }
    self.reorderControls = nil;
    if (self.cell) {
        self.cell.contentView.layoutMargins = self.contentMargins;
        [self.cell layoutIfNeeded];
    }
    self.star.transform = self.starTransform;
    self.star = nil;
    objc_setAssociatedObject(self.cell, &kCellConfirmation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.panel) ApolloLog(@"[ListEditing] dismiss");
    [self.panel removeFromSuperview];
    [self.table removeGestureRecognizer:self.outsideTap];
    [self.table.panGestureRecognizer removeTarget:self action:@selector(scrolled:)];
    self.panel = nil;
    self.cell = nil;
    self.outsideTap = nil;
}
- (void)close {
    UIView *panel = self.panel;
    UITableViewCell *cell = self.cell;
    if (!panel || !cell) { [self dismiss]; return; }
    if (self.closing) return;
    self.closing = YES;
    // Ignore taps while closing; the completion retains this state.
    panel.userInteractionEnabled = NO;
    [self.table removeGestureRecognizer:self.outsideTap];
    [self.table.panGestureRecognizer removeTarget:self action:@selector(scrolled:)];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.28
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        cell.contentView.layoutMargins = self.contentMargins;
        [cell layoutIfNeeded];
        panel.subviews.firstObject.transform = CGAffineTransformMakeTranslation(CGRectGetWidth(panel.bounds), 0.0);
    } completion:^(BOOL finished) {
        // A reload, reuse or another minus tap may have replaced this panel.
        if (self.panel == panel) [self dismiss];
    }];
}
- (void)scrolled:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self dismiss];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"UITableViewCellEditControl"]) return NO;
    }
    // Exclude the panel bounds from outside taps during animation.
    if (self.panel && CGRectContainsPoint(self.panel.bounds, [touch locationInView:self.panel])) return NO;
    return ![touch.view isDescendantOfView:self.panel];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)confirm {
    UITableView *table = self.table;
    NSIndexPath *path = [table indexPathForCell:self.cell];
    ApolloLog(@"[ListEditing] confirmation tapped editing=%d validRow=%d", table.editing, path != nil);
    [self dismiss];
    // Resolve the current row before the remapping hooks translate its index.
    if (table.editing && path && [table.dataSource respondsToSelector:@selector(tableView:commitEditingStyle:forRowAtIndexPath:)]) {
        ApolloFollowingAnimateNextRemoval(table, path);
        [table.dataSource tableView:table commitEditingStyle:UITableViewCellEditingStyleDelete forRowAtIndexPath:path];
    }
}
@end

static BOOL ApolloEditingShowConfirmation(UIControl *control) {
    if (![NSStringFromClass(control.class) isEqualToString:@"UITableViewCellEditControl"]) return NO;
    UIView *parent = control.superview;
    while (parent && ![parent isKindOfClass:UITableViewCell.class]) parent = parent.superview;
    UITableViewCell *cell = (UITableViewCell *)parent;
    UITableView *table = ApolloEditingTable(cell);
    if (!ApolloEditingIsList(table) || !table.editing || cell.editingStyle != UITableViewCellEditingStyleDelete) return NO;
    NSIndexPath *path = [table indexPathForCell:cell];
    if (!path) return NO;
    ApolloListEditConfirmation *state = objc_getAssociatedObject(table, &kListConfirmation);
    BOOL sameCell = state.cell == cell;
    if (sameCell) { [state close]; return YES; }
    [state close];
    // Keep outgoing animations independent. Clean up any earlier confirmation
    // on this cell before installing the new one.
    [(ApolloListEditConfirmation *)objc_getAssociatedObject(cell, &kCellConfirmation) dismiss];
    state = [ApolloListEditConfirmation new];
    state.table = table;
    objc_setAssociatedObject(table, &kListConfirmation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *title = nil;
    if ([table.delegate respondsToSelector:@selector(tableView:titleForDeleteConfirmationButtonForRowAtIndexPath:)]) {
        title = [table.delegate tableView:table titleForDeleteConfirmationButtonForRowAtIndexPath:path];
    }
    if (!title.length) title = NSLocalizedString(@"Delete", nil);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    button.backgroundColor = UIColor.systemRedColor;
    button.layer.cornerRadius = 16.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.accessibilityIdentifier = @"ApolloListEditConfirmation";
    [button addTarget:state action:@selector(confirm) forControlEvents:UIControlEventTouchUpInside];
    UIView *panel = [UIView new];
    // Cover the grip around the rounded button with the row background.
    panel.clipsToBounds = YES;
    UIView *surface = [UIView new];
    surface.backgroundColor = cell.contentView.backgroundColor ?: cell.backgroundColor;
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:surface];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [surface addSubview:button];
    [cell addSubview:panel];
    // Preserve native button sizing, rounded to the display pixel.
    CGFloat scale = MAX(1.0, cell.traitCollection.displayScale);
    CGFloat textWidth = [title sizeWithAttributes:@{NSFontAttributeName: button.titleLabel.font}].width;
    CGFloat width = ceil((textWidth + 24.0) * scale) / scale;
    [NSLayoutConstraint activateConstraints:@[
        [panel.trailingAnchor constraintEqualToAnchor:cell.safeAreaLayoutGuide.trailingAnchor constant:-30.0],
        [panel.topAnchor constraintEqualToAnchor:cell.topAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
        [panel.widthAnchor constraintEqualToConstant:width + 8.0],
        [surface.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [surface.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [surface.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [surface.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [button.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:4.0],
        [button.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-4.0],
        [button.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor],
        [button.heightAnchor constraintEqualToAnchor:surface.heightAnchor constant:-8.0]
    ]];
    ApolloLog(@"[ListEditing] showing confirmation %@", title);
    state.cell = cell;
    objc_setAssociatedObject(cell, &kCellConfirmation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    state.panel = panel;
    state.outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(close)];
    state.outsideTap.cancelsTouchesInView = NO;
    state.outsideTap.delegate = state;
    [table addGestureRecognizer:state.outsideTap];
    [table.panGestureRecognizer addTarget:state action:@selector(scrolled:)];
    [cell layoutIfNeeded];
    // Disable the covered grip so it cannot intercept confirmation taps.
    state.reorderControls = [NSMutableArray new];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithArray:cell.subviews];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([NSStringFromClass(view.class) containsString:@"ReorderControl"]) {
            [state.reorderControls addObject:@[view, @(view.userInteractionEnabled)]];
            view.userInteractionEnabled = NO;
        } else {
            [pending addObjectsFromArray:view.subviews];
        }
    }
    [cell bringSubviewToFront:panel];
    state.star = ApolloEditingIvar(cell, "accessoryButton");
    state.starTransform = state.star.transform;
    state.contentMargins = cell.contentView.layoutMargins;
    CGRect starFrame = [state.star convertRect:state.star.bounds toView:cell];
    CGFloat starNudge = state.star ? MAX(16.0, CGRectGetMaxX(starFrame) - CGRectGetMinX(panel.frame) + 8.0) : 0.0;
    surface.transform = CGAffineTransformMakeTranslation(width + 8.0, 0.0);
    // Narrow the text/star stack to truncate the label without moving its left edge.
    UIEdgeInsets confirmationMargins = state.contentMargins;
    confirmationMargins.right += starNudge;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.28
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        cell.contentView.layoutMargins = confirmationMargins;
        [cell layoutIfNeeded];
        surface.transform = CGAffineTransformIdentity;
    } completion:nil];
    return YES;
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    // The minus sends rotation and confirmation actions; only the latter toggles the panel.
    if (action == NSSelectorFromString(@"editControlWasClicked:") && ApolloEditingShowConfirmation(self)) return;
    if (action == NSSelectorFromString(@"_toggleRotate") &&
        [NSStringFromClass(self.class) isEqualToString:@"UITableViewCellEditControl"] &&
        ApolloEditingIsList(ApolloEditingTable(self))) return;
    %orig;
}
%end

%hook UITableView
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [(ApolloListEditConfirmation *)objc_getAssociatedObject(self, &kListConfirmation) dismiss];
    BOOL list = ApolloEditingIsList(self);
    if (list && editing && !objc_getAssociatedObject(self, &kEditingSelection)) {
        objc_setAssociatedObject(self, &kEditingSelection, @(self.allowsSelectionDuringEditing), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.allowsSelectionDuringEditing = NO;
    }
    %orig;
    if (list) {
        for (NSIndexPath *path in self.indexPathsForSelectedRows.copy) [self deselectRowAtIndexPath:path animated:NO];
        for (UITableViewCell *cell in self.visibleCells) [cell setHighlighted:NO animated:NO];
        if (!editing) {
            NSNumber *previous = objc_getAssociatedObject(self, &kEditingSelection);
            if (previous) self.allowsSelectionDuringEditing = previous.boolValue;
            objc_setAssociatedObject(self, &kEditingSelection, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}
- (void)reloadData {
    [(ApolloListEditConfirmation *)objc_getAssociatedObject(self, &kListConfirmation) dismiss];
    %orig;
}
%end

%hook UITableViewCell
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    UITableView *table = ApolloEditingTable(self);
    if (table.editing && ApolloEditingIsList(table)) highlighted = NO;
    %orig(highlighted, animated);
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    UITableView *table = ApolloEditingTable(self);
    if (table.editing && ApolloEditingIsList(table)) selected = NO;
    %orig(selected, animated);
}
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    ApolloEditingAlignStar(self, editing);
    %orig;
}
- (void)didMoveToSuperview {
    %orig;
    ApolloEditingAlignStar(self, self.editing);
}
- (void)prepareForReuse {
    ApolloListEditConfirmation *state = objc_getAssociatedObject(self, &kCellConfirmation);
    if (state.cell == self) [state dismiss];
    ApolloEditingAlignStar(self, NO);
    %orig;
}
%end

static UITableView *ApolloEditingFindListTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class] && ApolloEditingIsList((UITableView *)view)) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = ApolloEditingFindListTable(child);
        if (table) return table;
    }
    return nil;
}

static void ApolloEditingMatchListBackground(UIViewController *controller) {
    UITableView *table = ApolloEditingFindListTable(controller.view);
    UIColor *color = nil;
    for (UITableViewCell *cell in table.visibleCells) {
        for (UIColor *candidate in @[cell.contentView.backgroundColor ?: UIColor.clearColor,
                                     cell.backgroundColor ?: UIColor.clearColor]) {
            if (CGColorGetAlpha([candidate resolvedColorWithTraitCollection:table.traitCollection].CGColor) > 0.99) {
                color = candidate;
                break;
            }
        }
        if (color) break;
    }
    if (!color) return;
    // The top inset and scroll-edge effect draw from the table's background.
    table.backgroundColor = color;
    controller.view.backgroundColor = color;
}

@interface ApolloEditListController : UIViewController @end
%group ApolloListEditingController
%hook ApolloEditListController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloEditingMatchListBackground(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloEditingMatchListBackground(self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloEditingMatchListBackground(self); });
}
%end
%end

// The Swift cell skips super.prepareForReuse, so hook both implementations.
@interface ApolloEditListCell : UITableViewCell @end
%group ApolloListEditingCells
%hook ApolloEditListCell
- (void)prepareForReuse {
    ApolloListEditConfirmation *state = objc_getAssociatedObject(self, &kCellConfirmation);
    if (state.cell == self) [state dismiss];
    ApolloEditingAlignStar(self, NO);
    %orig;
}
%end
%end

%ctor {
    %init;
    Class listClass = NSClassFromString(@"Apollo.RedditListViewController");
    if (listClass) {
        %init(ApolloListEditingController, ApolloEditListController = listClass);
    }
    Class cellClass = NSClassFromString(@"Apollo.RedditListTableViewCell");
    if (cellClass) {
        %init(ApolloListEditingCells, ApolloEditListCell = cellClass);
    }
}
