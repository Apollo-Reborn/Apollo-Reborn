#import "ApolloSettingsForm.h"

__BEGIN_DECLS
static const NSUInteger ApolloSettingsShortcutLimit = 15;
UIImage *ApolloSettingsNativeShortcutImage(NSString *title);
UIViewController *ApolloSettingsNativeShortcutScreen(NSString *title);
NSArray<NSString *> *ApolloSettingsShortcutIDs(void);
NSArray<NSString *> *ApolloSettingsShortcutCatalog(void);
NSString *ApolloSettingsShortcutTitle(NSString *identifier);
UIImage *ApolloSettingsShortcutImage(NSString *identifier, UITraitCollection *traits, CGFloat size);
__END_DECLS

@interface ApolloSettingsShortcutsViewController : ApolloSettingsFormViewController
@end
