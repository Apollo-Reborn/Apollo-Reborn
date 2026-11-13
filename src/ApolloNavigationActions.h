#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Returns the original custom content inside the item's viewport.
UIView *ApolloNavigationActionsContentView(UIBarButtonItem *item);
// UIKit owns this surface during menu transitions: do not duplicate it, alter
// its visibility, or change its geometry until native ownership ends.
UIView *ApolloNavigationActionsMenuSourceView(UIView *action);

// YES while the trailing Duo rail publishes `button` (a control inside Apollo's
// composite actions) as one of its generated native items.
BOOL ApolloNavigationActionsDuoMirrorsButton(UINavigationItem *item, UIView *button);

// Defers measurement, so calling from a layout callback is safe.
void ApolloNavigationActionsRefresh(UINavigationBar *navigationBar);
// Tint a native Edit/Done item's UIKit-owned prominent fill while editing.
// Keeps its native target, image, style, sizing and transition unchanged.
void ApolloNavigationActionsSetNativeEditingAccent(UIBarButtonItem *item, BOOL enabled);
// Accent Navigation Buttons (Liquid Glass): turn the setting on or off and
// re-tint the buttons already on screen.
void ApolloNavigationActionsSetAccentButtons(BOOL enabled);
// The theme accent navigation buttons take while Accent Navigation Buttons is
// on, else nil (they keep the neutral chrome color).
UIColor *ApolloNavigationButtonAccentColor(void);
// Posted on the main queue when that color changes (the setting or the theme),
// for buttons the tweak styles itself rather than through a navigation item.
extern NSNotificationName const ApolloNavigationButtonColorDidChangeNotification;
// For such a button in a glass bar, after setting its colors: glass draws its
// glyphs monochrome, hiding an accent foreground, so this keeps that off while
// the setting is on and hands the glyphs back to UIKit when it is off.
void ApolloNavigationActionsAccentControl(UIView *control);
// An item outside the bars NavigationActions manages (the Duo drawer's +, the
// account switcher's Add and Edit): pinned to the accent while the setting is
// on, released when it is off.
void ApolloNavigationActionsAccentItem(UIBarButtonItem *item);
// Collapse this item's action pill at once (no animation). For screens that
// replace their trailing items in place for a while (the comments find
// navigator) so the pill neither stays expanded under the stand-in nor comes
// back expanded when the items return.
void ApolloNavigationActionsCollapse(UINavigationItem *item);

// Physical bar coordinates. Keep the collapsed reservation for stable title
// width; the expanded edge is used only for optional collision displacement.
CGRect ApolloNavigationActionsCollapsedFrame(UINavigationBar *navigationBar);
CGRect ApolloNavigationActionsExpandedFrame(UINavigationBar *navigationBar);

// Excludes action views from title measurement. Discover once per traversal;
// do not cache across layout/content changes.
NSArray<UIView *> *ApolloNavigationActionsManagedRoots(UINavigationBar *navigationBar);

// YES for an actions strip that belongs to another navigation item. UIKit keeps
// the outgoing page's bar items mounted briefly after a stack change; they are
// not edges of the incoming page's title.
BOOL ApolloNavigationActionsViewIsStaleForItem(UIView *view, UINavigationItem *item);

static inline BOOL ApolloNavigationActionsViewIsInManagedRoots(UIView *view, NSArray<UIView *> *roots) {
    for (UIView *root in roots) {
        if (view == root || [view isDescendantOfView:root]) return YES;
    }
    return NO;
}

__END_DECLS
