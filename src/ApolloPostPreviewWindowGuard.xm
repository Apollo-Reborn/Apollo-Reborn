// ApolloPostPreviewWindowGuard.xm
//
// Fixes Apollo-Reborn issue #1188: the app dies with an
// NSInternalInconsistencyException while scrolling a feed. A finger landing on
// a post starts that post's long-press menu, and UIKit asks for the highlight
// preview almost immediately.
//
// MECHANISM (Hopper, stock binary UUID 9E4EC7AC; the #1188 report symbolicates
// to it): -[PostCellActionTaker contextMenuInteraction:
// previewForHighlightingMenuWithConfiguration:] hands off to sub_100344204,
// which does NOT preview the view that was pressed. It finds the cell again
// through the post's section controller and hit-tests that node:
//     node = [sectionController.tableNode nodeForRowAtIndexPath:sectionController.indexPath]
//     hit  = [node hitTest:[interaction locationInView:node.view] withEvent:nil]
// and passes `hit` to -[UITargetedPreview initWithView:]. All four of its
// initWithView: call sites (large- and compact-cell branches) preview a hit
// view found this way; the report's is 0x100345194. ASTableNode answers from
// its data controller's pending map, so the lookup can land on a cell node
// whose view is loaded but not on screen. A detached view's coordinates are
// effectively the window's, so whenever the touch falls inside that off-screen
// cell's bounds (a press high on the screen, a tall post), `hit` is one of its
// subviews and has no window. UIKit then asserts inside -initWithView: ("This
// UITargetedPreview initializer requires that the view is in a window")
// before Apollo gets anything back.
//
// FIX: while Apollo builds that preview, remember the interaction's own view,
// which is the cell under the finger and is necessarily in a window (the press
// gesture could not have started otherwise). If Apollo then asks for a preview
// of a view with no window, preview the pressed view instead: the whole-cell
// lift Apollo already shows for a press on a post's title or body. Previews of
// on-screen views, which is every preview that works today, are untouched.
//
// The hook has to be on -initWithView: itself. UIKit checks the window at the
// top of that method (BUG_IN_CLIENT_OF_TARGETED_PREVIEW__VIEW_IS_NOT_IN_A_WINDOW,
// decompiled UIKitCore 23B85), before it reaches -initWithView:parameters: or
// the designated initializer that ApolloContextMenuPreviewTheme.xm hooks, so a
// hook further down never runs for this case.

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"

// Set only for the duration of Apollo's post highlight-preview builder. Weak, so
// a value left behind can never keep a cell alive.
static __weak UIView *sApolloPostPreviewPressedView = nil;

%hook _TtC6Apollo19PostCellActionTaker

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    // Save and restore rather than clear, so a nested preview request (none is
    // known) can't end the outer one's scope early. @finally, so the scope
    // still closes if UIKit's assertion is ever caught above us.
    UIView *previous = sApolloPostPreviewPressedView;
    sApolloPostPreviewPressedView = interaction.view;
    @try {
        return %orig;
    } @finally {
        sApolloPostPreviewPressedView = previous;
    }
}

%end

%hook UITargetedPreview

- (instancetype)initWithView:(UIView *)view {
    // Every preview outside Apollo's post builder bails on the nil check. The
    // scope is only ever set on the main thread (a UIKit delegate callback), so
    // never read another thread's view state against it.
    UIView *pressed = sApolloPostPreviewPressedView;
    if (!pressed || !NSThread.isMainThread || view.window) return %orig;

    if (pressed.window) {
        ApolloLog(@"[PostPreviewGuard] Apollo asked to preview %@ %p, which is not in a window; previewing the pressed %@ %p instead",
                  NSStringFromClass([view class]), view, NSStringFromClass([pressed class]), pressed);
        return %orig(pressed);
    }

    // Both off-window: nothing on screen to lift, so UIKit's assertion will
    // still fire. Leave a trail in the log that ships with crash reports.
    ApolloLog(@"[PostPreviewGuard] neither Apollo's preview view %@ %p nor the pressed %@ %p is in a window",
              NSStringFromClass([view class]), view, NSStringFromClass([pressed class]), pressed);
    return %orig;
}

%end

%ctor {
    %init;
    ApolloLog(@"[PostPreviewGuard] hook installed (post highlight previews fall back to the pressed cell when Apollo's view is off-window)");
}
