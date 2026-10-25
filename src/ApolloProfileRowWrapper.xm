// Hidden & Deleted (ApolloHiddenContentMenu.xm) and Recently Read
// (ApolloRecentlyRead.xm) each stack [row, separator, row] in one ASCellNode
// wrapper so they keep Apollo's native row styling. UIKit and Texture see that
// wrapper as a single row: the press highlight never reached either native row
// (they only darken through their own highlighted/selected properties), and on
// iPad the focus halo outlined both rows at once. Route both to whichever half
// the finger is on.
#import "ApolloProfileRowWrapper.h"
#import "ApolloTextureDecls.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ipad/ApolloPaneLayout.h"
#import <objc/message.h>
#import <objc/runtime.h>

@interface ASDisplayNode (ApolloProfileRowWrapper)
@property (nonatomic) CGRect frame;
@property (nonatomic, getter=isHighlighted) BOOL highlighted;
@property (nonatomic, getter=isSelected) BOOL selected;
@end

static char kApolloProfileRowTouchedChild;
static char kApolloProfileRowInjectedOpen;

@interface UITableViewCell (ApolloProfileRowTextureCell)
- (id)node;
@end

static NSArray<ASDisplayNode *> *ApolloProfileRowChildren(id node) {
    static SEL key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ key = sel_registerName("apollo_profileShortcutChildren"); });
    return node ? objc_getAssociatedObject(node, key) : nil;
}

static UITableViewCell *ApolloProfileRowCellForView(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UITableViewCell.class]) return (UITableViewCell *)ancestor;
    }
    return nil;
}

static ASDisplayNode *ApolloProfileRowWrapperForCell(UITableViewCell *cell) {
    static SEL nodeSelector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ nodeSelector = sel_registerName("asyncdisplaykit_node"); });
    for (UIView *view in cell.contentView.subviews) {
        if (![view respondsToSelector:nodeSelector]) continue;
        id node = ((id (*)(id, SEL))objc_msgSend)(view, nodeSelector);
        if (ApolloProfileRowChildren(node)) return node;
    }
    return nil;
}

// Mirror the wrapper's highlighted/selected state onto the touched row only.
static void ApolloProfileRowApplyState(ASDisplayNode *wrapper) {
    NSArray<ASDisplayNode *> *children = ApolloProfileRowChildren(wrapper);
    if (!children) return;
    ASDisplayNode *touched = objc_getAssociatedObject(wrapper, &kApolloProfileRowTouchedChild);
    BOOL highlighted = wrapper.highlighted;
    BOOL selected = wrapper.selected;
    for (ASDisplayNode *child in children) {
        BOOL owns = child == touched;
        if (child.highlighted != (highlighted && owns)) child.highlighted = highlighted && owns;
        if (child.selected != (selected && owns)) child.selected = selected && owns;
    }
}

// UIKit moves focus to a tapped row but, for these two-row cells, never asks
// for its halo to be drawn. Re-assigning the effect is that request.
static void ApolloProfileRowRefreshHaloAfter(UITableViewCell *cell, NSTimeInterval delay) {
    __weak UITableViewCell *weakCell = cell;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableViewCell *strongCell = weakCell;
        if (strongCell.window && strongCell.focusEffect) strongCell.focusEffect = [strongCell.focusEffect copy];
    });
}

static void ApolloProfileRowRefreshHalo(UITableViewCell *cell) {
    ApolloProfileRowRefreshHaloAfter(cell, 0.0);
}

static void ApolloProfileRowSetTouchedChild(ASDisplayNode *wrapper, ASDisplayNode *child) {
    if (objc_getAssociatedObject(wrapper, &kApolloProfileRowTouchedChild) == child) return;
    objc_setAssociatedObject(wrapper, &kApolloProfileRowTouchedChild, child, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloProfileRowApplyState(wrapper);
    // Let the pane's cell chrome move the focus halo to the new row.
    [ApolloProfileRowCellForView(wrapper.view) setNeedsLayout];
}

void ApolloProfileRowWrapperRegisterInjectedRow(id row, void (^open)(UIView *rowView)) {
    if (row && open) objc_setAssociatedObject(row, &kApolloProfileRowInjectedOpen, open, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// The half that should act now: its registered opener for an injected row,
// nil for Apollo's own row (which the table's normal selection handles).
static void (^ApolloProfileRowInjectedOpenForWrapper(ASDisplayNode *wrapper))(UIView *) {
    ASDisplayNode *touched = wrapper ? objc_getAssociatedObject(wrapper, &kApolloProfileRowTouchedChild) : nil;
    if (![touched isNodeLoaded]) return nil;
    return objc_getAssociatedObject(touched, &kApolloProfileRowInjectedOpen);
}

static UITableView *ApolloProfileRowTableForCell(UITableViewCell *cell) {
    for (UIView *ancestor = cell.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UITableView.class]) return (UITableView *)ancestor;
    }
    return nil;
}

// Selection follows focus for whole cells only. When the arrow keys move
// between the halves of one cell, open the newly focused half ourselves the
// way the table would have: Apollo's row through the table's own selection
// callback, an injected row through its registered opener.
static void ApolloProfileRowOpenTouchedChild(UITableViewCell *cell, ASDisplayNode *wrapper) {
    __weak UITableViewCell *weakCell = cell;
    __weak ASDisplayNode *weakWrapper = wrapper;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableViewCell *strongCell = weakCell;
        ASDisplayNode *strongWrapper = weakWrapper;
        if (!strongCell.window || !strongWrapper) return;
        void (^open)(UIView *) = ApolloProfileRowInjectedOpenForWrapper(strongWrapper);
        ASDisplayNode *touched = objc_getAssociatedObject(strongWrapper, &kApolloProfileRowTouchedChild);
        if (open) {
            open(touched.view);
            return;
        }
        UITableView *table = ApolloProfileRowTableForCell(strongCell);
        NSIndexPath *path = [table indexPathForCell:strongCell];
        if (path && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            [table.delegate tableView:table didSelectRowAtIndexPath:path];
        }
    });
}

BOOL ApolloProfileRowWrapperFocusRect(UITableViewCell *cell, CGRect *outRect) {
    ASDisplayNode *wrapper = ApolloProfileRowWrapperForCell(cell);
    ASDisplayNode *row = wrapper ? objc_getAssociatedObject(wrapper, &kApolloProfileRowTouchedChild) : nil;
    if (!row || ![row isNodeLoaded] || !outRect) return NO;
    *outRect = [row.view convertRect:row.view.bounds toView:cell];
    return YES;
}

void ApolloProfileRowWrapperFocusRowView(UIView *rowView) {
    UITableViewCell *cell = ApolloProfileRowCellForView(rowView);
    ASDisplayNode *wrapper = ApolloProfileRowWrapperForCell(cell);
    if (!wrapper) return;
    for (ASDisplayNode *child in ApolloProfileRowChildren(wrapper)) {
        if ([child isNodeLoaded] && child.view == rowView) ApolloProfileRowSetTouchedChild(wrapper, child);
    }
    // Native rows get focus (and the iPad halo) from the table's own row
    // selection. The injected row's gesture cancels that, so UIKit defers focus
    // for an unselected cell and draws nothing. Select the row the same way,
    // without the delegate so the native half doesn't open too, then mirror
    // UIKit's immediate focus update for a selected row. iPad Layout only: on a
    // phone the row would simply stay selected.
    if (!ApolloPaneLayoutActive()) return;
    UITableView *table = ApolloProfileRowTableForCell(cell);
    NSIndexPath *path = [table indexPathForCell:cell];
    if (!path) return;
    [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
    UIFocusSystem *system = [UIFocusSystem focusSystemForEnvironment:cell];
    SEL immediate = NSSelectorFromString(@"_updateFocusImmediatelyToEnvironment:");
    if ([system respondsToSelector:immediate]) {
        ((void (*)(id, SEL, id))objc_msgSend)(system, immediate, cell);
    } else {
        [system requestFocusUpdateToEnvironment:cell];
        [system updateFocusIfNeeded];
    }
    ApolloProfileRowRefreshHalo(cell);
}

%hook ApolloProfileRowCellNode

// Touches inside either native row bubble up through the responder chain to
// the wrapper; the location decides which row the press belongs to.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ASDisplayNode *wrapper = (ASDisplayNode *)self;
    NSArray<ASDisplayNode *> *children = ApolloProfileRowChildren(wrapper);
    if (!children) return;
    CGPoint point = [touches.anyObject locationInView:wrapper.view];
    for (ASDisplayNode *child in children) {
        if (CGRectContainsPoint(child.frame, point)) {
            ApolloProfileRowSetTouchedChild(wrapper, child);
            return;
        }
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    ApolloProfileRowApplyState((ASDisplayNode *)self);
}

- (void)setSelected:(BOOL)selected {
    %orig;
    ASDisplayNode *wrapper = (ASDisplayNode *)self;
    ApolloProfileRowApplyState(wrapper);
    if (!selected || !ApolloProfileRowChildren(wrapper) || ![wrapper isNodeLoaded]) return;
    ApolloProfileRowRefreshHalo(ApolloProfileRowCellForView(wrapper.view));
}

%end

%hook ApolloProfileRowTableCell

// Apollo's separators are rows of their own. As focus stops, every arrow press
// alternated between a row and the hairline under it. Applies to every list.
- (BOOL)canBecomeFocused {
    id node = [self respondsToSelector:@selector(node)] ? [(UITableViewCell *)self node] : nil;
    if ((ApolloClassThinSeparatorCellNode && [node isKindOfClass:ApolloClassThinSeparatorCellNode]) ||
        (ApolloClassThickSeparatorCellNode && [node isKindOfClass:ApolloClassThickSeparatorCellNode])) return NO;
    return %orig;
}

// The arrow keys treat a two-row cell as one stop. Arriving, start on the half
// that faces the direction of travel; leaving, step to the other half first.
- (BOOL)shouldUpdateFocusInContext:(UIFocusUpdateContext *)context {
    if (!%orig) return NO;
    UITableViewCell *cell = (UITableViewCell *)self;
    id node = [cell respondsToSelector:@selector(node)] ? [cell node] : nil;
    NSArray<ASDisplayNode *> *children = ApolloProfileRowChildren(node);
    BOOL down = (context.focusHeading & UIFocusHeadingDown) != 0;
    BOOL up = (context.focusHeading & UIFocusHeadingUp) != 0;
    if (children.count < 2 || (!down && !up)) return YES;
    ASDisplayNode *wrapper = node;

    if (context.nextFocusedItem == (id<UIFocusItem>)cell && context.previouslyFocusedItem != (id<UIFocusItem>)cell) {
        ApolloProfileRowSetTouchedChild(wrapper, down ? children.firstObject : children.lastObject);
        return YES;
    }
    if (context.previouslyFocusedItem != (id<UIFocusItem>)cell) return YES;
    // A refused move is retried at once, in the same key press, with a fresh
    // context. Hold this cell for the rest of the run-loop turn after stepping.
    static __weak UITableViewCell *steppedCell;
    if (steppedCell == cell) return NO;

    ASDisplayNode *touched = objc_getAssociatedObject(wrapper, &kApolloProfileRowTouchedChild);
    NSUInteger index = touched ? [children indexOfObject:touched] : 0;
    if (index == NSNotFound) index = 0;
    NSInteger target = (NSInteger)index + (down ? 1 : -1);
    if (target < 0 || target >= (NSInteger)children.count) return YES;
    steppedCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{ steppedCell = nil; });
    ApolloProfileRowSetTouchedChild(wrapper, children[target]);
    ApolloProfileRowOpenTouchedChild(cell, wrapper);
    // UIKit treats the refused move as a failed one and clears the halo after
    // this returns, so redraw it on the new half once that has settled.
    ApolloProfileRowRefreshHaloAfter(cell, 0.3);
    return NO;
}

%end

%hook ApolloProfileRowTextureTable

// A keyboard selection (or selection following focus) of a two-row cell opens
// the focused half, not always Apollo's own row.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    ASDisplayNode *wrapper = cell ? ApolloProfileRowWrapperForCell(cell) : nil;
    void (^open)(UIView *) = ApolloProfileRowInjectedOpenForWrapper(wrapper);
    if (open) {
        ASDisplayNode *touched = objc_getAssociatedObject(wrapper, &kApolloProfileRowTouchedChild);
        open(touched.view);
    } else {
        %orig;
    }
    // Re-selecting the other half of an already selected cell changes no
    // selection state, so nothing else asks for its halo.
    if (wrapper) ApolloProfileRowRefreshHaloAfter(cell, 0.3);
}

%end

%ctor {
    Class tableCell = objc_getClass("_ASTableViewCell");
    if (!ApolloClassASCellNode || !tableCell || !ApolloClassASTableView) {
        ApolloLog(@"[ProfileRowWrapper] Texture classes missing; shared profile rows keep stock behaviour");
        return;
    }
    %init(ApolloProfileRowCellNode = ApolloClassASCellNode,
          ApolloProfileRowTableCell = tableCell,
          ApolloProfileRowTextureTable = ApolloClassASTableView);
}
