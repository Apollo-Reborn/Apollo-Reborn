#import "ApolloSettingsForm.h"

// The "Kagi Session Link" sheet: where the Search tab's Kagi mode gets the
// subscriber's Session Link (kagi.com → Settings → Account → Session Link).
// Shown when Kagi is picked with no link saved, and from the "Kagi Session
// Expired" card. Save checks the link with Kagi (one account-page request, not
// a search) before storing it (ApolloKagiSetSessionToken). The settings
// screen's Accounts & API Keys → Kagi Session Link field edits the same value.

NS_ASSUME_NONNULL_BEGIN

@interface ApolloKagiSessionLinkViewController : ApolloSettingsFormViewController
// Runs after a link Kagi accepted is saved and the sheet has closed.
@property (nonatomic, copy, nullable) void (^saved)(void);
@end

// Presents the sheet (in its own navigation controller) from the topmost
// controller above `presenter`. `saved` doesn't run on Cancel.
FOUNDATION_EXPORT void ApolloKagiPresentSessionLinkSheet(UIViewController *presenter, void (^_Nullable saved)(void));

NS_ASSUME_NONNULL_END
