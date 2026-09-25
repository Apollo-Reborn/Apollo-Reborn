#import "ApolloSettingsForm.h"

NS_ASSUME_NONNULL_BEGIN

// "Action Menus" (Apollo Reborn → Interface): the list of Apollo's menus whose
// rows can be reordered and hidden — the ••• menus (feed, post, post's
// comments, comment) and, for moderators, the shield menus — plus an "All
// Menus" visibility overview. Each row pushes that menu's editor. Model, item
// catalogue and persistence live in ApolloActionMenuLayout.h; the menus
// themselves read the saved layout in ApolloActionMenu.xm.
@interface ApolloActionMenuSettingsViewController : ApolloSettingsFormViewController
@end

// The context that edits visibility across every menu at once.
extern NSString *const ApolloActionMenuEditorAllMenus;

// One menu's editor (or the All Menus overview): its items in the saved order,
// tap to check or uncheck (hide), touch and hold to drag into place. The
// button top-right is the preview: ••• or the shield, whichever opens the menu
// being edited, and it opens that menu as Apollo would open it right now (a
// real UIMenu on Liquid Glass, a classic-sheet lookalike before it).
@interface ApolloActionMenuEditorViewController : ApolloSettingsFormViewController
// `context` is an ApolloActionMenuContext or ApolloActionMenuEditorAllMenus.
- (instancetype)initWithContext:(NSString *)context;
@end

NS_ASSUME_NONNULL_END
