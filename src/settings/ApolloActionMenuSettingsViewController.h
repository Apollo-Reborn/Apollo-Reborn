#import "ApolloSettingsForm.h"

// "Action Menus" screen (Apollo Reborn → Interface): reorder and hide the rows
// of Apollo's ••• menus — the feed's, a post's, a post's comments view's and a
// comment's — with a live mock of the selected menu pinned above the list
// (ApolloSettingsPinnedPreview; tap the card to pin/unpin). Touch and hold a
// row to drag it into place; its switch hides it (and brings it back later).
// Model, item catalogue and persistence live in ApolloActionMenuLayout.h; the
// menus themselves read the saved layout in ApolloActionMenu.xm.
@interface ApolloActionMenuSettingsViewController : ApolloSettingsFormViewController
@end
