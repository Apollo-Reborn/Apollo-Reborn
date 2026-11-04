#import <UIKit/UIKit.h>

__BEGIN_DECLS
// Starts the one-time invitation independently of the layout's opt-in gate.
void ApolloIPadLayoutWelcomeStart(void);
// Replays the card without resetting the layout or the first-run marker.
void ApolloIPadLayoutWelcomePresentForDebug(UIViewController *presenter);
NSAttributedString *ApolloIPadLayoutBetaTitle(UIFont *font, UITraitCollection *traits);
__END_DECLS
