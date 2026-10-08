// The "Update available" sheet, styled like the What's New sheet (ApolloWhatsNew.xm):
// page sheet, plain background, the app icon, a large bold title and a full-width
// accent button. Two pages inside one sheet: the prompt, then a sideloader chooser
// that slides in from the right while the prompt fades out to the left.

#import <UIKit/UIKit.h>
#import "ApolloUpdateManifest.h"

NS_ASSUME_NONNULL_BEGIN

@interface ApolloUpdatePromptViewController : UIViewController

- (instancetype)initWithInfo:(ApolloUpdateInfo *)info
            installedVersion:(NSString *)installedVersion
                   offerSkip:(BOOL)offerSkip;

// Runs when the user picks "Skip This Version" (the sheet dismisses itself).
@property (nonatomic, copy, nullable) void (^onSkip)(void);

// Presents `presenter` -> this sheet with the same page-sheet setup What's New uses.
- (void)presentOverViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
