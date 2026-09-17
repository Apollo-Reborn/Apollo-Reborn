#import "ApolloSettingsForm.h"

// "Action Menus" screen (Apollo Reborn → Interface): reorder and hide the rows
// of Apollo's ••• menus — the feed's, a post's, a post's comments view's and a
// comment's. The ••• button top-right is the preview: it opens the menu being
// edited as Apollo would open it right now (a real UIMenu on Liquid Glass, a
// classic-sheet lookalike before it). Touch and hold a row to drag it into
// place; tap it to uncheck (hide) it, tap again to bring it back. Model,
// item catalogue and persistence live in ApolloActionMenuLayout.h; the menus
// themselves read the saved layout in ApolloActionMenu.xm.
@interface ApolloActionMenuSettingsViewController : ApolloSettingsFormViewController
@end
