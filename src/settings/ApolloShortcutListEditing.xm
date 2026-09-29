#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"


// Overlay confirmation buttons without shifting or clearing the row.
static char kListConfirmation, kCellConfirmation, kEditingSelection;

static UITableView *ApolloEditingTable(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
    }
    return nil;
}

static id ApolloShortcutEditingOwner(UITableView *table) {
    Class cls = NSClassFromString(@"ApolloSettingsShortcutsViewController");
    // UIKit may wrap the data source in _UIFilteredDataSource during editing.
    // The responder chain still identifies the actual owning controller.
    for (UIResponder *responder = table; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:cls]) return responder;
    }
    return nil;
}
static BOOL ApolloEditingIsList(UITableView *table) {
    return ApolloShortcutEditingOwner(table) != nil;
}

@interface ApolloShortcutEditConfirmation : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, weak) UITableViewCell *cell;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, weak) UIView *reorderControl;
@property(nonatomic) BOOL reorderControlWasEnabled;
@property(nonatomic, strong) UITapGestureRecognizer *outsideTap;
@property(nonatomic) BOOL closing;
- (void)dismiss;
- (void)close;
- (void)confirm;
@end

@implementation ApolloShortcutEditConfirmation
- (void)dismiss {
    self.reorderControl.userInteractionEnabled = self.reorderControlWasEnabled;
    self.reorderControl = nil;
    objc_setAssociatedObject(self.cell, &kCellConfirmation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.panel) ApolloLog(@"[ShortcutEditing] dismiss");
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
    ApolloLog(@"[ShortcutEditing] confirmation tapped editing=%d validRow=%d", table.editing, path != nil);
    [self dismiss];
    // Resolve the current row identity at confirmation time, after any updates.
    id owner = ApolloShortcutEditingOwner(table);
    if (table.editing && path && [owner respondsToSelector:@selector(tableView:commitEditingStyle:forRowAtIndexPath:)]) {

        [owner tableView:table commitEditingStyle:UITableViewCellEditingStyleDelete forRowAtIndexPath:path];
    }
}
@end

static BOOL ApolloEditingShowConfirmation(UIControl *control) {
    if (![NSStringFromClass(control.class) isEqualToString:@"UITableViewCellEditControl"]) return NO;
    UIView *parent = control.superview;
    while (parent && ![parent isKindOfClass:UITableViewCell.class]) parent = parent.superview;
    UITableViewCell *cell = (UITableViewCell *)parent;
    UITableView *table = ApolloEditingTable(cell);
    if (!ApolloEditingIsList(table) || !table.editing) return NO;
    NSIndexPath *path = [table indexPathForCell:cell];
    if (!path || [ApolloShortcutEditingOwner(table) tableView:table editingStyleForRowAtIndexPath:path]
        != UITableViewCellEditingStyleDelete) return NO;
    ApolloShortcutEditConfirmation *state = objc_getAssociatedObject(table, &kListConfirmation);
    BOOL sameCell = state.cell == cell;
    if (sameCell) { [state close]; return YES; }
    [state close];
    // Keep outgoing animations independent. Clean up any earlier confirmation
    // on this cell before installing the new one.
    [(ApolloShortcutEditConfirmation *)objc_getAssociatedObject(cell, &kCellConfirmation) dismiss];
    state = [ApolloShortcutEditConfirmation new];
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
    button.accessibilityIdentifier = @"ApolloShortcutEditConfirmation";
    [button addTarget:state action:@selector(confirm) forControlEvents:UIControlEventTouchUpInside];
    UIView *panel = [UIView new];
    // Overlay the confirmation inside the existing row; leave its left edge fixed.
    panel.clipsToBounds = YES;
    UIView *surface = [UIView new];
    surface.backgroundColor = cell.backgroundColor ?: cell.contentView.backgroundColor;
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
    // Leave the separator pixels outside the overlay while preserving the
    // existing button size and vertical center.
    [NSLayoutConstraint activateConstraints:@[
        [panel.trailingAnchor constraintEqualToAnchor:cell.safeAreaLayoutGuide.trailingAnchor constant:-8.0],
        [panel.topAnchor constraintEqualToAnchor:cell.topAnchor constant:1.0],
        [panel.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-1.0],
        [panel.widthAnchor constraintEqualToConstant:width + 8.0],
        [surface.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [surface.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [surface.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [surface.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [button.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:4.0],
        [button.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-4.0],
        [button.centerYAnchor constraintEqualToAnchor:surface.centerYAnchor],
        [button.heightAnchor constraintEqualToAnchor:surface.heightAnchor constant:-6.0]
    ]];
    ApolloLog(@"[ShortcutEditing] showing confirmation %@", title);
    state.cell = cell;
    objc_setAssociatedObject(cell, &kCellConfirmation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    state.panel = panel;
    state.outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(close)];
    state.outsideTap.cancelsTouchesInView = NO;
    state.outsideTap.delegate = state;
    [table addGestureRecognizer:state.outsideTap];
    [table.panGestureRecognizer addTarget:state action:@selector(scrolled:)];
    [cell layoutIfNeeded];
    // The grip lies behind Remove. Disable it until the confirmation closes
    // so its hit target cannot steal taps from the visible button.
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithArray:cell.subviews];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([NSStringFromClass(view.class) containsString:@"ReorderControl"]) {
            state.reorderControl = view;
            state.reorderControlWasEnabled = view.userInteractionEnabled;
            view.userInteractionEnabled = NO;
            break;
        } else {
            [pending addObjectsFromArray:view.subviews];
        }
    }
    [cell bringSubviewToFront:panel];
    surface.transform = CGAffineTransformMakeTranslation(width + 8.0, 0.0);
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.28
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
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
    [(ApolloShortcutEditConfirmation *)objc_getAssociatedObject(self, &kListConfirmation) dismiss];
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
    [(ApolloShortcutEditConfirmation *)objc_getAssociatedObject(self, &kListConfirmation) dismiss];
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
- (void)prepareForReuse {
    ApolloShortcutEditConfirmation *state = objc_getAssociatedObject(self, &kCellConfirmation);
    if (state.cell == self) [state dismiss];
    %orig;
}
%end

%ctor { %init; }
