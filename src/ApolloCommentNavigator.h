#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloCommentNavigationMode) {
    ApolloCommentNavigationModeParentThreads = 0,
    ApolloCommentNavigationModeNewComments = 1,
};

__BEGIN_DECLS

// Both entry points edit the same persistent, app-wide navigation preference.
ApolloCommentNavigationMode ApolloCommentNavigatorMode(void);
void ApolloCommentNavigatorSetMode(ApolloCommentNavigationMode mode);

// Liquid Glass: the checked UIMenu at the settings row. Standard builds: the
// settings screens' shared action sheet. Never pushes a page.
void ApolloCommentNavigatorPresentModePicker(UIViewController *presenter,
                                              UIView *_Nullable sourceView);

// Called from the global presentation hooks. While the standard-build mode
// sheet is being reopened, swaps that ActionController's rows for the modes.
void ApolloCommentNavigatorPreparePresentation(UIViewController *controller);

__END_DECLS

NS_ASSUME_NONNULL_END
